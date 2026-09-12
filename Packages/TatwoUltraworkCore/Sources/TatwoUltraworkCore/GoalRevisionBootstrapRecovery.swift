import CryptoKit
import Foundation

/// Exact evidence for the one narrow recovery case where the installed App
/// human-gate issuer cannot issue the Goal revision needed to replace its own
/// legacy contract.
///
/// This value is not authority by itself. Authority exists only after an
/// external trust provider verifies either a pre-pinned host signature or an
/// exact one-time grant installed under a fresh root/admin human gate.
public struct TatwoGoalRevisionBootstrapRecoveryEvidenceV1:
  Codable, Sendable, Equatable, Identifiable
{
  public let schema: String
  public let id: String
  public let challengeID: String
  public let threadID: String
  public let turnID: String
  public let eventID: String
  public let observedRole: String
  public let humanMessageDigest: String
  public let legacyAppBundleIdentifier: String
  public let legacyAppVersion: String
  public let legacyAppBuild: String
  public let legacyIssuerAvailability: String
  public let legacyUnavailableEvidenceDigest: String
  public let authorityKind: String
  public let hostKeyID: String
  public let authorizationID: String
  public let grantID: String
  public let shortCode: String
  public let localUserUID: UInt32
  public let deviceID: String
  public let recoveryReason: String
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

  public init(
    schema: String = "TatwoGoalRevisionBootstrapRecoveryEvidenceV1",
    id: String,
    challengeID: String,
    threadID: String,
    turnID: String,
    eventID: String,
    observedRole: String,
    humanMessageDigest: String,
    legacyAppBundleIdentifier: String,
    legacyAppVersion: String,
    legacyAppBuild: String,
    legacyIssuerAvailability: String,
    legacyUnavailableEvidenceDigest: String,
    authorityKind: String = "ed25519_host_key",
    hostKeyID: String,
    authorizationID: String,
    grantID: String,
    shortCode: String,
    localUserUID: UInt32,
    deviceID: String,
    recoveryReason: String,
    sessionID: String,
    oldPointerRevisionDigest: String,
    oldPointerGeneration: UInt64,
    oldContractID: String,
    oldGoalID: String,
    oldGoalRevision: UInt64,
    oldActivationEpoch: UInt64,
    oldObjectiveDigest: String,
    oldReceiptsDigest: String,
    newContractID: String,
    newGoalID: String,
    newGoalRevision: UInt64,
    newObjectiveDigest: String,
    topologyDigest: String,
    capabilityDigest: String,
    requestedHostScopeDigest: String,
    allowedOperations: [String],
    deniedOperations: [String],
    maxUses: UInt64,
    issuedAt: Date,
    expiresAt: Date,
    nonce: String
  ) {
    self.schema = schema
    self.id = id
    self.challengeID = challengeID
    self.threadID = threadID
    self.turnID = turnID
    self.eventID = eventID
    self.observedRole = observedRole
    self.humanMessageDigest = humanMessageDigest
    self.legacyAppBundleIdentifier = legacyAppBundleIdentifier
    self.legacyAppVersion = legacyAppVersion
    self.legacyAppBuild = legacyAppBuild
    self.legacyIssuerAvailability = legacyIssuerAvailability
    self.legacyUnavailableEvidenceDigest = legacyUnavailableEvidenceDigest
    self.authorityKind = authorityKind
    self.hostKeyID = hostKeyID
    self.authorizationID = authorizationID
    self.grantID = grantID
    self.shortCode = shortCode
    self.localUserUID = localUserUID
    self.deviceID = deviceID
    self.recoveryReason = recoveryReason
    self.sessionID = sessionID
    self.oldPointerRevisionDigest = oldPointerRevisionDigest
    self.oldPointerGeneration = oldPointerGeneration
    self.oldContractID = oldContractID
    self.oldGoalID = oldGoalID
    self.oldGoalRevision = oldGoalRevision
    self.oldActivationEpoch = oldActivationEpoch
    self.oldObjectiveDigest = oldObjectiveDigest
    self.oldReceiptsDigest = oldReceiptsDigest
    self.newContractID = newContractID
    self.newGoalID = newGoalID
    self.newGoalRevision = newGoalRevision
    self.newObjectiveDigest = newObjectiveDigest
    self.topologyDigest = topologyDigest
    self.capabilityDigest = capabilityDigest
    self.requestedHostScopeDigest = requestedHostScopeDigest
    self.allowedOperations = allowedOperations.sorted()
    self.deniedOperations = deniedOperations.sorted()
    self.maxUses = maxUses
    self.issuedAt = Self.wholeSecond(issuedAt)
    self.expiresAt = Self.wholeSecond(expiresAt)
    self.nonce = nonce
  }

  public static let requiredAllowedOperations = [
    "goal_revision_transition"
  ]

  public static let signedHostAuthorityKind = "ed25519_host_key"
  public static let rootOwnedGrantAuthorityKind =
    "root_owned_one_time_grant"

  public static let requiredDeniedOperations = [
    "applications_mutation",
    "auth",
    "build",
    "deploy",
    "host_operation",
    "install",
    "keychain",
    "launchagent",
    "signing",
  ].sorted()

  /// Context that only the trusted host event boundary can attest. This digest
  /// is included in the promotion subject without creating a self-referential
  /// evidence digest.
  public var authorityContextDigest: String {
    Self.digest(
      Self.canonicalData([
        schema,
        id,
        challengeID,
        threadID,
        turnID,
        eventID,
        observedRole,
        humanMessageDigest,
        legacyAppBundleIdentifier,
        legacyAppVersion,
        legacyAppBuild,
        legacyIssuerAvailability,
        legacyUnavailableEvidenceDigest,
        authorityKind,
        hostKeyID,
        authorizationID,
        grantID,
        shortCode,
        String(localUserUID),
        deviceID,
        recoveryReason,
        allowedOperations.joined(separator: "\u{1f}"),
        deniedOperations.joined(separator: "\u{1f}"),
        String(maxUses),
        String(Int64(issuedAt.timeIntervalSince1970)),
        String(Int64(expiresAt.timeIntervalSince1970)),
        nonce,
      ]))
  }

  public var expectedHumanGateSubjectDigest: String {
    TatwoGoalRevisionPromotionAuthorizationV1.digest([
      sessionID,
      oldPointerRevisionDigest,
      String(oldPointerGeneration),
      oldContractID,
      oldGoalID,
      String(oldGoalRevision),
      oldObjectiveDigest,
      newContractID,
      newGoalID,
      String(newGoalRevision),
      newObjectiveDigest,
      topologyDigest,
      capabilityDigest,
      requestedHostScopeDigest,
      oldReceiptsDigest,
      String(oldActivationEpoch),
      authorityContextDigest,
    ].joined(separator: "\n"))
  }

  func isExactBinding(
    for authorization: TatwoGoalRevisionPromotionAuthorizationV1
  ) -> Bool {
    authorization.issuerDomain
      == TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain
      && authorization.sessionID == sessionID
      && authorization.oldPointerRevisionDigest == oldPointerRevisionDigest
      && authorization.oldPointerGeneration == oldPointerGeneration
      && authorization.oldContractID == oldContractID
      && authorization.oldGoalID == oldGoalID
      && authorization.oldGoalRevision == oldGoalRevision
      && authorization.oldObjectiveDigest == oldObjectiveDigest
      && authorization.newContractID == newContractID
      && authorization.newGoalID == newGoalID
      && authorization.newGoalRevision == newGoalRevision
      && authorization.newObjectiveDigest == newObjectiveDigest
      && authorization.topologyDigest == topologyDigest
      && authorization.capabilityDigest == capabilityDigest
      && authorization.requestedHostScopeDigest == requestedHostScopeDigest
      && authorization.oldReceiptsDigest == oldReceiptsDigest
      && authorization.oldActivationEpoch == oldActivationEpoch
      && authorization.bootstrapRecoveryContextDigest
        == authorityContextDigest
      && authorization.humanGateSubjectDigest
        == expectedHumanGateSubjectDigest
  }

  var canonicalValue: String {
    String(decoding: Self.canonicalData([
      schema,
      id,
      challengeID,
      threadID,
      turnID,
      eventID,
      observedRole,
      humanMessageDigest,
      legacyAppBundleIdentifier,
      legacyAppVersion,
      legacyAppBuild,
      legacyIssuerAvailability,
      legacyUnavailableEvidenceDigest,
      authorityKind,
      hostKeyID,
      authorizationID,
      grantID,
      shortCode,
      String(localUserUID),
      deviceID,
      recoveryReason,
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
    ]), as: UTF8.self)
  }

  static func isSHA256Digest(_ value: String) -> Bool {
    guard value.hasPrefix("sha256:"), value.count == 71 else { return false }
    return value.dropFirst(7).allSatisfy {
      $0.isNumber || ("a"..."f").contains(String($0))
    }
  }

  static func digest(_ data: Data) -> String {
    let value = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(value)"
  }

  static func wholeSecond(_ value: Date) -> Date {
    Date(timeIntervalSince1970: value.timeIntervalSince1970.rounded(.down))
  }

  static func canonicalData(_ values: [String]) -> Data {
    var result = Data("TatwoLengthPrefixedFieldsV1".utf8)
    for value in values {
      let bytes = Data(value.utf8)
      result.append(Data("\n\(bytes.count):".utf8))
      result.append(bytes)
    }
    return result
  }
}

extension TatwoGoalRevisionBootstrapRecoveryEvidenceV1 {
  func bindingRootOwnedGrant(
    bodyDigest: String
  ) -> TatwoGoalRevisionBootstrapRecoveryEvidenceV1 {
    TatwoGoalRevisionBootstrapRecoveryEvidenceV1(
      schema: schema,
      id: id,
      challengeID: challengeID,
      threadID: threadID,
      turnID: turnID,
      eventID: eventID,
      observedRole: observedRole,
      humanMessageDigest: humanMessageDigest,
      legacyAppBundleIdentifier: legacyAppBundleIdentifier,
      legacyAppVersion: legacyAppVersion,
      legacyAppBuild: legacyAppBuild,
      legacyIssuerAvailability: legacyIssuerAvailability,
      legacyUnavailableEvidenceDigest: legacyUnavailableEvidenceDigest,
      authorityKind: Self.rootOwnedGrantAuthorityKind,
      hostKeyID: bodyDigest,
      authorizationID: authorizationID,
      grantID: grantID,
      shortCode: shortCode,
      localUserUID: localUserUID,
      deviceID: deviceID,
      recoveryReason: recoveryReason,
      sessionID: sessionID,
      oldPointerRevisionDigest: oldPointerRevisionDigest,
      oldPointerGeneration: oldPointerGeneration,
      oldContractID: oldContractID,
      oldGoalID: oldGoalID,
      oldGoalRevision: oldGoalRevision,
      oldActivationEpoch: oldActivationEpoch,
      oldObjectiveDigest: oldObjectiveDigest,
      oldReceiptsDigest: oldReceiptsDigest,
      newContractID: newContractID,
      newGoalID: newGoalID,
      newGoalRevision: newGoalRevision,
      newObjectiveDigest: newObjectiveDigest,
      topologyDigest: topologyDigest,
      capabilityDigest: capabilityDigest,
      requestedHostScopeDigest: requestedHostScopeDigest,
      allowedOperations: allowedOperations,
      deniedOperations: deniedOperations,
      maxUses: maxUses,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      nonce: nonce)
  }
}

/// Supplies a bootstrap-recovery trust anchor from a boundary that ordinary
/// same-user code cannot replace.
///
/// Production checks the fixed root-owned one-time-grant path and fails closed
/// with `unavailable` when the exact grant is absent. A separately trusted
/// signed host remains supported as an injected integration. Test targets may
/// inject immutable fixtures through `@testable`; the public/SPI issuer
/// surface never accepts caller-supplied key material or a caller-supplied
/// grant path.
protocol TatwoBootstrapRecoveryTrustAnchorProviding: Sendable {
  func trustedPublicKeyRawRepresentation() throws -> Data
  func trustedRootGrant(
    for evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1
  ) throws -> TatwoValidatedRootOwnedBootstrapRecoveryGrant
}

extension TatwoBootstrapRecoveryTrustAnchorProviding {
  func trustedRootGrant(
    for evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1
  ) throws -> TatwoValidatedRootOwnedBootstrapRecoveryGrant {
    throw TatwoHumanGateVerificationError.unavailable
  }
}

struct TatwoUnavailableBootstrapRecoveryTrustAnchorProvider:
  TatwoBootstrapRecoveryTrustAnchorProviding
{
  func trustedPublicKeyRawRepresentation() throws -> Data {
    throw TatwoHumanGateVerificationError.unavailable
  }
}

/// The only recovery receipt issuer surface. It never creates or loads a
/// private key. The trusted host signs the exact payload outside Core; Core
/// only verifies against a public key delivered by an OS-enforced trust
/// provider and persists the receipt create-only.
@_spi(TatwoBootstrapRecoveryHost)
public struct TatwoGoalRevisionBootstrapRecoveryIssuer: Sendable {
  public static let issuerDomain =
    "host.tatwo.ultrawork.user-instruction-recovery"

  public let stateDirectoryURL: URL
  public let receiptStore: TatwoHumanGateReceiptStore
  private let trustAnchorProvider:
    any TatwoBootstrapRecoveryTrustAnchorProviding

  public init(stateDirectoryURL: URL) {
    self.init(
      stateDirectoryURL: stateDirectoryURL,
      trustAnchorProvider:
        TatwoRootOwnedBootstrapRecoveryGrantProvider())
  }

  init(
    stateDirectoryURL: URL,
    trustAnchorProvider:
      any TatwoBootstrapRecoveryTrustAnchorProviding
  ) {
    self.stateDirectoryURL = stateDirectoryURL
    self.receiptStore = TatwoHumanGateReceiptStore(
      directoryURL: stateDirectoryURL.appendingPathComponent(
        "human-gate-receipts", isDirectory: true))
    self.trustAnchorProvider = trustAnchorProvider
  }

  public func signingPayload(
    for evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1,
    now: Date = Date()
  ) throws -> Data {
    let publicKey = try loadPinnedPublicKey()
    try validate(
      evidence: evidence,
      now: now,
      pinnedPublicKey: publicKey)
    return makeReceipt(evidence: evidence, proofDigest: "").signingPayload
  }

  @discardableResult
  public func acceptHostSignedEvidence(
    _ evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1,
    proofDigest: String,
    now: Date = Date()
  ) throws -> TatwoHumanGateReceiptV1 {
    let publicKey = try loadPinnedPublicKey()
    try validate(
      evidence: evidence,
      now: now,
      pinnedPublicKey: publicKey)
    let receipt = makeReceipt(
      evidence: evidence,
      proofDigest: proofDigest)
    guard Self.isValidSignature(
      proofDigest,
      payload: receipt.signingPayload,
      publicKey: publicKey)
    else {
      throw TatwoHumanGateVerificationError.signatureRejected
    }
    try receiptStore.persistAuthorized(receipt)
    let persisted = try receiptStore.require(id: receipt.id)
    guard persisted == receipt else {
      throw TatwoHumanGateVerificationError.consumptionConflict
    }
    return receipt
  }

  /// Accept an exact one-time grant that was installed outside the App/CLI/MCP
  /// trust domain by a fresh administrator interaction. This method never
  /// writes the system grant and cannot create authority on missing state.
  @discardableResult
  public func acceptRootOwnedGrantEvidence(
    _ evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1,
    now: Date = Date()
  ) throws -> TatwoHumanGateReceiptV1 {
    let validated = try trustAnchorProvider.trustedRootGrant(
      for: evidence)
    try validateRootGrantEvidence(
      evidence,
      validated: validated,
      now: now)
    let receipt = makeReceipt(
      evidence: evidence,
      proofDigest: "root-grant:\(validated.fileDigest)")
    try receiptStore.persistAuthorized(receipt)
    let persisted = try receiptStore.require(id: receipt.id)
    guard persisted == receipt else {
      throw TatwoHumanGateVerificationError.consumptionConflict
    }
    return receipt
  }

  func validatePersistedReceipt(
    _ receipt: TatwoHumanGateReceiptV1,
    subjectDigest: String,
    now: Date
  ) throws {
    guard let evidence = receipt.bootstrapRecoveryEvidence else {
      throw TatwoHumanGateVerificationError.invalid(
        "bootstrap_recovery_evidence")
    }
    if evidence.authorityKind
      == TatwoGoalRevisionBootstrapRecoveryEvidenceV1
        .rootOwnedGrantAuthorityKind
    {
      let validated = try trustAnchorProvider.trustedRootGrant(
        for: evidence)
      try validateRootGrantEvidence(
        evidence,
        validated: validated,
        now: now)
      guard receipt.proofDigest
        == "root-grant:\(validated.fileDigest)"
      else {
        throw TatwoHumanGateVerificationError.signatureRejected
      }
    } else {
      let publicKey = try loadPinnedPublicKey()
      try validate(
        evidence: evidence,
        now: now,
        pinnedPublicKey: publicKey)
      guard Self.isValidSignature(
        receipt.proofDigest,
        payload: receipt.signingPayload,
        publicKey: publicKey)
      else {
        throw TatwoHumanGateVerificationError.signatureRejected
      }
    }
    guard receipt.schema == "TatwoHumanGateReceiptV1",
      receipt.id == evidence.id,
      receipt.issuerDomain == Self.issuerDomain,
      receipt.sessionID == evidence.sessionID,
      receipt.oldContractID == evidence.oldContractID,
      receipt.oldGoalID == evidence.oldGoalID,
      receipt.newContractID == evidence.newContractID,
      receipt.newGoalID == evidence.newGoalID,
      receipt.subjectDigest == subjectDigest,
      receipt.subjectDigest == evidence.expectedHumanGateSubjectDigest,
      receipt.issuedAt == evidence.issuedAt,
      receipt.expiresAt == evidence.expiresAt,
      receipt.nonce == evidence.nonce,
      receipt.issuerArtifactIdentity == nil
    else {
      throw TatwoHumanGateVerificationError.invalid(
        "bootstrap_recovery_receipt")
    }
    let persisted = try receiptStore.require(id: receipt.id)
    guard persisted == receipt else {
      throw TatwoHumanGateVerificationError.consumptionConflict
    }
  }

  private func makeReceipt(
    evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1,
    proofDigest: String
  ) -> TatwoHumanGateReceiptV1 {
    TatwoHumanGateReceiptV1(
      id: evidence.id,
      issuerDomain: Self.issuerDomain,
      sessionID: evidence.sessionID,
      oldContractID: evidence.oldContractID,
      oldGoalID: evidence.oldGoalID,
      newContractID: evidence.newContractID,
      newGoalID: evidence.newGoalID,
      subjectDigest: evidence.expectedHumanGateSubjectDigest,
      issuedAt: evidence.issuedAt,
      expiresAt: evidence.expiresAt,
      nonce: evidence.nonce,
      proofDigest: proofDigest,
      bootstrapRecoveryEvidence: evidence)
  }

  private func validate(
    evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1,
    now: Date,
    pinnedPublicKey: Curve25519.Signing.PublicKey
  ) throws {
    let exactStrings = [
      evidence.id,
      evidence.challengeID,
      evidence.threadID,
      evidence.turnID,
      evidence.eventID,
      evidence.humanMessageDigest,
      evidence.legacyAppVersion,
      evidence.legacyAppBuild,
      evidence.legacyUnavailableEvidenceDigest,
      evidence.authorityKind,
      evidence.hostKeyID,
      evidence.authorizationID,
      evidence.grantID,
      evidence.shortCode,
      evidence.deviceID,
      evidence.recoveryReason,
      evidence.sessionID,
      evidence.oldPointerRevisionDigest,
      evidence.oldContractID,
      evidence.oldGoalID,
      evidence.oldObjectiveDigest,
      evidence.oldReceiptsDigest,
      evidence.newContractID,
      evidence.newGoalID,
      evidence.newObjectiveDigest,
      evidence.topologyDigest,
      evidence.capabilityDigest,
      evidence.requestedHostScopeDigest,
      evidence.nonce,
    ]
    let digests = [
      evidence.humanMessageDigest,
      evidence.legacyUnavailableEvidenceDigest,
      evidence.hostKeyID,
      evidence.oldPointerRevisionDigest,
      evidence.oldObjectiveDigest,
      evidence.oldReceiptsDigest,
      evidence.newObjectiveDigest,
      evidence.topologyDigest,
      evidence.capabilityDigest,
      evidence.requestedHostScopeDigest,
      evidence.authorityContextDigest,
      evidence.expectedHumanGateSubjectDigest,
    ]
    guard evidence.schema
      == "TatwoGoalRevisionBootstrapRecoveryEvidenceV1",
      exactStrings.allSatisfy(Self.isExactNonEmpty),
      !evidence.id.contains("/"),
      !evidence.id.contains(".."),
      evidence.observedRole == "user",
      evidence.legacyAppBundleIdentifier == "com.tatwo.ultrawork",
      evidence.legacyIssuerAvailability == "unavailable",
      evidence.authorityKind == Self.signedAuthorityKind,
      evidence.allowedOperations
        == TatwoGoalRevisionBootstrapRecoveryEvidenceV1
          .requiredAllowedOperations,
      evidence.deniedOperations
        == TatwoGoalRevisionBootstrapRecoveryEvidenceV1
          .requiredDeniedOperations,
      evidence.maxUses == 1,
      evidence.oldPointerGeneration > 0,
      evidence.oldGoalRevision > 0,
      evidence.oldGoalRevision < UInt64.max,
      evidence.oldActivationEpoch == evidence.oldGoalRevision,
      evidence.newGoalRevision == evidence.oldGoalRevision + 1,
      evidence.oldContractID != evidence.newContractID,
      evidence.oldGoalID != evidence.newGoalID,
      digests.allSatisfy(
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1.isSHA256Digest),
      evidence.issuedAt <= now,
      evidence.expiresAt > evidence.issuedAt,
      evidence.expiresAt > now,
      evidence.expiresAt.timeIntervalSince(evidence.issuedAt) <= 30 * 60,
      evidence.hostKeyID
        == TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(
          pinnedPublicKey.rawRepresentation)
    else {
      throw TatwoHumanGateVerificationError.invalid(
        "bootstrap_recovery_evidence")
    }
  }

  private static let signedAuthorityKind =
    TatwoGoalRevisionBootstrapRecoveryEvidenceV1.signedHostAuthorityKind

  private func validateRootGrantEvidence(
    _ evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1,
    validated: TatwoValidatedRootOwnedBootstrapRecoveryGrant,
    now: Date
  ) throws {
    let exactStrings = [
      evidence.id,
      evidence.challengeID,
      evidence.threadID,
      evidence.turnID,
      evidence.eventID,
      evidence.humanMessageDigest,
      evidence.legacyAppVersion,
      evidence.legacyAppBuild,
      evidence.legacyUnavailableEvidenceDigest,
      evidence.authorityKind,
      evidence.hostKeyID,
      evidence.authorizationID,
      evidence.grantID,
      evidence.shortCode,
      evidence.deviceID,
      evidence.recoveryReason,
      evidence.sessionID,
      evidence.oldPointerRevisionDigest,
      evidence.oldContractID,
      evidence.oldGoalID,
      evidence.oldObjectiveDigest,
      evidence.oldReceiptsDigest,
      evidence.newContractID,
      evidence.newGoalID,
      evidence.newObjectiveDigest,
      evidence.topologyDigest,
      evidence.capabilityDigest,
      evidence.requestedHostScopeDigest,
      evidence.nonce,
    ]
    let digests = [
      evidence.humanMessageDigest,
      evidence.legacyUnavailableEvidenceDigest,
      evidence.hostKeyID,
      evidence.oldPointerRevisionDigest,
      evidence.oldObjectiveDigest,
      evidence.oldReceiptsDigest,
      evidence.newObjectiveDigest,
      evidence.topologyDigest,
      evidence.capabilityDigest,
      evidence.requestedHostScopeDigest,
      evidence.authorityContextDigest,
      evidence.expectedHumanGateSubjectDigest,
      validated.fileDigest,
    ]
    guard evidence.schema
      == "TatwoGoalRevisionBootstrapRecoveryEvidenceV1",
      exactStrings.allSatisfy(Self.isExactNonEmpty),
      !evidence.id.contains("/"),
      !evidence.id.contains(".."),
      evidence.observedRole == "user",
      evidence.legacyAppBundleIdentifier == "com.tatwo.ultrawork",
      evidence.legacyIssuerAvailability == "unavailable",
      evidence.authorityKind
        == TatwoGoalRevisionBootstrapRecoveryEvidenceV1
          .rootOwnedGrantAuthorityKind,
      evidence.allowedOperations
        == TatwoGoalRevisionBootstrapRecoveryEvidenceV1
          .requiredAllowedOperations,
      evidence.deniedOperations
        == TatwoGoalRevisionBootstrapRecoveryEvidenceV1
          .requiredDeniedOperations,
      evidence.maxUses == 1,
      evidence.oldPointerGeneration > 0,
      evidence.oldGoalRevision > 0,
      evidence.oldGoalRevision < UInt64.max,
      evidence.oldActivationEpoch == evidence.oldGoalRevision,
      evidence.newGoalRevision == evidence.oldGoalRevision + 1,
      evidence.oldContractID != evidence.newContractID,
      evidence.oldGoalID != evidence.newGoalID,
      digests.allSatisfy(
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1.isSHA256Digest),
      evidence.issuedAt <= now,
      evidence.expiresAt > evidence.issuedAt,
      evidence.expiresAt > now,
      evidence.expiresAt.timeIntervalSince(evidence.issuedAt) <= 30 * 60,
      validated.grant.bodyDigest == evidence.hostKeyID,
      validated.grant.body.matches(evidence)
    else {
      throw TatwoHumanGateVerificationError.invalid(
        "bootstrap_recovery_evidence")
    }
  }

  private func loadPinnedPublicKey() throws
    -> Curve25519.Signing.PublicKey
  {
    let data = try trustAnchorProvider
      .trustedPublicKeyRawRepresentation()
    guard data.count == 32,
      let key = try? Curve25519.Signing.PublicKey(
        rawRepresentation: data)
    else {
      throw TatwoHumanGateVerificationError.signatureRejected
    }
    return key
  }

  private static func isExactNonEmpty(_ value: String) -> Bool {
    !value.isEmpty
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isValidSignature(
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
}

extension TatwoGoalRevisionPromotionAuthorizationStore {
  /// Exchange one already-persisted, externally authorized bootstrap recovery
  /// receipt for the existing revision-transition authorization format. This
  /// remains a host SPI; ordinary App, CLI, MCP, and model routes stay
  /// consume-only.
  @_spi(TatwoBootstrapRecoveryHost)
  @discardableResult
  public func authorizeAfterBootstrapRecovery(
    id: String,
    humanGateReceipt: TatwoHumanGateReceiptV1,
    ttl: TimeInterval = 10 * 60,
    now: Date = Date()
  ) throws -> TatwoGoalRevisionPromotionAuthorizationV1 {
    try authorizeAfterBootstrapRecovery(
      id: id,
      humanGateReceipt: humanGateReceipt,
      ttl: ttl,
      now: now,
      trustAnchorProvider:
        TatwoRootOwnedBootstrapRecoveryGrantProvider())
  }

  func authorizeAfterBootstrapRecovery(
    id: String,
    humanGateReceipt: TatwoHumanGateReceiptV1,
    ttl: TimeInterval = 10 * 60,
    now: Date = Date(),
    trustAnchorProvider:
      any TatwoBootstrapRecoveryTrustAnchorProviding
  ) throws -> TatwoGoalRevisionPromotionAuthorizationV1 {
    let safeID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let evidence = humanGateReceipt.bootstrapRecoveryEvidence,
      humanGateReceipt.schema == "TatwoHumanGateReceiptV1",
      humanGateReceipt.issuerDomain
        == TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain,
      safeID == id,
      safeID == evidence.authorizationID,
      !safeID.isEmpty,
      !safeID.contains("/"),
      !safeID.contains(".."),
      ttl.isFinite,
      ttl > 0
    else {
      throw TatwoGoalRevisionPromotionAuthorizationError.invalid
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
      stateDirectoryURL: stateDirectoryURL,
      bootstrapRecoveryTrustAnchorProvider: trustAnchorProvider
    ).validate(
      receipt: humanGateReceipt,
      subjectDigest: evidence.expectedHumanGateSubjectDigest,
      now: now)

    let issuedAt = Self.wholeSecond(humanGateReceipt.issuedAt)
    let expiresAt = min(
      humanGateReceipt.expiresAt,
      issuedAt.addingTimeInterval(max(60, min(ttl, 30 * 60))))
    guard issuedAt <= now,
      expiresAt > now,
      expiresAt > issuedAt
    else {
      throw TatwoGoalRevisionPromotionAuthorizationError.expired
    }

    let nonceSeed = [
      humanGateReceipt.id,
      humanGateReceipt.nonce,
      humanGateReceipt.proofDigest,
      safeID,
      evidence.sessionID,
      evidence.oldPointerRevisionDigest,
      evidence.newContractID,
      evidence.newGoalID,
      evidence.requestedHostScopeDigest,
      evidence.authorityContextDigest,
    ].joined(separator: "\n")
    let unsigned = TatwoGoalRevisionPromotionAuthorizationV1(
      id: safeID,
      issuerDomain: TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain,
      sessionID: evidence.sessionID,
      oldPointerRevisionDigest: evidence.oldPointerRevisionDigest,
      oldPointerGeneration: evidence.oldPointerGeneration,
      oldContractID: evidence.oldContractID,
      oldGoalID: evidence.oldGoalID,
      oldGoalRevision: evidence.oldGoalRevision,
      oldObjectiveDigest: evidence.oldObjectiveDigest,
      newContractID: evidence.newContractID,
      newGoalID: evidence.newGoalID,
      newGoalRevision: evidence.newGoalRevision,
      newObjectiveDigest: evidence.newObjectiveDigest,
      topologyDigest: evidence.topologyDigest,
      capabilityDigest: evidence.capabilityDigest,
      humanGateReceiptID: humanGateReceipt.id,
      requestedHostScopeDigest: evidence.requestedHostScopeDigest,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      nonce: "promotion-\(Self.sha256Hex(nonceSeed))",
      proofDigest: "",
      oldReceiptsDigest: evidence.oldReceiptsDigest,
      oldActivationEpoch: evidence.oldActivationEpoch,
      bootstrapRecoveryContextDigest: evidence.authorityContextDigest)
    guard humanGateReceipt.sessionID == unsigned.sessionID,
      humanGateReceipt.oldContractID == unsigned.oldContractID,
      humanGateReceipt.oldGoalID == unsigned.oldGoalID,
      humanGateReceipt.newContractID == unsigned.newContractID,
      humanGateReceipt.newGoalID == unsigned.newGoalID,
      humanGateReceipt.subjectDigest == unsigned.humanGateSubjectDigest
    else {
      throw TatwoGoalRevisionPromotionAuthorizationError.scopeMismatch(
        "human_gate_receipt")
    }
    let authorization = TatwoGoalRevisionPromotionAuthorizationV1(
      schema: unsigned.schema,
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
      proofDigest: Self.proofDigest(for: unsigned),
      oldReceiptsDigest: unsigned.oldReceiptsDigest,
      oldActivationEpoch: unsigned.oldActivationEpoch,
      bootstrapRecoveryContextDigest:
        unsigned.bootstrapRecoveryContextDigest)
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
}
