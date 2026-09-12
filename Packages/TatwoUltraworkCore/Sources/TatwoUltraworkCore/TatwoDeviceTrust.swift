import CryptoKit
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Security)
import LocalAuthentication
import Security
#endif

public enum TatwoDeviceKeyStatusV1: String, Codable, Sendable {
  case active
  case revoked
}

public struct TatwoDevicePublicIdentityV1: Codable, Equatable, Sendable {
  public let schema: String
  public let algorithm: String
  public let deviceID: String
  public let keyID: String
  public let publicKey: String
  public let keyGeneration: UInt64
  public let keyStatus: TatwoDeviceKeyStatusV1
  public let pinnedAt: String

  public init(
    schema: String = "TatwoDevicePublicIdentityV1",
    algorithm: String = "Ed25519",
    deviceID: String,
    keyID: String,
    publicKey: String,
    keyGeneration: UInt64,
    keyStatus: TatwoDeviceKeyStatusV1,
    pinnedAt: String
  ) {
    self.schema = schema
    self.algorithm = algorithm
    self.deviceID = deviceID
    self.keyID = keyID
    self.publicKey = publicKey
    self.keyGeneration = keyGeneration
    self.keyStatus = keyStatus
    self.pinnedAt = pinnedAt
  }
}

public struct TatwoDeviceSignatureV1: Codable, Equatable, Sendable {
  public let schema: String
  public let algorithm: String
  public let purpose: String
  public let deviceID: String
  public let keyID: String
  public let keyGeneration: UInt64
  public let payloadDigest: String
  public let signedAt: String
  public let signature: String

  public init(
    schema: String = "TatwoDeviceSignatureV1",
    algorithm: String = "Ed25519",
    purpose: String,
    deviceID: String,
    keyID: String,
    keyGeneration: UInt64,
    payloadDigest: String,
    signedAt: String,
    signature: String
  ) {
    self.schema = schema
    self.algorithm = algorithm
    self.purpose = purpose
    self.deviceID = deviceID
    self.keyID = keyID
    self.keyGeneration = keyGeneration
    self.payloadDigest = payloadDigest
    self.signedAt = signedAt
    self.signature = signature
  }
}

public struct TatwoDeviceKeyRotationReceiptV1: Codable, Equatable, Sendable {
  public let schema: String
  public let deviceID: String
  public let oldKeyID: String
  public let oldKeyGeneration: UInt64
  public let newIdentity: TatwoDevicePublicIdentityV1
  public let rotatedAt: String
  /// Monotonic authority epoch for this rotation / re-enrollment event.
  public let authorityEpoch: UInt64
  /// When > 0, this is re-enrollment that supersedes a prior revocation epoch.
  /// Must be signed by an unrevoked authority identity (not the revoked key).
  public let supersedesRevocationEpoch: UInt64
  public let authorization: TatwoDeviceSignatureV1

  public init(
    schema: String = "TatwoDeviceKeyRotationReceiptV1",
    deviceID: String,
    oldKeyID: String,
    oldKeyGeneration: UInt64,
    newIdentity: TatwoDevicePublicIdentityV1,
    rotatedAt: String,
    authorityEpoch: UInt64,
    supersedesRevocationEpoch: UInt64 = 0,
    authorization: TatwoDeviceSignatureV1
  ) {
    self.schema = schema
    self.deviceID = deviceID
    self.oldKeyID = oldKeyID
    self.oldKeyGeneration = oldKeyGeneration
    self.newIdentity = newIdentity
    self.rotatedAt = rotatedAt
    self.authorityEpoch = authorityEpoch
    self.supersedesRevocationEpoch = supersedesRevocationEpoch
    self.authorization = authorization
  }

  public var isReEnrollment: Bool { supersedesRevocationEpoch > 0 }
}

public struct TatwoDeviceKeyRevocationReceiptV1: Codable, Equatable, Sendable {
  public let schema: String
  public let targetDeviceID: String
  public let targetKeyID: String
  public let targetKeyGeneration: UInt64
  public let authorizedByDeviceID: String
  public let authorizedByKeyID: String
  public let authorizedByKeyGeneration: UInt64
  public let authorityEpoch: UInt64
  public let reason: String
  public let revokedAt: String
  public let authorization: TatwoDeviceSignatureV1

  public init(
    schema: String = "TatwoDeviceKeyRevocationReceiptV1",
    targetDeviceID: String,
    targetKeyID: String,
    targetKeyGeneration: UInt64,
    authorizedByDeviceID: String,
    authorizedByKeyID: String,
    authorizedByKeyGeneration: UInt64,
    authorityEpoch: UInt64,
    reason: String,
    revokedAt: String,
    authorization: TatwoDeviceSignatureV1
  ) {
    self.schema = schema
    self.targetDeviceID = targetDeviceID
    self.targetKeyID = targetKeyID
    self.targetKeyGeneration = targetKeyGeneration
    self.authorizedByDeviceID = authorizedByDeviceID
    self.authorizedByKeyID = authorizedByKeyID
    self.authorizedByKeyGeneration = authorizedByKeyGeneration
    self.authorityEpoch = authorityEpoch
    self.reason = reason
    self.revokedAt = revokedAt
    self.authorization = authorization
  }
}

public enum TatwoDeviceTrustError: Error, Equatable, LocalizedError {
  case unavailable
  case timeout
  case interactionNotAllowed
  case keychain(Int32)
  case missingPrivateKey
  case duplicatePrivateKeyMismatch
  case invalidPrivateKey
  case invalidPublicKey
  case invalidIdentity
  case invalidSignature
  case inactiveKey
  case staleKeyGeneration
  case unsafeField(String)
  case invalidRotation
  case reEnrollmentRequiresAuthority
  case invalidRevocation
  case testStorageNotAuthorized
  /// Production refuses env overrides that relocate trust Keychain namespaces.
  case trustNamespaceOverrideForbidden(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "Device trust storage is unavailable."
    case .timeout:
      "Device trust Keychain operation timed out."
    case .interactionNotAllowed:
      "Device trust Keychain access is not authorized for this signer."
    case .keychain(let status):
      "Device trust Keychain error: \(status)."
    case .missingPrivateKey:
      "The local device private key is missing."
    case .duplicatePrivateKeyMismatch:
      "A different private key already exists for this device generation."
    case .invalidPrivateKey:
      "The local device private key is invalid."
    case .invalidPublicKey:
      "The pinned device public key is invalid."
    case .invalidIdentity:
      "The device trust identity is invalid."
    case .invalidSignature:
      "The device signature is invalid."
    case .inactiveKey:
      "The device key is not active."
    case .staleKeyGeneration:
      "The device signature uses a stale or unexpected key generation."
    case .unsafeField(let field):
      "The device trust field is empty or contains a control delimiter: \(field)."
    case .invalidRotation:
      "The device key rotation receipt is invalid."
    case .reEnrollmentRequiresAuthority:
      "Post-revocation re-enrollment requires an unrevoked authority signature."
    case .invalidRevocation:
      "The device key revocation receipt is invalid."
    case .testStorageNotAuthorized:
      "File-backed device private-key storage is restricted to explicit test mode."
    case .trustNamespaceOverrideForbidden(let envKey):
      "\(envKey) is only allowed when \(TatwoLoopJobChannelTrust.testModeEnvKey)=1."
    }
  }
}

public protocol TatwoDevicePrivateKeyStore: Sendable {
  func loadPrivateKey(deviceID: String, generation: UInt64) throws -> Data?
  func storePrivateKey(_ key: Data, deviceID: String, generation: UInt64) throws
}

private final class TatwoDeviceTrustResultBox<Value: Sendable>:
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

/// Production device private keys are retained in the local Keychain with a
/// ThisDeviceOnly accessibility class. Public identities and signed receipts
/// may be synchronized; raw private-key bytes may not.
public struct TatwoDeviceKeychainPrivateKeyStore: TatwoDevicePrivateKeyStore {
  public static let serviceEnvKey = "TATWO_DEVICE_TRUST_KEYCHAIN_SERVICE"
  public static let canonicalService = "ai.tatwo.ultrawork.device-trust"

  private static let readTimeoutSeconds: TimeInterval = 1
  private let service: String

  public static func configuration(
    environment: [String: String]
  ) throws -> String {
    let testMode = environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1"
    let configured =
      environment[serviceEnvKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let configured, !configured.isEmpty {
      guard testMode else {
        throw TatwoDeviceTrustError.trustNamespaceOverrideForbidden(serviceEnvKey)
      }
      return configured
    }
    return canonicalService
  }

  public init(service: String = TatwoDeviceKeychainPrivateKeyStore.canonicalService) {
    self.service = service
  }

  public func loadPrivateKey(
    deviceID: String,
    generation: UInt64
  ) throws -> Data? {
    #if canImport(Security)
    let account = try Self.account(deviceID: deviceID, generation: generation)
    let service = service
    let result = try Self.performWithTimeout(
      seconds: Self.readTimeoutSeconds
    ) {
      let context = LAContext()
      context.interactionNotAllowed = true
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationContext as String: context,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
      ]
      var value: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &value)
      return (status: Int32(status), data: value as? Data)
    }
    if result.status == errSecItemNotFound {
      return nil
    }
    if let error = Self.readError(for: result.status) {
      throw error
    }
    guard let data = result.data, data.count == 32 else {
      throw TatwoDeviceTrustError.invalidPrivateKey
    }
    return data
    #else
    throw TatwoDeviceTrustError.unavailable
    #endif
  }

  public func storePrivateKey(
    _ key: Data,
    deviceID: String,
    generation: UInt64
  ) throws {
    #if canImport(Security)
    guard key.count == 32 else {
      throw TatwoDeviceTrustError.invalidPrivateKey
    }
    if let existing = try loadPrivateKey(
      deviceID: deviceID,
      generation: generation)
    {
      guard existing == key else {
        throw TatwoDeviceTrustError.duplicatePrivateKeyMismatch
      }
      return
    }
    let account = try Self.account(deviceID: deviceID, generation: generation)
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: key,
      kSecAttrAccessible as String:
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecSuccess {
      return
    }
    if status == errSecDuplicateItem,
      let existing = try loadPrivateKey(
        deviceID: deviceID,
        generation: generation),
      existing == key
    {
      return
    }
    throw TatwoDeviceTrustError.keychain(Int32(status))
    #else
    throw TatwoDeviceTrustError.unavailable
    #endif
  }

  #if canImport(Security)
  static func readError(for status: Int32) -> TatwoDeviceTrustError? {
    if status == errSecSuccess || status == errSecItemNotFound {
      return nil
    }
    if status == errSecInteractionNotAllowed {
      return .interactionNotAllowed
    }
    return .keychain(status)
  }

  private static func performWithTimeout<Value: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () -> Value
  ) throws -> Value {
    let completed = DispatchSemaphore(value: 0)
    let result = TatwoDeviceTrustResultBox<Value>()
    DispatchQueue.global(qos: .userInitiated).async {
      result.store(operation())
      completed.signal()
    }
    guard completed.wait(timeout: .now() + max(seconds, 0.01)) == .success,
      let value = result.load()
    else {
      throw TatwoDeviceTrustError.timeout
    }
    return value
  }
  #endif

  private static func account(
    deviceID: String,
    generation: UInt64
  ) throws -> String {
    try validateField(deviceID, name: "deviceID")
    guard generation > 0 else {
      throw TatwoDeviceTrustError.invalidIdentity
    }
    return "\(deviceID):generation:\(generation)"
  }
}

/// This store exists only so integration tests can exercise real Ed25519
/// signing without reading or writing the user's Keychain. Construction requires
/// both an explicit caller authorization flag **and** `TATWO_TEST_MODE=1` in the
/// environment (caller Boolean alone is not sufficient).
public struct TatwoDeviceTestFilePrivateKeyStore: TatwoDevicePrivateKeyStore {
  private let rootURL: URL

  public init(
    rootURL: URL,
    testModeAuthorized: Bool,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    guard testModeAuthorized,
      environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1"
    else {
      throw TatwoDeviceTrustError.testStorageNotAuthorized
    }
    let canonicalRoot =
      rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let canonicalTemporaryRoot =
      FileManager.default.temporaryDirectory.standardizedFileURL
      .resolvingSymlinksInPath()
    guard canonicalRoot != canonicalTemporaryRoot,
      canonicalRoot.path.hasPrefix(canonicalTemporaryRoot.path + "/")
    else {
      throw TatwoDeviceTrustError.testStorageNotAuthorized
    }
    self.rootURL = canonicalRoot
  }

  public func loadPrivateKey(
    deviceID: String,
    generation: UInt64
  ) throws -> Data? {
    let url = try keyURL(deviceID: deviceID, generation: generation)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let data = try Data(contentsOf: url)
    guard data.count == 32 else {
      throw TatwoDeviceTrustError.invalidPrivateKey
    }
    return data
  }

  public func storePrivateKey(
    _ key: Data,
    deviceID: String,
    generation: UInt64
  ) throws {
    guard key.count == 32 else {
      throw TatwoDeviceTrustError.invalidPrivateKey
    }
    let url = try keyURL(deviceID: deviceID, generation: generation)
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: rootURL.path)
    if let existing = try loadPrivateKey(
      deviceID: deviceID,
      generation: generation)
    {
      guard existing == key else {
        throw TatwoDeviceTrustError.duplicatePrivateKeyMismatch
      }
      return
    }
    try Self.writePrivateKeyWithoutOverwrite(key, to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path)
  }

  private static func writePrivateKeyWithoutOverwrite(
    _ key: Data,
    to url: URL
  ) throws {
    #if canImport(Darwin)
    let descriptor = Darwin.open(
      url.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
      S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw posixError(path: url.path)
    }
    var descriptorIsOpen = true
    defer {
      if descriptorIsOpen {
        _ = Darwin.close(descriptor)
      }
    }
    try key.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        throw TatwoDeviceTrustError.invalidPrivateKey
      }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          rawBuffer.count - offset)
        if written < 0, errno == EINTR {
          continue
        }
        guard written > 0 else {
          throw posixError(path: url.path)
        }
        offset += written
      }
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw posixError(path: url.path)
    }
    guard Darwin.close(descriptor) == 0 else {
      throw posixError(path: url.path)
    }
    descriptorIsOpen = false
    #else
    try key.write(to: url, options: [.withoutOverwriting])
    #endif
  }

  private static func posixError(path: String) -> NSError {
    NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(errno),
      userInfo: [NSFilePathErrorKey: path])
  }

  private func keyURL(
    deviceID: String,
    generation: UInt64
  ) throws -> URL {
    try Self.validateFileToken(deviceID, field: "deviceID")
    guard generation > 0 else {
      throw TatwoDeviceTrustError.invalidIdentity
    }
    let url = rootURL.appendingPathComponent(
      "\(deviceID).generation-\(generation).ed25519-private",
      isDirectory: false)
    let canonicalParent =
      url.deletingLastPathComponent().standardizedFileURL
      .resolvingSymlinksInPath()
    guard canonicalParent.path == rootURL.path else {
      throw TatwoDeviceTrustError.invalidIdentity
    }
    return url
  }

  private static func validateFileToken(
    _ value: String,
    field: String
  ) throws {
    try validateField(value, name: field)
    guard value.range(
      of: #"^[A-Za-z0-9._:-]+$"#,
      options: .regularExpression) != nil
    else {
      throw TatwoDeviceTrustError.unsafeField(field)
    }
  }
}

public struct TatwoDeviceTrustAuthority: Sendable {
  private let privateKeyStore: any TatwoDevicePrivateKeyStore

  public init(privateKeyStore: any TatwoDevicePrivateKeyStore) {
    self.privateKeyStore = privateKeyStore
  }

  public func ensureIdentity(
    deviceID: String,
    generation: UInt64 = 1,
    pinnedAt: String
  ) throws -> TatwoDevicePublicIdentityV1 {
    try Self.validateIdentityInput(
      deviceID: deviceID,
      generation: generation,
      timestamp: pinnedAt)
    let privateKey: Curve25519.Signing.PrivateKey
    if let raw = try privateKeyStore.loadPrivateKey(
      deviceID: deviceID,
      generation: generation)
    {
      guard let loaded = try? Curve25519.Signing.PrivateKey(
        rawRepresentation: raw)
      else {
        throw TatwoDeviceTrustError.invalidPrivateKey
      }
      privateKey = loaded
    } else {
      let created = Curve25519.Signing.PrivateKey()
      try privateKeyStore.storePrivateKey(
        created.rawRepresentation,
        deviceID: deviceID,
        generation: generation)
      privateKey = created
    }
    return Self.identity(
      deviceID: deviceID,
      generation: generation,
      status: .active,
      pinnedAt: pinnedAt,
      publicKey: privateKey.publicKey.rawRepresentation)
  }

  public func assertLocalPrivateKey(
    matches identity: TatwoDevicePublicIdentityV1
  ) throws {
    try Self.validate(identity)
    guard let raw = try privateKeyStore.loadPrivateKey(
      deviceID: identity.deviceID,
      generation: identity.keyGeneration)
    else {
      throw TatwoDeviceTrustError.missingPrivateKey
    }
    guard let key = try? Curve25519.Signing.PrivateKey(
      rawRepresentation: raw)
    else {
      throw TatwoDeviceTrustError.invalidPrivateKey
    }
    guard key.publicKey.rawRepresentation
      == Data(base64Encoded: identity.publicKey)
    else {
      throw TatwoDeviceTrustError.invalidIdentity
    }
  }

  public func sign(
    payload: Data,
    purpose: String,
    identity: TatwoDevicePublicIdentityV1,
    signedAt: String
  ) throws -> TatwoDeviceSignatureV1 {
    try Self.validate(identity)
    guard identity.keyStatus == .active else {
      throw TatwoDeviceTrustError.inactiveKey
    }
    try validateField(purpose, name: "purpose")
    try validateField(signedAt, name: "signedAt")
    guard let raw = try privateKeyStore.loadPrivateKey(
      deviceID: identity.deviceID,
      generation: identity.keyGeneration)
    else {
      throw TatwoDeviceTrustError.missingPrivateKey
    }
    guard let key = try? Curve25519.Signing.PrivateKey(
      rawRepresentation: raw)
    else {
      throw TatwoDeviceTrustError.invalidPrivateKey
    }
    guard key.publicKey.rawRepresentation
      == Data(base64Encoded: identity.publicKey)
    else {
      throw TatwoDeviceTrustError.invalidIdentity
    }
    let digest = Self.sha256Hex(payload)
    let material = try Self.signatureMaterial(
      purpose: purpose,
      identity: identity,
      payloadDigest: digest,
      signedAt: signedAt)
    let signature = try key.signature(for: material)
    return TatwoDeviceSignatureV1(
      purpose: purpose,
      deviceID: identity.deviceID,
      keyID: identity.keyID,
      keyGeneration: identity.keyGeneration,
      payloadDigest: digest,
      signedAt: signedAt,
      signature: signature.base64EncodedString())
  }

  public static func verify(
    payload: Data,
    purpose: String,
    signature: TatwoDeviceSignatureV1,
    pinnedIdentity: TatwoDevicePublicIdentityV1
  ) throws {
    try validate(pinnedIdentity)
    guard pinnedIdentity.keyStatus == .active else {
      throw TatwoDeviceTrustError.inactiveKey
    }
    guard signature.schema == "TatwoDeviceSignatureV1",
      signature.algorithm == "Ed25519",
      signature.purpose == purpose,
      signature.deviceID == pinnedIdentity.deviceID,
      signature.keyID == pinnedIdentity.keyID
    else {
      throw TatwoDeviceTrustError.invalidSignature
    }
    guard signature.keyGeneration == pinnedIdentity.keyGeneration else {
      throw TatwoDeviceTrustError.staleKeyGeneration
    }
    let digest = sha256Hex(payload)
    guard signature.payloadDigest == digest else {
      throw TatwoDeviceTrustError.invalidSignature
    }
    guard let publicKeyData = Data(base64Encoded: pinnedIdentity.publicKey),
      publicKeyData.count == 32,
      let publicKey = try? Curve25519.Signing.PublicKey(
        rawRepresentation: publicKeyData),
      let signatureData = Data(base64Encoded: signature.signature),
      signatureData.count == 64
    else {
      throw TatwoDeviceTrustError.invalidSignature
    }
    let material = try signatureMaterial(
      purpose: purpose,
      identity: pinnedIdentity,
      payloadDigest: digest,
      signedAt: signature.signedAt)
    guard publicKey.isValidSignature(signatureData, for: material) else {
      throw TatwoDeviceTrustError.invalidSignature
    }
  }

  public func rotate(
    identity: TatwoDevicePublicIdentityV1,
    rotatedAt: String,
    authorityEpoch: UInt64? = nil
  ) throws -> (
    identity: TatwoDevicePublicIdentityV1,
    receipt: TatwoDeviceKeyRotationReceiptV1
  ) {
    try Self.validate(identity)
    guard identity.keyStatus == .active else {
      throw TatwoDeviceTrustError.inactiveKey
    }
    guard identity.keyGeneration < UInt64.max else {
      throw TatwoDeviceTrustError.invalidRotation
    }
    try validateField(rotatedAt, name: "rotatedAt")
    let newPrivateKey = Curve25519.Signing.PrivateKey()
    let newGeneration = identity.keyGeneration + 1
    let epoch = authorityEpoch ?? newGeneration
    guard epoch > 0 else {
      throw TatwoDeviceTrustError.invalidRotation
    }
    try privateKeyStore.storePrivateKey(
      newPrivateKey.rawRepresentation,
      deviceID: identity.deviceID,
      generation: newGeneration)
    let newIdentity = Self.identity(
      deviceID: identity.deviceID,
      generation: newGeneration,
      status: .active,
      pinnedAt: rotatedAt,
      publicKey: newPrivateKey.publicKey.rawRepresentation)
    let payload = try Self.rotationPayloadData(
      deviceID: identity.deviceID,
      oldKeyID: identity.keyID,
      oldKeyGeneration: identity.keyGeneration,
      newIdentity: newIdentity,
      rotatedAt: rotatedAt,
      authorityEpoch: epoch,
      supersedesRevocationEpoch: 0)
    let authorization = try sign(
      payload: payload,
      purpose: "device-key-rotation",
      identity: identity,
      signedAt: rotatedAt)
    return (
      newIdentity,
      TatwoDeviceKeyRotationReceiptV1(
        deviceID: identity.deviceID,
        oldKeyID: identity.keyID,
        oldKeyGeneration: identity.keyGeneration,
        newIdentity: newIdentity,
        rotatedAt: rotatedAt,
        authorityEpoch: epoch,
        supersedesRevocationEpoch: 0,
        authorization: authorization)
    )
  }

  /// Authorize re-enrollment of a device after revocation.
  /// Must be signed by an unrevoked authority identity — never the revoked key.
  public func authorizeReEnrollment(
    oldIdentity: TatwoDevicePublicIdentityV1,
    newIdentity: TatwoDevicePublicIdentityV1,
    authorizedBy authorizerIdentity: TatwoDevicePublicIdentityV1,
    authorityEpoch: UInt64,
    supersedesRevocationEpoch: UInt64,
    rotatedAt: String
  ) throws -> TatwoDeviceKeyRotationReceiptV1 {
    try Self.validate(oldIdentity)
    try Self.validate(newIdentity)
    try Self.validate(authorizerIdentity)
    guard oldIdentity.keyStatus == .revoked || oldIdentity.keyStatus == .active,
      authorizerIdentity.keyStatus == .active,
      authorityEpoch > 0,
      supersedesRevocationEpoch > 0,
      authorityEpoch > supersedesRevocationEpoch,
      newIdentity.deviceID == oldIdentity.deviceID,
      newIdentity.keyGeneration == oldIdentity.keyGeneration + 1,
      newIdentity.keyStatus == .active,
      newIdentity.pinnedAt == rotatedAt,
      authorizerIdentity.keyID != oldIdentity.keyID
        || authorizerIdentity.publicKey != oldIdentity.publicKey
        || authorizerIdentity.deviceID != oldIdentity.deviceID
    else {
      throw TatwoDeviceTrustError.invalidRotation
    }
    // Revoked key material must never authorize its own resurrection.
    if authorizerIdentity.deviceID == oldIdentity.deviceID,
      authorizerIdentity.keyID == oldIdentity.keyID,
      authorizerIdentity.publicKey == oldIdentity.publicKey
    {
      throw TatwoDeviceTrustError.reEnrollmentRequiresAuthority
    }
    try validateField(rotatedAt, name: "rotatedAt")
    let payload = try Self.rotationPayloadData(
      deviceID: oldIdentity.deviceID,
      oldKeyID: oldIdentity.keyID,
      oldKeyGeneration: oldIdentity.keyGeneration,
      newIdentity: newIdentity,
      rotatedAt: rotatedAt,
      authorityEpoch: authorityEpoch,
      supersedesRevocationEpoch: supersedesRevocationEpoch)
    let authorization = try sign(
      payload: payload,
      purpose: "device-key-rotation",
      identity: authorizerIdentity,
      signedAt: rotatedAt)
    return TatwoDeviceKeyRotationReceiptV1(
      deviceID: oldIdentity.deviceID,
      oldKeyID: oldIdentity.keyID,
      oldKeyGeneration: oldIdentity.keyGeneration,
      newIdentity: newIdentity,
      rotatedAt: rotatedAt,
      authorityEpoch: authorityEpoch,
      supersedesRevocationEpoch: supersedesRevocationEpoch,
      authorization: authorization)
  }

  public static func verifyRotation(
    _ receipt: TatwoDeviceKeyRotationReceiptV1,
    oldIdentity: TatwoDevicePublicIdentityV1,
    authorizingIdentity: TatwoDevicePublicIdentityV1? = nil
  ) throws {
    try validate(oldIdentity)
    try validate(receipt.newIdentity)
    guard receipt.schema == "TatwoDeviceKeyRotationReceiptV1",
      receipt.deviceID == oldIdentity.deviceID,
      receipt.oldKeyID == oldIdentity.keyID,
      receipt.oldKeyGeneration == oldIdentity.keyGeneration,
      receipt.newIdentity.deviceID == oldIdentity.deviceID,
      receipt.newIdentity.keyGeneration == oldIdentity.keyGeneration + 1,
      receipt.newIdentity.keyStatus == .active,
      receipt.newIdentity.pinnedAt == receipt.rotatedAt,
      receipt.authorityEpoch > 0
    else {
      throw TatwoDeviceTrustError.invalidRotation
    }

    let payload = try rotationPayloadData(
      deviceID: receipt.deviceID,
      oldKeyID: receipt.oldKeyID,
      oldKeyGeneration: receipt.oldKeyGeneration,
      newIdentity: receipt.newIdentity,
      rotatedAt: receipt.rotatedAt,
      authorityEpoch: receipt.authorityEpoch,
      supersedesRevocationEpoch: receipt.supersedesRevocationEpoch)

    if receipt.isReEnrollment {
      guard let authorizer = authorizingIdentity,
        authorizer.keyStatus == .active,
        receipt.supersedesRevocationEpoch > 0,
        receipt.authorityEpoch > receipt.supersedesRevocationEpoch
      else {
        throw TatwoDeviceTrustError.reEnrollmentRequiresAuthority
      }
      // Fail closed: revoked (or same compromised) key cannot re-enroll itself.
      if authorizer.deviceID == oldIdentity.deviceID,
        authorizer.keyID == oldIdentity.keyID,
        authorizer.publicKey == oldIdentity.publicKey
      {
        throw TatwoDeviceTrustError.reEnrollmentRequiresAuthority
      }
      do {
        try verify(
          payload: payload,
          purpose: "device-key-rotation",
          signature: receipt.authorization,
          pinnedIdentity: authorizer)
      } catch {
        throw TatwoDeviceTrustError.invalidRotation
      }
      return
    }

    // Normal rotation: prior key must still be active and must self-sign.
    guard oldIdentity.keyStatus == .active,
      receipt.supersedesRevocationEpoch == 0
    else {
      throw TatwoDeviceTrustError.reEnrollmentRequiresAuthority
    }
    do {
      try verify(
        payload: payload,
        purpose: "device-key-rotation",
        signature: receipt.authorization,
        pinnedIdentity: oldIdentity)
    } catch {
      throw TatwoDeviceTrustError.invalidRotation
    }
  }

  public func revoke(
    targetIdentity: TatwoDevicePublicIdentityV1,
    authorizedBy authorizerIdentity: TatwoDevicePublicIdentityV1,
    authorityEpoch: UInt64,
    reason: String,
    revokedAt: String
  ) throws -> (
    identity: TatwoDevicePublicIdentityV1,
    receipt: TatwoDeviceKeyRevocationReceiptV1
  ) {
    try Self.validate(targetIdentity)
    try Self.validate(authorizerIdentity)
    guard targetIdentity.keyStatus == .active,
      authorizerIdentity.keyStatus == .active,
      authorityEpoch > 0
    else {
      throw TatwoDeviceTrustError.invalidRevocation
    }
    try validateField(reason, name: "reason")
    try validateField(revokedAt, name: "revokedAt")
    let payload = try Self.revocationPayloadData(
      targetIdentity: targetIdentity,
      authorizerIdentity: authorizerIdentity,
      authorityEpoch: authorityEpoch,
      reason: reason,
      revokedAt: revokedAt)
    let authorization = try sign(
      payload: payload,
      purpose: "device-key-revocation",
      identity: authorizerIdentity,
      signedAt: revokedAt)
    let revokedIdentity = TatwoDevicePublicIdentityV1(
      deviceID: targetIdentity.deviceID,
      keyID: targetIdentity.keyID,
      publicKey: targetIdentity.publicKey,
      keyGeneration: targetIdentity.keyGeneration,
      keyStatus: .revoked,
      pinnedAt: targetIdentity.pinnedAt)
    let receipt = TatwoDeviceKeyRevocationReceiptV1(
      targetDeviceID: targetIdentity.deviceID,
      targetKeyID: targetIdentity.keyID,
      targetKeyGeneration: targetIdentity.keyGeneration,
      authorizedByDeviceID: authorizerIdentity.deviceID,
      authorizedByKeyID: authorizerIdentity.keyID,
      authorizedByKeyGeneration: authorizerIdentity.keyGeneration,
      authorityEpoch: authorityEpoch,
      reason: reason,
      revokedAt: revokedAt,
      authorization: authorization)
    return (revokedIdentity, receipt)
  }

  public static func verifyRevocation(
    _ receipt: TatwoDeviceKeyRevocationReceiptV1,
    targetIdentity: TatwoDevicePublicIdentityV1,
    authorizerIdentity: TatwoDevicePublicIdentityV1,
    expectedAuthorityEpoch: UInt64
  ) throws {
    try validate(targetIdentity)
    try validate(authorizerIdentity)
    guard receipt.schema == "TatwoDeviceKeyRevocationReceiptV1",
      targetIdentity.keyStatus == .active,
      authorizerIdentity.keyStatus == .active,
      receipt.targetDeviceID == targetIdentity.deviceID,
      receipt.targetKeyID == targetIdentity.keyID,
      receipt.targetKeyGeneration == targetIdentity.keyGeneration,
      receipt.authorizedByDeviceID == authorizerIdentity.deviceID,
      receipt.authorizedByKeyID == authorizerIdentity.keyID,
      receipt.authorizedByKeyGeneration == authorizerIdentity.keyGeneration,
      receipt.authorityEpoch == expectedAuthorityEpoch,
      expectedAuthorityEpoch > 0
    else {
      throw TatwoDeviceTrustError.invalidRevocation
    }
    let payload = try revocationPayloadData(
      targetIdentity: targetIdentity,
      authorizerIdentity: authorizerIdentity,
      authorityEpoch: receipt.authorityEpoch,
      reason: receipt.reason,
      revokedAt: receipt.revokedAt)
    do {
      try verify(
        payload: payload,
        purpose: "device-key-revocation",
        signature: receipt.authorization,
        pinnedIdentity: authorizerIdentity)
    } catch {
      throw TatwoDeviceTrustError.invalidRevocation
    }
  }

  private static func identity(
    deviceID: String,
    generation: UInt64,
    status: TatwoDeviceKeyStatusV1,
    pinnedAt: String,
    publicKey: Data
  ) -> TatwoDevicePublicIdentityV1 {
    let keyDigest = sha256Hex(publicKey)
    return TatwoDevicePublicIdentityV1(
      deviceID: deviceID,
      keyID: "ed25519-\(keyDigest)",
      publicKey: publicKey.base64EncodedString(),
      keyGeneration: generation,
      keyStatus: status,
      pinnedAt: pinnedAt)
  }

  private static func validate(
    _ identity: TatwoDevicePublicIdentityV1
  ) throws {
    guard identity.schema == "TatwoDevicePublicIdentityV1",
      identity.algorithm == "Ed25519",
      identity.keyGeneration > 0
    else {
      throw TatwoDeviceTrustError.invalidIdentity
    }
    try validateIdentityInput(
      deviceID: identity.deviceID,
      generation: identity.keyGeneration,
      timestamp: identity.pinnedAt)
    try validateField(identity.keyID, name: "keyID")
    guard let publicKey = Data(base64Encoded: identity.publicKey),
      publicKey.count == 32,
      (try? Curve25519.Signing.PublicKey(
        rawRepresentation: publicKey)) != nil,
      identity.keyID == "ed25519-\(sha256Hex(publicKey))"
    else {
      throw TatwoDeviceTrustError.invalidPublicKey
    }
  }

  private static func validateIdentityInput(
    deviceID: String,
    generation: UInt64,
    timestamp: String
  ) throws {
    try validateField(deviceID, name: "deviceID")
    try validateField(timestamp, name: "timestamp")
    guard generation > 0 else {
      throw TatwoDeviceTrustError.invalidIdentity
    }
  }

  private static func signatureMaterial(
    purpose: String,
    identity: TatwoDevicePublicIdentityV1,
    payloadDigest: String,
    signedAt: String
  ) throws -> Data {
    try validateField(purpose, name: "purpose")
    try validateField(signedAt, name: "signedAt")
    return Data(
      [
        "TatwoDeviceSignatureV1",
        purpose,
        identity.deviceID,
        identity.keyID,
        String(identity.keyGeneration),
        payloadDigest,
        signedAt,
      ].joined(separator: "\n").utf8)
  }

  private struct RotationPayload: Codable {
    let deviceID: String
    let oldKeyID: String
    let oldKeyGeneration: UInt64
    let newIdentity: TatwoDevicePublicIdentityV1
    let rotatedAt: String
    let authorityEpoch: UInt64
    let supersedesRevocationEpoch: UInt64
  }

  private static func rotationPayloadData(
    deviceID: String,
    oldKeyID: String,
    oldKeyGeneration: UInt64,
    newIdentity: TatwoDevicePublicIdentityV1,
    rotatedAt: String,
    authorityEpoch: UInt64,
    supersedesRevocationEpoch: UInt64
  ) throws -> Data {
    try canonicalJSON(
      RotationPayload(
        deviceID: deviceID,
        oldKeyID: oldKeyID,
        oldKeyGeneration: oldKeyGeneration,
        newIdentity: newIdentity,
        rotatedAt: rotatedAt,
        authorityEpoch: authorityEpoch,
        supersedesRevocationEpoch: supersedesRevocationEpoch))
  }

  private struct RevocationPayload: Codable {
    let targetDeviceID: String
    let targetKeyID: String
    let targetKeyGeneration: UInt64
    let authorizedByDeviceID: String
    let authorizedByKeyID: String
    let authorizedByKeyGeneration: UInt64
    let authorityEpoch: UInt64
    let reason: String
    let revokedAt: String
  }

  private static func revocationPayloadData(
    targetIdentity: TatwoDevicePublicIdentityV1,
    authorizerIdentity: TatwoDevicePublicIdentityV1,
    authorityEpoch: UInt64,
    reason: String,
    revokedAt: String
  ) throws -> Data {
    try canonicalJSON(
      RevocationPayload(
        targetDeviceID: targetIdentity.deviceID,
        targetKeyID: targetIdentity.keyID,
        targetKeyGeneration: targetIdentity.keyGeneration,
        authorizedByDeviceID: authorizerIdentity.deviceID,
        authorizedByKeyID: authorizerIdentity.keyID,
        authorizedByKeyGeneration: authorizerIdentity.keyGeneration,
        authorityEpoch: authorityEpoch,
        reason: reason,
        revokedAt: revokedAt))
  }

  private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private func validateField(_ value: String, name: String) throws {
  guard !value.isEmpty,
    !value.contains("\n"),
    !value.contains("\r"),
    !value.contains("\0")
  else {
    throw TatwoDeviceTrustError.unsafeField(name)
  }
}
