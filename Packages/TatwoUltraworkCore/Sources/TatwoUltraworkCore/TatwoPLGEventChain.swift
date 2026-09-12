import CryptoKit
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Security)
import Security
import LocalAuthentication
#endif

public protocol TatwoPLGAnchorAuthority: Sendable {
  func sign(_ material: String) throws -> String
  func verify(_ signature: String, material: String) throws -> Bool
}

public enum TatwoPLGAnchorError: Error, Equatable, LocalizedError {
  case unavailable
  case timeout
  case keychain(OSStatus)
  case invalidKeyMaterial

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "PLG host anchor authority unavailable."
    case .timeout:
      "PLG host anchor Keychain operation timed out."
    case .keychain(let status):
      "PLG host anchor Keychain error: \(status)."
    case .invalidKeyMaterial:
      "PLG host anchor key material is invalid."
    }
  }
}

private final class TatwoPLGKeychainResultBox<Value: Sendable>:
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

/// The anchor secret is generated and retained by the OS Keychain. It is never
/// serialized with the PLG projection or event chain.
public struct TatwoPLGKeychainAnchorAuthority: TatwoPLGAnchorAuthority {
  private static let readTimeoutSeconds: TimeInterval = 1
  private static let writeTimeoutSeconds: TimeInterval = 1
  private let service: String
  private let account: String

  static func configuration(
    environment: [String: String]
  ) -> (service: String, account: String) {
    let service =
      environment["TATWO_ULTRAWORK_PLG_ANCHOR_SERVICE"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let account =
      environment["TATWO_ULTRAWORK_PLG_ANCHOR_ACCOUNT"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (
      service: service.flatMap { $0.isEmpty ? nil : $0 }
        ?? "ai.tatwo.ultrawork.plg-chain-anchor",
      account: account.flatMap { $0.isEmpty ? nil : $0 }
        ?? "local-host-v1")
  }

  #if canImport(Security)
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
    ]
  }

  static func addQuery(
    service: String,
    account: String,
    key: Data
  ) -> [String: Any] {
    let context = LAContext()
    context.interactionNotAllowed = true
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: key,
      kSecAttrAccessible as String:
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecUseAuthenticationContext as String: context,
    ]
  }

  static func performWithTimeout<Value: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () -> Value
  ) throws -> Value {
    let completed = DispatchSemaphore(value: 0)
    let result = TatwoPLGKeychainResultBox<Value>()
    DispatchQueue.global(qos: .userInitiated).async {
      result.store(operation())
      completed.signal()
    }
    guard completed.wait(timeout: .now() + max(seconds, 0.01)) == .success,
      let value = result.load()
    else {
      throw TatwoPLGAnchorError.timeout
    }
    return value
  }
  #endif

  public init(
    service: String = "ai.tatwo.ultrawork.plg-chain-anchor",
    account: String = "local-host-v1"
  ) {
    self.service = service
    self.account = account
  }

  public func sign(_ material: String) throws -> String {
    let key = try keyData(createIfMissing: true)
    let code = HMAC<SHA256>.authenticationCode(
      for: Data(material.utf8),
      using: SymmetricKey(data: key))
    return Data(code).map { String(format: "%02x", $0) }.joined()
  }

  public func verify(_ signature: String, material: String) throws -> Bool {
    guard signature.count == 64 else { return false }
    let key = try keyData(createIfMissing: false)
    let code = HMAC<SHA256>.authenticationCode(
      for: Data(material.utf8),
      using: SymmetricKey(data: key))
    let expected = Data(code).map { String(format: "%02x", $0) }.joined()
    return constantTimeEqual(signature, expected)
  }

  private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices {
      difference |= left[index] ^ right[index]
    }
    return difference == 0
  }

  private func keyData(createIfMissing: Bool) throws -> Data {
    #if canImport(Security)
    let service = service
    let account = account
    let read = try Self.performWithTimeout(
      seconds: Self.readTimeoutSeconds
    ) {
      let query = Self.readQuery(service: service, account: account)
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      return (status: status, data: result as? Data)
    }
    let status = read.status
    if status == errSecSuccess {
      guard let data = read.data, data.count == 32 else {
        throw TatwoPLGAnchorError.invalidKeyMaterial
      }
      return data
    }
    guard status == errSecItemNotFound, createIfMissing else {
      throw TatwoPLGAnchorError.keychain(status)
    }

    var bytes = [UInt8](repeating: 0, count: 32)
    let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard randomStatus == errSecSuccess else {
      throw TatwoPLGAnchorError.keychain(randomStatus)
    }
    let key = Data(bytes)
    let addStatus = try Self.performWithTimeout(
      seconds: Self.writeTimeoutSeconds
    ) {
      let add = Self.addQuery(
        service: service,
        account: account,
        key: key)
      return SecItemAdd(add as CFDictionary, nil)
    }
    if addStatus == errSecSuccess {
      return key
    }
    if addStatus == errSecDuplicateItem {
      return try keyData(createIfMissing: false)
    }
    throw TatwoPLGAnchorError.keychain(addStatus)
    #else
    throw TatwoPLGAnchorError.unavailable
    #endif
  }
}

/// Runs a source-pinned, ad-hoc-signed helper whose binary identity stays
/// stable across App rebuilds. Key material remains inside the helper process;
/// the App only sends anchor material over stdin and receives a 64-byte hex MAC.
public struct TatwoPLGHelperAnchorAuthority: TatwoPLGAnchorAuthority {
  public static let productionRelativePath =
    "Contents/Helpers/TatwoPLGAnchorHelper"
  public static let productionExecutableSHA256InfoKey =
    "TatwoPLGAnchorHelperSHA256"

  public static func productionExecutableSHA256(
    infoDictionary: [String: Any]?
  ) -> String? {
    guard let raw = infoDictionary?[productionExecutableSHA256InfoKey]
      as? String
    else {
      return nil
    }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.range(
      of: "^[0-9a-f]{64}$",
      options: .regularExpression) != nil
    else {
      return nil
    }
    return value
  }

  private let helperURL: URL
  private let timeoutSeconds: TimeInterval
  private let expectedExecutableSHA256: String?
  private let environmentOverrides: [String: String]
  private static let executableDigestCache = TatwoPLGExecutableDigestCache()

  public init(
    helperURL: URL,
    timeoutSeconds: TimeInterval = 3,
    expectedExecutableSHA256: String? = nil,
    environmentOverrides: [String: String] = [:]
  ) {
    self.helperURL = helperURL
    self.timeoutSeconds = timeoutSeconds
    self.expectedExecutableSHA256 = expectedExecutableSHA256
    self.environmentOverrides = environmentOverrides
  }

  private static func posixUserHome() -> String? {
    #if canImport(Darwin)
    guard let password = Darwin.getpwuid(Darwin.getuid()),
      let homePointer = password.pointee.pw_dir
    else {
      return nil
    }
    let home = String(cString: homePointer)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard home.hasPrefix("/"), home != "/" else { return nil }
    return home
    #else
    return nil
    #endif
  }

  public func sign(_ material: String) throws -> String {
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
      throw TatwoPLGAnchorError.unavailable
    }
    guard material.utf8.count <= 64 * 1024 else {
      throw TatwoPLGAnchorError.unavailable
    }
    if let expectedExecutableSHA256 {
      guard Self.executableDigestCache.sha256(for: helperURL)
        == expectedExecutableSHA256
      else {
        throw TatwoPLGAnchorError.unavailable
      }
    }

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errorOutput = Pipe()
    let completed = DispatchSemaphore(value: 0)
    let inputCompleted = DispatchSemaphore(value: 0)
    let inputSucceeded = TatwoPLGKeychainResultBox<Bool>()
    process.executableURL = helperURL
    guard let posixUserHome = Self.posixUserHome() else {
      throw TatwoPLGAnchorError.unavailable
    }
    var helperEnvironment = ProcessInfo.processInfo.environment
    helperEnvironment["HOME"] = posixUserHome
    for (key, value) in environmentOverrides {
      helperEnvironment[key] = value
    }
    process.environment = helperEnvironment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errorOutput
    process.terminationHandler = { _ in completed.signal() }
    #if canImport(Darwin)
    guard Darwin.fcntl(
      input.fileHandleForWriting.fileDescriptor,
      F_SETNOSIGPIPE,
      1) == 0
    else {
      throw TatwoPLGAnchorError.unavailable
    }
    #endif

    do {
      try process.run()
    } catch {
      if process.isRunning { process.terminate() }
      throw TatwoPLGAnchorError.unavailable
    }
    let inputData = Data(material.utf8)
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try input.fileHandleForWriting.write(contentsOf: inputData)
        try input.fileHandleForWriting.close()
        inputSucceeded.store(true)
      } catch {
        try? input.fileHandleForWriting.close()
        inputSucceeded.store(false)
      }
      inputCompleted.signal()
    }

    guard completed.wait(
      timeout: .now() + max(timeoutSeconds, 0.01)
    ) == .success else {
      if process.isRunning {
        process.terminate()
        if completed.wait(timeout: .now() + 0.15) != .success {
          #if canImport(Darwin)
          Darwin.kill(process.processIdentifier, SIGKILL)
          #endif
        }
      }
      throw TatwoPLGAnchorError.timeout
    }
    guard inputCompleted.wait(timeout: .now() + 0.15) == .success,
      inputSucceeded.load() == true
    else {
      throw TatwoPLGAnchorError.unavailable
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    _ = errorOutput.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0,
      let signature = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      signature.count == 64,
      signature.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      })
    else {
      throw TatwoPLGAnchorError.unavailable
    }
    return signature
  }

  public func verify(_ signature: String, material: String) throws -> Bool {
    guard signature.count == 64 else { return false }
    let expected = try sign(material)
    let left = Array(signature.utf8)
    let right = Array(expected.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices {
      difference |= left[index] ^ right[index]
    }
    return difference == 0
  }
}

private final class TatwoPLGExecutableDigestCache: @unchecked Sendable {
  private struct Entry {
    let modificationDate: Date
    let fileSize: UInt64
    let digest: String
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]

  func sha256(for url: URL) -> String? {
    guard let values = try? url.resourceValues(
      forKeys: [.contentModificationDateKey, .fileSizeKey]),
      let modificationDate = values.contentModificationDate,
      let fileSize = values.fileSize
    else {
      return nil
    }
    let path = url.standardizedFileURL.path
    lock.lock()
    if let cached = entries[path],
       cached.modificationDate == modificationDate,
       cached.fileSize == UInt64(fileSize)
    {
      lock.unlock()
      return cached.digest
    }
    lock.unlock()

    guard let data = try? Data(contentsOf: url) else { return nil }
    let digest = Data(SHA256.hash(data: data)).map {
      String(format: "%02x", $0)
    }.joined()

    lock.lock()
    entries[path] = Entry(
      modificationDate: modificationDate,
      fileSize: UInt64(fileSize),
      digest: digest)
    lock.unlock()
    return digest
  }
}

public struct TatwoPLGChainSeedRecord: Codable, Sendable, Equatable {
  public let schema: String
  public let contractID: String
  public let goalID: String
  public let runID: UUID
  public let run: TatwoPLGRun
  public let seedHash: String
  public let anchorMAC: String

  public init(
    schema: String = "TatwoPLGChainSeedV1",
    contractID: String,
    goalID: String,
    runID: UUID,
    run: TatwoPLGRun,
    seedHash: String,
    anchorMAC: String
  ) {
    self.schema = schema
    self.contractID = contractID
    self.goalID = goalID
    self.runID = runID
    self.run = run
    self.seedHash = seedHash
    self.anchorMAC = anchorMAC
  }
}

public struct TatwoPLGEventEnvelope: Codable, Sendable, Equatable {
  public let schema: String
  public let contractID: String
  public let goalID: String
  public let runID: UUID
  public let revision: Int
  public let eventID: UUID
  public let previousHash: String
  public let payloadHash: String
  public let event: TatwoPLGEvent
  public let envelopeHash: String
  public let anchorMAC: String

  public init(
    schema: String = "TatwoPLGEventEnvelopeV1",
    contractID: String,
    goalID: String,
    runID: UUID,
    revision: Int,
    eventID: UUID,
    previousHash: String,
    payloadHash: String,
    event: TatwoPLGEvent,
    envelopeHash: String,
    anchorMAC: String
  ) {
    self.schema = schema
    self.contractID = contractID
    self.goalID = goalID
    self.runID = runID
    self.revision = revision
    self.eventID = eventID
    self.previousHash = previousHash
    self.payloadHash = payloadHash
    self.event = event
    self.envelopeHash = envelopeHash
    self.anchorMAC = anchorMAC
  }
}

public struct TatwoPLGReplayResult: Sendable, Equatable {
  public let run: TatwoPLGRun
  public let appliedEventIDs: Set<UUID>
  public let headHash: String

  public init(
    run: TatwoPLGRun,
    appliedEventIDs: Set<UUID>,
    headHash: String
  ) {
    self.run = run
    self.appliedEventIDs = appliedEventIDs
    self.headHash = headHash
  }
}

struct TatwoPLGChainLine: Codable {
  enum Kind: String, Codable {
    case seed
    case event
  }

  let kind: Kind
  let seed: TatwoPLGChainSeedRecord?
  let event: TatwoPLGEventEnvelope?

  static func seed(_ record: TatwoPLGChainSeedRecord) -> Self {
    Self(kind: .seed, seed: record, event: nil)
  }

  static func event(_ record: TatwoPLGEventEnvelope) -> Self {
    Self(kind: .event, seed: nil, event: record)
  }
}
