import Foundation

// MARK: - Toolchain fingerprint (D10 S1 / K4)

/// Normalized toolchain + machine capability snapshot for distributed build/test.
///
/// Wire schema: `TatwoToolchainFingerprintV1`.
/// - Primary identity for cross-machine result semantics is `swiftVersion`.
/// - Xcode path/version differences are **degraded compatible**, not hard fail.
/// - `hostName` is advisory for display; it is excluded from compatibility digests
///   so the same toolchain does not rehash solely because of hostname.
///
/// Remote loop **result receipt** embedding of this fingerprint is **S2** scope
/// (see `docs/protocol/DISTRIBUTED_BUILD_TEST_DESIGN.md` §12 S2 checklist note).
public struct TatwoToolchainFingerprintV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoToolchainFingerprintV1"

  public let schema: String
  /// Normalized Swift version token (e.g. `6.4 (swiftlang-…)`). Match primary key.
  public let swiftVersion: String
  /// `xcode-select -p` when present; null/nil if absent.
  public let xcodePath: String?
  /// Combined `xcodebuild -version` line(s); null/nil if absent.
  public let xcodeVersion: String?
  /// `sw_vers` compact string (product + version + build).
  public let os: String
  public let arch: String
  /// Display / machine id aid. Not part of compatibility digest.
  public let hostName: String
  /// Physical RAM in whole GiB (floor of `hw.memsize`).
  public let ramGB: Int
  public let logicalCPU: Int
  /// UTC ISO-8601 timestamp when the probe ran (`YYYY-MM-DDTHH:MM:SSZ`).
  public let generatedAt: String

  public init(
    schema: String = TatwoToolchainFingerprintV1.schemaName,
    swiftVersion: String,
    xcodePath: String? = nil,
    xcodeVersion: String? = nil,
    os: String,
    arch: String,
    hostName: String,
    ramGB: Int,
    logicalCPU: Int,
    generatedAt: String
  ) {
    self.schema = schema
    self.swiftVersion = swiftVersion
    self.xcodePath = Self.normalizeOptional(xcodePath)
    self.xcodeVersion = Self.normalizeOptional(xcodeVersion)
    self.os = os
    self.arch = arch
    self.hostName = hostName
    self.ramGB = ramGB
    self.logicalCPU = logicalCPU
    self.generatedAt = generatedAt
  }

  // MARK: Decoding

  public static func decode(from data: Data) throws -> TatwoToolchainFingerprintV1 {
    let decoder = JSONDecoder()
    let value = try decoder.decode(TatwoToolchainFingerprintV1.self, from: data)
    try value.validateRequiredFields()
    return value
  }

  public static func decode(jsonUTF8: String) throws -> TatwoToolchainFingerprintV1 {
    guard let data = jsonUTF8.data(using: .utf8) else {
      throw TatwoToolchainFingerprintErrorV1.invalidUTF8
    }
    return try decode(from: data)
  }

  public func validateRequiredFields() throws {
    if schema != Self.schemaName {
      throw TatwoToolchainFingerprintErrorV1.schemaMismatch(schema)
    }
    for (name, value) in [
      ("swiftVersion", swiftVersion),
      ("os", os),
      ("arch", arch),
      ("hostName", hostName),
      ("generatedAt", generatedAt),
    ] {
      if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw TatwoToolchainFingerprintErrorV1.emptyField(name)
      }
    }
    if ramGB <= 0 {
      throw TatwoToolchainFingerprintErrorV1.nonPositiveField("ramGB")
    }
    if logicalCPU <= 0 {
      throw TatwoToolchainFingerprintErrorV1.nonPositiveField("logicalCPU")
    }
  }

  // MARK: Match

  /// Compare toolchains for distributed result semantics.
  ///
  /// - `swiftVersion` is the primary key: difference → `.mismatch` (environment_skew class).
  /// - Xcode path/version differences (including one side missing Xcode) → `.degradedCompatible`.
  /// - Host name / generatedAt / RAM / CPU are not match keys.
  public func matches(_ other: TatwoToolchainFingerprintV1) -> TatwoToolchainFingerprintMatchV1 {
    let lhsSwift = Self.normalizeToken(swiftVersion)
    let rhsSwift = Self.normalizeToken(other.swiftVersion)
    if lhsSwift != rhsSwift {
      return .mismatch
    }

    let xcodeSame =
      Self.normalizeOptionalToken(xcodeVersion) == Self.normalizeOptionalToken(other.xcodeVersion)
      && Self.normalizeOptionalToken(xcodePath) == Self.normalizeOptionalToken(other.xcodePath)

    if xcodeSame {
      // Arch / OS skew with identical Swift is still treated as compatible primary class;
      // callers may further gate on `compatibilityKey` if they need stricter policy.
      return .compatible
    }
    return .degradedCompatible
  }

  /// True when results from the two probes may be treated as the same fingerprint class
  /// (compatible or degraded). Mismatch → treat divergences as environment_skew.
  public func isSameFingerprintClass(as other: TatwoToolchainFingerprintV1) -> Bool {
    switch matches(other) {
    case .compatible, .degradedCompatible:
      return true
    case .mismatch:
      return false
    }
  }

  // MARK: Canonical identity (excludes hostName / generatedAt)

  /// Stable key for environment_skew policy: swift + xcode + os + arch.
  /// Hostname deliberately omitted (design §6.4).
  public var compatibilityKey: String {
    let parts: [String] = [
      "swift=\(Self.normalizeToken(swiftVersion))",
      "xcodeVersion=\(Self.normalizeOptionalToken(xcodeVersion) ?? "")",
      "xcodePath=\(Self.normalizeOptionalToken(xcodePath) ?? "")",
      "os=\(Self.normalizeToken(os))",
      "arch=\(Self.normalizeToken(arch))",
    ]
    return parts.joined(separator: "|")
  }

  /// Short display token for logs: `swiftVersion@hostName`.
  public var logSummary: String {
    "\(swiftVersion)@\(hostName)"
  }

  // MARK: Normalization

  private static func normalizeToken(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
  }

  private static func normalizeOptional(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func normalizeOptionalToken(_ value: String?) -> String? {
    guard let value = normalizeOptional(value) else { return nil }
    return normalizeToken(value)
  }
}

// MARK: - Match class

/// Result of `TatwoToolchainFingerprintV1.matches(_:)`.
public enum TatwoToolchainFingerprintMatchV1: String, Codable, Sendable, Equatable, CaseIterable {
  /// Same primary toolchain; Xcode fields agree (including both absent).
  case compatible
  /// Same `swiftVersion`; Xcode path/version differs → degraded, not fail.
  case degradedCompatible = "degraded_compatible"
  /// Different `swiftVersion` → environment_skew / not same fingerprint class.
  case mismatch

  public var isCompatible: Bool {
    switch self {
    case .compatible, .degradedCompatible:
      return true
    case .mismatch:
      return false
    }
  }

  public var isDegraded: Bool {
    self == .degradedCompatible
  }

  /// Distributed result divergence label when fingerprints disagree.
  public var environmentSkewLabel: String? {
    switch self {
    case .compatible:
      return nil
    case .degradedCompatible:
      return "environment_skew_degraded"
    case .mismatch:
      return "environment_skew"
    }
  }
}

// MARK: - Errors

public enum TatwoToolchainFingerprintErrorV1: Error, Equatable, Sendable {
  case invalidUTF8
  case schemaMismatch(String)
  case emptyField(String)
  case nonPositiveField(String)
}

// MARK: - Environment skew policy (S1 pure function)

/// Policy helper for “same commit, two machines, different results”.
///
/// - mismatch → environment difference, not automatic code failure
/// - degraded → still same fingerprint class; flag degraded toolchain
/// - compatible → may treat as code_failure if both failed equivalently
public enum TatwoToolchainEnvironmentSkewPolicyV1: Sendable {
  public static func classify(
    lhs: TatwoToolchainFingerprintV1,
    rhs: TatwoToolchainFingerprintV1
  ) -> TatwoToolchainFingerprintMatchV1 {
    lhs.matches(rhs)
  }

  /// True when result divergence must not be auto-classified as code_failure.
  public static func treatDivergenceAsEnvironment(
    lhs: TatwoToolchainFingerprintV1,
    rhs: TatwoToolchainFingerprintV1
  ) -> Bool {
    lhs.matches(rhs) == .mismatch
  }
}
