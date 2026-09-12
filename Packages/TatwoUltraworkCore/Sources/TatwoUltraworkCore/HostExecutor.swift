import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum TatwoHostActionKind: String, Codable, Sendable, CaseIterable, Hashable {
  case readFile = "read_file"
  case writeFile = "write_file"
  case runCommand = "run_command"
  case computerUse = "computer_use"
  case rollback
}

public struct TatwoHumanGateIssuerArtifactIdentityV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let bundleIdentifier: String
  public let teamIdentifier: String?
  public let codeDirectoryHash: String
  public let executableSHA256: String

  public init(
    schema: String = "TatwoHumanGateIssuerArtifactIdentityV1",
    bundleIdentifier: String,
    teamIdentifier: String?,
    codeDirectoryHash: String,
    executableSHA256: String
  ) {
    self.schema = schema
    self.bundleIdentifier = bundleIdentifier
    self.teamIdentifier = teamIdentifier
    self.codeDirectoryHash = codeDirectoryHash
    self.executableSHA256 = executableSHA256
  }

  fileprivate var canonicalValue: String {
    [
      schema,
      bundleIdentifier,
      teamIdentifier ?? "ad-hoc",
      codeDirectoryHash,
      executableSHA256,
    ].joined(separator: "\n")
  }
}

public enum TatwoGoalRevisionIssuerArtifactPolicy {
  public static let productionBundleIdentifier = "com.tatwo.ultrawork"
  public static let stagingBundleIdentifierPrefix =
    "com.tatwo.ultrawork.staging.s"

  public static func acceptsBundleIdentifier(_ value: String) -> Bool {
    value == productionBundleIdentifier
      || isIsolatedStagingBundleIdentifier(value)
  }

  public static func isIsolatedStagingBundleIdentifier(
    _ value: String
  ) -> Bool {
    guard value.hasPrefix(stagingBundleIdentifierPrefix) else {
      return false
    }
    let suffix = value.dropFirst(stagingBundleIdentifierPrefix.count)
    let components = suffix.split(
      separator: ".",
      omittingEmptySubsequences: false)
    guard components.count == 2 else { return false }
    let stamp = components[0]
    let token = components[1]
    guard stamp.count == 16,
      stamp[stamp.index(stamp.startIndex, offsetBy: 8)] == "T",
      stamp.last == "Z",
      stamp.prefix(8).allSatisfy(\.isNumber),
      stamp.dropFirst(9).dropLast().allSatisfy(\.isNumber),
      token.count == 8,
      token.allSatisfy({ "0123456789abcdef".contains($0) })
    else {
      return false
    }
    return true
  }
}

public struct TatwoHumanGateReceiptV1: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let id: String
  public let issuerDomain: String
  public let sessionID: String
  public let oldContractID: String
  public let oldGoalID: String
  public let newContractID: String
  public let newGoalID: String
  public let subjectDigest: String
  public let issuedAt: Date
  public let expiresAt: Date
  public let nonce: String
  public let proofDigest: String
  public let issuerArtifactIdentity:
    TatwoHumanGateIssuerArtifactIdentityV1?
  public let bootstrapRecoveryEvidence:
    TatwoGoalRevisionBootstrapRecoveryEvidenceV1?

  public init(
    schema: String = "TatwoHumanGateReceiptV1",
    id: String,
    issuerDomain: String,
    sessionID: String,
    oldContractID: String,
    oldGoalID: String,
    newContractID: String,
    newGoalID: String,
    subjectDigest: String,
    issuedAt: Date,
    expiresAt: Date,
    nonce: String,
    proofDigest: String,
    issuerArtifactIdentity:
      TatwoHumanGateIssuerArtifactIdentityV1? = nil,
    bootstrapRecoveryEvidence:
      TatwoGoalRevisionBootstrapRecoveryEvidenceV1? = nil
  ) {
    self.schema = schema
    self.id = id
    self.issuerDomain = issuerDomain
    self.sessionID = sessionID
    self.oldContractID = oldContractID
    self.oldGoalID = oldGoalID
    self.newContractID = newContractID
    self.newGoalID = newGoalID
    self.subjectDigest = subjectDigest
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.nonce = nonce
    self.proofDigest = proofDigest
    self.issuerArtifactIdentity = issuerArtifactIdentity
    self.bootstrapRecoveryEvidence = bootstrapRecoveryEvidence
  }

  var signingPayload: Data {
    if issuerDomain == TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain,
      let bootstrapRecoveryEvidence
    {
      return Data(
        [
          "TatwoHumanGateBootstrapRecoverySigningPayloadV1",
          schema,
          id,
          issuerDomain,
          sessionID,
          oldContractID,
          oldGoalID,
          newContractID,
          newGoalID,
          subjectDigest,
          String(Int64(issuedAt.timeIntervalSince1970)),
          String(Int64(expiresAt.timeIntervalSince1970)),
          nonce,
          bootstrapRecoveryEvidence.canonicalValue,
        ].joined(separator: "\n").utf8)
    }
    return Data(
      [
        schema,
        id,
        issuerDomain,
        sessionID,
        oldContractID,
        oldGoalID,
        newContractID,
        newGoalID,
        subjectDigest,
        String(Int64(issuedAt.timeIntervalSince1970)),
        String(Int64(expiresAt.timeIntervalSince1970)),
        nonce,
        issuerArtifactIdentity?.canonicalValue ?? "missing-artifact-identity",
      ].joined(separator: "\n").utf8)
  }
}

public enum TatwoHumanGateVerificationError:
  Error, LocalizedError, Sendable, Equatable
{
  case unavailable
  case testDomainRejected
  case invalid(String)
  case expired
  case signatureRejected
  case consumptionConflict

  public var errorDescription: String? {
    switch self {
    case .unavailable: "human_gate_unavailable"
    case .testDomainRejected: "human_gate_test_domain_rejected"
    case .invalid(let field): "human_gate_invalid:\(field)"
    case .expired: "human_gate_expired"
    case .signatureRejected: "human_gate_signature_rejected"
    case .consumptionConflict: "human_gate_consumption_conflict"
    }
  }
}

public protocol TatwoHumanGateVerifying: Sendable {
  func verify(
    receipt: TatwoHumanGateReceiptV1,
    subjectDigest: String,
    now: Date
  ) throws
}

public struct TatwoHumanGateAuthorizationConsumptionV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let receiptID: String
  public let issuerDomain: String
  public let subjectDigest: String
  public let consumedAt: Date
  public let receiptProofDigest: String

  public init(
    schema: String = "TatwoHumanGateAuthorizationConsumptionV1",
    receiptID: String,
    issuerDomain: String,
    subjectDigest: String,
    consumedAt: Date,
    receiptProofDigest: String
  ) {
    self.schema = schema
    self.receiptID = receiptID
    self.issuerDomain = issuerDomain
    self.subjectDigest = subjectDigest
    self.consumedAt = consumedAt
    self.receiptProofDigest = receiptProofDigest
  }
}

/// App-only integration surface. The App calls this only after its visible
/// human-confirmation UI succeeds. CLI and MCP intentionally expose no issuer.
///
/// The private Ed25519 key remains in the local state root with mode 0600. This
/// provides durable provenance and tamper detection across processes/restarts;
/// the same-user userland authority limit still applies.
@_spi(TatwoHumanGateApp)
public struct TatwoAppHumanGateAuthorizationStore: Sendable {
  public static let issuerDomain = "app.tatwo.ultrawork.human-gate"

  public let stateDirectoryURL: URL
  public let receiptStore: TatwoHumanGateReceiptStore

  public init(stateDirectoryURL: URL) {
    self.stateDirectoryURL = stateDirectoryURL
    self.receiptStore = TatwoHumanGateReceiptStore(
      directoryURL: stateDirectoryURL.appendingPathComponent(
        "human-gate-receipts", isDirectory: true))
  }

  @discardableResult
  public func authorizeAfterHumanConfirmation(
    id: String,
    sessionID: String,
    oldContractID: String,
    oldGoalID: String,
    newContractID: String,
    newGoalID: String,
    subjectDigest: String,
    issuerArtifactIdentity:
      TatwoHumanGateIssuerArtifactIdentityV1,
    ttl: TimeInterval = 10 * 60,
    now: Date = Date()
  ) throws -> TatwoHumanGateReceiptV1 {
    let issuedAt = Self.wholeSecond(now)
    let expiresAt = Self.wholeSecond(
      issuedAt.addingTimeInterval(max(60, min(ttl, 30 * 60))))
    let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedID.isEmpty,
      !normalizedID.contains("/"),
      !normalizedID.contains(".."),
      !sessionID.isEmpty,
      !oldContractID.isEmpty,
      !oldGoalID.isEmpty,
      !newContractID.isEmpty,
      !newGoalID.isEmpty,
      subjectDigest.hasPrefix("sha256:"),
      Self.validIssuerArtifactIdentity(issuerArtifactIdentity)
    else {
      throw TatwoHumanGateVerificationError.invalid("authorization")
    }
    return try TatwoFileLock.withExclusiveLock(for: authorityLockURL) {
      let privateKey = try loadOrCreatePrivateKey()
      if FileManager.default.fileExists(
        atPath: receiptStore.url(for: normalizedID).path)
      {
        let existing = try receiptStore.require(id: normalizedID)
        guard existing.schema == "TatwoHumanGateReceiptV1",
          existing.id == normalizedID,
          existing.issuerDomain == Self.issuerDomain,
          existing.sessionID == sessionID,
          existing.oldContractID == oldContractID,
          existing.oldGoalID == oldGoalID,
          existing.newContractID == newContractID,
          existing.newGoalID == newGoalID,
          existing.subjectDigest == subjectDigest,
          existing.issuerArtifactIdentity == issuerArtifactIdentity,
          Self.isValidSignature(
            existing.proofDigest,
            payload: existing.signingPayload,
            publicKey: privateKey.publicKey)
        else {
          throw TatwoHumanGateVerificationError.consumptionConflict
        }
        return existing
      }
      let unsigned = TatwoHumanGateReceiptV1(
        id: normalizedID,
        issuerDomain: Self.issuerDomain,
        sessionID: sessionID,
        oldContractID: oldContractID,
        oldGoalID: oldGoalID,
        newContractID: newContractID,
        newGoalID: newGoalID,
        subjectDigest: subjectDigest,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
        nonce: UUID().uuidString.lowercased(),
        proofDigest: "",
        issuerArtifactIdentity: issuerArtifactIdentity)
      let signature = try privateKey.signature(for: unsigned.signingPayload)
      let receipt = TatwoHumanGateReceiptV1(
        id: unsigned.id,
        issuerDomain: unsigned.issuerDomain,
        sessionID: unsigned.sessionID,
        oldContractID: unsigned.oldContractID,
        oldGoalID: unsigned.oldGoalID,
        newContractID: unsigned.newContractID,
        newGoalID: unsigned.newGoalID,
        subjectDigest: unsigned.subjectDigest,
        issuedAt: unsigned.issuedAt,
        expiresAt: unsigned.expiresAt,
        nonce: unsigned.nonce,
      proofDigest: "ed25519:\(signature.base64EncodedString())",
        issuerArtifactIdentity: unsigned.issuerArtifactIdentity,
        bootstrapRecoveryEvidence: unsigned.bootstrapRecoveryEvidence)
      try receiptStore.persistAuthorized(receipt)
      return receipt
    }
  }

  private var authorityDirectoryURL: URL {
    stateDirectoryURL.appendingPathComponent(
      "human-gate-authority", isDirectory: true)
  }

  private var privateKeyURL: URL {
    authorityDirectoryURL.appendingPathComponent("app-private-key")
  }

  private var publicKeyURL: URL {
    authorityDirectoryURL.appendingPathComponent("app-public-key")
  }

  private var authorityLockURL: URL {
    authorityDirectoryURL.appendingPathComponent("authority")
  }

  private func loadOrCreatePrivateKey() throws
    -> Curve25519.Signing.PrivateKey
  {
    try FileManager.default.createDirectory(
      at: authorityDirectoryURL, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: privateKeyURL.path) {
      let key = try Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(contentsOf: privateKeyURL))
      try requireMatchingPublicKey(key.publicKey)
      return key
    }
    let key = Curve25519.Signing.PrivateKey()
    let created = try TatwoHumanGateCreateOnlyFile.write(
      key.rawRepresentation, to: privateKeyURL)
    guard created else {
      let existing = try Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(contentsOf: privateKeyURL))
      try requireMatchingPublicKey(existing.publicKey)
      return existing
    }
    try persistPublicKey(key.publicKey)
    return key
  }

  private func requireMatchingPublicKey(
    _ publicKey: Curve25519.Signing.PublicKey
  ) throws {
    guard FileManager.default.fileExists(atPath: publicKeyURL.path) else {
      try persistPublicKey(publicKey)
      return
    }
    guard try Data(contentsOf: publicKeyURL) == publicKey.rawRepresentation else {
      throw TatwoHumanGateVerificationError.signatureRejected
    }
  }

  private func persistPublicKey(
    _ publicKey: Curve25519.Signing.PublicKey
  ) throws {
    let created = try TatwoHumanGateCreateOnlyFile.write(
      publicKey.rawRepresentation, to: publicKeyURL)
    if created { return }
    guard try Data(contentsOf: publicKeyURL) == publicKey.rawRepresentation else {
      throw TatwoHumanGateVerificationError.signatureRejected
    }
  }

  private static func wholeSecond(_ value: Date) -> Date {
    Date(timeIntervalSince1970: value.timeIntervalSince1970.rounded(.down))
  }

  private static func validIssuerArtifactIdentity(
    _ identity: TatwoHumanGateIssuerArtifactIdentityV1
  ) -> Bool {
    identity.schema == "TatwoHumanGateIssuerArtifactIdentityV1"
      && TatwoGoalRevisionIssuerArtifactPolicy.acceptsBundleIdentifier(
        identity.bundleIdentifier)
      && !identity.codeDirectoryHash.isEmpty
      && !identity.executableSHA256.isEmpty
  }

  fileprivate static func isValidSignature(
    _ proofDigest: String,
    payload: Data,
    publicKey: Curve25519.Signing.PublicKey
  ) -> Bool {
    guard proofDigest.hasPrefix("ed25519:"),
      let signature = Data(
        base64Encoded: String(proofDigest.dropFirst("ed25519:".count))),
      signature.count == 64
    else {
      return false
    }
    return publicKey.isValidSignature(signature, for: payload)
  }

  fileprivate func signAppAuthorizationPayload(_ payload: Data) throws
    -> String
  {
    let privateKey = try loadOrCreatePrivateKey()
    let signature = try privateKey.signature(for: payload)
    return "ed25519:\(signature.base64EncodedString())"
  }
}

/// Production verifier for App-issued human authorization. Verification is
/// cryptographic and records an idempotent durable consume marker before any
/// Goal revision mutation begins.
struct TatwoProductionHumanGateVerifier: TatwoHumanGateVerifying {
  let stateDirectoryURL: URL
  private let bootstrapRecoveryTrustAnchorProvider:
    any TatwoBootstrapRecoveryTrustAnchorProviding

  init(stateDirectoryURL: URL) {
    self.init(
      stateDirectoryURL: stateDirectoryURL,
      bootstrapRecoveryTrustAnchorProvider:
        TatwoRootOwnedBootstrapRecoveryGrantProvider())
  }

  init(
    stateDirectoryURL: URL,
    bootstrapRecoveryTrustAnchorProvider:
      any TatwoBootstrapRecoveryTrustAnchorProviding
  ) {
    self.stateDirectoryURL = stateDirectoryURL
    self.bootstrapRecoveryTrustAnchorProvider =
      bootstrapRecoveryTrustAnchorProvider
  }

  func verify(
    receipt: TatwoHumanGateReceiptV1,
    subjectDigest: String,
    now: Date
  ) throws {
    try validate(
      receipt: receipt,
      subjectDigest: subjectDigest,
      now: now)
    try persistConsumption(
      TatwoHumanGateAuthorizationConsumptionV1(
        receiptID: receipt.id,
        issuerDomain: receipt.issuerDomain,
        subjectDigest: subjectDigest,
        consumedAt: now,
        receiptProofDigest: receipt.proofDigest))
  }

  func validate(
    receipt: TatwoHumanGateReceiptV1,
    subjectDigest: String,
    now: Date
  ) throws {
    if receipt.issuerDomain.hasPrefix("test.") {
      throw TatwoHumanGateVerificationError.testDomainRejected
    }
    if receipt.issuerDomain
      == TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain
    {
      try TatwoGoalRevisionBootstrapRecoveryIssuer(
        stateDirectoryURL: stateDirectoryURL,
        trustAnchorProvider: bootstrapRecoveryTrustAnchorProvider
      ).validatePersistedReceipt(
        receipt,
        subjectDigest: subjectDigest,
        now: now)
      return
    }
    let artifactBundleIdentifierIsAccepted =
      receipt.issuerArtifactIdentity.map {
        TatwoGoalRevisionIssuerArtifactPolicy.acceptsBundleIdentifier(
          $0.bundleIdentifier)
      } ?? false
    guard receipt.schema == "TatwoHumanGateReceiptV1",
      receipt.issuerDomain == TatwoAppHumanGateAuthorizationStore.issuerDomain,
      receipt.issuerArtifactIdentity?.schema
        == "TatwoHumanGateIssuerArtifactIdentityV1",
      artifactBundleIdentifierIsAccepted,
      receipt.issuerArtifactIdentity?.codeDirectoryHash.isEmpty == false,
      receipt.issuerArtifactIdentity?.executableSHA256.isEmpty == false,
      receipt.subjectDigest == subjectDigest,
      receipt.issuedAt <= now,
      receipt.expiresAt > receipt.issuedAt
    else {
      throw TatwoHumanGateVerificationError.invalid("receipt")
    }
    guard receipt.expiresAt > now else {
      throw TatwoHumanGateVerificationError.expired
    }
    let publicKeyURL = stateDirectoryURL
      .appendingPathComponent("human-gate-authority", isDirectory: true)
      .appendingPathComponent("app-public-key")
    guard FileManager.default.fileExists(atPath: publicKeyURL.path),
      let publicKey = try? Curve25519.Signing.PublicKey(
        rawRepresentation: Data(contentsOf: publicKeyURL)),
      TatwoAppHumanGateAuthorizationStore.isValidSignature(
        receipt.proofDigest,
        payload: receipt.signingPayload,
        publicKey: publicKey)
    else {
      throw TatwoHumanGateVerificationError.signatureRejected
    }
  }

  func requireConsumed(
    receipt: TatwoHumanGateReceiptV1,
    subjectDigest: String
  ) throws {
    let url = consumptionURL(receiptID: receipt.id)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoHumanGateVerificationError.unavailable
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let consumption = try decoder.decode(
      TatwoHumanGateAuthorizationConsumptionV1.self,
      from: Data(contentsOf: url))
    guard consumption.schema == "TatwoHumanGateAuthorizationConsumptionV1",
      consumption.receiptID == receipt.id,
      consumption.issuerDomain == receipt.issuerDomain,
      consumption.subjectDigest == subjectDigest,
      consumption.receiptProofDigest == receipt.proofDigest
    else {
      throw TatwoHumanGateVerificationError.consumptionConflict
    }
  }

  private func persistConsumption(
    _ consumption: TatwoHumanGateAuthorizationConsumptionV1
  ) throws {
    let url = consumptionURL(receiptID: consumption.receiptID)
    try TatwoFileLock.withExclusiveLock(for: url) {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      if FileManager.default.fileExists(atPath: url.path) {
        let existing = try decoder.decode(
          TatwoHumanGateAuthorizationConsumptionV1.self,
          from: Data(contentsOf: url))
        guard existing.receiptID == consumption.receiptID,
          existing.issuerDomain == consumption.issuerDomain,
          existing.subjectDigest == consumption.subjectDigest,
          existing.receiptProofDigest == consumption.receiptProofDigest
        else {
          throw TatwoHumanGateVerificationError.consumptionConflict
        }
        return
      }
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      guard try TatwoHumanGateCreateOnlyFile.write(
        encoder.encode(consumption), to: url)
      else {
        let existing = try decoder.decode(
          TatwoHumanGateAuthorizationConsumptionV1.self,
          from: Data(contentsOf: url))
        guard existing.receiptID == consumption.receiptID,
          existing.issuerDomain == consumption.issuerDomain,
          existing.subjectDigest == consumption.subjectDigest,
          existing.receiptProofDigest == consumption.receiptProofDigest
        else {
          throw TatwoHumanGateVerificationError.consumptionConflict
        }
        return
      }
    }
  }

  private func consumptionURL(receiptID: String) -> URL {
    stateDirectoryURL
      .appendingPathComponent(
        "human-gate-authority/consumptions", isDirectory: true)
      .appendingPathComponent(
        "\(TatwoLoopPathComponent.sanitize(receiptID)).json")
  }
}

enum TatwoHumanGateCreateOnlyFile {
  /// Security-relevant authorization/key artifacts are create-only. Returning
  /// false means another writer already committed the final path.
  static func write(_ data: Data, to url: URL) throws -> Bool {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    if descriptor < 0 {
      if errno == EEXIST { return false }
      throw TatwoHumanGateVerificationError.invalid(
        "create_only:\(errno)")
    }
    var committed = false
    defer {
      close(descriptor)
      if !committed {
        unlink(url.path)
      }
    }
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var written = 0
      while written < rawBuffer.count {
        let count = DarwinOrGlibcWrite.write(
          descriptor,
          base.advanced(by: written),
          rawBuffer.count - written)
        if count < 0 {
          if errno == EINTR { continue }
          throw TatwoHumanGateVerificationError.invalid(
            "create_only_write:\(errno)")
        }
        written += count
      }
    }
    guard fsync(descriptor) == 0 else {
      throw TatwoHumanGateVerificationError.invalid(
        "create_only_fsync:\(errno)")
    }
    committed = true
    return true
  }
}

private enum DarwinOrGlibcWrite {
  static func write(
    _ descriptor: Int32,
    _ buffer: UnsafeRawPointer,
    _ count: Int
  ) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
    #else
    Glibc.write(descriptor, buffer, count)
    #endif
  }
}

public struct TatwoHumanGateReceiptStore: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL) { self.directoryURL = directoryURL }

  func url(for id: String) -> URL {
    directoryURL.appendingPathComponent("\(id).json")
  }

  public func require(id: String) throws -> TatwoHumanGateReceiptV1 {
    let safeID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !safeID.isEmpty, !safeID.contains("/"), !safeID.contains("..") else {
      throw TatwoHumanGateVerificationError.invalid("id")
    }
    let url = url(for: safeID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoHumanGateVerificationError.invalid("missing")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
      TatwoHumanGateReceiptV1.self, from: Data(contentsOf: url))
  }

  func persistFixture(_ receipt: TatwoHumanGateReceiptV1) throws {
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(receipt).write(
      to: directoryURL.appendingPathComponent("\(receipt.id).json"),
      options: [.atomic])
  }

  func persistAuthorized(
    _ receipt: TatwoHumanGateReceiptV1
  ) throws {
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let url = directoryURL.appendingPathComponent("\(receipt.id).json")
    let encoded = try encoder.encode(receipt)
    if try !TatwoHumanGateCreateOnlyFile.write(encoded, to: url) {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      guard try decoder.decode(
        TatwoHumanGateReceiptV1.self,
        from: Data(contentsOf: url)) == receipt
      else {
        throw TatwoHumanGateVerificationError.consumptionConflict
      }
      return
    }
  }
}

/// One-time authorization for only the revision activation transaction. It can
/// never be presented to Host Executor as permission to mutate the host.
public struct TatwoGoalRevisionPromotionAuthorizationV1:
  Codable, Sendable, Equatable, Identifiable
{
  public let schema: String
  public let id: String
  public let issuerDomain: String
  public let sessionID: String
  public let oldPointerRevisionDigest: String
  public let oldPointerGeneration: UInt64
  public let oldContractID: String
  public let oldGoalID: String
  public let oldGoalRevision: UInt64
  public let oldObjectiveDigest: String
  public let newContractID: String
  public let newGoalID: String
  public let newGoalRevision: UInt64
  public let newObjectiveDigest: String
  public let topologyDigest: String
  public let capabilityDigest: String
  public let humanGateReceiptID: String
  public let requestedHostScopeDigest: String
  public let oldReceiptsDigest: String?
  public let oldActivationEpoch: UInt64?
  public let bootstrapRecoveryContextDigest: String?
  public let issuedAt: Date
  public let expiresAt: Date
  public let nonce: String
  public let proofDigest: String

  public init(
    schema: String = "TatwoGoalRevisionPromotionAuthorizationV1",
    id: String,
    issuerDomain: String,
    sessionID: String,
    oldPointerRevisionDigest: String,
    oldPointerGeneration: UInt64,
    oldContractID: String,
    oldGoalID: String,
    oldGoalRevision: UInt64,
    oldObjectiveDigest: String,
    newContractID: String,
    newGoalID: String,
    newGoalRevision: UInt64,
    newObjectiveDigest: String,
    topologyDigest: String,
    capabilityDigest: String,
    humanGateReceiptID: String,
    requestedHostScopeDigest: String,
    issuedAt: Date,
    expiresAt: Date,
    nonce: String,
    proofDigest: String,
    oldReceiptsDigest: String? = nil,
    oldActivationEpoch: UInt64? = nil,
    bootstrapRecoveryContextDigest: String? = nil
  ) {
    self.schema = schema
    self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
    self.issuerDomain = issuerDomain
    self.sessionID = sessionID
    self.oldPointerRevisionDigest = oldPointerRevisionDigest
    self.oldPointerGeneration = oldPointerGeneration
    self.oldContractID = oldContractID
    self.oldGoalID = oldGoalID
    self.oldGoalRevision = oldGoalRevision
    self.oldObjectiveDigest = oldObjectiveDigest
    self.newContractID = newContractID
    self.newGoalID = newGoalID
    self.newGoalRevision = newGoalRevision
    self.newObjectiveDigest = newObjectiveDigest
    self.topologyDigest = topologyDigest
    self.capabilityDigest = capabilityDigest
    self.humanGateReceiptID = humanGateReceiptID
    self.requestedHostScopeDigest = requestedHostScopeDigest
    self.oldReceiptsDigest = oldReceiptsDigest
    self.oldActivationEpoch = oldActivationEpoch
    self.bootstrapRecoveryContextDigest = bootstrapRecoveryContextDigest
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.nonce = nonce.trimmingCharacters(in: .whitespacesAndNewlines)
    self.proofDigest = proofDigest
  }

  public static func objectiveDigest(_ objective: String) -> String {
    digest(TatwoObjectiveIdentity.make(objective).objectiveHash)
  }

  public static func canonicalWorkspacePath(_ path: String) -> String {
    URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
  }

  public static func workspaceDigest(_ path: String) -> String {
    digest(canonicalWorkspacePath(path))
  }

  public static func topologyDigest(
    sessionID: String,
    oldContractID: String,
    oldGoalID: String,
    newContractID: String,
    newGoalID: String
  ) -> String {
    digest([
      sessionID, oldContractID, oldGoalID, newContractID, newGoalID,
    ].joined(separator: "\n"))
  }

  public static func capabilityDigest(
    oldBindingsDigest: String?,
    newBindingsDigest: String?
  ) -> String {
    digest([
      oldBindingsDigest ?? "missing",
      newBindingsDigest ?? "missing",
    ].joined(separator: "\n"))
  }

  public static func receiptsDigest(
    _ receipts: [TatwoStoredReceipt]
  ) -> String {
    var stream = "TatwoStoredReceiptSnapshotV1"
    for receipt in receipts.sorted(by: {
      let lhs = [
        $0.receiptID,
        $0.kind,
        $0.loopID ?? "none",
        String(Int64($0.submittedAt.timeIntervalSince1970)),
      ]
      let rhs = [
        $1.receiptID,
        $1.kind,
        $1.loopID ?? "none",
        String(Int64($1.submittedAt.timeIntervalSince1970)),
      ]
      return lhs.lexicographicallyPrecedes(rhs)
    }) {
      for value in [
        receipt.schema,
        receipt.receiptID,
        receipt.kind,
        receipt.loopID ?? "none",
        String(Int64(receipt.submittedAt.timeIntervalSince1970)),
      ] {
        stream += "|\(value.utf8.count):\(value)"
      }
    }
    return digest(stream)
  }

  public var humanGateSubjectDigest: String {
    var fields = [
      sessionID, oldPointerRevisionDigest, String(oldPointerGeneration),
      oldContractID, oldGoalID, String(oldGoalRevision), oldObjectiveDigest,
      newContractID, newGoalID, String(newGoalRevision), newObjectiveDigest,
      topologyDigest, capabilityDigest, requestedHostScopeDigest,
    ]
    if issuerDomain == TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain {
      fields.append(oldReceiptsDigest ?? "missing")
      fields.append(oldActivationEpoch.map(String.init) ?? "missing")
      fields.append(bootstrapRecoveryContextDigest ?? "missing")
    }
    return Self.digest(fields.joined(separator: "\n"))
  }

  static func digest(_ value: String) -> String { digest(Data(value.utf8)) }

  static func digest(_ data: Data) -> String {
    let bytes = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(bytes)"
  }
}

public enum TatwoGoalRevisionPromotionAuthorizationError:
  Error, LocalizedError, Sendable, Equatable
{
  case missing
  case invalid
  case expired
  case conflict
  case scopeMismatch(String)

  public var errorDescription: String? {
    switch self {
    case .missing: "revision_promotion_authorization_missing"
    case .invalid: "revision_promotion_authorization_invalid"
    case .expired: "revision_promotion_authorization_expired"
    case .conflict: "revision_promotion_authorization_conflict"
    case .scopeMismatch(let field):
      "revision_promotion_authorization_scope_mismatch:\(field)"
    }
  }
}

public struct TatwoGoalRevisionPromotionAuthorizationStore: Sendable {
  public let directoryURL: URL
  public init(directoryURL: URL) { self.directoryURL = directoryURL }

  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    let state = TatwoGoalRunStore.default(environment: environment).directoryURL
    return Self(directoryURL: state.appendingPathComponent(
      "goal-revision-authorizations", isDirectory: true))
  }

  /// App-only issuer. CLI and MCP intentionally remain consume-only.
  ///
  /// The signed human-gate receipt is the authority anchor. Promotion fields
  /// are exact, expiry cannot outlive that receipt, and persistence is
  /// create-only with byte-for-byte idempotency.
  @_spi(TatwoHumanGateApp)
  @discardableResult
  public func authorizeAfterHumanConfirmation(
    id: String,
    sessionID: String,
    oldPointerRevisionDigest: String,
    oldPointerGeneration: UInt64,
    oldContractID: String,
    oldGoalID: String,
    oldGoalRevision: UInt64,
    oldObjectiveDigest: String,
    newContractID: String,
    newGoalID: String,
    newGoalRevision: UInt64,
    newObjectiveDigest: String,
    topologyDigest: String,
    capabilityDigest: String,
    humanGateReceipt: TatwoHumanGateReceiptV1,
    requestedHostScopeDigest: String,
    ttl: TimeInterval = 10 * 60,
    now: Date = Date()
  ) throws -> TatwoGoalRevisionPromotionAuthorizationV1 {
    let safeID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    let exactStrings = [
      sessionID, oldContractID, oldGoalID, newContractID, newGoalID,
      humanGateReceipt.id,
    ]
    let exactDigests = [
      oldPointerRevisionDigest, oldObjectiveDigest, newObjectiveDigest,
      topologyDigest, capabilityDigest, requestedHostScopeDigest,
    ]
    guard !safeID.isEmpty,
      !safeID.contains("/"),
      !safeID.contains(".."),
      exactStrings.allSatisfy(Self.isExactNonEmpty),
      Self.isExactNonEmpty(humanGateReceipt.nonce),
      exactDigests.allSatisfy(Self.isSHA256Digest),
      oldPointerGeneration > 0,
      oldGoalRevision > 0,
      oldGoalRevision < UInt64.max,
      newGoalRevision == oldGoalRevision + 1,
      oldContractID != newContractID,
      oldGoalID != newGoalID,
      ttl.isFinite,
      ttl > 0
    else {
      throw TatwoGoalRevisionPromotionAuthorizationError.invalid
    }

    let issuedAt = Self.wholeSecond(humanGateReceipt.issuedAt)
    let expiresAt = min(
      humanGateReceipt.expiresAt,
      issuedAt.addingTimeInterval(max(60, min(ttl, 30 * 60))))
    guard issuedAt <= now, expiresAt > now, expiresAt > issuedAt else {
      throw TatwoGoalRevisionPromotionAuthorizationError.expired
    }

    let nonceSeed = [
      humanGateReceipt.id,
      humanGateReceipt.nonce,
      humanGateReceipt.proofDigest,
      safeID,
      sessionID,
      oldPointerRevisionDigest,
      newContractID,
      newGoalID,
      requestedHostScopeDigest,
    ].joined(separator: "\n")
    let nonce = "promotion-\(Self.sha256Hex(nonceSeed))"
    let unsigned = TatwoGoalRevisionPromotionAuthorizationV1(
      id: safeID,
      issuerDomain: TatwoAppHumanGateAuthorizationStore.issuerDomain,
      sessionID: sessionID,
      oldPointerRevisionDigest: oldPointerRevisionDigest,
      oldPointerGeneration: oldPointerGeneration,
      oldContractID: oldContractID,
      oldGoalID: oldGoalID,
      oldGoalRevision: oldGoalRevision,
      oldObjectiveDigest: oldObjectiveDigest,
      newContractID: newContractID,
      newGoalID: newGoalID,
      newGoalRevision: newGoalRevision,
      newObjectiveDigest: newObjectiveDigest,
      topologyDigest: topologyDigest,
      capabilityDigest: capabilityDigest,
      humanGateReceiptID: humanGateReceipt.id,
      requestedHostScopeDigest: requestedHostScopeDigest,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      nonce: nonce,
      proofDigest: "")
    guard humanGateReceipt.schema == "TatwoHumanGateReceiptV1",
      humanGateReceipt.issuerDomain
        == TatwoAppHumanGateAuthorizationStore.issuerDomain,
      humanGateReceipt.sessionID == sessionID,
      humanGateReceipt.oldContractID == oldContractID,
      humanGateReceipt.oldGoalID == oldGoalID,
      humanGateReceipt.newContractID == newContractID,
      humanGateReceipt.newGoalID == newGoalID,
      humanGateReceipt.subjectDigest == unsigned.humanGateSubjectDigest
    else {
      throw TatwoGoalRevisionPromotionAuthorizationError.scopeMismatch(
        "human_gate_receipt")
    }

    let stateDirectoryURL = directoryURL.deletingLastPathComponent()
    let persistedReceipt = try TatwoHumanGateReceiptStore(
      directoryURL: stateDirectoryURL.appendingPathComponent(
        "human-gate-receipts", isDirectory: true)
    ).require(id: humanGateReceipt.id)
    guard persistedReceipt == humanGateReceipt else {
      throw TatwoGoalRevisionPromotionAuthorizationError.scopeMismatch(
        "human_gate_receipt_bytes")
    }
    try TatwoProductionHumanGateVerifier(
      stateDirectoryURL: stateDirectoryURL
    ).validate(
      receipt: humanGateReceipt,
      subjectDigest: unsigned.humanGateSubjectDigest,
      now: now)

    let authorization = TatwoGoalRevisionPromotionAuthorizationV1(
      id: unsigned.id,
      issuerDomain: unsigned.issuerDomain,
      sessionID: unsigned.sessionID,
      oldPointerRevisionDigest: unsigned.oldPointerRevisionDigest,
      oldPointerGeneration: unsigned.oldPointerGeneration,
      oldContractID: unsigned.oldContractID,
      oldGoalID: unsigned.oldGoalID,
      oldGoalRevision: unsigned.oldGoalRevision,
      oldObjectiveDigest: unsigned.oldObjectiveDigest,
      newContractID: unsigned.newContractID,
      newGoalID: unsigned.newGoalID,
      newGoalRevision: unsigned.newGoalRevision,
      newObjectiveDigest: unsigned.newObjectiveDigest,
      topologyDigest: unsigned.topologyDigest,
      capabilityDigest: unsigned.capabilityDigest,
      humanGateReceiptID: unsigned.humanGateReceiptID,
      requestedHostScopeDigest: unsigned.requestedHostScopeDigest,
      issuedAt: unsigned.issuedAt,
      expiresAt: unsigned.expiresAt,
      nonce: unsigned.nonce,
      proofDigest: Self.proofDigest(for: unsigned))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(authorization)
    let url = directoryURL.appendingPathComponent("\(safeID).json")
    return try TatwoFileLock.withExclusiveLock(for: url) {
      if FileManager.default.fileExists(atPath: url.path) {
        guard try Data(contentsOf: url) == encoded else {
          throw TatwoGoalRevisionPromotionAuthorizationError.conflict
        }
        return authorization
      }
      guard try TatwoHumanGateCreateOnlyFile.write(encoded, to: url) else {
        guard try Data(contentsOf: url) == encoded else {
          throw TatwoGoalRevisionPromotionAuthorizationError.conflict
        }
        return authorization
      }
      return authorization
    }
  }

  public func require(
    id: String, now: Date = Date()
  ) throws -> TatwoGoalRevisionPromotionAuthorizationV1 {
    let authorization = try requireActivated(id: id)
    guard authorization.issuedAt <= now,
      authorization.expiresAt > now
    else {
      throw TatwoGoalRevisionPromotionAuthorizationError.expired
    }
    return authorization
  }

  /// Verifies a promotion authorization as historical activation evidence.
  /// The short expiry gates the transition; a later Host operation separately
  /// proves that the completed transition occurred inside this window.
  func requireActivated(
    id: String
  ) throws -> TatwoGoalRevisionPromotionAuthorizationV1 {
    let safeID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !safeID.isEmpty, !safeID.contains("/"), !safeID.contains("..") else {
      throw TatwoGoalRevisionPromotionAuthorizationError.invalid
    }
    let url = directoryURL.appendingPathComponent("\(safeID).json")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoGoalRevisionPromotionAuthorizationError.missing
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let authorization: TatwoGoalRevisionPromotionAuthorizationV1
    do {
      authorization = try decoder.decode(
        TatwoGoalRevisionPromotionAuthorizationV1.self,
        from: Data(contentsOf: url))
    } catch {
      throw TatwoGoalRevisionPromotionAuthorizationError.invalid
    }
    guard authorization.schema == "TatwoGoalRevisionPromotionAuthorizationV1",
      authorization.id == safeID,
      !authorization.issuerDomain.isEmpty,
      !authorization.sessionID.isEmpty,
      !authorization.nonce.isEmpty,
      !authorization.proofDigest.isEmpty,
      authorization.expiresAt > authorization.issuedAt
    else { throw TatwoGoalRevisionPromotionAuthorizationError.invalid }
    if authorization.issuerDomain.hasPrefix("test.") {
      // Test fixtures stay injectable only inside the Core test boundary.
    } else {
      guard [
        TatwoAppHumanGateAuthorizationStore.issuerDomain,
        TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain,
      ].contains(authorization.issuerDomain)
      else { throw TatwoGoalRevisionPromotionAuthorizationError.invalid }
      if authorization.issuerDomain
        == TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain
      {
        guard authorization.oldReceiptsDigest.map(Self.isSHA256Digest) == true,
          authorization.oldActivationEpoch != nil,
          authorization.bootstrapRecoveryContextDigest
            .map(Self.isSHA256Digest) == true
        else {
          throw TatwoGoalRevisionPromotionAuthorizationError.invalid
        }
      } else {
        guard authorization.oldReceiptsDigest == nil,
          authorization.oldActivationEpoch == nil,
          authorization.bootstrapRecoveryContextDigest == nil
        else {
          throw TatwoGoalRevisionPromotionAuthorizationError.invalid
        }
      }
      guard authorization.proofDigest == Self.proofDigest(for: authorization)
      else { throw TatwoGoalRevisionPromotionAuthorizationError.invalid }
    }
    return authorization
  }

  func persistFixture(
    _ authorization: TatwoGoalRevisionPromotionAuthorizationV1
  ) throws {
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(authorization).write(
      to: directoryURL.appendingPathComponent("\(authorization.id).json"),
      options: [.atomic])
  }

  static func isExactNonEmpty(_ value: String) -> Bool {
    !value.isEmpty
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func isSHA256Digest(_ value: String) -> Bool {
    guard value.hasPrefix("sha256:"), value.count == 71 else { return false }
    return value.dropFirst(7).allSatisfy {
      ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
    }
  }

  static func wholeSecond(_ value: Date) -> Date {
    Date(timeIntervalSince1970: value.timeIntervalSince1970.rounded(.down))
  }

  static func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  static func proofDigest(
    for authorization: TatwoGoalRevisionPromotionAuthorizationV1
  ) -> String {
    var fields = [
      authorization.schema,
      authorization.id,
      authorization.issuerDomain,
      authorization.sessionID,
      authorization.oldPointerRevisionDigest,
      String(authorization.oldPointerGeneration),
      authorization.oldContractID,
      authorization.oldGoalID,
      String(authorization.oldGoalRevision),
      authorization.oldObjectiveDigest,
      authorization.newContractID,
      authorization.newGoalID,
      String(authorization.newGoalRevision),
      authorization.newObjectiveDigest,
      authorization.topologyDigest,
      authorization.capabilityDigest,
      authorization.humanGateReceiptID,
      authorization.requestedHostScopeDigest,
      String(Int64(authorization.issuedAt.timeIntervalSince1970)),
      String(Int64(authorization.expiresAt.timeIntervalSince1970)),
      authorization.nonce,
    ]
    if authorization.issuerDomain
      == TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain
    {
      fields.append(authorization.oldReceiptsDigest ?? "missing")
      fields.append(
        authorization.oldActivationEpoch.map(String.init) ?? "missing")
      fields.append(
        authorization.bootstrapRecoveryContextDigest ?? "missing")
    }
    return TatwoGoalRevisionPromotionAuthorizationV1.digest(
      fields.joined(separator: "\n"))
  }
}

public struct TatwoHostResourceBoundsV1: Codable, Sendable, Equatable {
  public let maxDurationSeconds: UInt64
  public let maxOutputBytes: UInt64
  public let maxFileCount: UInt64

  public init(
    maxDurationSeconds: UInt64,
    maxOutputBytes: UInt64,
    maxFileCount: UInt64
  ) {
    self.maxDurationSeconds = maxDurationSeconds
    self.maxOutputBytes = maxOutputBytes
    self.maxFileCount = maxFileCount
  }
}

public struct TatwoHostOperationAuthorizationV1:
  Codable, Sendable, Equatable, Identifiable
{
  public let schema: String
  public let id: String
  public let issuerDomain: String
  public let contractID: String
  public let goalID: String
  public let goalRevision: UInt64
  public let pointerGeneration: UInt64
  public let activationEpoch: UInt64
  public let completedTransitionReceiptID: String
  public let humanGateReceiptID: String
  public let canonicalWorkspacePath: String
  public let canonicalWorkspaceDigest: String
  public let action: TatwoHostActionKind
  public let argumentDigest: String
  public let outputRoots: [String]
  public let resourceBounds: TatwoHostResourceBoundsV1
  public let issuedAt: Date
  public let expiresAt: Date
  public let nonce: String
  public let proofDigest: String

  public init(
    schema: String = "TatwoHostOperationAuthorizationV1",
    id: String,
    issuerDomain: String,
    contractID: String,
    goalID: String,
    goalRevision: UInt64,
    pointerGeneration: UInt64,
    activationEpoch: UInt64,
    completedTransitionReceiptID: String,
    humanGateReceiptID: String,
    canonicalWorkspacePath: String,
    action: TatwoHostActionKind,
    argumentDigest: String,
    outputRoots: [String],
    resourceBounds: TatwoHostResourceBoundsV1,
    issuedAt: Date,
    expiresAt: Date,
    nonce: String,
    proofDigest: String
  ) {
    let workspace = TatwoGoalRevisionPromotionAuthorizationV1
      .canonicalWorkspacePath(canonicalWorkspacePath)
    self.schema = schema
    self.id = id
    self.issuerDomain = issuerDomain
    self.contractID = contractID
    self.goalID = goalID
    self.goalRevision = goalRevision
    self.pointerGeneration = pointerGeneration
    self.activationEpoch = activationEpoch
    self.completedTransitionReceiptID = completedTransitionReceiptID
    self.humanGateReceiptID = humanGateReceiptID
    self.canonicalWorkspacePath = workspace
    self.canonicalWorkspaceDigest =
      TatwoGoalRevisionPromotionAuthorizationV1.workspaceDigest(workspace)
    self.action = action
    self.argumentDigest = argumentDigest
    self.outputRoots = outputRoots.map { rawRoot in
      let trimmed = rawRoot.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("/") {
        return TatwoGoalRevisionPromotionAuthorizationV1
          .canonicalWorkspacePath(trimmed)
      }
      return TatwoGoalRevisionPromotionAuthorizationV1.canonicalWorkspacePath(
        URL(fileURLWithPath: workspace, isDirectory: true)
          .appendingPathComponent(trimmed, isDirectory: true).path)
    }.sorted()
    self.resourceBounds = resourceBounds
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.nonce = nonce
    self.proofDigest = proofDigest
  }

  public var requestedScopeDigest: String {
    TatwoGoalRevisionPromotionAuthorizationV1.digest([
      canonicalWorkspaceDigest,
      action.rawValue,
      argumentDigest,
      outputRoots.joined(separator: "\u{1f}"),
      String(resourceBounds.maxDurationSeconds),
      String(resourceBounds.maxOutputBytes),
      String(resourceBounds.maxFileCount),
    ].joined(separator: "\n"))
  }

  public static func argumentDigest(
    action: TatwoHostActionKind,
    components: [String]
  ) -> String {
    TatwoGoalRevisionPromotionAuthorizationV1.digest(
      ([action.rawValue] + components).joined(separator: "\n"))
  }

  fileprivate var signingPayload: Data {
    Data(
      [
        schema,
        id,
        issuerDomain,
        contractID,
        goalID,
        String(goalRevision),
        String(pointerGeneration),
        String(activationEpoch),
        completedTransitionReceiptID,
        humanGateReceiptID,
        canonicalWorkspacePath,
        canonicalWorkspaceDigest,
        action.rawValue,
        argumentDigest,
        outputRoots.joined(separator: "\u{1f}"),
        String(resourceBounds.maxDurationSeconds),
        String(resourceBounds.maxOutputBytes),
        String(resourceBounds.maxFileCount),
        String(Int64(issuedAt.timeIntervalSince1970)),
        String(Int64(expiresAt.timeIntervalSince1970)),
        nonce,
      ].joined(separator: "\n").utf8)
  }
}

public struct TatwoHostOperationAuthorizationConsumptionV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let authorizationID: String
  public let issuerDomain: String
  public let authorizationProofDigest: String
  public let approvalID: String
  public let consumedAt: Date

  public init(
    schema: String = "TatwoHostOperationAuthorizationConsumptionV1",
    authorizationID: String,
    issuerDomain: String,
    authorizationProofDigest: String,
    approvalID: String,
    consumedAt: Date
  ) {
    self.schema = schema
    self.authorizationID = authorizationID
    self.issuerDomain = issuerDomain
    self.authorizationProofDigest = authorizationProofDigest
    self.approvalID = approvalID
    self.consumedAt = consumedAt
  }
}

public struct TatwoHostOperationAuthorizationStore: Sendable {
  public let directoryURL: URL
  public init(directoryURL: URL) { self.directoryURL = directoryURL }

  /// App-only issuer. Production authorizations are Ed25519 signed by the same
  /// App authority that issued the human-gate receipt. Test domains remain an
  /// internal fixture seam and are never accepted by the production path.
  @_spi(TatwoHumanGateApp)
  @discardableResult
  public func authorizeAfterHumanConfirmation(
    _ draft: TatwoHostOperationAuthorizationV1
  ) throws -> TatwoHostOperationAuthorizationV1 {
    guard draft.schema == "TatwoHostOperationAuthorizationV1",
      draft.issuerDomain == TatwoAppHumanGateAuthorizationStore.issuerDomain,
      draft.proofDigest.isEmpty,
      Self.isStructurallyValid(draft, requiresProof: false)
    else {
      throw TatwoHostExecutorError.approvalScopeMismatch
    }
    let authority = TatwoAppHumanGateAuthorizationStore(
      stateDirectoryURL: stateDirectoryURL)
    let proofDigest = try authority.signAppAuthorizationPayload(
      draft.signingPayload)
    let authorization = TatwoHostOperationAuthorizationV1(
      schema: draft.schema,
      id: draft.id,
      issuerDomain: draft.issuerDomain,
      contractID: draft.contractID,
      goalID: draft.goalID,
      goalRevision: draft.goalRevision,
      pointerGeneration: draft.pointerGeneration,
      activationEpoch: draft.activationEpoch,
      completedTransitionReceiptID: draft.completedTransitionReceiptID,
      humanGateReceiptID: draft.humanGateReceiptID,
      canonicalWorkspacePath: draft.canonicalWorkspacePath,
      action: draft.action,
      argumentDigest: draft.argumentDigest,
      outputRoots: draft.outputRoots,
      resourceBounds: draft.resourceBounds,
      issuedAt: draft.issuedAt,
      expiresAt: draft.expiresAt,
      nonce: draft.nonce,
      proofDigest: proofDigest)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(authorization)
    let url = authorizationURL(id: authorization.id)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      if FileManager.default.fileExists(atPath: url.path) {
        guard try Data(contentsOf: url) == encoded else {
          throw TatwoHostExecutorError.approvalScopeMismatch
        }
        return authorization
      }
      guard try TatwoHumanGateCreateOnlyFile.write(encoded, to: url) else {
        guard try Data(contentsOf: url) == encoded else {
          throw TatwoHostExecutorError.approvalScopeMismatch
        }
        return authorization
      }
      return authorization
    }
  }

  public func require(
    id: String, now: Date = Date()
  ) throws -> TatwoHostOperationAuthorizationV1 {
    let safeID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !safeID.isEmpty, !safeID.contains("/"), !safeID.contains("..") else {
      throw TatwoHostExecutorError.approvalScopeMismatch
    }
    let url = authorizationURL(id: safeID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoHostExecutorError.approvalRequired
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let authorization: TatwoHostOperationAuthorizationV1
    do {
      authorization = try decoder.decode(
        TatwoHostOperationAuthorizationV1.self, from: Data(contentsOf: url))
    } catch {
      throw TatwoHostExecutorError.approvalScopeMismatch
    }
    guard authorization.schema == "TatwoHostOperationAuthorizationV1",
      authorization.id == safeID,
      Self.isStructurallyValid(authorization),
      authorization.issuedAt <= now,
      authorization.expiresAt > now
    else { throw TatwoHostExecutorError.approvalScopeMismatch }
    if authorization.issuerDomain.hasPrefix("test.") {
      // Test fixtures are admitted only when issueHostOperationBound receives
      // its explicit test verifier seam.
    } else {
      guard authorization.issuerDomain
        == TatwoAppHumanGateAuthorizationStore.issuerDomain
      else { throw TatwoHostExecutorError.approvalScopeMismatch }
      let publicKeyURL = stateDirectoryURL
        .appendingPathComponent("human-gate-authority", isDirectory: true)
        .appendingPathComponent("app-public-key")
      guard FileManager.default.fileExists(atPath: publicKeyURL.path),
        let publicKey = try? Curve25519.Signing.PublicKey(
          rawRepresentation: Data(contentsOf: publicKeyURL)),
        TatwoAppHumanGateAuthorizationStore.isValidSignature(
          authorization.proofDigest,
          payload: authorization.signingPayload,
          publicKey: publicKey)
      else { throw TatwoHostExecutorError.approvalScopeMismatch }
    }
    return authorization
  }

  fileprivate func consumeExactlyOnce(
    _ authorization: TatwoHostOperationAuthorizationV1,
    approvalID: String,
    now: Date
  ) throws {
    let consumption = TatwoHostOperationAuthorizationConsumptionV1(
      authorizationID: authorization.id,
      issuerDomain: authorization.issuerDomain,
      authorizationProofDigest: authorization.proofDigest,
      approvalID: approvalID,
      consumedAt: now)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(consumption)
    let url = consumptionURL(id: authorization.id)
    try TatwoFileLock.withExclusiveLock(for: url) {
      guard !FileManager.default.fileExists(atPath: url.path),
        try TatwoHumanGateCreateOnlyFile.write(encoded, to: url)
      else {
        throw TatwoHostExecutorError.approvalReplayRejected
      }
    }
  }

  fileprivate func hasMatchingConsumption(
    _ authorization: TatwoHostOperationAuthorizationV1,
    approvalID: String
  ) throws -> Bool {
    let url = consumptionURL(id: authorization.id)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let existing: TatwoHostOperationAuthorizationConsumptionV1
    do {
      existing = try decoder.decode(
        TatwoHostOperationAuthorizationConsumptionV1.self,
        from: Data(contentsOf: url))
    } catch {
      throw TatwoHostExecutorError.approvalReplayRejected
    }
    guard existing.schema
        == "TatwoHostOperationAuthorizationConsumptionV1",
      existing.authorizationID == authorization.id,
      existing.issuerDomain == authorization.issuerDomain,
      existing.authorizationProofDigest == authorization.proofDigest,
      existing.approvalID == approvalID
    else {
      throw TatwoHostExecutorError.approvalReplayRejected
    }
    return true
  }

  func persistFixture(_ authorization: TatwoHostOperationAuthorizationV1) throws {
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(authorization).write(
      to: directoryURL.appendingPathComponent("\(authorization.id).json"),
      options: [.atomic])
  }

  private var stateDirectoryURL: URL {
    directoryURL.deletingLastPathComponent()
  }

  private func authorizationURL(id: String) -> URL {
    directoryURL.appendingPathComponent("\(id).json")
  }

  private func consumptionURL(id: String) -> URL {
    stateDirectoryURL
      .appendingPathComponent(
        "host-operation-authorization-consumptions", isDirectory: true)
      .appendingPathComponent(
        "\(TatwoLoopPathComponent.sanitize(id)).json")
  }

  private static func isStructurallyValid(
    _ authorization: TatwoHostOperationAuthorizationV1,
    requiresProof: Bool = true
  ) -> Bool {
    let exactStrings = [
      authorization.id,
      authorization.issuerDomain,
      authorization.contractID,
      authorization.goalID,
      authorization.completedTransitionReceiptID,
      authorization.humanGateReceiptID,
      authorization.canonicalWorkspacePath,
      authorization.canonicalWorkspaceDigest,
      authorization.argumentDigest,
      authorization.nonce,
    ]
    return exactStrings.allSatisfy {
      !$0.isEmpty
        && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
      && !authorization.id.contains("/")
      && !authorization.id.contains("..")
      && authorization.goalRevision > 0
      && authorization.pointerGeneration > 0
      && authorization.activationEpoch > 0
      && authorization.canonicalWorkspaceDigest
        == TatwoGoalRevisionPromotionAuthorizationV1.workspaceDigest(
          authorization.canonicalWorkspacePath)
      && authorization.outputRoots == authorization.outputRoots.sorted()
      && !authorization.outputRoots.isEmpty
      && authorization.resourceBounds.maxDurationSeconds > 0
      && authorization.resourceBounds.maxOutputBytes > 0
      && authorization.resourceBounds.maxFileCount > 0
      && authorization.expiresAt > authorization.issuedAt
      && (!requiresProof || !authorization.proofDigest.isEmpty)
  }
}

public struct TatwoHostApprovalLeaseV1: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let id: String
  public let contractID: String
  public let workspaceRoot: String
  public let allowedActions: [TatwoHostActionKind]
  public let issuedAt: Date
  public let expiresAt: Date
  public let goalID: String?
  public let goalRevision: UInt64?
  public let humanGateReceiptID: String?
  public let hostOperationAuthorizationID: String?
  public let pointerGeneration: UInt64?
  public let activationEpoch: UInt64?
  public let completedTransitionReceiptID: String?
  public let canonicalWorkspaceDigest: String?
  public let argumentDigest: String?
  public let outputRoots: [String]?
  public let resourceBounds: TatwoHostResourceBoundsV1?

  public init(
    schema: String = "TatwoHostApprovalLeaseV1",
    id: String = "lease-\(UUID().uuidString.lowercased())",
    contractID: String,
    workspaceRoot: String,
    allowedActions: [TatwoHostActionKind],
    issuedAt: Date = Date(),
    expiresAt: Date,
    goalID: String? = nil,
    goalRevision: UInt64? = nil,
    humanGateReceiptID: String? = nil,
    hostOperationAuthorizationID: String? = nil,
    pointerGeneration: UInt64? = nil,
    activationEpoch: UInt64? = nil,
    completedTransitionReceiptID: String? = nil,
    canonicalWorkspaceDigest: String? = nil,
    argumentDigest: String? = nil,
    outputRoots: [String]? = nil,
    resourceBounds: TatwoHostResourceBoundsV1? = nil
  ) {
    self.schema = schema
    self.id = id
    self.contractID = contractID
    self.workspaceRoot = TatwoGoalRevisionPromotionAuthorizationV1
      .canonicalWorkspacePath(workspaceRoot)
    self.allowedActions = Array(Set(allowedActions)).sorted { $0.rawValue < $1.rawValue }
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.goalID = goalID
    self.goalRevision = goalRevision
    self.humanGateReceiptID = humanGateReceiptID
    self.hostOperationAuthorizationID = hostOperationAuthorizationID
    self.pointerGeneration = pointerGeneration
    self.activationEpoch = activationEpoch
    self.completedTransitionReceiptID = completedTransitionReceiptID
    self.canonicalWorkspaceDigest = canonicalWorkspaceDigest
    self.argumentDigest = argumentDigest
    self.outputRoots = outputRoots?.sorted()
    self.resourceBounds = resourceBounds
  }

  public var isRevisionBound: Bool {
    goalID != nil
      && goalRevision != nil
      && humanGateReceiptID != nil
      && hostOperationAuthorizationID != nil
      && pointerGeneration != nil
      && activationEpoch != nil
      && completedTransitionReceiptID != nil
      && canonicalWorkspaceDigest != nil
      && argumentDigest != nil
      && outputRoots != nil
      && resourceBounds != nil
  }
}

public struct TatwoHostApprovalStore: Sendable {
  public let directoryURL: URL
  public let goalRunStore: TatwoGoalRunStore
  public let hostOperationAuthorizationStore: TatwoHostOperationAuthorizationStore
  public let humanGateReceiptStore: TatwoHumanGateReceiptStore

  public init(
    directoryURL: URL,
    goalRunStore: TatwoGoalRunStore = .default(),
    hostOperationAuthorizationStore: TatwoHostOperationAuthorizationStore? = nil,
    humanGateReceiptStore: TatwoHumanGateReceiptStore? = nil
  ) {
    self.directoryURL = directoryURL
    self.goalRunStore = goalRunStore
    self.hostOperationAuthorizationStore =
      hostOperationAuthorizationStore
      ?? TatwoHostOperationAuthorizationStore(
        directoryURL: goalRunStore.directoryURL.appendingPathComponent(
          "host-operation-authorizations", isDirectory: true))
    self.humanGateReceiptStore =
      humanGateReceiptStore
      ?? TatwoHumanGateReceiptStore(
        directoryURL: goalRunStore.directoryURL.appendingPathComponent(
          "human-gate-receipts", isDirectory: true))
  }

  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    let base = TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
    let goalStore = TatwoGoalRunStore.default(environment: environment)
    return Self(
      directoryURL: base.appendingPathComponent(
        "host-executor/approvals", isDirectory: true),
      goalRunStore: goalStore)
  }

  /// Consume an App-issued HostOperationAuthorization after revision activation.
  /// Core, CLI, and MCP expose no HostOperationAuthorization issuer.
  @discardableResult
  public func issueHostOperationBound(
    authorizationID: String,
    sessionStore: TatwoSessionStore,
    humanGateVerifier: (any TatwoHumanGateVerifying)? = nil,
    now: Date = Date()
  ) throws -> TatwoHostApprovalLeaseV1 {
    let authorization = try hostOperationAuthorizationStore.require(
      id: authorizationID, now: now)
    if authorization.issuerDomain.hasPrefix("test."),
      humanGateVerifier == nil
    {
      throw TatwoHostExecutorError.approvalScopeMismatch
    }
    let snapshot = try sessionStore.snapshotCurrent()
    guard let snapshot else { throw TatwoSessionMutationError.noCurrentSession }
    let pointer = snapshot.pointer
    let goalSnapshot = try goalRunStore.snapshot(
      forContractID: authorization.contractID)
    let goal = goalSnapshot.record
    let contract = try WorkOSFactory.storedContractProjection(
      snapshot: goalSnapshot,
      catalog: .defaults,
      scenarioBook: TatwoScenarioConfigStore.loadDefaultStaging(),
      store: goalRunStore)
    guard pointer.contractID == authorization.contractID,
      pointer.goalID == authorization.goalID,
      (pointer.generation ?? 1) == authorization.pointerGeneration,
      goal.contractID == authorization.contractID,
      goal.goalID == authorization.goalID,
      goal.resolvedRevision == authorization.goalRevision,
      goal.status == .running,
      let supersession = goal.supersession,
      supersession.successorRevision == authorization.goalRevision,
      supersession.supersessionReceiptID
        == authorization.completedTransitionReceiptID,
      supersession.humanGateReceiptID == authorization.humanGateReceiptID,
      authorization.activationEpoch == authorization.goalRevision,
      authorization.canonicalWorkspaceDigest
        == TatwoGoalRevisionPromotionAuthorizationV1.workspaceDigest(
          authorization.canonicalWorkspacePath),
      (
        supersession.requestedHostScopeDigest
          == authorization.requestedScopeDigest
        || supersession.requestedHostScopeDigest
          == Self.revisionActivationOnlyScopeDigest
      ),
      contract.humanApprovableHostActions?.contains(authorization.action) == true,
      let ceiling = contract.hostActionCeiling,
      Self.resourceBounds(authorization.resourceBounds, fitWithin: ceiling),
      Self.outputRoots(
        authorization.outputRoots,
        areCanonicalChildrenOf: authorization.canonicalWorkspacePath)
    else { throw TatwoHostExecutorError.approvalScopeMismatch }

    let promotionStore = TatwoGoalRevisionPromotionAuthorizationStore(
      directoryURL: goalRunStore.directoryURL.appendingPathComponent(
        "goal-revision-authorizations", isDirectory: true))
    let promotion = try promotionStore.requireActivated(
      id: supersession.promotionAuthorizationID)
    let sessionID =
      pointer.ownerBinding?.sessionID
      ?? "unowned:\(pointer.contractID):\(pointer.goalID)"
    guard authorization.issuerDomain == promotion.issuerDomain,
      authorization.issuedAt >= supersession.supersededAt,
      promotion.sessionID == sessionID,
      promotion.oldPointerRevisionDigest == supersession.oldPointerRevisionDigest,
      promotion.oldPointerGeneration == supersession.oldPointerGeneration,
      promotion.oldContractID == supersession.predecessorContractID,
      promotion.oldGoalID == supersession.predecessorGoalID,
      promotion.oldGoalRevision == supersession.predecessorRevision,
      promotion.oldObjectiveDigest == supersession.oldObjectiveDigest,
      promotion.newContractID == supersession.successorContractID,
      promotion.newGoalID == supersession.successorGoalID,
      promotion.newGoalRevision == supersession.successorRevision,
      promotion.newObjectiveDigest == supersession.newObjectiveDigest,
      promotion.topologyDigest == supersession.topologyDigest,
      promotion.capabilityDigest == supersession.capabilityDigest,
      promotion.humanGateReceiptID == supersession.humanGateReceiptID,
      promotion.requestedHostScopeDigest
        == supersession.requestedHostScopeDigest
    else { throw TatwoHostExecutorError.approvalScopeMismatch }

    let completedReceipt = try Self.requireCompletedSupersessionReceipt(
      id: authorization.completedTransitionReceiptID,
      sessionStore: sessionStore)
    guard completedReceipt.promotionAuthorizationID == promotion.id,
      completedReceipt.humanGateReceiptID == authorization.humanGateReceiptID,
      completedReceipt.predecessorContractID == supersession.predecessorContractID,
      completedReceipt.predecessorGoalID == supersession.predecessorGoalID,
      completedReceipt.predecessorRevision == supersession.predecessorRevision,
      completedReceipt.successorContractID == authorization.contractID,
      completedReceipt.successorGoalID == authorization.goalID,
      completedReceipt.successorRevision == authorization.goalRevision,
      completedReceipt.oldPointerRevisionDigest == supersession.oldPointerRevisionDigest,
      completedReceipt.oldPointerGeneration == supersession.oldPointerGeneration,
      completedReceipt.newPointerGeneration == authorization.pointerGeneration,
      completedReceipt.completedAt == supersession.supersededAt,
      promotion.issuedAt <= completedReceipt.completedAt,
      promotion.expiresAt > completedReceipt.completedAt
    else { throw TatwoHostExecutorError.approvalScopeMismatch }

    let humanReceipt = try humanGateReceiptStore.require(
      id: authorization.humanGateReceiptID)
    guard humanReceipt.sessionID == promotion.sessionID,
      humanReceipt.oldContractID == promotion.oldContractID,
      humanReceipt.oldGoalID == promotion.oldGoalID,
      humanReceipt.newContractID == promotion.newContractID,
      humanReceipt.newGoalID == promotion.newGoalID
    else { throw TatwoHostExecutorError.approvalScopeMismatch }
    if let humanGateVerifier {
      try humanGateVerifier.verify(
        receipt: humanReceipt,
        subjectDigest: promotion.humanGateSubjectDigest,
        now: now)
    } else {
      let productionVerifier = TatwoProductionHumanGateVerifier(
        stateDirectoryURL: goalRunStore.directoryURL)
      try productionVerifier.validate(
        receipt: humanReceipt,
        subjectDigest: promotion.humanGateSubjectDigest,
        now: completedReceipt.completedAt)
      try productionVerifier.requireConsumed(
        receipt: humanReceipt,
        subjectDigest: promotion.humanGateSubjectDigest)
    }

    let approval = Self.revisionBoundLease(for: authorization)
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true)
    return try TatwoFileLock.withExclusiveLock(
      for: revisionBoundIssueLockURL(authorizationID: authorization.id)
    ) {
      let wasConsumed =
        try hostOperationAuthorizationStore.hasMatchingConsumption(
          authorization,
          approvalID: approval.id)
      if wasConsumed {
        // Delivery cannot be proven by a marker written before this function
        // returns. Re-emit only the exact persisted finite lease: this mints no
        // new scope or lifetime, while a missing/revoked/replaced lease remains
        // a replay rejection.
        return try requireIdenticalPersistedRevisionBoundLease(approval)
      }
      _ = try persistRevisionBoundBeforeConsumption(approval)
      try hostOperationAuthorizationStore.consumeExactlyOnce(
        authorization,
        approvalID: approval.id,
        now: now)
      return approval
    }
  }

  private static func resourceBounds(
    _ requested: TatwoHostResourceBoundsV1,
    fitWithin ceiling: TatwoHostResourceBoundsV1
  ) -> Bool {
    requested.maxDurationSeconds > 0
      && requested.maxOutputBytes > 0
      && requested.maxFileCount > 0
      && requested.maxDurationSeconds <= ceiling.maxDurationSeconds
      && requested.maxOutputBytes <= ceiling.maxOutputBytes
      && requested.maxFileCount <= ceiling.maxFileCount
  }

  private static let revisionActivationOnlyScopeDigest =
    TatwoGoalRevisionPromotionAuthorizationV1.digest(
      [
        "revision_activation_only",
        "none",
        "",
        "none",
        "none",
        "none",
      ].joined(separator: "\n"))

  private static func revisionBoundLease(
    for authorization: TatwoHostOperationAuthorizationV1
  ) -> TatwoHostApprovalLeaseV1 {
    TatwoHostApprovalLeaseV1(
      id: authorization.id,
      contractID: authorization.contractID,
      workspaceRoot: authorization.canonicalWorkspacePath,
      allowedActions: [authorization.action],
      issuedAt: authorization.issuedAt,
      expiresAt: authorization.expiresAt,
      goalID: authorization.goalID,
      goalRevision: authorization.goalRevision,
      humanGateReceiptID: authorization.humanGateReceiptID,
      hostOperationAuthorizationID: authorization.id,
      pointerGeneration: authorization.pointerGeneration,
      activationEpoch: authorization.activationEpoch,
      completedTransitionReceiptID: authorization.completedTransitionReceiptID,
      canonicalWorkspaceDigest: authorization.canonicalWorkspaceDigest,
      argumentDigest: authorization.argumentDigest,
      outputRoots: authorization.outputRoots,
      resourceBounds: authorization.resourceBounds)
  }

  private static func outputRoots(
    _ roots: [String],
    areCanonicalChildrenOf workspaceRoot: String
  ) -> Bool {
    guard !roots.isEmpty else { return false }
    let workspace = TatwoGoalRevisionPromotionAuthorizationV1
      .canonicalWorkspacePath(workspaceRoot)
    return roots.allSatisfy { root in
      let canonical = TatwoGoalRevisionPromotionAuthorizationV1
        .canonicalWorkspacePath(root)
      return root == canonical
        && (canonical == workspace
          || canonical.hasPrefix(workspace + "/"))
    }
  }

  private static func requireCompletedSupersessionReceipt(
    id: String,
    sessionStore: TatwoSessionStore
  ) throws -> TatwoGoalSupersessionReceiptV1 {
    let safeID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !safeID.isEmpty, !safeID.contains("/"), !safeID.contains("..") else {
      throw TatwoHostExecutorError.approvalScopeMismatch
    }
    let url = sessionStore.directoryURL
      .appendingPathComponent("goal-revision-promotion", isDirectory: true)
      .appendingPathComponent("receipts", isDirectory: true)
      .appendingPathComponent("\(TatwoLoopPathComponent.sanitize(safeID)).json")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoHostExecutorError.approvalScopeMismatch
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let receipt = try decoder.decode(
      TatwoGoalSupersessionReceiptV1.self, from: Data(contentsOf: url))
    guard receipt.schema == "TatwoGoalSupersessionReceiptV1",
      receipt.id == safeID
    else { throw TatwoHostExecutorError.approvalScopeMismatch }
    return receipt
  }

  /// Legacy pre-revision authorization. Once a Goal has revision lineage this
  /// path is unavailable; the App-issued HostOperationAuthorization is required.
  @discardableResult
  public func issue(
    contractID: String,
    workspaceRoot: String,
    allowedActions: [TatwoHostActionKind],
    ttl: TimeInterval = 30 * 60,
    now: Date = Date()
  ) throws -> TatwoHostApprovalLeaseV1 {
    let gate = TatwoWorkOSChokepoint.authorize(
      contractID: contractID,
      action: "tatwo.host.authorize",
      store: goalRunStore)
    guard gate.ok else { throw TatwoHostExecutorError.contractDenied(gate.code) }
    let goal = try goalRunStore.requireIssuedContract(contractID)
    guard goal.supersession == nil,
      goal.predecessorContractID == nil,
      goal.successorContractID == nil
    else { throw TatwoHostExecutorError.approvalRequired }
    guard !allowedActions.isEmpty else { throw TatwoHostExecutorError.approvalRequired }
    let lease = TatwoHostApprovalLeaseV1(
      contractID: contractID,
      workspaceRoot: workspaceRoot,
      allowedActions: allowedActions,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(max(60, min(ttl, 4 * 60 * 60))))
    try persist(lease)
    return lease
  }

  /// Native approve-for-me issuer for pre-revision goals only. The lease is
  /// scoped to one exact action/argument digest and a short lifetime. Once a
  /// goal has revision lineage, only an App-issued HostOperationAuthorization
  /// may produce a lease through `issueHostOperationBound`.
  @discardableResult
  public func issueNativeOperationBound(
    contractID: String,
    workspaceRoot: String,
    action: TatwoHostActionKind,
    argumentDigest: String,
    isMutation: Bool = true,
    ttl: TimeInterval = 60,
    now: Date = Date()
  ) throws -> TatwoHostApprovalLeaseV1 {
    let digest = argumentDigest.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !digest.isEmpty else {
      throw TatwoHostExecutorError.approvalScopeMismatch
    }
    let gate = TatwoWorkOSChokepoint.authorize(
      contractID: contractID,
      action: "tatwo.host.authorize",
      store: goalRunStore)
    guard gate.ok else { throw TatwoHostExecutorError.contractDenied(gate.code) }
    let goal = try goalRunStore.requireIssuedContract(contractID)
    guard goal.supersession == nil,
      goal.predecessorContractID == nil,
      goal.successorContractID == nil
    else { throw TatwoHostExecutorError.approvalRequired }
    if action != .readFile {
      guard isMutation
        ? [.dispatching, .running].contains(goal.status)
        : action == .runCommand
          && [.dispatching, .running, .blocked].contains(goal.status)
      else {
        throw TatwoHostExecutorError.approvalRequired
      }
    }
    let lease = TatwoHostApprovalLeaseV1(
      contractID: contractID,
      workspaceRoot: workspaceRoot,
      allowedActions: [action],
      issuedAt: now,
      expiresAt: now.addingTimeInterval(max(5, min(ttl, 60))),
      argumentDigest: digest)
    try persist(lease)
    return lease
  }

  public func require(
    id: String,
    contractID: String,
    workspaceRoot: String,
    action: TatwoHostActionKind,
    argumentDigest: String? = nil,
    isMutation: Bool = true,
    now: Date = Date()
  ) throws -> TatwoHostApprovalLeaseV1 {
    let url = directoryURL.appendingPathComponent("\(id).json")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoHostExecutorError.approvalRequired
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let leaseBytes = try Data(contentsOf: url)
    let lease = try decoder.decode(
      TatwoHostApprovalLeaseV1.self, from: leaseBytes)
    guard lease.contractID == contractID else {
      throw TatwoHostExecutorError.approvalScopeMismatch
    }
    guard lease.expiresAt > now else { throw TatwoHostExecutorError.approvalExpired }
    let requestedRoot = TatwoGoalRevisionPromotionAuthorizationV1
      .canonicalWorkspacePath(workspaceRoot)
    guard lease.workspaceRoot == requestedRoot,
      lease.allowedActions.contains(action)
    else { throw TatwoHostExecutorError.approvalScopeMismatch }

    let goal = try goalRunStore.requireIssuedContract(contractID)
    guard goal.status != .superseded else {
      throw TatwoHostExecutorError.contractDenied("stale_goal_revision")
    }
    if goal.supersession != nil || goal.predecessorContractID != nil {
      guard lease.isRevisionBound,
        goal.status == .running,
        goal.successorContractID == nil,
        lease.goalID == goal.goalID,
        lease.goalRevision == goal.resolvedRevision,
        lease.canonicalWorkspaceDigest
          == TatwoGoalRevisionPromotionAuthorizationV1.workspaceDigest(
            requestedRoot),
        lease.argumentDigest == argumentDigest,
        let authorizationID = lease.hostOperationAuthorizationID
      else { throw TatwoHostExecutorError.approvalScopeMismatch }
      let authorization = try hostOperationAuthorizationStore.require(
        id: authorizationID, now: now)
      let expectedLease = Self.revisionBoundLease(for: authorization)
      guard lease == expectedLease,
        leaseBytes == (try encodedRevisionBoundLease(expectedLease)),
        authorization.contractID == contractID,
        authorization.goalID == goal.goalID,
        authorization.goalRevision == goal.resolvedRevision,
        authorization.pointerGeneration == lease.pointerGeneration,
        authorization.activationEpoch == lease.activationEpoch,
        authorization.humanGateReceiptID == lease.humanGateReceiptID,
        authorization.action == action,
        authorization.argumentDigest == argumentDigest,
        authorization.outputRoots == lease.outputRoots,
        authorization.resourceBounds == lease.resourceBounds,
        authorization.completedTransitionReceiptID
          == goal.supersession?.supersessionReceiptID,
        authorization.completedTransitionReceiptID
          == lease.completedTransitionReceiptID,
        let current = try TatwoSessionStore(
          directoryURL: goalRunStore.directoryURL).snapshotCurrent(),
        current.pointer.contractID == contractID,
        current.pointer.goalID == goal.goalID,
        (current.pointer.generation ?? 1) == authorization.pointerGeneration
      else { throw TatwoHostExecutorError.approvalScopeMismatch }
      guard try hostOperationAuthorizationStore.hasMatchingConsumption(
        authorization,
        approvalID: lease.id)
      else { throw TatwoHostExecutorError.approvalRequired }
    } else if let exactDigest = lease.argumentDigest {
      guard exactDigest == argumentDigest else {
        throw TatwoHostExecutorError.approvalScopeMismatch
      }
      if action != .readFile {
        guard isMutation
          ? [.dispatching, .running].contains(goal.status)
          : action == .runCommand
            && [.dispatching, .running, .blocked].contains(goal.status)
        else {
          throw TatwoHostExecutorError.approvalRequired
        }
      }
    }
    return lease
  }

  public func revoke(id: String) throws {
    let safeID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !safeID.isEmpty, !safeID.contains("/"), !safeID.contains("..") else {
      throw TatwoHostExecutorError.approvalScopeMismatch
    }
    let url = directoryURL.appendingPathComponent("\(safeID).json")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  @discardableResult
  public func cleanupExpired(now: Date = Date()) throws -> [String] {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var removed: [String] = []
    for url in try FileManager.default.contentsOfDirectory(
      at: directoryURL, includingPropertiesForKeys: nil
    ) where url.pathExtension == "json" {
      guard let data = try? Data(contentsOf: url),
        let lease = try? decoder.decode(
          TatwoHostApprovalLeaseV1.self, from: data),
        lease.expiresAt <= now
      else { continue }
      try FileManager.default.removeItem(at: url)
      removed.append(lease.id)
    }
    return removed.sorted()
  }

  private func persist(_ approval: TatwoHostApprovalLeaseV1) throws {
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(approval).write(
      to: directoryURL.appendingPathComponent("\(approval.id).json"),
      options: [.atomic])
  }

  private enum RevisionBoundLeasePersistence {
    case created
    case reconciledIdentical
  }

  private func persistRevisionBoundBeforeConsumption(
    _ approval: TatwoHostApprovalLeaseV1
  ) throws -> RevisionBoundLeasePersistence {
    let encoded = try encodedRevisionBoundLease(approval)
    let url = directoryURL.appendingPathComponent("\(approval.id).json")
    if FileManager.default.fileExists(atPath: url.path) {
      guard let existing = try? Data(contentsOf: url),
        existing == encoded
      else {
        throw TatwoHostExecutorError.approvalScopeMismatch
      }
      return .reconciledIdentical
    }
    guard try TatwoHumanGateCreateOnlyFile.write(encoded, to: url) else {
      guard let existing = try? Data(contentsOf: url),
        existing == encoded
      else {
        throw TatwoHostExecutorError.approvalScopeMismatch
      }
      return .reconciledIdentical
    }
    return .created
  }

  private func requireIdenticalPersistedRevisionBoundLease(
    _ approval: TatwoHostApprovalLeaseV1
  ) throws -> TatwoHostApprovalLeaseV1 {
    let url = directoryURL.appendingPathComponent("\(approval.id).json")
    let expected = try encodedRevisionBoundLease(approval)
    guard let existing = try? Data(contentsOf: url),
      existing == expected
    else {
      throw TatwoHostExecutorError.approvalReplayRejected
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let reconciled = try? decoder.decode(
      TatwoHostApprovalLeaseV1.self, from: existing),
      reconciled == approval
    else {
      throw TatwoHostExecutorError.approvalReplayRejected
    }
    return reconciled
  }

  private func encodedRevisionBoundLease(
    _ approval: TatwoHostApprovalLeaseV1
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(approval)
  }

  private func revisionBoundIssueLockURL(
    authorizationID: String
  ) -> URL {
    let safeID = TatwoLoopPathComponent.sanitize(authorizationID)
    return directoryURL.appendingPathComponent(
      ".revision-bound-\(safeID)")
  }
}

public enum TatwoHostExecutionOutcome: String, Codable, Sendable, Equatable {
  case completed
  case timeout
  case outputIncomplete = "output_incomplete"
  case rolledBack = "rolled_back"
}

public struct TatwoHostExecutorPlanV1: Codable, Sendable, Equatable {
  public let schema: String
  public let requiresContract: Bool
  public let requiresHumanApprovalLease: Bool
  public let approvalIssuer: String
  public let supportedActions: [TatwoHostActionKind]
  public let rollbackBeforePromotion: Bool
  public let forbiddenTargets: [String]

  public init(
    schema: String = "TatwoHostExecutorPlanV1",
    requiresContract: Bool = true,
    requiresHumanApprovalLease: Bool = true,
    approvalIssuer: String = "local Tatwo CLI/App human gate",
    supportedActions: [TatwoHostActionKind] = TatwoHostActionKind.allCases,
    rollbackBeforePromotion: Bool = true,
    forbiddenTargets: [String] = [
      ".git", ".codex", ".ssh", "LaunchAgents", "browser profiles",
      "auth/session/token/cookie files", "signed app bundles",
    ]
  ) {
    self.schema = schema
    self.requiresContract = requiresContract
    self.requiresHumanApprovalLease = requiresHumanApprovalLease
    self.approvalIssuer = approvalIssuer
    self.supportedActions = supportedActions
    self.rollbackBeforePromotion = rollbackBeforePromotion
    self.forbiddenTargets = forbiddenTargets
  }
}

public struct TatwoHostExecutionReceiptV1: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let receiptID: String
  public let contractID: String
  public let action: TatwoHostActionKind
  public let result: String
  public let exitCode: Int32?
  public let backupPath: String?
  public let contentSHA256: String?
  public let hostMutationPerformed: Bool
  public let targetRelativePath: String?
  public let originalExisted: Bool
  public let outcome: TatwoHostExecutionOutcome

  public init(
    schema: String = "TatwoHostExecutionReceiptV1",
    ok: Bool,
    receiptID: String,
    contractID: String,
    action: TatwoHostActionKind,
    result: String,
    exitCode: Int32? = nil,
    backupPath: String? = nil,
    contentSHA256: String? = nil,
    hostMutationPerformed: Bool,
    targetRelativePath: String? = nil,
    originalExisted: Bool = false,
    outcome: TatwoHostExecutionOutcome = .completed
  ) {
    self.schema = schema
    self.ok = ok
    self.receiptID = receiptID
    self.contractID = contractID
    self.action = action
    self.result = TatwoPrivacyRedactor.redacted(result)
    self.exitCode = exitCode
    self.backupPath = backupPath.map(TatwoPrivacyRedactor.redacted)
    self.contentSHA256 = contentSHA256
    self.hostMutationPerformed = hostMutationPerformed
    self.targetRelativePath = targetRelativePath.map(TatwoPrivacyRedactor.redacted)
    self.originalExisted = originalExisted
    self.outcome = outcome
  }

  private enum CodingKeys: String, CodingKey {
    case schema, ok, receiptID, contractID, action, result, exitCode, backupPath
    case contentSHA256, hostMutationPerformed, targetRelativePath, originalExisted, outcome
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decodeIfPresent(String.self, forKey: .schema)
      ?? "TatwoHostExecutionReceiptV1"
    ok = try container.decode(Bool.self, forKey: .ok)
    receiptID = try container.decode(String.self, forKey: .receiptID)
    contractID = try container.decode(String.self, forKey: .contractID)
    action = try container.decode(TatwoHostActionKind.self, forKey: .action)
    result = try container.decode(String.self, forKey: .result)
    exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
    backupPath = try container.decodeIfPresent(String.self, forKey: .backupPath)
    contentSHA256 = try container.decodeIfPresent(String.self, forKey: .contentSHA256)
    hostMutationPerformed =
      try container.decodeIfPresent(Bool.self, forKey: .hostMutationPerformed) ?? false
    targetRelativePath = try container.decodeIfPresent(String.self, forKey: .targetRelativePath)
    originalExisted = try container.decodeIfPresent(Bool.self, forKey: .originalExisted) ?? false
    outcome =
      try container.decodeIfPresent(TatwoHostExecutionOutcome.self, forKey: .outcome)
      ?? .completed
  }
}

public enum TatwoHostExecutorError: Error, LocalizedError, Sendable, Equatable {
  case contractDenied(String)
  case approvalRequired
  case approvalExpired
  case approvalScopeMismatch
  case approvalReplayRejected
  case invalidRelativePath
  case pathDenied
  case protectedTarget
  case commandDenied
  case rollbackDenied
  case resourceLimitExceeded(String)
  case permissionDenied(String)
  case unsupportedPlatform

  public var errorDescription: String? {
    switch self {
    case .contractDenied(let code): "contract_denied:\(code)"
    case .approvalRequired: "approval_required"
    case .approvalExpired: "approval_expired"
    case .approvalScopeMismatch: "approval_scope_mismatch"
    case .approvalReplayRejected: "approval_replay_rejected"
    case .invalidRelativePath: "invalid_relative_path"
    case .pathDenied: "path_denied"
    case .protectedTarget: "protected_target"
    case .commandDenied: "command_denied"
    case .rollbackDenied: "rollback_denied"
    case .resourceLimitExceeded(let resource):
      "resource_limit_exceeded:\(resource)"
    case .permissionDenied(let permission): "permission_denied:\(permission)"
    case .unsupportedPlatform: "unsupported_platform"
    }
  }
}

public struct TatwoHostExecutor: Sendable {
  public let approvalStore: TatwoHostApprovalStore
  public let backupRoot: URL
  public let goalRunStore: TatwoGoalRunStore

  public init(
    approvalStore: TatwoHostApprovalStore,
    backupRoot: URL,
    goalRunStore: TatwoGoalRunStore? = nil
  ) {
    self.approvalStore = approvalStore
    self.backupRoot = backupRoot
    self.goalRunStore = goalRunStore ?? approvalStore.goalRunStore
  }

  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    let store = TatwoHostApprovalStore.default(environment: environment)
    return Self(
      approvalStore: store,
      backupRoot: store.directoryURL.deletingLastPathComponent()
        .appendingPathComponent("backups", isDirectory: true),
      goalRunStore: store.goalRunStore)
  }

  public func readFile(
    contractID: String,
    leaseID: String,
    workspaceRoot: String,
    relativePath: String
  ) throws -> TatwoHostExecutionReceiptV1 {
    let lease = try authorize(
      contractID, leaseID, workspaceRoot, .readFile,
      argumentDigest: TatwoHostOperationAuthorizationV1.argumentDigest(
        action: .readFile, components: [relativePath]))
    let target = try safeTarget(workspaceRoot: workspaceRoot, relativePath: relativePath)
    try enforceTarget(target, lease: lease)
    let data = try Data(contentsOf: target)
    try enforceResources(outputBytes: data.count, fileCount: 1, lease: lease)
    return receipt(
      contractID: contractID, action: .readFile,
      result: String(decoding: data.prefix(256 * 1024), as: UTF8.self),
      content: data, mutated: false)
  }

  public func listFiles(
    contractID: String,
    leaseID: String,
    workspaceRoot: String,
    relativePath: String = ".",
    maximumDepth: Int = 8
  ) throws -> TatwoHostExecutionReceiptV1 {
    let boundedDepth = max(0, min(maximumDepth, 32))
    let lease = try authorize(
      contractID, leaseID, workspaceRoot, .readFile,
      argumentDigest: TatwoHostOperationAuthorizationV1.argumentDigest(
        action: .readFile,
        components: ["list", relativePath, String(boundedDepth)]))
    let target = try safeTarget(workspaceRoot: workspaceRoot, relativePath: relativePath)
    try enforceTarget(target, lease: lease)
    let workspace = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
    ]
    guard let enumerator = FileManager.default.enumerator(
      at: target,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants],
      errorHandler: { _, _ in false })
    else {
      throw TatwoHostExecutorError.pathDenied
    }
    var paths: [String] = []
    for case let url as URL in enumerator {
      if Task.isCancelled { throw CancellationError() }
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
        continue
      }
      if values.isSymbolicLink == true {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      guard let relative = Self.workspaceRelativePath(
        url, workspace: workspace)
      else {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      do {
        let checked = try safeTarget(
          workspaceRoot: workspace.path, relativePath: relative)
        guard checked.standardizedFileURL.path
          == url.standardizedFileURL.path
        else {
          if values.isDirectory == true { enumerator.skipDescendants() }
          continue
        }
      } catch {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      let depth = relative.split(separator: "/").count
      if values.isDirectory == true, depth >= boundedDepth {
        enumerator.skipDescendants()
      }
      guard values.isRegularFile == true, depth <= boundedDepth else { continue }
      paths.append(relative)
    }
    let result = paths.sorted().joined(separator: "\n")
    let data = Data(result.utf8)
    try enforceResources(
      outputBytes: data.count,
      fileCount: paths.count,
      lease: lease)
    return receipt(
      contractID: contractID,
      action: .readFile,
      result: Self.boundedVisibleText(data),
      content: data,
      mutated: false)
  }

  public func searchFiles(
    contractID: String,
    leaseID: String,
    workspaceRoot: String,
    relativePath: String = ".",
    query: String,
    maximumMatches: Int = 200
  ) throws -> TatwoHostExecutionReceiptV1 {
    let safeQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !safeQuery.isEmpty, !safeQuery.contains("\0") else {
      throw TatwoHostExecutorError.commandDenied
    }
    let boundedMatches = max(1, min(maximumMatches, 2_000))
    let lease = try authorize(
      contractID, leaseID, workspaceRoot, .readFile,
      argumentDigest: TatwoHostOperationAuthorizationV1.argumentDigest(
        action: .readFile,
        components: ["search", relativePath, safeQuery, String(boundedMatches)]))
    let target = try safeTarget(workspaceRoot: workspaceRoot, relativePath: relativePath)
    try enforceTarget(target, lease: lease)
    let workspace = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ]
    guard let enumerator = FileManager.default.enumerator(
      at: target,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants],
      errorHandler: { _, _ in false })
    else {
      throw TatwoHostExecutorError.pathDenied
    }
    var matches: [String] = []
    var inspectedFiles = 0
    searchLoop: for case let url as URL in enumerator {
      if Task.isCancelled { throw CancellationError() }
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
        continue
      }
      if values.isSymbolicLink == true {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      guard let relative = Self.workspaceRelativePath(
        url, workspace: workspace)
      else {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      do {
        let checked = try safeTarget(
          workspaceRoot: workspace.path, relativePath: relative)
        guard checked.standardizedFileURL.path
          == url.standardizedFileURL.path
        else {
          if values.isDirectory == true { enumerator.skipDescendants() }
          continue
        }
      } catch {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      guard values.isRegularFile == true,
        (values.fileSize ?? 0) <= 1_048_576
      else { continue }
      guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
      else { continue }
      guard !data.contains(0) else { continue }
      inspectedFiles += 1
      let text = String(decoding: data, as: UTF8.self)
      for (index, line) in text.split(
        separator: "\n", omittingEmptySubsequences: false
      ).enumerated() where line.localizedStandardContains(safeQuery) {
        matches.append("\(relative):\(index + 1):\(line)")
        if matches.count >= boundedMatches { break searchLoop }
      }
    }
    let result = matches.joined(separator: "\n")
    let data = Data(result.utf8)
    try enforceResources(
      outputBytes: data.count,
      fileCount: inspectedFiles,
      lease: lease)
    return receipt(
      contractID: contractID,
      action: .readFile,
      result: Self.boundedVisibleText(data),
      content: data,
      mutated: false)
  }

  public func writeFile(
    contractID: String,
    leaseID: String,
    workspaceRoot: String,
    relativePath: String,
    content: String
  ) throws -> TatwoHostExecutionReceiptV1 {
    let contentDigest = Self.sha256(Data(content.utf8))
    let lease = try authorize(
      contractID, leaseID, workspaceRoot, .writeFile,
      argumentDigest: TatwoHostOperationAuthorizationV1.argumentDigest(
        action: .writeFile, components: [relativePath, contentDigest]))
    let target = try safeTarget(workspaceRoot: workspaceRoot, relativePath: relativePath)
    try enforceTarget(target, lease: lease)
    try enforceResources(
      outputBytes: content.utf8.count, fileCount: 1, lease: lease)
    let receiptID = "host-\(UUID().uuidString.lowercased())"
    let backup = backupRoot.appendingPathComponent(receiptID, isDirectory: true)
      .appendingPathComponent(relativePath)
    var backupPath: String?
    let originalExisted = FileManager.default.fileExists(atPath: target.path)
    if originalExisted {
      try FileManager.default.createDirectory(
        at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: target, to: backup)
      backupPath = "\(receiptID)/\(relativePath)"
    }
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = Data(content.utf8)
    try data.write(to: target, options: [.atomic])
    return TatwoHostExecutionReceiptV1(
      ok: true, receiptID: receiptID, contractID: contractID, action: .writeFile,
      result: "wrote \(relativePath)", backupPath: backupPath,
      contentSHA256: Self.sha256(data), hostMutationPerformed: true,
      targetRelativePath: relativePath, originalExisted: originalExisted)
  }

  public func rollback(
    contractID: String,
    leaseID: String,
    workspaceRoot: String,
    writeReceipt: TatwoHostExecutionReceiptV1
  ) throws -> TatwoHostExecutionReceiptV1 {
    let lease = try authorize(
      contractID, leaseID, workspaceRoot, .rollback,
      argumentDigest: TatwoHostOperationAuthorizationV1.argumentDigest(
        action: .rollback,
        components: [
          writeReceipt.receiptID,
          writeReceipt.contentSHA256 ?? "missing",
        ]))
    guard
      writeReceipt.contractID == contractID,
      writeReceipt.action == .writeFile,
      let relativePath = writeReceipt.targetRelativePath
    else { throw TatwoHostExecutorError.rollbackDenied }
    let target = try safeTarget(workspaceRoot: workspaceRoot, relativePath: relativePath)
    try enforceTarget(target, lease: lease)
    try enforceResources(fileCount: 1, lease: lease)
    if writeReceipt.originalExisted {
      guard let rawBackupPath = writeReceipt.backupPath else {
        throw TatwoHostExecutorError.rollbackDenied
      }
      let canonicalBackupRoot = backupRoot.standardizedFileURL
      let backup =
        rawBackupPath.hasPrefix("/")
        ? URL(fileURLWithPath: rawBackupPath).standardizedFileURL
        : canonicalBackupRoot.appendingPathComponent(rawBackupPath).standardizedFileURL
      guard backup.path.hasPrefix(canonicalBackupRoot.path + "/"),
        FileManager.default.fileExists(atPath: backup.path)
      else { throw TatwoHostExecutorError.rollbackDenied }
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: backup, to: target)
    } else if FileManager.default.fileExists(atPath: target.path) {
      try FileManager.default.removeItem(at: target)
    }
    let restoredData = (try? Data(contentsOf: target)) ?? Data()
    return TatwoHostExecutionReceiptV1(
      ok: true,
      receiptID: "host-\(UUID().uuidString.lowercased())",
      contractID: contractID,
      action: .rollback,
      result: "rolled back \(relativePath)",
      contentSHA256: Self.sha256(restoredData),
      hostMutationPerformed: true,
      targetRelativePath: relativePath,
      originalExisted: writeReceipt.originalExisted,
      outcome: .rolledBack)
  }

  #if os(macOS)
  public func runCommand(
    contractID: String,
    leaseID: String,
    workspaceRoot: String,
    executable: String,
    arguments: [String],
    timeout: TimeInterval = 120,
    cancellationRequested: @Sendable () -> Bool = { false }
  ) throws -> TatwoHostExecutionReceiptV1 {
    let lease = try authorize(
      contractID, leaseID, workspaceRoot, .runCommand,
      argumentDigest: TatwoHostOperationAuthorizationV1.argumentDigest(
        action: .runCommand,
        components: [executable] + arguments),
      isMutation: Self.commandMayMutate(
        executable, arguments: arguments))
    try enforceDuration(timeout, lease: lease)
    try enforceCommandWorkspaceScope(workspaceRoot, lease: lease)
    let canonicalWorkspace = URL(
      fileURLWithPath: workspaceRoot, isDirectory: true
    ).standardizedFileURL.resolvingSymlinksInPath()
    guard !Self.isProtectedAbsolutePath(canonicalWorkspace.path) else {
      throw TatwoHostExecutorError.protectedTarget
    }
    guard let resolvedExecutable = Self.resolvedExecutable(executable),
      Self.allowedExecutable(
      resolvedExecutable,
      arguments: arguments,
      workspaceRoot: workspaceRoot)
    else {
      throw TatwoHostExecutorError.commandDenied
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: resolvedExecutable)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
    let inherited = ProcessInfo.processInfo.environment
    let allowedEnvironmentKeys = Set([
      "PATH", "HOME", "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL", "LC_CTYPE",
      "TERM", "USER", "LOGNAME", "SHELL", "DEVELOPER_DIR", "SDKROOT",
    ])
    process.environment = inherited.filter { allowedEnvironmentKeys.contains($0.key) }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    let outputDrain = TatwoHostCommandOutputDrain()
    let outputDrainGroup = DispatchGroup()
    outputDrainGroup.enter()
    DispatchQueue.global(qos: .utility).async {
      outputDrain.readToEnd(from: output.fileHandleForReading)
      outputDrainGroup.leave()
    }
    do {
      try process.run()
      try? output.fileHandleForWriting.close()
    } catch {
      try? output.fileHandleForWriting.close()
      _ = outputDrainGroup.wait(timeout: .now() + 1)
      throw error
    }
    let processID = process.processIdentifier
    _ = Darwin.setpgid(processID, processID)
    let deadline = Date().addingTimeInterval(max(0.05, min(timeout, 900)))
    var cancelled = false
    while process.isRunning, Date() < deadline {
      if cancellationRequested() {
        cancelled = true
        break
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    if cancelled {
      Self.terminateProcessGroup(process, processID: processID)
      _ = outputDrainGroup.wait(timeout: .now() + 1)
      throw CancellationError()
    }
    // See ComputerHost: a negative pid signals a process group, so pid 0 would
    // signal our own group rather than the child.
    if process.isRunning {
      Self.terminateProcessGroup(process, processID: processID)
      _ = outputDrainGroup.wait(timeout: .now() + 1)
      let data = outputDrain.snapshot()
      try enforceResources(outputBytes: data.count, lease: lease)
      return TatwoHostExecutionReceiptV1(
        ok: false,
        receiptID: "host-\(UUID().uuidString.lowercased())",
        contractID: contractID,
        action: .runCommand,
        result: "timeout",
        exitCode: nil,
        contentSHA256: Self.sha256(data),
        hostMutationPerformed: Self.commandMayMutate(
          executable, arguments: arguments),
        outcome: .timeout)
    }
    let drainFinished =
      outputDrainGroup.wait(timeout: .now() + 1) == .success
    let data = outputDrain.snapshot()
    try enforceResources(outputBytes: data.count, lease: lease)
    guard drainFinished, outputDrain.isComplete else {
      return TatwoHostExecutionReceiptV1(
        ok: false,
        receiptID: "host-\(UUID().uuidString.lowercased())",
        contractID: contractID,
        action: .runCommand,
        result:
          String(decoding: data.suffix(8 * 1024), as: UTF8.self)
          + "\n<tatwo-output-incomplete>",
        exitCode: process.terminationStatus,
        contentSHA256: nil,
        hostMutationPerformed: Self.commandMayMutate(
          executable, arguments: arguments),
        outcome: .outputIncomplete)
    }
    return TatwoHostExecutionReceiptV1(
      ok: process.terminationStatus == 0,
      receiptID: "host-\(UUID().uuidString.lowercased())",
      contractID: contractID,
      action: .runCommand,
      // Keep receipt text bounded before the privacy redactor runs. Resource
      // enforcement and the content hash above still cover the complete output.
      result: String(decoding: data.suffix(8 * 1024), as: UTF8.self),
      exitCode: process.terminationStatus,
      contentSHA256: Self.sha256(data),
      hostMutationPerformed: Self.commandMayMutate(
        executable, arguments: arguments))
  }
  #endif

  private func authorize(
    _ contractID: String,
    _ leaseID: String,
    _ workspaceRoot: String,
    _ action: TatwoHostActionKind,
    argumentDigest: String,
    isMutation: Bool = true
  ) throws -> TatwoHostApprovalLeaseV1 {
    let gate = TatwoWorkOSChokepoint.authorize(
      contractID: contractID,
      action: "tatwo.host.\(action.rawValue)",
      store: goalRunStore)
    guard gate.ok else { throw TatwoHostExecutorError.contractDenied(gate.code) }
    return try approvalStore.require(
      id: leaseID,
      contractID: contractID,
      workspaceRoot: workspaceRoot,
      action: action,
      argumentDigest: argumentDigest,
      isMutation: isMutation)
  }

  private func enforceTarget(
    _ target: URL,
    lease: TatwoHostApprovalLeaseV1
  ) throws {
    guard lease.isRevisionBound else { return }
    guard let roots = lease.outputRoots,
      roots.contains(where: { rawRoot in
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
          .standardizedFileURL.resolvingSymlinksInPath().path
        return target.path == root || target.path.hasPrefix(root + "/")
      })
    else { throw TatwoHostExecutorError.approvalScopeMismatch }
  }

  private func enforceCommandWorkspaceScope(
    _ workspaceRoot: String,
    lease: TatwoHostApprovalLeaseV1
  ) throws {
    guard lease.isRevisionBound else { return }
    let workspace = TatwoGoalRevisionPromotionAuthorizationV1
      .canonicalWorkspacePath(workspaceRoot)
    guard lease.outputRoots?.contains(workspace) == true else {
      throw TatwoHostExecutorError.approvalScopeMismatch
    }
  }

  private func enforceDuration(
    _ timeout: TimeInterval,
    lease: TatwoHostApprovalLeaseV1
  ) throws {
    guard lease.isRevisionBound, let bounds = lease.resourceBounds else { return }
    guard timeout > 0,
      timeout <= TimeInterval(bounds.maxDurationSeconds)
    else {
      throw TatwoHostExecutorError.resourceLimitExceeded("duration")
    }
  }

  private func enforceResources(
    outputBytes: Int = 0,
    fileCount: Int = 0,
    lease: TatwoHostApprovalLeaseV1
  ) throws {
    guard lease.isRevisionBound, let bounds = lease.resourceBounds else { return }
    guard outputBytes >= 0,
      UInt64(outputBytes) <= bounds.maxOutputBytes
    else {
      throw TatwoHostExecutorError.resourceLimitExceeded("output_bytes")
    }
    guard fileCount >= 0,
      UInt64(fileCount) <= bounds.maxFileCount
    else {
      throw TatwoHostExecutorError.resourceLimitExceeded("file_count")
    }
  }

  private func safeTarget(workspaceRoot: String, relativePath: String) throws -> URL {
    let relative = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..")
    else { throw TatwoHostExecutorError.invalidRelativePath }
    let root = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    guard !Self.isProtectedAbsolutePath(root.path) else {
      throw TatwoHostExecutorError.protectedTarget
    }
    let target = root.appendingPathComponent(relative).standardizedFileURL
    guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
      throw TatwoHostExecutorError.pathDenied
    }
    let targetRelative = Self.workspaceRelativePath(target, workspace: root)
      ?? relative
    guard !Self.isProtectedRelativePath(targetRelative) else {
      throw TatwoHostExecutorError.protectedTarget
    }
    if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
      throw TatwoHostExecutorError.pathDenied
    }
    var cursor = target.deletingLastPathComponent()
    while cursor.path.hasPrefix(root.path), cursor.path != root.path {
      if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        throw TatwoHostExecutorError.pathDenied
      }
      cursor.deleteLastPathComponent()
    }
    return target
  }

  private static func workspaceRelativePath(
    _ url: URL,
    workspace: URL
  ) -> String? {
    let rootPath = workspace.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path == rootPath || path.hasPrefix(rootPath + "/") else {
      return nil
    }
    if path == rootPath { return "." }
    return String(path.dropFirst(rootPath.count + 1))
  }

  private static func isProtectedRelativePath(_ relativePath: String) -> Bool {
    let lowered = relativePath.lowercased()
    let components = lowered.split(separator: "/").map(String.init)
    if components.contains(where: isProtectedPathComponent) {
      return true
    }
    if lowered.contains("library/application support/google/chrome/") {
      return true
    }
    return false
  }

  private static func isProtectedAbsolutePath(_ path: String) -> Bool {
    let lowered = path.lowercased()
    if lowered.contains("library/application support/google/chrome/") {
      return true
    }
    return lowered.split(separator: "/").map(String.init)
      .contains(where: isProtectedPathComponent)
  }

  private static func isProtectedPathComponent(_ component: String) -> Bool {
    let lowered = component.lowercased()
    let exactProtectedNames = Set([
      ".git", ".codex", ".ssh", "launchagents", "auth", "auth.json",
      ".auth", "secret", "secrets", "token", "tokens", "cookie", "cookies",
      "cookie-store", "credentials", "credentials.json", ".netrc",
      "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
    ])
    let sensitiveStems = Set([
      "auth", "secret", "secrets", "token", "tokens", "cookie",
      "cookies", "credential", "credentials",
    ])
    let sensitiveExtensions = Set(["pem", "key", "p12", "pfx"])
    var candidate = lowered
    while true {
      if exactProtectedNames.contains(candidate)
        || candidate == ".env"
        || candidate.hasPrefix(".env.")
      {
        return true
      }
      let url = URL(fileURLWithPath: candidate)
      let pathExtension = url.pathExtension.lowercased()
      let stem = url.deletingPathExtension().lastPathComponent
      if sensitiveExtensions.contains(pathExtension)
        || sensitiveStems.contains(stem)
        || stem.hasSuffix("-token")
        || stem.hasSuffix("_token")
        || stem.hasSuffix(".token")
        || stem.hasSuffix("-cookie")
        || stem.hasSuffix("_cookie")
        || stem.hasSuffix(".cookie")
      {
        return true
      }
      guard !pathExtension.isEmpty, stem != candidate else {
        return false
      }
      candidate = stem
    }
  }

  private func receipt(
    contractID: String,
    action: TatwoHostActionKind,
    result: String,
    content: Data,
    mutated: Bool
  ) -> TatwoHostExecutionReceiptV1 {
    TatwoHostExecutionReceiptV1(
      ok: true, receiptID: "host-\(UUID().uuidString.lowercased())",
      contractID: contractID, action: action, result: result,
      contentSHA256: Self.sha256(content), hostMutationPerformed: mutated)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func allowedExecutable(
    _ executable: String,
    arguments: [String],
    workspaceRoot: String
  ) -> Bool {
    let name = URL(fileURLWithPath: executable).lastPathComponent
    guard !arguments.contains(where: {
      ["-c", "-e", "--eval", "--prefix", "--dir", "-C", "--package-path"].contains($0)
    }) else { return false }
    switch name {
    case "pwd":
      return arguments.isEmpty
    case "git":
      guard let command = arguments.first else { return false }
      return safeGitArguments(
        command: command,
        arguments: Array(arguments.dropFirst()),
        workspaceRoot: workspaceRoot)
    case "swift":
      guard let command = arguments.first else { return false }
      return ["--version", "-version", "build", "test"].contains(command)
        && safePathArguments(arguments.dropFirst(), workspaceRoot: workspaceRoot)
    case "node":
      guard let command = arguments.first else { return false }
      if ["--version", "-v"].contains(command) { return arguments.count == 1 }
      guard command == "--check", arguments.count == 2 else { return false }
      return safePathArguments(arguments.dropFirst(), workspaceRoot: workspaceRoot)
    case "npm", "pnpm":
      guard let command = arguments.first else { return false }
      if ["--version", "-v"].contains(command) { return arguments.count == 1 }
      if command == "test" { return arguments.count == 1 }
      guard command == "run", arguments.count == 2 else { return false }
      return ["test", "lint", "check", "build"].contains(arguments[1])
    case "xcodebuild":
      if arguments == ["-version"] { return true }
      guard !arguments.isEmpty else { return false }
      return safePathArguments(arguments[...], workspaceRoot: workspaceRoot)
    case "sleep":
      guard arguments.count == 1, let value = Double(arguments[0]) else { return false }
      return value >= 0 && value <= 900
    default:
      return false
    }
  }

  private static func resolvedExecutable(_ executable: String) -> String? {
    if (executable as NSString).isAbsolutePath {
      return executable
    }
    guard !executable.contains("/") else { return nil }
    switch executable {
    case "pwd": return "/bin/pwd"
    case "git": return "/usr/bin/git"
    case "swift": return "/usr/bin/swift"
    case "xcodebuild": return "/usr/bin/xcodebuild"
    case "sleep": return "/bin/sleep"
    case "node", "npm", "pnpm":
      for root in ["/opt/homebrew/bin", "/usr/local/bin"] {
        let candidate = URL(fileURLWithPath: root, isDirectory: true)
          .appendingPathComponent(executable).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
          return candidate
        }
      }
      return nil
    default:
      return nil
    }
  }

  private static func safePathArguments<S: Sequence>(
    _ arguments: S,
    workspaceRoot: String
  ) -> Bool where S.Element == String {
    let root = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    guard !isProtectedAbsolutePath(root.path) else { return false }
    for argument in arguments {
      if argument.contains("\0") || argument.contains("\n") || argument.contains("\r") {
        return false
      }
      let pathArgument: String
      if argument.hasPrefix("-"), let equals = argument.firstIndex(of: "=") {
        pathArgument = String(argument[argument.index(after: equals)...])
      } else {
        pathArgument = argument
      }
      if !pathArgument.hasPrefix("-"), isProtectedRelativePath(pathArgument) {
        return false
      }
      guard pathArgument.hasPrefix("/") || pathArgument.contains("/")
        || pathArgument.contains("..")
      else {
        continue
      }
      let candidate = pathArgument.hasPrefix("/")
        ? URL(fileURLWithPath: pathArgument).standardizedFileURL.resolvingSymlinksInPath()
        : root.appendingPathComponent(pathArgument).standardizedFileURL
          .resolvingSymlinksInPath()
      guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
        return false
      }
      guard let relative = workspaceRelativePath(candidate, workspace: root),
        !isProtectedRelativePath(relative)
      else { return false }
    }
    return true
  }

  private static func isForbiddenGitArgument(_ argument: String) -> Bool {
    argument == "--no-index"
      || argument == "--git-dir"
      || argument.hasPrefix("--git-dir=")
      || argument == "--work-tree"
      || argument.hasPrefix("--work-tree=")
      || argument == "-c"
      || (argument.hasPrefix("-c") && !argument.hasPrefix("--"))
      || argument == "--output"
      || argument.hasPrefix("--output=")
      || argument == "--ext-diff"
      || argument == "--textconv"
      || argument == "-O"
      || (argument.hasPrefix("-O") && argument.count > 2)
      || argument == "--order-file"
      || argument.hasPrefix("--order-file=")
      || argument == "--pathspec-from-file"
      || argument.hasPrefix("--pathspec-from-file=")
  }

  private static func safeGitArguments(
    command: String,
    arguments: [String],
    workspaceRoot: String
  ) -> Bool {
    switch command {
    case "status":
      return arguments == ["--porcelain"] || arguments == ["--short"]
    case "diff":
      var remaining = arguments
      if remaining.first == "--no-ext-diff" {
        remaining.removeFirst()
      }
      guard remaining.first == "--" else { return false }
      remaining.removeFirst()
      guard !remaining.isEmpty else { return false }
      for path in remaining {
        guard !path.isEmpty,
          !path.hasPrefix("-"),
          !path.hasPrefix(":("),
          path.rangeOfCharacter(
            from: CharacterSet(charactersIn: "*?[")) == nil,
          isSafeGitDiffPathspec(path, workspaceRoot: workspaceRoot)
        else { return false }
      }
      return true
    default:
      return false
    }
  }

  static func isSafeGitDiffPathspec(
    _ path: String,
    workspaceRoot: String
  ) -> Bool {
    guard safePathArguments([path], workspaceRoot: workspaceRoot) else {
      return false
    }
    let root = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    let candidate = root.appendingPathComponent(path).standardizedFileURL
      .resolvingSymlinksInPath()
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(
      atPath: candidate.path,
      isDirectory: &isDirectory)
    else {
      return false
    }
    return !isDirectory.boolValue
  }

  private static func boundedVisibleText(
    _ data: Data,
    maximumBytes: Int = 64 * 1024
  ) -> String {
    guard data.count > maximumBytes else {
      return String(decoding: data, as: UTF8.self)
    }
    return String(decoding: data.prefix(maximumBytes), as: UTF8.self)
      + "\n<tatwo-truncated original_bytes=\(data.count)>"
  }

  private static func terminateProcessGroup(
    _ process: Process,
    processID: Int32
  ) {
    guard process.isRunning, processID > 1 else { return }
    _ = Darwin.kill(-processID, SIGTERM)
    let termDeadline = Date().addingTimeInterval(0.4)
    while process.isRunning, Date() < termDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    guard process.isRunning else { return }
    _ = Darwin.kill(-processID, SIGKILL)
    let killDeadline = Date().addingTimeInterval(0.4)
    while process.isRunning, Date() < killDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
  }

  private static func commandMayMutate(_ executable: String, arguments: [String]) -> Bool {
    let name = URL(fileURLWithPath: executable).lastPathComponent
    switch name {
    case "swift":
      return arguments.first == "build" || arguments.first == "test"
    case "npm", "pnpm", "xcodebuild":
      return !["--version", "-v", "-version"].contains(arguments.first ?? "")
    default:
      return false
    }
  }
}

private final class TatwoHostCommandOutputDrain: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private var complete = false

  func readToEnd(from handle: FileHandle) {
    while true {
      let bytes = handle.availableData
      if bytes.isEmpty {
        lock.lock()
        complete = true
        lock.unlock()
        return
      }
      lock.lock()
      data.append(bytes)
      lock.unlock()
    }
  }

  func snapshot() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }

  var isComplete: Bool {
    lock.lock()
    defer { lock.unlock() }
    return complete
  }
}
