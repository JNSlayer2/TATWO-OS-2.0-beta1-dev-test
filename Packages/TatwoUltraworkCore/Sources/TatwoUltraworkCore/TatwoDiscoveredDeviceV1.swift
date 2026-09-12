import Foundation

// MARK: - Plug-and-Manage S1: read-only discovered device (D11 / PLUG_AND_MANAGE_DESIGN.md)
//
// Discovery-only prototype. Iron rules:
// - trustState is always `untrusted` at this stage.
// - `canBeManaged` is always false (S1 cannot produce trust or control).
// - No pairing / enroll / pin / invoke APIs on this type layer (those are S2/S3/S4).
// - Serials and other stable hardware IDs appear only as hashed `identityFingerprint`
//   (or `unstable:` when no serial-like material was available).

// MARK: - Transport

/// Observation transport for a discovered (still untrusted) device.
public enum TatwoDiscoveredTransportV1: String, Codable, Sendable, CaseIterable, Equatable {
  case thunderbolt
  case usb
  case bonjour
}

// MARK: - Optional telemetry slots (usually null in S1)

/// Optional CPU / GPU / memory claim. S1 leaves this null unless a future
/// read-only claim source fills it; Bonjour self-claims remain untrusted.
public struct TatwoDiscoveredCpuGpuMemoryV1: Codable, Sendable, Equatable {
  public let cpu: String?
  public let gpu: String?
  public let memoryGB: Double?

  public init(cpu: String? = nil, gpu: String? = nil, memoryGB: Double? = nil) {
    self.cpu = cpu
    self.gpu = gpu
    self.memoryGB = memoryGB
  }
}

/// Optional power / thermal observation. Most external devices cannot expose
/// this via read-only macOS tools without entitlements; S1 expects null.
public struct TatwoDiscoveredPowerThermalV1: Codable, Sendable, Equatable {
  public let power: String?
  public let thermal: String?

  public init(power: String? = nil, thermal: String? = nil) {
    self.power = power
    self.thermal = thermal
  }
}

// MARK: - Errors

public enum TatwoDiscoveredDeviceErrorV1: Error, LocalizedError, Equatable, Sendable {
  case invalidUTF8
  case schemaMismatch(String)
  case emptyField(String)
  case invalidTransport(String)
  case invalidTrustState(String)
  case rawSerialLeak(String)

  public var errorDescription: String? {
    switch self {
    case .invalidUTF8:
      "discovered device JSON is not valid UTF-8"
    case let .schemaMismatch(schema):
      "discovered device schema mismatch: \(schema)"
    case let .emptyField(field):
      "discovered device missing/empty field: \(field)"
    case let .invalidTransport(value):
      "discovered device invalid transport: \(value)"
    case let .invalidTrustState(value):
      "discovered device trustState must be untrusted in S1, got: \(value)"
    case let .rawSerialLeak(detail):
      "discovered device payload must not embed raw serial material: \(detail)"
    }
  }
}

// MARK: - Device

/// Read-only discovery card for Plug-and-Manage S1.
///
/// Wire schema: `TatwoDiscoveredDeviceV1`.
/// Aligns with `scripts/tatwo-device-discover.sh` device objects.
public struct TatwoDiscoveredDeviceV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoDiscoveredDeviceV1"
  public static let requiredTrustState = "untrusted"

  public let schema: String
  public let transport: TatwoDiscoveredTransportV1
  public let name: String
  /// `sha256:<hex>` when serial-like material was hashed; `unstable:<hex>` when not.
  public let identityFingerprint: String
  public let interfaces: [String]
  public let capabilitiesObserved: [String]
  public let storageGB: Double?
  public let cpuGpuMemory: TatwoDiscoveredCpuGpuMemoryV1?
  public let powerThermal: TatwoDiscoveredPowerThermalV1?
  /// Always `untrusted` in S1. Decode rejects any other value.
  public let trustState: String

  public init(
    schema: String = TatwoDiscoveredDeviceV1.schemaName,
    transport: TatwoDiscoveredTransportV1,
    name: String,
    identityFingerprint: String,
    interfaces: [String] = [],
    capabilitiesObserved: [String] = [],
    storageGB: Double? = nil,
    cpuGpuMemory: TatwoDiscoveredCpuGpuMemoryV1? = nil,
    powerThermal: TatwoDiscoveredPowerThermalV1? = nil,
    trustState: String = TatwoDiscoveredDeviceV1.requiredTrustState
  ) {
    self.schema = schema
    self.transport = transport
    self.name = name
    self.identityFingerprint = identityFingerprint
    self.interfaces = interfaces
    self.capabilitiesObserved = capabilitiesObserved
    self.storageGB = storageGB
    self.cpuGpuMemory = cpuGpuMemory
    self.powerThermal = powerThermal
    self.trustState = trustState
  }

  /// S1 iron rule: discovery never yields a manageable device.
  public var canBeManaged: Bool { false }

  /// True when fingerprint was built without serial-like material.
  public var hasUnstableIdentity: Bool {
    identityFingerprint.hasPrefix("unstable:")
  }

  // MARK: Decoding

  public static func decode(from data: Data) throws -> TatwoDiscoveredDeviceV1 {
    let decoder = JSONDecoder()
    let value = try decoder.decode(TatwoDiscoveredDeviceV1.self, from: data)
    try value.validateS1Invariants()
    return value
  }

  public static func decode(jsonUTF8: String) throws -> TatwoDiscoveredDeviceV1 {
    guard let data = jsonUTF8.data(using: .utf8) else {
      throw TatwoDiscoveredDeviceErrorV1.invalidUTF8
    }
    return try decode(from: data)
  }

  public func validateS1Invariants() throws {
    if schema != Self.schemaName {
      throw TatwoDiscoveredDeviceErrorV1.schemaMismatch(schema)
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedName.isEmpty {
      throw TatwoDiscoveredDeviceErrorV1.emptyField("name")
    }
    let fp = identityFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
    if fp.isEmpty {
      throw TatwoDiscoveredDeviceErrorV1.emptyField("identityFingerprint")
    }
    if !(fp.hasPrefix("sha256:") || fp.hasPrefix("unstable:")) {
      throw TatwoDiscoveredDeviceErrorV1.emptyField("identityFingerprint")
    }
    if trustState != Self.requiredTrustState {
      throw TatwoDiscoveredDeviceErrorV1.invalidTrustState(trustState)
    }
    // Defense-in-depth: common serial key substrings must not appear as raw fields
    // in name/interfaces/capabilities (fingerprint may only carry hashes).
    let leakHaystack = (
      [name] + interfaces + capabilitiesObserved + [identityFingerprint]
    ).joined(separator: "\n")
    if leakHaystack.range(of: #"serial[_-]?number\s*[:=]"#, options: [.regularExpression, .caseInsensitive])
      != nil
    {
      throw TatwoDiscoveredDeviceErrorV1.rawSerialLeak("serial key pattern in public fields")
    }
  }
}

// MARK: - Discovery report envelope

public enum TatwoDeviceDiscoveryReportErrorV1: Error, LocalizedError, Equatable, Sendable {
  case invalidUTF8
  case schemaMismatch(String)
  case invalidStage(String)
  case invalidNextStep(String)
  case deviceInvariant(TatwoDiscoveredDeviceErrorV1)

  public var errorDescription: String? {
    switch self {
    case .invalidUTF8:
      "discovery report JSON is not valid UTF-8"
    case let .schemaMismatch(schema):
      "discovery report schema mismatch: \(schema)"
    case let .invalidStage(stage):
      "discovery report stage must be discovery-only, got: \(stage)"
    case let .invalidNextStep(step):
      "discovery report nextStep must be requires-pairing-code, got: \(step)"
    case let .deviceInvariant(err):
      "discovery report device invariant: \(err.localizedDescription)"
    }
  }
}

/// Envelope written by `scripts/tatwo-device-discover.sh`.
///
/// Wire schema: `TatwoDeviceDiscoveryReportV1`.
/// `stage` / `nextStep` force the three-phase separation: discovery never
/// auto-advances to pairing or enrollment.
public struct TatwoDeviceDiscoveryReportV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoDeviceDiscoveryReportV1"
  public static let requiredStage = "discovery-only"
  public static let requiredNextStep = "requires-pairing-code"

  public let schema: String
  public let stage: String
  public let nextStep: String
  public let devices: [TatwoDiscoveredDeviceV1]
  public let notes: [String]

  public init(
    schema: String = TatwoDeviceDiscoveryReportV1.schemaName,
    stage: String = TatwoDeviceDiscoveryReportV1.requiredStage,
    nextStep: String = TatwoDeviceDiscoveryReportV1.requiredNextStep,
    devices: [TatwoDiscoveredDeviceV1] = [],
    notes: [String] = []
  ) {
    self.schema = schema
    self.stage = stage
    self.nextStep = nextStep
    self.devices = devices
    self.notes = notes
  }

  /// Aggregate S1 gate: no device in a discovery report is manageable.
  public var canAnyBeManaged: Bool {
    // Type-layer constant for S1 (each device also exposes `canBeManaged == false`).
    false
  }

  public static func decode(from data: Data) throws -> TatwoDeviceDiscoveryReportV1 {
    let decoder = JSONDecoder()
    let value = try decoder.decode(TatwoDeviceDiscoveryReportV1.self, from: data)
    try value.validateS1Invariants()
    return value
  }

  public static func decode(jsonUTF8: String) throws -> TatwoDeviceDiscoveryReportV1 {
    guard let data = jsonUTF8.data(using: .utf8) else {
      throw TatwoDeviceDiscoveryReportErrorV1.invalidUTF8
    }
    return try decode(from: data)
  }

  public func validateS1Invariants() throws {
    if schema != Self.schemaName {
      throw TatwoDeviceDiscoveryReportErrorV1.schemaMismatch(schema)
    }
    if stage != Self.requiredStage {
      throw TatwoDeviceDiscoveryReportErrorV1.invalidStage(stage)
    }
    if nextStep != Self.requiredNextStep {
      throw TatwoDeviceDiscoveryReportErrorV1.invalidNextStep(nextStep)
    }
    for device in devices {
      do {
        try device.validateS1Invariants()
      } catch let err as TatwoDiscoveredDeviceErrorV1 {
        throw TatwoDeviceDiscoveryReportErrorV1.deviceInvariant(err)
      }
    }
  }
}

// MARK: - Explicit S1 non-API (documentation seam)
//
// Pairing (`createPairing`), pin-import / enroll, capability invoke, and fleet
// dispatch are **intentionally absent** from this file. S2/S3/S4 own those
// surfaces. Do not add convenience wrappers here that would collapse
// discovery → pair → enroll.
