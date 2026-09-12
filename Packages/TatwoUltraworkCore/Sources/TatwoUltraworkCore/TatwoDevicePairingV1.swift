import Foundation

// MARK: - Plug-and-Manage S2: discovery → pairing (pure Core)
//
// Design: docs/protocol/PLUG_AND_MANAGE_DESIGN.md §4.3 / N1 discovery types.
// Iron rules:
// - Reuse Devices-page limited single-use pairing code semantics (TTL 180s,
//   one-shot consume, replay reject). Source of truth for production wire
//   format remains scripts/tatwo-device-sync.sh cmd_pairing_create /
//   cmd_register; this file ports the pure validation rules into Core.
// - State machine is explicit-event only; no skip steps.
// - `unstable:` identity fingerprints cannot enter pairing (fail-closed).
// - Pairing never grants execution capability; canBeManaged stays false in S2
//   (S3 enroll may raise it only after state == paired).
// - No network, no real device IO, no second crypto stack.

// MARK: - Pairing code (reused Devices page / channel schema)

/// Wire-compatible pairing code record.
///
/// Reuses the JSON shape produced by `scripts/tatwo-device-sync.sh`
/// `cmd_pairing_create` (seed / createdAt / expiresAt / consumedAt /
/// createdBy / authorityPrimary / authorityEpoch).
public struct TatwoDevicePairingCodeRecordV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoDevicePairingCodeRecordV1"
  /// Production TTL: 180s (`TATWO_PAIRING_TTL_SECONDS` default in device-sync).
  public static let ttlSeconds: TimeInterval = 180
  /// 8-char A–Z0–9 seed (device-sync `cmd_pairing_create`).
  public static let seedLength = 8

  public let schema: String
  public let seed: String
  public let createdAt: Date
  public let expiresAt: Date
  /// Empty / nil until successful single-use consumption.
  public let consumedAt: Date?
  public let createdBy: String
  public let authorityPrimary: String
  public let authorityEpoch: UInt64

  public init(
    schema: String = TatwoDevicePairingCodeRecordV1.schemaName,
    seed: String,
    createdAt: Date,
    expiresAt: Date,
    consumedAt: Date? = nil,
    createdBy: String,
    authorityPrimary: String,
    authorityEpoch: UInt64
  ) {
    self.schema = schema
    self.seed = seed
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.consumedAt = consumedAt
    self.createdBy = createdBy
    self.authorityPrimary = authorityPrimary
    self.authorityEpoch = authorityEpoch
  }

  public var isConsumed: Bool { consumedAt != nil }

  public func isExpired(at now: Date) -> Bool {
    expiresAt <= now
  }
}

/// Pure pairing-code mint / validate / consume (no channel IO).
///
/// Reuse paths (receipt must list these):
/// - `scripts/tatwo-device-sync.sh` `PAIRING_TTL_SECONDS` + `cmd_pairing_create` + register consume
/// - `Apps/TatwoUltraworkMac/.../DeviceLocalActionOutbox.swift` `createPairing` intent
/// - `docs/tatwo/devices-sync-perf-test-plan.md` §4 (180s / consumedAt / replay)
public enum TatwoDevicePairingCodeEngineV1 {
  private static let seedAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

  public static func isValidSeedFormat(_ seed: String) -> Bool {
    guard seed.count == TatwoDevicePairingCodeRecordV1.seedLength else { return false }
    return seed.unicodeScalars.allSatisfy { scalar in
      (scalar.value >= 0x41 && scalar.value <= 0x5A)  // A-Z
        || (scalar.value >= 0x30 && scalar.value <= 0x39)  // 0-9
    }
  }

  /// Mint a limited single-use code. `seed` may be injected for tests; production
  /// callers should pass nil to draw a random A–Z0–9 seed.
  public static func mint(
    createdBy: String,
    authorityPrimary: String,
    authorityEpoch: UInt64,
    now: Date = Date(),
    ttlSeconds: TimeInterval = TatwoDevicePairingCodeRecordV1.ttlSeconds,
    seed: String? = nil,
    randomBytes: ((Int) -> [UInt8])? = nil
  ) throws -> TatwoDevicePairingCodeRecordV1 {
    let resolvedSeed: String
    if let seed {
      guard isValidSeedFormat(seed) else {
        throw TatwoDevicePairingErrorV1.invalidSeedFormat(seed)
      }
      resolvedSeed = seed
    } else {
      resolvedSeed = try generateSeed(randomBytes: randomBytes)
    }
    guard ttlSeconds > 0, ttlSeconds.isFinite else {
      throw TatwoDevicePairingErrorV1.invalidTTL
    }
    let createdByTrim = createdBy.trimmingCharacters(in: .whitespacesAndNewlines)
    let primaryTrim = authorityPrimary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !createdByTrim.isEmpty, !primaryTrim.isEmpty else {
      throw TatwoDevicePairingErrorV1.emptyAuthority
    }
    return TatwoDevicePairingCodeRecordV1(
      seed: resolvedSeed,
      createdAt: now,
      expiresAt: now.addingTimeInterval(ttlSeconds),
      consumedAt: nil,
      createdBy: createdByTrim,
      authorityPrimary: primaryTrim,
      authorityEpoch: authorityEpoch)
  }

  /// Validate seed against a record: format, match, not expired, not reused,
  /// authority binding. Does **not** mutate.
  public static func validate(
    seed: String,
    against record: TatwoDevicePairingCodeRecordV1,
    expectedPrimary: String? = nil,
    expectedEpoch: UInt64? = nil,
    now: Date = Date()
  ) throws {
    guard isValidSeedFormat(seed) else {
      throw TatwoDevicePairingErrorV1.invalidSeedFormat(seed)
    }
    guard seed == record.seed else {
      throw TatwoDevicePairingErrorV1.seedMismatch
    }
    if record.isConsumed {
      throw TatwoDevicePairingErrorV1.codeAlreadyConsumed
    }
    if record.isExpired(at: now) {
      throw TatwoDevicePairingErrorV1.codeExpired
    }
    if let expectedPrimary {
      let want = expectedPrimary.trimmingCharacters(in: .whitespacesAndNewlines)
      guard record.authorityPrimary == want, record.createdBy == want else {
        throw TatwoDevicePairingErrorV1.authorityMismatch
      }
    }
    if let expectedEpoch, record.authorityEpoch != expectedEpoch {
      throw TatwoDevicePairingErrorV1.authorityMismatch
    }
  }

  /// Single-use consume: validate then write `consumedAt`. Replay fails.
  public static func consume(
    seed: String,
    record: TatwoDevicePairingCodeRecordV1,
    expectedPrimary: String? = nil,
    expectedEpoch: UInt64? = nil,
    now: Date = Date()
  ) throws -> TatwoDevicePairingCodeRecordV1 {
    try validate(
      seed: seed,
      against: record,
      expectedPrimary: expectedPrimary,
      expectedEpoch: expectedEpoch,
      now: now)
    return TatwoDevicePairingCodeRecordV1(
      schema: record.schema,
      seed: record.seed,
      createdAt: record.createdAt,
      expiresAt: record.expiresAt,
      consumedAt: now,
      createdBy: record.createdBy,
      authorityPrimary: record.authorityPrimary,
      authorityEpoch: record.authorityEpoch)
  }

  private static func generateSeed(randomBytes: ((Int) -> [UInt8])?) throws -> String {
    let bytes: [UInt8]
    if let randomBytes {
      bytes = randomBytes(TatwoDevicePairingCodeRecordV1.seedLength)
    } else {
      // SystemRandomNumberGenerator is the platform CSPRNG front-end (not a
      // second crypto stack). Production channel mint remains in
      // scripts/tatwo-device-sync.sh; this path is for pure-Core tests/host
      // facades that do not touch the channel.
      var rng = SystemRandomNumberGenerator()
      bytes = (0..<TatwoDevicePairingCodeRecordV1.seedLength).map { _ in
        UInt8.random(in: 0...255, using: &rng)
      }
    }
    guard bytes.count >= TatwoDevicePairingCodeRecordV1.seedLength else {
      throw TatwoDevicePairingErrorV1.seedEntropyUnavailable
    }
    var chars: [Character] = []
    chars.reserveCapacity(TatwoDevicePairingCodeRecordV1.seedLength)
    for i in 0..<TatwoDevicePairingCodeRecordV1.seedLength {
      let idx = Int(bytes[i]) % seedAlphabet.count
      chars.append(seedAlphabet[idx])
    }
    return String(chars)
  }
}

// MARK: - Pairing request (from discovered device)

/// Pairing request minted from a discovered (still untrusted) device.
///
/// Always carries a limited single-use pairing code. Does **not** invoke
/// real channel IO or pair any physical device.
public struct TatwoDevicePairingRequestV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoDevicePairingRequestV1"

  public let schema: String
  public let requestID: String
  public let discoveryName: String
  public let identityFingerprint: String
  public let transport: TatwoDiscoveredTransportV1
  public let pairingCode: TatwoDevicePairingCodeRecordV1
  public let requestedAt: Date
  /// Always false at request time (pairing ≠ manage / enroll).
  public let grantsExecutionCapability: Bool
  public let capabilityList: [String]

  public init(
    schema: String = TatwoDevicePairingRequestV1.schemaName,
    requestID: String = UUID().uuidString,
    discoveryName: String,
    identityFingerprint: String,
    transport: TatwoDiscoveredTransportV1,
    pairingCode: TatwoDevicePairingCodeRecordV1,
    requestedAt: Date,
    grantsExecutionCapability: Bool = false,
    capabilityList: [String] = []
  ) {
    self.schema = schema
    self.requestID = requestID
    self.discoveryName = discoveryName
    self.identityFingerprint = identityFingerprint
    self.transport = transport
    self.pairingCode = pairingCode
    self.requestedAt = requestedAt
    // Iron rule: pairing never grants capability; force false regardless of caller.
    self.grantsExecutionCapability = false
    self.capabilityList = []
    _ = grantsExecutionCapability
    _ = capabilityList
  }

  /// Build a pairing request from a discovered device + minted code.
  /// Rejects `unstable:` fingerprints (no serial-like material).
  public static func make(
    from device: TatwoDiscoveredDeviceV1,
    pairingCode: TatwoDevicePairingCodeRecordV1,
    requestID: String = UUID().uuidString,
    now: Date = Date()
  ) throws -> TatwoDevicePairingRequestV1 {
    try device.validateS1Invariants()
    if device.hasUnstableIdentity {
      throw TatwoDevicePairingErrorV1.unstableIdentityForbidden(device.identityFingerprint)
    }
    guard device.identityFingerprint.hasPrefix("sha256:") else {
      throw TatwoDevicePairingErrorV1.unstableIdentityForbidden(device.identityFingerprint)
    }
    return TatwoDevicePairingRequestV1(
      requestID: requestID,
      discoveryName: device.name,
      identityFingerprint: device.identityFingerprint,
      transport: device.transport,
      pairingCode: pairingCode,
      requestedAt: now)
  }
}

// MARK: - State machine

/// Explicit pairing lifecycle. No automatic advancement.
public enum TatwoDevicePairingStateV1: String, Codable, Sendable, CaseIterable, Equatable {
  case discovered
  case pairingRequested
  case pairingCodeVerified
  case paired
}

/// Explicit events. Every transition requires the matching event; skips fail closed.
public enum TatwoDevicePairingEventV1: Sendable, Equatable {
  /// discovered → pairingRequested (mints/attaches code via request).
  case requestPairing(TatwoDevicePairingRequestV1)
  /// pairingRequested → pairingCodeVerified (consume code).
  case verifyPairingCode(seed: String)
  /// pairingCodeVerified → paired (identity confirmed; still unmanaged).
  case completePairing
}

public enum TatwoDevicePairingErrorV1: Error, LocalizedError, Equatable, Sendable {
  case invalidSeedFormat(String)
  case invalidTTL
  case emptyAuthority
  case seedEntropyUnavailable
  case seedMismatch
  case codeExpired
  case codeAlreadyConsumed
  case authorityMismatch
  case unstableIdentityForbidden(String)
  case invalidTransition(from: TatwoDevicePairingStateV1, event: String)
  case requestFingerprintMismatch
  case pairingDoesNotGrantManage
  case pairingProofMissing
  case pairingProofInvalid

  public var errorDescription: String? {
    switch self {
    case let .invalidSeedFormat(seed):
      "pairing seed format invalid: \(seed)"
    case .invalidTTL:
      "pairing TTL must be positive"
    case .emptyAuthority:
      "pairing authority primary/createdBy must be non-empty"
    case .seedEntropyUnavailable:
      "pairing seed entropy unavailable"
    case .seedMismatch:
      "pairing seed does not match the active request"
    case .codeExpired:
      "pairing code expired"
    case .codeAlreadyConsumed:
      "pairing code already consumed (replay rejected)"
    case .authorityMismatch:
      "pairing code authority primary/epoch mismatch"
    case let .unstableIdentityForbidden(fp):
      "unstable identity fingerprint cannot enter pairing: \(fp)"
    case let .invalidTransition(from, event):
      "pairing state \(from.rawValue) rejects event \(event)"
    case .requestFingerprintMismatch:
      "pairing request identityFingerprint does not match session device"
    case .pairingDoesNotGrantManage:
      "pairing does not grant canBeManaged; enroll is S3"
    case .pairingProofMissing:
      "paired aggregate is missing the verified pairing proof"
    case .pairingProofInvalid:
      "pairing proof is not bound to the paired device/session"
    }
  }
}

/// Capability proof minted only by the pairing-code verification transition.
///
/// The initializer is intentionally internal: callers can inspect and
/// present a proof to the S3 manage seam, but cannot manufacture one by
/// calling a public initializer.
public struct TatwoDevicePairingProofV1: Sendable, Equatable {
  public static let schemaName = "TatwoDevicePairingProofV1"

  public let schema: String
  public let verificationDigest: String
  public let verifiedAt: Date
  public let deviceFingerprint: String

  internal init(
    verificationDigest: String,
    verifiedAt: Date,
    deviceFingerprint: String
  ) {
    self.schema = Self.schemaName
    self.verificationDigest = verificationDigest
    self.verifiedAt = verifiedAt
    self.deviceFingerprint = deviceFingerprint
  }
}

/// In-memory pairing session bound to one discovered device.
///
/// Pure Core: no network, no channel writes, no real device pairing.
public struct TatwoDevicePairingSessionV1: Sendable, Equatable {
  public let device: TatwoDiscoveredDeviceV1
  public private(set) var state: TatwoDevicePairingStateV1
  public private(set) var activeRequest: TatwoDevicePairingRequestV1?
  public private(set) var activeCode: TatwoDevicePairingCodeRecordV1?
  /// Non-nil only after the pairing-code verification transition succeeds.
  public private(set) var pairingProof: TatwoDevicePairingProofV1?
  /// S3 enroll may set this only when `state == .paired`. S2 never sets true.
  public private(set) var enrollManagedFlag: Bool
  public let authorityPrimary: String
  public let authorityEpoch: UInt64

  internal init(
    device: TatwoDiscoveredDeviceV1,
    authorityPrimary: String,
    authorityEpoch: UInt64
  ) {
    self.device = device
    self.state = .discovered
    self.activeRequest = nil
    self.activeCode = nil
    self.pairingProof = nil
    self.enrollManagedFlag = false
    self.authorityPrimary = authorityPrimary
    self.authorityEpoch = authorityEpoch
  }

  /// Manageable only after paired **and** S3 enroll flag. Pairing alone is never enough.
  public var canBeManaged: Bool {
    state == .paired && enrollManagedFlag
  }

  /// True once identity is paired; S3 may then enroll. Pairing does not set manage.
  public var mayBecomeManagedAfterEnroll: Bool {
    state == .paired
  }

  /// Apply an explicit event. Skip-step attempts throw `invalidTransition`.
  public mutating func apply(
    _ event: TatwoDevicePairingEventV1,
    now: Date = Date()
  ) throws {
    switch (state, event) {
    case (.discovered, let .requestPairing(request)):
      try acceptRequest(request, now: now)
      state = .pairingRequested

    case (.pairingRequested, let .verifyPairingCode(seed)):
      guard var code = activeCode else {
        throw TatwoDevicePairingErrorV1.invalidTransition(
          from: state, event: "verifyPairingCode(missing-code)")
      }
      code = try TatwoDevicePairingCodeEngineV1.consume(
        seed: seed,
        record: code,
        expectedPrimary: authorityPrimary,
        expectedEpoch: authorityEpoch,
        now: now)
      activeCode = code
      if let request = activeRequest {
        activeRequest = TatwoDevicePairingRequestV1(
          requestID: request.requestID,
          discoveryName: request.discoveryName,
          identityFingerprint: request.identityFingerprint,
          transport: request.transport,
          pairingCode: code,
          requestedAt: request.requestedAt)
      }
      guard let request = activeRequest else {
        throw TatwoDevicePairingErrorV1.pairingProofMissing
      }
      let proofMaterial = [
        request.requestID,
        request.identityFingerprint,
        request.pairingCode.seed,
        request.pairingCode.consumedAt.map(TatwoPluginApplyEngineV1.iso8601) ?? "",
        authorityPrimary,
        String(authorityEpoch),
      ].joined(separator: "|")
      pairingProof = TatwoDevicePairingProofV1(
        verificationDigest: TatwoLoopJobDigest.sha256(Data(proofMaterial.utf8)),
        verifiedAt: code.consumedAt ?? now,
        deviceFingerprint: device.identityFingerprint)
      state = .pairingCodeVerified

    case (.pairingCodeVerified, .completePairing):
      // Paired = identity confirmed. Still no capability / manage.
      guard pairingProof != nil else {
        throw TatwoDevicePairingErrorV1.pairingProofMissing
      }
      state = .paired

    case (.discovered, .verifyPairingCode):
      throw TatwoDevicePairingErrorV1.invalidTransition(
        from: .discovered, event: "verifyPairingCode")
    case (.discovered, .completePairing):
      throw TatwoDevicePairingErrorV1.invalidTransition(
        from: .discovered, event: "completePairing")
    case (.pairingRequested, .requestPairing):
      throw TatwoDevicePairingErrorV1.invalidTransition(
        from: .pairingRequested, event: "requestPairing")
    case (.pairingRequested, .completePairing):
      throw TatwoDevicePairingErrorV1.invalidTransition(
        from: .pairingRequested, event: "completePairing")
    case (.pairingCodeVerified, .requestPairing):
      throw TatwoDevicePairingErrorV1.invalidTransition(
        from: .pairingCodeVerified, event: "requestPairing")
    case (.pairingCodeVerified, .verifyPairingCode):
      // Code already consumed; replay / re-verify is forbidden.
      throw TatwoDevicePairingErrorV1.codeAlreadyConsumed
    case (.paired, .requestPairing):
      throw TatwoDevicePairingErrorV1.invalidTransition(
        from: .paired, event: "requestPairing")
    case (.paired, .verifyPairingCode):
      throw TatwoDevicePairingErrorV1.invalidTransition(
        from: .paired, event: "verifyPairingCode")
    case (.paired, .completePairing):
      throw TatwoDevicePairingErrorV1.invalidTransition(
        from: .paired, event: "completePairing")
    }
  }

  /// S3 seam: only a paired session may accept an enroll-managed flag.
  /// S2 tests assert pairing path never calls this successfully for capability.
  public mutating func markEnrolledManagedForS3(
    pairingProof: TatwoDevicePairingProofV1
  ) throws {
    guard state == .paired else {
      throw TatwoDevicePairingErrorV1.pairingDoesNotGrantManage
    }
    try verifyPairedProof(pairingProof)
    enrollManagedFlag = true
  }

  /// Verify that a proof came from this session's code-verification event.
  /// S3 seams must call this instead of checking only `state == .paired`.
  public func verifyPairedProof(
    _ proof: TatwoDevicePairingProofV1
  ) throws {
    guard state == .paired, let expected = pairingProof else {
      throw TatwoDevicePairingErrorV1.pairingProofMissing
    }
    guard expected == proof,
      proof.deviceFingerprint == device.identityFingerprint,
      proof.schema == TatwoDevicePairingProofV1.schemaName
    else {
      throw TatwoDevicePairingErrorV1.pairingProofInvalid
    }
  }

  // MARK: Internals

  private mutating func acceptRequest(
    _ request: TatwoDevicePairingRequestV1,
    now: Date
  ) throws {
    if device.hasUnstableIdentity {
      throw TatwoDevicePairingErrorV1.unstableIdentityForbidden(device.identityFingerprint)
    }
    guard request.identityFingerprint == device.identityFingerprint else {
      throw TatwoDevicePairingErrorV1.requestFingerprintMismatch
    }
    // Re-validate code is still fresh and unconsumed at request accept time.
    try TatwoDevicePairingCodeEngineV1.validate(
      seed: request.pairingCode.seed,
      against: request.pairingCode,
      expectedPrimary: authorityPrimary,
      expectedEpoch: authorityEpoch,
      now: now)
    // Force zero capability on the accepted request.
    activeRequest = TatwoDevicePairingRequestV1(
      requestID: request.requestID,
      discoveryName: request.discoveryName,
      identityFingerprint: request.identityFingerprint,
      transport: request.transport,
      pairingCode: request.pairingCode,
      requestedAt: request.requestedAt)
    activeCode = request.pairingCode
  }
}

// MARK: - Convenience: discover → request

public enum TatwoDevicePairingFacadeV1 {
  /// Create a session + pairing request for a discovered device (pure Core).
  /// Unstable fingerprints fail closed before any code is attached.
  public static func beginPairing(
    device: TatwoDiscoveredDeviceV1,
    authorityPrimary: String,
    authorityEpoch: UInt64,
    now: Date = Date(),
    seed: String? = nil,
    requestID: String = UUID().uuidString
  ) throws -> (session: TatwoDevicePairingSessionV1, request: TatwoDevicePairingRequestV1) {
    if device.hasUnstableIdentity {
      throw TatwoDevicePairingErrorV1.unstableIdentityForbidden(device.identityFingerprint)
    }
    let code = try TatwoDevicePairingCodeEngineV1.mint(
      createdBy: authorityPrimary,
      authorityPrimary: authorityPrimary,
      authorityEpoch: authorityEpoch,
      now: now,
      seed: seed)
    let request = try TatwoDevicePairingRequestV1.make(
      from: device,
      pairingCode: code,
      requestID: requestID,
      now: now)
    var session = TatwoDevicePairingSessionV1(
      device: device,
      authorityPrimary: authorityPrimary,
      authorityEpoch: authorityEpoch)
    try session.apply(.requestPairing(request), now: now)
    return (session, request)
  }
}
