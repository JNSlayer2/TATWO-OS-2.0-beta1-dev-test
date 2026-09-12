import CryptoKit
import Foundation

/// Fixed channel signature purposes for remote loop artifacts.
/// Aligns with the hot-sync sidecar model (purpose/deviceID/keyID/digest/signature)
/// while remaining brand-free and scoped to the loop-job channel.
///
/// ## Trust boundary note (M6 durable pin store)
/// Process-local pins remain available via internal `withPin` (tests). Production hosts
/// load peer pins from the durable, locally co-signed store under App Support
/// `device-trust/pin-store/` (`TatwoDeviceTrustPinStore`). Distribution is
/// out-of-band (`device-trust export-identity` / `pin-import` + fingerprint).
/// Empty store does **not** default-trust peers. Live dual-host flag/run is a
/// separate gate; do not treat same-process e2e green as multi-host proof.
public enum TatwoLoopChannelSignaturePurposeV1: String, Codable, Sendable, Equatable {
  case loopJob = "loop-job"
  case loopAck = "loop-ack"
  case loopResult = "loop-result"
  case loopJournal = "loop-journal"
  /// Target-produced raw job output bytes under `outputs/<jobID>`.
  case loopOutput = "loop-output"
  /// Target-produced pre-dispatch readiness snapshot.
  case loopTargetReadiness = "loop-target-readiness"
  /// Target App-produced pressure admission permit for runner spawn.
  case appPressurePermit = "app-pressure-permit"
  /// Skill bundle transport on the sealed loop channel. Job drain must never
  /// open these artifacts; they live under `skillet/`, not `outbox/<target>/*.json`.
  case skilletBundle = "skillet-bundle"
}

extension TatwoLoopJobChannelTrust {
  /// Reloads durable pin state, then verifies a target readiness signature using
  /// the same revocation, generation, digest, signature, and freshness gates as
  /// other channel artifacts.
  func verifyRemoteDispatchReadiness(
    payload: Data,
    signature: TatwoDeviceSignatureV1,
    targetDeviceID: String,
    now: Date,
    maxAgeSec: TimeInterval,
    environment: [String: String]
  ) throws {
    let current = try reloadedFromDurableStoreIfNeeded(environment: environment)
    try current.verify(
      payload: payload,
      purpose: .loopTargetReadiness,
      signature: signature,
      expectedDeviceID: targetDeviceID,
      enforceFreshness: true,
      now: now,
      maxAgeSec: maxAgeSec,
      environment: environment)
  }

  func currentPinnedIdentity(
    deviceID: String,
    environment: [String: String]
  ) throws -> TatwoDevicePublicIdentityV1? {
    try reloadedFromDurableStoreIfNeeded(environment: environment)
      .pinnedIdentities[deviceID]
  }
}

public enum TatwoLoopChannelArtifactKindV1: String, Codable, Sendable, Equatable {
  case job
  case ack
  case result
  case journal
  case output
  case cancel
}

public enum TatwoLoopChannelRejectReasonV1: String, Codable, Sendable, Equatable {
  case missingSignature = "missing_signature"
  case unknownIdentity = "unknown_identity"
  case digestMismatch = "digest_mismatch"
  case invalidSignature = "invalid_signature"
  case revoked = "revoked"
  case producerMismatch = "producer_mismatch"
  /// Artifact payload jobID does not match the caller-requested / path-bound jobID.
  case jobIdMismatch = "job_id_mismatch"
  /// Signature `signedAt` missing, unparseable, or outside the consume freshness window.
  case staleSignature = "stale_signature"
}

public struct TatwoLoopJobRejectEntryV1: Codable, Sendable, Equatable {
  public let schema: String
  public let jobID: String
  public let artifact: TatwoLoopChannelArtifactKindV1
  public let reason: TatwoLoopChannelRejectReasonV1
  public let detail: String?
  public let occurredAt: Date

  public init(
    schema: String = "TatwoLoopJobRejectEntryV1",
    jobID: String,
    artifact: TatwoLoopChannelArtifactKindV1,
    reason: TatwoLoopChannelRejectReasonV1,
    detail: String? = nil,
    occurredAt: Date = Date()
  ) {
    self.schema = schema
    self.jobID = jobID
    self.artifact = artifact
    self.reason = reason
    self.detail = detail.map { String(TatwoPrivacyRedactor.redacted($0).prefix(256)) }
    self.occurredAt = occurredAt
  }
}

/// Fail-closed pin merge violations (durable revoked wins; no silent un-revoke).
public enum TatwoDeviceTrustPinMergeError: Error, Equatable, LocalizedError {
  case cannotUnrevoke(deviceID: String)
  case generationRegression(deviceID: String, existing: UInt64, incoming: UInt64)
  case sameGenerationKeyMismatch(deviceID: String, generation: UInt64)
  case keyReplacementRequiresRotation(deviceID: String)
  case reEnrollmentRequiresAuthority(deviceID: String)
  case reEnrollmentEpochTooLow(deviceID: String, required: UInt64, observed: UInt64)

  public var errorDescription: String? {
    switch self {
    case .cannotUnrevoke(let deviceID):
      "Refusing to overwrite durable revoked pin for \(deviceID) with an active identity."
    case .generationRegression(let deviceID, let existing, let incoming):
      "Refusing pin generation regression for \(deviceID): existing \(existing) incoming \(incoming)."
    case .sameGenerationKeyMismatch(let deviceID, let generation):
      "Refusing same-generation key replacement for \(deviceID) generation \(generation)."
    case .keyReplacementRequiresRotation(let deviceID):
      "Key replacement for \(deviceID) requires an authorized rotation receipt."
    case .reEnrollmentRequiresAuthority(let deviceID):
      "Re-enrollment for revoked device \(deviceID) requires an unrevoked authority-signed rotation receipt."
    case .reEnrollmentEpochTooLow(let deviceID, let required, let observed):
      "Re-enrollment for \(deviceID) supersedes epoch \(observed) below required \(required)."
    }
  }
}

/// Producer/consumer trust context for the file job channel.
///
/// Reuses `TatwoDeviceTrustAuthority` only — no second crypto stack.
/// Production hosts inject Keychain-backed stores; sandbox/e2e/tests inject
/// `TatwoDeviceTestFilePrivateKeyStore` (test path only) or an in-memory store.
///
/// Peer pins load from `TatwoDeviceTrustPinStore` when a durable root is provided.
/// Process-local pin injection uses the same monotonic merge policy as durable load
/// (`withPin` is internal test wiring only and cannot un-revoke without authority re-enrollment).
/// Empty durable store ⇒ no peer pins.
public struct TatwoLoopJobChannelTrust: Sendable {
  /// Default max age for consume-path signature freshness (seconds).
  public static let defaultSignatureMaxAgeSec: TimeInterval = 900
  /// Hard maximum for test-mode env override (seconds). Values above this refuse startup.
  public static let signatureMaxAgeHardMaxSec: TimeInterval = 3600
  /// Clock skew tolerance applied on both sides of the freshness window (seconds).
  public static let signatureClockSkewSec: TimeInterval = 120
  /// Env override for max age (TATWO_TEST_MODE=1 only; production ignores).
  public static let signatureMaxAgeEnvKey = "TATWO_ULTRAWORK_JOB_SIGNATURE_MAX_AGE_SEC"
  /// Explicit test capability gate used by freshness override and test key stores.
  public static let testModeEnvKey = "TATWO_TEST_MODE"

  public let authority: TatwoDeviceTrustAuthority
  public let localIdentity: TatwoDevicePublicIdentityV1
  /// deviceID → pinned public identity (peers and typically self).
  public let pinnedIdentities: [String: TatwoDevicePublicIdentityV1]
  /// Durable pin-store generation observed when this snapshot was built (0 = none).
  public let pinStoreGeneration: UInt64
  /// Durable pin-store root used for live reload; nil disables generation refresh.
  public let durablePinStoreRoot: URL?

  public init(
    authority: TatwoDeviceTrustAuthority,
    localIdentity: TatwoDevicePublicIdentityV1,
    pinnedIdentities: [String: TatwoDevicePublicIdentityV1],
    pinStoreGeneration: UInt64 = 0,
    durablePinStoreRoot: URL? = nil
  ) {
    self.authority = authority
    self.localIdentity = localIdentity
    self.pinnedIdentities = pinnedIdentities
    self.pinStoreGeneration = pinStoreGeneration
    self.durablePinStoreRoot = durablePinStoreRoot.map { $0.standardizedFileURL }
  }

  /// Process-local pin injection (**test / internal only** — not a production API).
  /// Uses the same monotonic merge policy as durable enroll — cannot un-revoke
  /// without an authority-signed re-enrollment receipt.
  func withPin(
    _ identity: TatwoDevicePublicIdentityV1,
    rotationReceipt: TatwoDeviceKeyRotationReceiptV1? = nil,
    authorizingIdentity: TatwoDevicePublicIdentityV1? = nil,
    knownRevocationEpoch: UInt64 = 0
  ) throws -> TatwoLoopJobChannelTrust {
    var pins = pinnedIdentities
    let authorizer =
      authorizingIdentity
      ?? rotationReceipt.flatMap { receipt in
        pins.first(where: { $0.value.keyID == receipt.authorization.keyID
          && $0.value.deviceID == receipt.authorization.deviceID })?.value
      }
    pins[identity.deviceID] = try Self.mergePinnedIdentity(
      existing: pins[identity.deviceID],
      incoming: identity,
      rotationReceipt: rotationReceipt,
      authorizingIdentity: authorizer,
      knownRevocationEpoch: knownRevocationEpoch)
    let nextLocal =
      localIdentity.deviceID == identity.deviceID
      ? (pins[identity.deviceID] ?? localIdentity)
      : localIdentity
    return TatwoLoopJobChannelTrust(
      authority: authority,
      localIdentity: nextLocal,
      pinnedIdentities: pins,
      pinStoreGeneration: pinStoreGeneration,
      durablePinStoreRoot: durablePinStoreRoot)
  }

  /// Monotonic pin merge: durable revoked wins; post-revoke resurrection requires
  /// authority-signed re-enrollment (never self-signed by the revoked key).
  public static func mergePinnedIdentity(
    existing: TatwoDevicePublicIdentityV1?,
    incoming: TatwoDevicePublicIdentityV1,
    rotationReceipt: TatwoDeviceKeyRotationReceiptV1? = nil,
    authorizingIdentity: TatwoDevicePublicIdentityV1? = nil,
    knownRevocationEpoch: UInt64 = 0
  ) throws -> TatwoDevicePublicIdentityV1 {
    try TatwoDeviceTrustAuthority.validatePublicIdentity(incoming)
    guard let existing else { return incoming }
    guard existing.deviceID == incoming.deviceID else { return incoming }
    if existing == incoming { return existing }

    if incoming.keyGeneration < existing.keyGeneration {
      throw TatwoDeviceTrustPinMergeError.generationRegression(
        deviceID: existing.deviceID,
        existing: existing.keyGeneration,
        incoming: incoming.keyGeneration)
    }

    if incoming.keyGeneration == existing.keyGeneration {
      if incoming.keyID != existing.keyID || incoming.publicKey != existing.publicKey {
        throw TatwoDeviceTrustPinMergeError.sameGenerationKeyMismatch(
          deviceID: existing.deviceID,
          generation: existing.keyGeneration)
      }
      // Same key material: revoked dominates active.
      if existing.keyStatus == .revoked {
        if incoming.keyStatus == .active {
          throw TatwoDeviceTrustPinMergeError.cannotUnrevoke(deviceID: existing.deviceID)
        }
        return existing
      }
      if incoming.keyStatus == .revoked {
        return incoming
      }
      return existing
    }

    // Higher generation: key replacement requires authorized rotation receipt.
    let keyChanged =
      incoming.keyID != existing.keyID || incoming.publicKey != existing.publicKey
    let postRevocationResurrection =
      existing.keyStatus == .revoked && incoming.keyStatus == .active

    if keyChanged || postRevocationResurrection {
      guard let rotationReceipt else {
        throw TatwoDeviceTrustPinMergeError.keyReplacementRequiresRotation(
          deviceID: existing.deviceID)
      }
      guard rotationReceipt.newIdentity.keyID == incoming.keyID,
        rotationReceipt.newIdentity.keyGeneration == incoming.keyGeneration,
        rotationReceipt.newIdentity.publicKey == incoming.publicKey
      else {
        throw TatwoDeviceTrustPinMergeError.keyReplacementRequiresRotation(
          deviceID: existing.deviceID)
      }

      if postRevocationResurrection || knownRevocationEpoch > 0 {
        // Authority epoch chain: re-enrollment must supersede known revocation.
        guard rotationReceipt.isReEnrollment else {
          throw TatwoDeviceTrustPinMergeError.reEnrollmentRequiresAuthority(
            deviceID: existing.deviceID)
        }
        let requiredEpoch = max(knownRevocationEpoch, 1)
        if rotationReceipt.supersedesRevocationEpoch < requiredEpoch {
          throw TatwoDeviceTrustPinMergeError.reEnrollmentEpochTooLow(
            deviceID: existing.deviceID,
            required: requiredEpoch,
            observed: rotationReceipt.supersedesRevocationEpoch)
        }
        guard let authorizer = authorizingIdentity, authorizer.keyStatus == .active else {
          throw TatwoDeviceTrustPinMergeError.reEnrollmentRequiresAuthority(
            deviceID: existing.deviceID)
        }
        try TatwoDeviceTrustAuthority.verifyRotation(
          rotationReceipt,
          oldIdentity: existing,
          authorizingIdentity: authorizer)
      } else {
        // Normal higher-generation rotation: prior active key self-signs.
        guard existing.keyStatus == .active else {
          throw TatwoDeviceTrustPinMergeError.reEnrollmentRequiresAuthority(
            deviceID: existing.deviceID)
        }
        try TatwoDeviceTrustAuthority.verifyRotation(
          rotationReceipt,
          oldIdentity: existing,
          authorizingIdentity: nil)
      }
    }

    if existing.keyStatus == .revoked, incoming.keyStatus == .active, !keyChanged {
      throw TatwoDeviceTrustPinMergeError.cannotUnrevoke(deviceID: existing.deviceID)
    }
    return incoming
  }

  public func sign(
    payload: Data,
    purpose: TatwoLoopChannelSignaturePurposeV1,
    signedAt: Date = Date()
  ) throws -> TatwoDeviceSignatureV1 {
    try authority.sign(
      payload: payload,
      purpose: purpose.rawValue,
      identity: localIdentity,
      signedAt: Self.iso8601(signedAt))
  }

  /// Fail-closed verification: missing pin, revoked, digest mismatch, or bad sig all throw.
  ///
  /// - Parameter enforceFreshness: When true (consume path only — runner taking a job,
  ///   accepting an ack), require `signedAt` within the max-age window. Historical
  ///   journal/result audit reads pass false so old ledgers do not retroactively fail.
  public func verify(
    payload: Data,
    purpose: TatwoLoopChannelSignaturePurposeV1,
    signature: TatwoDeviceSignatureV1,
    expectedDeviceID: String?,
    enforceFreshness: Bool = false,
    now: Date = Date(),
    maxAgeSec: TimeInterval? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    if let expectedDeviceID, signature.deviceID != expectedDeviceID {
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: expectedDeviceID,
        reason: TatwoLoopChannelRejectReasonV1.producerMismatch.rawValue)
    }
    guard let pinned = pinnedIdentities[signature.deviceID] else {
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: signature.deviceID,
        reason: TatwoLoopChannelRejectReasonV1.unknownIdentity.rawValue)
    }
    guard pinned.keyStatus == .active else {
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: signature.deviceID,
        reason: TatwoLoopChannelRejectReasonV1.revoked.rawValue)
    }
    let observedDigest = Self.sha256Hex(payload)
    if signature.payloadDigest != observedDigest {
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: signature.deviceID,
        reason: TatwoLoopChannelRejectReasonV1.digestMismatch.rawValue)
    }
    if enforceFreshness {
      try Self.requireFreshSignature(
        signature,
        now: now,
        maxAgeSec: maxAgeSec ?? (try Self.signatureMaxAgeSec(environment: environment)))
    }
    do {
      try TatwoDeviceTrustAuthority.verify(
        payload: payload,
        purpose: purpose.rawValue,
        signature: signature,
        pinnedIdentity: pinned)
    } catch let error as TatwoDeviceTrustError {
      switch error {
      case .inactiveKey:
        throw TatwoLoopJobStateError.signatureRejected(
          jobID: signature.deviceID,
          reason: TatwoLoopChannelRejectReasonV1.revoked.rawValue)
      case .invalidSignature, .staleKeyGeneration, .invalidIdentity, .invalidPublicKey:
        throw TatwoLoopJobStateError.signatureRejected(
          jobID: signature.deviceID,
          reason: TatwoLoopChannelRejectReasonV1.invalidSignature.rawValue)
      default:
        throw TatwoLoopJobStateError.signatureRejected(
          jobID: signature.deviceID,
          reason: TatwoLoopChannelRejectReasonV1.invalidSignature.rawValue)
      }
    }
  }

  /// Ingest a verified revocation receipt and mark the matching pin revoked.
  /// Optional `durableStore` persists the receipt (co-signed) for later reloads.
  public func ingestRevocationReceipt(
    _ receipt: TatwoDeviceKeyRevocationReceiptV1,
    expectedAuthorityEpoch: UInt64,
    durableStore: TatwoDeviceTrustPinStore? = nil
  ) throws -> TatwoLoopJobChannelTrust {
    guard let target = pinnedIdentities[receipt.targetDeviceID] else {
      throw TatwoDeviceTrustError.invalidRevocation
    }
    guard let authorizer = pinnedIdentities[receipt.authorizedByDeviceID] else {
      throw TatwoDeviceTrustError.invalidRevocation
    }
    try TatwoDeviceTrustAuthority.verifyRevocation(
      receipt,
      targetIdentity: target,
      authorizerIdentity: authorizer,
      expectedAuthorityEpoch: expectedAuthorityEpoch)
    if let durableStore {
      _ = try durableStore.ingestRevocation(
        receipt,
        expectedAuthorityEpoch: expectedAuthorityEpoch)
    }
    let revoked = TatwoDevicePublicIdentityV1(
      deviceID: target.deviceID,
      keyID: target.keyID,
      publicKey: target.publicKey,
      keyGeneration: target.keyGeneration,
      keyStatus: .revoked,
      pinnedAt: target.pinnedAt)
    var pins = pinnedIdentities
    pins[revoked.deviceID] = try Self.mergePinnedIdentity(
      existing: pins[revoked.deviceID],
      incoming: revoked)
    let nextLocal =
      localIdentity.deviceID == revoked.deviceID ? revoked : localIdentity
    let nextGeneration: UInt64
    if let durableStore {
      nextGeneration = try durableStore.currentStoreGeneration()
    } else {
      nextGeneration = pinStoreGeneration
    }
    return TatwoLoopJobChannelTrust(
      authority: authority,
      localIdentity: nextLocal,
      pinnedIdentities: pins,
      pinStoreGeneration: nextGeneration,
      durablePinStoreRoot: durablePinStoreRoot ?? durableStore?.rootURL)
  }

  /// Convenience: enroll a fresh local identity under a private-key store and pin it.
  /// When `durablePinStoreRoot` is set (or the default App Support pin-store exists),
  /// co-signed peer pins and revocations are loaded. Empty store = no peer trust.
  /// Durable revoked pins cannot be overridden by `additionalPins`.
  public static func enroll(
    deviceID: String,
    privateKeyStore: any TatwoDevicePrivateKeyStore,
    pinnedAt: Date = Date(),
    additionalPins: [TatwoDevicePublicIdentityV1] = [],
    durablePinStoreRoot: URL? = nil,
    loadDurablePins: Bool = false,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> TatwoLoopJobChannelTrust {
    // Fail closed on illegal freshness override before building trust.
    _ = try signatureMaxAgeSec(environment: environment)

    let authority = TatwoDeviceTrustAuthority(privateKeyStore: privateKeyStore)
    let identity = try authority.ensureIdentity(
      deviceID: deviceID,
      pinnedAt: iso8601(pinnedAt))
    var pins: [String: TatwoDevicePublicIdentityV1] = [identity.deviceID: identity]
    var storeGeneration: UInt64 = 0

    let storeRoot = durablePinStoreRoot ?? (
      loadDurablePins ? TatwoDeviceTrustPinStore.defaultRoot(environment: environment) : nil
    )
    if let storeRoot {
      let pinStore = TatwoDeviceTrustPinStore(
        rootURL: storeRoot,
        authority: authority,
        localIdentity: identity,
        environment: environment)
      let loaded = try pinStore.load()
      storeGeneration = loaded.storeGeneration
      for (id, pin) in loaded.pins {
        pins[id] = try mergePinnedIdentity(existing: pins[id], incoming: pin)
      }
      // Ensure self remains present even if store had no self pin.
      if pins[identity.deviceID] == nil {
        pins[identity.deviceID] = identity
      }
    }

    for pin in additionalPins {
      pins[pin.deviceID] = try mergePinnedIdentity(
        existing: pins[pin.deviceID],
        incoming: pin)
    }

    let resolvedLocal = pins[identity.deviceID] ?? identity
    return TatwoLoopJobChannelTrust(
      authority: authority,
      localIdentity: resolvedLocal,
      pinnedIdentities: pins,
      pinStoreGeneration: storeGeneration,
      durablePinStoreRoot: storeRoot)
  }

  /// Build a pin-store handle for this trust context (CLI / host wiring).
  public func durablePinStore(
    rootURL: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoDeviceTrustPinStore {
    TatwoDeviceTrustPinStore(
      rootURL: rootURL,
      authority: authority,
      localIdentity: localIdentity,
      environment: environment)
  }

  /// Reload pins from the durable store when generation advanced (revocation live reload).
  public func reloadedFromDurableStoreIfNeeded(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> TatwoLoopJobChannelTrust {
    guard let storeRoot = durablePinStoreRoot else { return self }
    let pinStore = durablePinStore(rootURL: storeRoot, environment: environment)
    let currentGeneration = try pinStore.currentStoreGeneration()
    guard currentGeneration != pinStoreGeneration else { return self }
    let loaded = try pinStore.load()
    var pins: [String: TatwoDevicePublicIdentityV1] = [
      localIdentity.deviceID: localIdentity
    ]
    for (id, pin) in loaded.pins {
      pins[id] = try Self.mergePinnedIdentity(existing: pins[id], incoming: pin)
    }
    if pins[localIdentity.deviceID] == nil {
      pins[localIdentity.deviceID] = localIdentity
    }
    let resolvedLocal = pins[localIdentity.deviceID] ?? localIdentity
    return TatwoLoopJobChannelTrust(
      authority: authority,
      localIdentity: resolvedLocal,
      pinnedIdentities: pins,
      pinStoreGeneration: loaded.storeGeneration,
      durablePinStoreRoot: storeRoot)
  }

  /// Resolve consume-path signature max age.
  /// - Production (`TATWO_TEST_MODE` unset/≠1): always 900s; env override ignored.
  /// - Test mode: env override allowed only for finite values in `(0, 3600]`; otherwise throws.
  public static func signatureMaxAgeSec(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> TimeInterval {
    let testMode = environment[testModeEnvKey] == "1"
    guard testMode else {
      return defaultSignatureMaxAgeSec
    }
    guard let raw = environment[signatureMaxAgeEnvKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else {
      return defaultSignatureMaxAgeSec
    }
    guard let value = TimeInterval(raw),
      value.isFinite,
      value > 0,
      value <= signatureMaxAgeHardMaxSec
    else {
      throw TatwoLoopJobStateError.invalidPayload(
        "\(signatureMaxAgeEnvKey) must be a finite positive number ≤ \(Int(signatureMaxAgeHardMaxSec)) when \(testModeEnvKey)=1")
    }
    return value
  }

  /// Fail-closed freshness gate for consume paths only.
  public static func requireFreshSignature(
    _ signature: TatwoDeviceSignatureV1,
    now: Date = Date(),
    maxAgeSec: TimeInterval = defaultSignatureMaxAgeSec,
    clockSkewSec: TimeInterval = signatureClockSkewSec
  ) throws {
    let trimmed = signature.signedAt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let signedAt = parseISO8601(trimmed) else {
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: signature.deviceID,
        reason: TatwoLoopChannelRejectReasonV1.staleSignature.rawValue)
    }
    let age = now.timeIntervalSince(signedAt)
    // Too old (beyond maxAge + skew) or too far in the future (beyond +skew).
    if age > maxAgeSec + clockSkewSec || age < -clockSkewSec {
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: signature.deviceID,
        reason: TatwoLoopChannelRejectReasonV1.staleSignature.rawValue)
    }
  }

  public static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  public static func parseISO8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: string) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
  }

  public static func sha256Hex(_ data: Data) -> String {
    // Match TatwoDeviceTrustAuthority digest encoding (raw lowercase hex, no prefix).
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
