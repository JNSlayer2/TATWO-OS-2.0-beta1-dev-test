import Foundation

// MARK: - Distributed test plan (Distributed Build/Test S3 + F18)

/// A leaf shard emitted by `scripts/tatwo-test-shard.mjs`.
///
/// Empty `filters` is valid when the sharder was asked for more shards than
/// leaf suites.  The shard key and expected count still make the partition
/// observable and verifiable.
public struct TatwoTestShardFilterSetV1: Codable, Sendable, Equatable, Identifiable {
  public static let schemaName = "TatwoTestShardFilterSetV1"

  public let schema: String
  public let shardKey: String
  public let expectedShardCount: Int
  public let filters: [String]

  public var id: String { shardKey }

  public init(
    schema: String = TatwoTestShardFilterSetV1.schemaName,
    shardKey: String,
    expectedShardCount: Int,
    filters: [String]
  ) throws {
    self.schema = schema
    self.shardKey = shardKey
    self.expectedShardCount = expectedShardCount
    let normalized = filters.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard Set(normalized).count == normalized.count else {
      throw TatwoDistributedTestPlanErrorV1.duplicateFilter(shardKey)
    }
    self.filters = normalized.sorted()
    try validate()
  }

  /// Convenience spelling for callers that call a shard key `shardID`.
  public init(
    shardID: String,
    expectedShardCount: Int,
    filters: [String]
  ) throws {
    try self.init(
      shardKey: shardID,
      expectedShardCount: expectedShardCount,
      filters: filters)
  }

  public func validate() throws {
    guard schema == Self.schemaName else {
      throw TatwoDistributedTestPlanErrorV1.invalidShard("schema \(schema)")
    }
    guard !shardKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !shardKey.contains("\0"), expectedShardCount > 0
    else {
      throw TatwoDistributedTestPlanErrorV1.invalidShard(shardKey)
    }
    guard filters.allSatisfy({
      let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return !value.isEmpty && !value.contains("\0")
    }) else {
      throw TatwoDistributedTestPlanErrorV1.invalidShard(
        "\(shardKey) contains an empty filter")
    }
    guard Set(filters).count == filters.count else {
      throw TatwoDistributedTestPlanErrorV1.duplicateFilter(shardKey)
    }
  }

}

/// Target capability declaration consumed by the pure planner.  The fleet
/// remains the authority for registration/lease/dispatch; this is only the
/// compute admission slice needed by a test plan.
public struct TatwoDistributedTestDeviceCapabilityV1: Codable, Sendable, Equatable, Identifiable {
  public static let schemaName = "TatwoDistributedTestDeviceCapabilityV1"

  public let schema: String
  public let deviceID: String
  public let toolchainFingerprint: TatwoToolchainFingerprintV1
  public let freeDiskBytes: Int64
  public let maxConcurrent: Int
  public let maxTimeoutSec: TimeInterval

  public var id: String { deviceID }

  public init(
    schema: String = TatwoDistributedTestDeviceCapabilityV1.schemaName,
    deviceID: String,
    toolchainFingerprint: TatwoToolchainFingerprintV1,
    freeDiskBytes: Int64,
    maxConcurrent: Int = 1,
    maxTimeoutSec: TimeInterval = 120
  ) throws {
    self.schema = schema
    self.deviceID = deviceID
    self.toolchainFingerprint = toolchainFingerprint
    self.freeDiskBytes = freeDiskBytes
    self.maxConcurrent = maxConcurrent
    self.maxTimeoutSec = maxTimeoutSec
    try validate()
  }

  /// Compatibility label used by capability probes.
  public init(
    deviceID: String,
    toolchainFingerprint: TatwoToolchainFingerprintV1,
    diskFreeBytes: Int64,
    maxConcurrent: Int = 1,
    timeoutSec: TimeInterval = 120
  ) throws {
    try self.init(
      deviceID: deviceID,
      toolchainFingerprint: toolchainFingerprint,
      freeDiskBytes: diskFreeBytes,
      maxConcurrent: maxConcurrent,
      maxTimeoutSec: timeoutSec)
  }

  public func validate() throws {
    guard schema == Self.schemaName,
      TatwoLoopPathComponent.isValid(deviceID),
      freeDiskBytes >= 0,
      maxConcurrent > 0,
      maxTimeoutSec.isFinite,
      maxTimeoutSec > 0
    else {
      throw TatwoDistributedTestPlanErrorV1.invalidCapability(deviceID)
    }
    try toolchainFingerprint.validateRequiredFields()
  }
}

/// One shard assignment.  `remoteLoopJob` is the existing RemoteLoopJob
/// transport object; this type does not create a second scheduler/channel.
public struct TatwoDistributedTestJobSpecV1: Codable, Sendable, Equatable, Identifiable {
  public static let schemaName = "TatwoDistributedTestJobSpecV1"

  public let schema: String
  public let jobID: String
  public let logicalJobID: String
  public let targetDeviceID: String
  public let shardKey: String
  public let expectedShardCount: Int
  public let filters: [String]
  public let expectedToolchain: TatwoToolchainFingerprintV1
  public let diskBudgetBytes: Int64
  public let timeoutSec: TimeInterval
  public let remoteLoopJob: TatwoLoopJobV1

  public var id: String { jobID }
  public var fleetJob: TatwoLoopJobV1 { remoteLoopJob }
  public var toolchainFingerprint: TatwoToolchainFingerprintV1 { expectedToolchain }

  public init(
    schema: String = TatwoDistributedTestJobSpecV1.schemaName,
    jobID: String,
    logicalJobID: String,
    targetDeviceID: String,
    shardKey: String,
    expectedShardCount: Int,
    filters: [String],
    expectedToolchain: TatwoToolchainFingerprintV1,
    diskBudgetBytes: Int64,
    timeoutSec: TimeInterval,
    remoteLoopJob: TatwoLoopJobV1
  ) {
    self.schema = schema
    self.jobID = jobID
    self.logicalJobID = logicalJobID
    self.targetDeviceID = targetDeviceID
    self.shardKey = shardKey
    self.expectedShardCount = expectedShardCount
    self.filters = filters.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.sorted()
    self.expectedToolchain = expectedToolchain
    self.diskBudgetBytes = diskBudgetBytes
    self.timeoutSec = timeoutSec
    self.remoteLoopJob = remoteLoopJob
  }
}

public struct TatwoDistributedTestResultV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoDistributedTestResultV1"

  public let schema: String
  public let shardKey: String
  public let expectedShardCount: Int
  public let filters: [String]
  /// Nil represents a malformed/missing result field and fails verification.
  public let toolchainFingerprint: TatwoToolchainFingerprintV1?
  public let logBytes: Int64
  public let passedSuites: Int
  public let failedSuites: Int
  /// Explicit XCTest skips. Skipped work is never folded into `passedSuites`.
  public let skippedCount: Int
  /// Capability identifiers reported unavailable by the target, for example
  /// `interactive-keychain`.
  public let unavailableCapabilities: [String]
  /// Fleet attempt binding copied from the scheduled remote loop job.
  public let jobID: String?
  public let logicalJobID: String?
  public let dispatchNonce: String?
  public let jobCanonicalDigest: String?
  public let targetDeviceID: String?
  /// Target-produced Ed25519 signature over `signingPayload()`.
  public let targetSignature: TatwoDeviceSignatureV1?

  private enum CodingKeys: String, CodingKey {
    case schema, shardKey, expectedShardCount, filters, toolchainFingerprint
    case logBytes, passedSuites, failedSuites, skippedCount, unavailableCapabilities
    case jobID, logicalJobID, dispatchNonce, jobCanonicalDigest, targetDeviceID
    case targetSignature
  }

  public init(
    schema: String = TatwoDistributedTestResultV1.schemaName,
    shardKey: String,
    expectedShardCount: Int,
    filters: [String],
    toolchainFingerprint: TatwoToolchainFingerprintV1?,
    logBytes: Int64,
    passedSuites: Int,
    failedSuites: Int,
    skippedCount: Int = 0,
    unavailableCapabilities: [String] = [],
    jobID: String? = nil,
    logicalJobID: String? = nil,
    dispatchNonce: String? = nil,
    jobCanonicalDigest: String? = nil,
    targetDeviceID: String? = nil,
    targetSignature: TatwoDeviceSignatureV1? = nil
  ) {
    self.schema = schema
    self.shardKey = shardKey
    self.expectedShardCount = expectedShardCount
    self.filters = filters.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.sorted()
    self.toolchainFingerprint = toolchainFingerprint
    self.logBytes = logBytes
    self.passedSuites = passedSuites
    self.failedSuites = failedSuites
    self.skippedCount = skippedCount
    self.unavailableCapabilities = Array(Set(unavailableCapabilities.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty })).sorted()
    self.jobID = jobID
    self.logicalJobID = logicalJobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.targetDeviceID = targetDeviceID
    self.targetSignature = targetSignature
  }

  /// Backward-compatible decode: pre-U1 V1 receipts did not carry skip fields.
  /// Missing fields mean zero skips, never an inferred pass-with-skips.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try c.decode(String.self, forKey: .schema),
      shardKey: try c.decode(String.self, forKey: .shardKey),
      expectedShardCount: try c.decode(Int.self, forKey: .expectedShardCount),
      filters: try c.decode([String].self, forKey: .filters),
      toolchainFingerprint: try c.decodeIfPresent(
        TatwoToolchainFingerprintV1.self, forKey: .toolchainFingerprint),
      logBytes: try c.decode(Int64.self, forKey: .logBytes),
      passedSuites: try c.decode(Int.self, forKey: .passedSuites),
      failedSuites: try c.decode(Int.self, forKey: .failedSuites),
      skippedCount: try c.decodeIfPresent(Int.self, forKey: .skippedCount) ?? 0,
      unavailableCapabilities: try c.decodeIfPresent(
        [String].self, forKey: .unavailableCapabilities) ?? [],
      jobID: try c.decodeIfPresent(String.self, forKey: .jobID),
      logicalJobID: try c.decodeIfPresent(String.self, forKey: .logicalJobID),
      dispatchNonce: try c.decodeIfPresent(String.self, forKey: .dispatchNonce),
      jobCanonicalDigest: try c.decodeIfPresent(String.self, forKey: .jobCanonicalDigest),
      targetDeviceID: try c.decodeIfPresent(String.self, forKey: .targetDeviceID),
      targetSignature: try c.decodeIfPresent(
        TatwoDeviceSignatureV1.self, forKey: .targetSignature))
  }

  public init(
    shardKey: String,
    expectedShardCount: Int,
    filters: [String],
    toolchainFingerprint: TatwoToolchainFingerprintV1?,
    logBytes: Int64,
    passedTestSuites: Int,
    failedTestSuites: Int
  ) {
    self.init(
      shardKey: shardKey,
      expectedShardCount: expectedShardCount,
      filters: filters,
      toolchainFingerprint: toolchainFingerprint,
      logBytes: logBytes,
      passedSuites: passedTestSuites,
      failedSuites: failedTestSuites)
  }

  public init(
    shardKey: String,
    expectedShardCount: Int,
    filters: [String],
    toolchainFingerprint: TatwoToolchainFingerprintV1?,
    logBytes: Int64,
    passedSuiteCount: Int,
    failedSuiteCount: Int
  ) {
    self.init(
      shardKey: shardKey,
      expectedShardCount: expectedShardCount,
      filters: filters,
      toolchainFingerprint: toolchainFingerprint,
      logBytes: logBytes,
      passedSuites: passedSuiteCount,
      failedSuites: failedSuiteCount)
  }

  /// Stable bytes signed by the target. The signature is intentionally over
  /// the complete result payload plus fleet attempt binding, not just counters.
  public func signingPayload() -> Data {
    let fingerprint = toolchainFingerprint.map { value in
      // Do not use String(describing:) here: its representation is not a wire
      // contract and could change across Swift/Foundation versions.  Length
      // prefixes keep delimiters in user-controlled fields unambiguous.
      let fields = [
        value.schema,
        value.swiftVersion,
        value.xcodePath ?? "",
        value.xcodeVersion ?? "",
        value.os,
        value.arch,
        value.hostName,
        String(value.ramGB),
        String(value.logicalCPU),
        value.generatedAt,
      ]
      return fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    } ?? ""
    return Data([
      "schema=\(schema)",
      "jobID=\(jobID ?? "")",
      "logicalJobID=\(logicalJobID ?? "")",
      "dispatchNonce=\(dispatchNonce ?? "")",
      "jobCanonicalDigest=\(jobCanonicalDigest ?? "")",
      "targetDeviceID=\(targetDeviceID ?? "")",
      "shardKey=\(shardKey)",
      "expectedShardCount=\(expectedShardCount)",
      "filters=\(filters.joined(separator: ","))",
      "toolchainFingerprint=\(fingerprint)",
      "logBytes=\(logBytes)",
      "passedSuites=\(passedSuites)",
      "failedSuites=\(failedSuites)",
      "skippedCount=\(skippedCount)",
      "unavailableCapabilities=\(unavailableCapabilities.joined(separator: ","))",
    ].joined(separator: "\n").utf8)
  }

  /// Pre-U1 V1 payload retained only to verify already-issued zero-skip
  /// receipts. New receipts must sign `signingPayload()`.
  func legacySigningPayloadV1() -> Data {
    let fingerprint = toolchainFingerprint.map { value in
      let fields = [
        value.schema,
        value.swiftVersion,
        value.xcodePath ?? "",
        value.xcodeVersion ?? "",
        value.os,
        value.arch,
        value.hostName,
        String(value.ramGB),
        String(value.logicalCPU),
        value.generatedAt,
      ]
      return fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    } ?? ""
    return Data([
      "schema=\(schema)",
      "jobID=\(jobID ?? "")",
      "logicalJobID=\(logicalJobID ?? "")",
      "dispatchNonce=\(dispatchNonce ?? "")",
      "jobCanonicalDigest=\(jobCanonicalDigest ?? "")",
      "targetDeviceID=\(targetDeviceID ?? "")",
      "shardKey=\(shardKey)",
      "expectedShardCount=\(expectedShardCount)",
      "filters=\(filters.joined(separator: ","))",
      "toolchainFingerprint=\(fingerprint)",
      "logBytes=\(logBytes)",
      "passedSuites=\(passedSuites)",
      "failedSuites=\(failedSuites)",
    ].joined(separator: "\n").utf8)
  }
}

public enum TatwoDistributedTestVerificationOutcomeV1: String, Codable, Sendable, Equatable {
  case pass = "PASS"
  case passWithSkips = "PASS_WITH_SKIPS"
  case degraded = "DEGRADED"
  case fail = "FAIL"
}

public struct TatwoDistributedTestVerificationV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoDistributedTestVerificationV1"

  public let schema: String
  public let outcome: TatwoDistributedTestVerificationOutcomeV1
  public let degraded: Bool
  public let conclusion: String
  public let missingShardKeys: [String]
  public let duplicateShardKeys: [String]
  public let unexpectedShardKeys: [String]
  public let failedShardKeys: [String]
  public let invalidShardKeys: [String]
  public let toolchainMismatches: [String]
  public let skippedCount: Int
  public let unavailableCapabilities: [String]
  /// `fleet-signature` when cryptographically verified; `transport-only` is
  /// an explicit known limitation and never a green default.
  public let trustSource: String

  private enum CodingKeys: String, CodingKey {
    case schema, outcome, degraded, conclusion, missingShardKeys
    case duplicateShardKeys, unexpectedShardKeys, failedShardKeys
    case invalidShardKeys, toolchainMismatches, skippedCount
    case unavailableCapabilities, trustSource
  }

  /// Only a complete, non-skipped result is a full pass.
  public var passed: Bool { outcome == .pass }
  public var isPass: Bool { passed }
  public var statusLabel: String { outcome.rawValue }
  public var status: TatwoDistributedTestVerificationOutcomeV1 { outcome }

  public init(
    schema: String = TatwoDistributedTestVerificationV1.schemaName,
    outcome: TatwoDistributedTestVerificationOutcomeV1,
    degraded: Bool,
    conclusion: String,
    missingShardKeys: [String] = [],
    duplicateShardKeys: [String] = [],
    unexpectedShardKeys: [String] = [],
    failedShardKeys: [String] = [],
    invalidShardKeys: [String] = [],
    toolchainMismatches: [String] = [],
    skippedCount: Int = 0,
    unavailableCapabilities: [String] = [],
    trustSource: String = "fleet-signature"
  ) {
    self.schema = schema
    self.outcome = outcome
    self.degraded = degraded
    self.conclusion = conclusion
    self.missingShardKeys = missingShardKeys
    self.duplicateShardKeys = duplicateShardKeys
    self.unexpectedShardKeys = unexpectedShardKeys
    self.failedShardKeys = failedShardKeys
    self.invalidShardKeys = invalidShardKeys
    self.toolchainMismatches = toolchainMismatches
    self.skippedCount = skippedCount
    self.unavailableCapabilities = unavailableCapabilities
    self.trustSource = trustSource
  }

  /// Older verification receipts predate `trustSource`; decode them as
  /// transport-only so they cannot silently become cryptographically trusted.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.schema = try c.decode(String.self, forKey: .schema)
    self.outcome = try c.decode(TatwoDistributedTestVerificationOutcomeV1.self, forKey: .outcome)
    self.degraded = try c.decode(Bool.self, forKey: .degraded)
    self.conclusion = try c.decode(String.self, forKey: .conclusion)
    self.missingShardKeys = try c.decodeIfPresent([String].self, forKey: .missingShardKeys) ?? []
    self.duplicateShardKeys = try c.decodeIfPresent([String].self, forKey: .duplicateShardKeys) ?? []
    self.unexpectedShardKeys = try c.decodeIfPresent([String].self, forKey: .unexpectedShardKeys) ?? []
    self.failedShardKeys = try c.decodeIfPresent([String].self, forKey: .failedShardKeys) ?? []
    self.invalidShardKeys = try c.decodeIfPresent([String].self, forKey: .invalidShardKeys) ?? []
    self.toolchainMismatches = try c.decodeIfPresent([String].self, forKey: .toolchainMismatches) ?? []
    self.skippedCount = try c.decodeIfPresent(Int.self, forKey: .skippedCount) ?? 0
    self.unavailableCapabilities =
      try c.decodeIfPresent([String].self, forKey: .unavailableCapabilities) ?? []
    self.trustSource = try c.decodeIfPresent(String.self, forKey: .trustSource) ?? "transport-only"
  }
}

public enum TatwoDistributedTestPlanErrorV1: Error, LocalizedError, Sendable, Equatable {
  case invalidShard(String)
  case duplicateShard(String)
  case duplicateFilter(String)
  case invalidCapability(String)
  case noTargetDevices
  case diskBudgetExceeded(deviceID: String)
  case timeoutExceedsCapability(deviceID: String)
  case invalidPlan(String)

  public var errorDescription: String? {
    switch self {
    case let .invalidShard(detail):
      return "distributed test shard invalid: \(detail)"
    case let .duplicateShard(shardKey):
      return "distributed test shard duplicated: \(shardKey)"
    case let .duplicateFilter(shardKey):
      return "distributed test filter duplicated in shard: \(shardKey)"
    case let .invalidCapability(deviceID):
      return "distributed test device capability invalid: \(deviceID)"
    case .noTargetDevices:
      return "distributed test plan requires at least one target device"
    case let .diskBudgetExceeded(deviceID):
      return "distributed test disk budget rejected by \(deviceID)"
    case let .timeoutExceedsCapability(deviceID):
      return "distributed test timeout exceeds capability of \(deviceID)"
    case let .invalidPlan(detail):
      return "distributed test plan invalid: \(detail)"
    }
  }
}

/// Pure S3 planner and origin-side rollup verifier.  It only produces existing
/// `TatwoLoopJobV1` values; dispatch still belongs to `TatwoFleetScheduler`.
public struct TatwoDistributedTestPlanV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoDistributedTestPlanV1"
  /// This pure planner produces signed-attempt-compatible test fixtures, not
  /// production GoalRun dispatches. An origin adapter must add a live session
  /// grant, target readiness binding, and workspace locator before dispatch.
  public static let isProductionDispatchReady = false
  public typealias Shard = TatwoTestShardFilterSetV1
  public typealias DeviceCapability = TatwoDistributedTestDeviceCapabilityV1
  public typealias JobSpec = TatwoDistributedTestJobSpecV1
  public typealias Result = TatwoDistributedTestResultV1
  public typealias Verification = TatwoDistributedTestVerificationV1

  public let schema: String
  public let expectedShardCount: Int
  public let diskBudgetBytes: Int64
  public let timeoutSec: TimeInterval
  public let jobSpecs: [TatwoDistributedTestJobSpecV1]

  public var specs: [TatwoDistributedTestJobSpecV1] { jobSpecs }
  public var jobs: [TatwoLoopJobV1] { jobSpecs.map(\.remoteLoopJob) }
  public var expectedShardKeys: [String] {
    jobSpecs.map(\.shardKey).sorted()
  }

  public init(
    schema: String = TatwoDistributedTestPlanV1.schemaName,
    shardFilters: [TatwoTestShardFilterSetV1],
    targetDevices: [TatwoDistributedTestDeviceCapabilityV1],
    diskBudgetBytes: Int64,
    timeoutSec: TimeInterval,
    originDeviceID: String = "origin",
    contractID: String = "distributed-test-contract",
    goalID: String = "distributed-test-goal",
    now: Date = Date(timeIntervalSince1970: 0)
  ) throws {
    guard schema == Self.schemaName else {
      throw TatwoDistributedTestPlanErrorV1.invalidPlan("schema \(schema)")
    }
    guard !shardFilters.isEmpty else {
      throw TatwoDistributedTestPlanErrorV1.invalidPlan("no shard filters")
    }
    guard diskBudgetBytes > 0, timeoutSec.isFinite, timeoutSec > 0 else {
      throw TatwoDistributedTestPlanErrorV1.invalidPlan(
        "disk budget and timeout must be positive")
    }
    guard TatwoLoopPathComponent.isValid(originDeviceID) else {
      throw TatwoDistributedTestPlanErrorV1.invalidPlan("invalid originDeviceID")
    }
    guard !contractID.isEmpty, !goalID.isEmpty else {
      throw TatwoDistributedTestPlanErrorV1.invalidPlan(
        "contractID and goalID are required")
    }
    guard !targetDevices.isEmpty else {
      throw TatwoDistributedTestPlanErrorV1.noTargetDevices
    }

    var seenShards = Set<String>()
    var seenFilters = Set<String>()
    for shard in shardFilters {
      try shard.validate()
      guard seenShards.insert(shard.shardKey).inserted else {
        throw TatwoDistributedTestPlanErrorV1.duplicateShard(shard.shardKey)
      }
      for filter in shard.filters {
        guard seenFilters.insert(filter).inserted else {
          throw TatwoDistributedTestPlanErrorV1.duplicateFilter(shard.shardKey)
        }
      }
    }

    var seenDevices = Set<String>()
    for device in targetDevices {
      try device.validate()
      guard seenDevices.insert(device.deviceID).inserted else {
        throw TatwoDistributedTestPlanErrorV1.invalidCapability(
          "duplicate device \(device.deviceID)")
      }
      guard device.freeDiskBytes >= diskBudgetBytes else {
        throw TatwoDistributedTestPlanErrorV1.diskBudgetExceeded(
          deviceID: device.deviceID)
      }
      guard device.maxTimeoutSec >= timeoutSec else {
        throw TatwoDistributedTestPlanErrorV1.timeoutExceedsCapability(
          deviceID: device.deviceID)
      }
    }

    let sortedShards = shardFilters.sorted { $0.shardKey < $1.shardKey }
    let shardCounts = Set(sortedShards.map(\.expectedShardCount))
    guard shardCounts.count == 1,
      shardCounts.first ?? 0 == sortedShards.count
    else {
      throw TatwoDistributedTestPlanErrorV1.invalidPlan(
        "expectedShardCount must equal the number of partition shards")
    }
    let sortedDevices = targetDevices.sorted { $0.deviceID < $1.deviceID }
    var specs: [TatwoDistributedTestJobSpecV1] = []
    specs.reserveCapacity(sortedShards.count)
    for (index, shard) in sortedShards.enumerated() {
      let device = sortedDevices[index % sortedDevices.count]
      let safeShard = TatwoLoopPathComponent.sanitize(shard.shardKey)
      let jobID = "distributed-test-\(safeShard)"
      let logicalJobID = "\(jobID)-logical"
      let taskDescription =
        "run test shard \(shard.shardKey) filters=\(shard.filters.joined(separator: ","))"
      let payload = TatwoLoopJobPayloadV1.tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .m,
          taskDescription: taskDescription,
          agent: .codex,
          exactModelRouteID: "gpt-5.6-sol"))
      let remoteJob = TatwoLoopJobV1(
        jobID: jobID,
        logicalJobID: logicalJobID,
        dispatchNonce: "nonce-\(safeShard)",
        contractID: contractID,
        goalID: goalID,
        identity: .sub,
        originDeviceID: originDeviceID,
        targetDeviceID: device.deviceID,
        payload: payload,
        workPath: "distributed-test/\(safeShard)",
        resourceCaps: TatwoLoopResourceCapsV1(
          maxDurationSec: timeoutSec,
          maxOutputBytes: TatwoLoopResourceCapsV1.localHardMaxOutputBytes),
        stopConditions: TatwoLoopStopConditionsV1(
          cancelFileSignal: true,
          rules: ["cancel-file", "shard-result-required"]),
        createdAt: now)
      try remoteJob.validate()

      specs.append(
        TatwoDistributedTestJobSpecV1(
          jobID: jobID,
          logicalJobID: logicalJobID,
          targetDeviceID: device.deviceID,
          shardKey: shard.shardKey,
          expectedShardCount: shard.expectedShardCount,
          filters: shard.filters,
          expectedToolchain: device.toolchainFingerprint,
          diskBudgetBytes: diskBudgetBytes,
          timeoutSec: timeoutSec,
          remoteLoopJob: remoteJob))
    }

    self.schema = schema
    self.expectedShardCount = sortedShards.count
    self.diskBudgetBytes = diskBudgetBytes
    self.timeoutSec = timeoutSec
    self.jobSpecs = specs
  }

  public static func make(
    shardFilters: [TatwoTestShardFilterSetV1],
    targetDevices: [TatwoDistributedTestDeviceCapabilityV1],
    diskBudgetBytes: Int64,
    timeoutSec: TimeInterval,
    originDeviceID: String = "origin",
    contractID: String = "distributed-test-contract",
    goalID: String = "distributed-test-goal",
    now: Date = Date(timeIntervalSince1970: 0)
  ) throws -> TatwoDistributedTestPlanV1 {
    try TatwoDistributedTestPlanV1(
      shardFilters: shardFilters,
      targetDevices: targetDevices,
      diskBudgetBytes: diskBudgetBytes,
      timeoutSec: timeoutSec,
      originDeviceID: originDeviceID,
      contractID: contractID,
      goalID: goalID,
      now: now)
  }

  /// Verify a complete collection of shard receipts.  This method never
  /// reduces a missing/duplicate shard to a partial green result.
  public func verify(
    results: [TatwoDistributedTestResultV1],
    trust: TatwoLoopJobChannelTrust? = nil,
    allowUnsignedResults: Bool = false
  ) -> TatwoDistributedTestVerificationV1 {
    let expectedByKey = Dictionary(uniqueKeysWithValues: jobSpecs.map {
      ($0.shardKey, $0)
    })
    var seen = Set<String>()
    var duplicate: [String] = []
    var unexpected: [String] = []
    var invalid: [String] = []
    var failed: [String] = []
    var mismatches: [String] = []
    var trustFailures: [String] = []
    var skippedCapabilities = Set<String>()
    var skippedCount = 0
    var signedResults = 0
    var unsignedResults = 0
    var observedFilters = Set<String>()
    var expectedFilters = Set<String>()

    for spec in jobSpecs {
      expectedFilters.formUnion(spec.filters)
    }

    for result in results {
      if !seen.insert(result.shardKey).inserted {
        duplicate.append(result.shardKey)
        continue
      }
      if result.schema != TatwoDistributedTestResultV1.schemaName {
        invalid.append(result.shardKey)
      }
      guard let spec = expectedByKey[result.shardKey] else {
        unexpected.append(result.shardKey)
        continue
      }
      let expectedJobDigest = try? spec.remoteLoopJob.canonicalDigest()
      guard result.jobID == spec.jobID,
        result.logicalJobID == spec.logicalJobID,
        result.dispatchNonce == spec.remoteLoopJob.dispatchNonce,
        result.jobCanonicalDigest == expectedJobDigest,
        result.targetDeviceID == spec.targetDeviceID
      else {
        invalid.append(result.shardKey)
        trustFailures.append("\(result.shardKey): attempt binding mismatch")
        continue
      }
      if let signature = result.targetSignature {
        signedResults += 1
        if let trust {
          do {
            try trust.verify(
              payload: result.signingPayload(),
              purpose: .loopResult,
              signature: signature,
              expectedDeviceID: spec.targetDeviceID,
              enforceFreshness: false)
          } catch {
            // Pre-U1 V1 receipts did not sign skip fields. Legacy fallback is
            // allowed only when the decoded result itself declares zero skips.
            guard result.skippedCount == 0, result.unavailableCapabilities.isEmpty else {
              invalid.append(result.shardKey)
              trustFailures.append("\(result.shardKey): signature rejected")
              continue
            }
            do {
              try trust.verify(
                payload: result.legacySigningPayloadV1(),
                purpose: .loopResult,
                signature: signature,
                expectedDeviceID: spec.targetDeviceID,
                enforceFreshness: false)
              trustFailures.append("\(result.shardKey): legacy V1 zero-skip signature")
            } catch {
              invalid.append(result.shardKey)
              trustFailures.append("\(result.shardKey): signature rejected")
              continue
            }
          }
        } else if !allowUnsignedResults {
          invalid.append(result.shardKey)
          trustFailures.append("\(result.shardKey): no fleet trust context")
          continue
        } else {
          trustFailures.append("\(result.shardKey): transport-only signed opt-in")
        }
      } else {
        unsignedResults += 1
        if allowUnsignedResults {
          trustFailures.append("\(result.shardKey): transport-only unsigned opt-in")
        } else {
          invalid.append(result.shardKey)
          trustFailures.append("\(result.shardKey): missing target signature")
          continue
        }
      }
      let expected = Set(spec.filters)
      let actual = Set(result.filters)
      if result.expectedShardCount != spec.expectedShardCount
        || expected != actual
        || result.filters.count != actual.count {
        invalid.append(result.shardKey)
      }
      if !actual.isDisjoint(with: observedFilters) {
        invalid.append(result.shardKey)
      }
      observedFilters.formUnion(actual)
      guard let fingerprint = result.toolchainFingerprint else {
        invalid.append(result.shardKey)
        continue
      }
      do {
        try fingerprint.validateRequiredFields()
      } catch {
        invalid.append(result.shardKey)
        continue
      }
      if result.logBytes <= 0 || result.passedSuites < 0 || result.failedSuites < 0
        || result.skippedCount < 0 {
        invalid.append(result.shardKey)
      }
      if result.skippedCount == 0, !result.unavailableCapabilities.isEmpty {
        invalid.append(result.shardKey)
      }
      if result.skippedCount > 0, result.unavailableCapabilities.isEmpty {
        invalid.append(result.shardKey)
      }
      skippedCount += max(0, result.skippedCount)
      skippedCapabilities.formUnion(result.unavailableCapabilities)
      if result.failedSuites > 0 {
        failed.append(result.shardKey)
      }
      let match = fingerprint.matches(spec.expectedToolchain)
      if match != .compatible {
        mismatches.append("\(result.shardKey): \(match.rawValue)")
      }
    }

    let missing = expectedByKey.keys.filter { !seen.contains($0) }.sorted()
    let filtersComplete = observedFilters == expectedFilters
      && observedFilters.count == expectedFilters.count
    if !filtersComplete {
      invalid.append("partition")
    }

    let duplicateKeys = Array(Set(duplicate)).sorted()
    let unexpectedKeys = Array(Set(unexpected)).sorted()
    let failedKeys = Array(Set(failed)).sorted()
    let mismatchKeys = Array(Set(mismatches)).sorted()
    if signedResults > 0, unsignedResults > 0 {
      // A collection that mixes cryptographically signed and unsigned shards
      // cannot have one coherent trust boundary, even in explicit downgrade
      // mode.
      invalid.append("signature-mode-mix")
    }
    let invalidKeysWithTrust = Array(Set(invalid)).sorted()
    let transportOnlyAccepted = allowUnsignedResults
      && (unsignedResults > 0 || (signedResults > 0 && trust == nil))
    let trustSource: String
    if transportOnlyAccepted {
      trustSource = "transport-only"
    } else if trust != nil {
      trustSource = "fleet-signature"
    } else {
      trustSource = "none"
    }
    let degraded = !mismatchKeys.isEmpty || transportOnlyAccepted

    let hardFailures = !missing.isEmpty
      || !duplicateKeys.isEmpty
      || !unexpectedKeys.isEmpty
      || !invalidKeysWithTrust.isEmpty
      || !failedKeys.isEmpty
    let outcome: TatwoDistributedTestVerificationOutcomeV1
    if hardFailures {
      outcome = .fail
    } else if skippedCount > 0 {
      outcome = .passWithSkips
    } else if degraded {
      outcome = .degraded
    } else {
      outcome = .pass
    }

    var notes: [String] = []
    if !missing.isEmpty {
      notes.append("missing shards: \(missing.joined(separator: ","))")
    }
    if !duplicateKeys.isEmpty {
      notes.append("duplicate shards: \(duplicateKeys.joined(separator: ","))")
    }
    if !unexpectedKeys.isEmpty {
      notes.append("unexpected shards: \(unexpectedKeys.joined(separator: ","))")
    }
    if !invalidKeysWithTrust.isEmpty {
      notes.append("partition/receipt invalid: \(invalidKeysWithTrust.joined(separator: ","))")
    }
    if !failedKeys.isEmpty {
      notes.append("failed suites: \(failedKeys.joined(separator: ","))")
    }
    if skippedCount > 0 {
      notes.append(
        "\(skippedCount) skipped; unavailable capabilities: "
          + skippedCapabilities.sorted().joined(separator: ","))
    }
    if degraded {
      if !mismatchKeys.isEmpty {
        notes.append("degraded toolchain: \(mismatchKeys.joined(separator: ","))")
      }
      if transportOnlyAccepted {
        notes.append("trustSource: transport-only; explicit allowUnsignedResults downgrade; known limitation; 不等於通過")
      } else if trust == nil {
        notes.append("trustSource: none; fleet signature verification unavailable")
      }
      // A hard failure can coexist with a degraded signal (for example,
      // failed suites on a transport-only result). Keep the human-readable
      // conclusion explicit in every such case; callers must not infer that
      // a degraded flag is a green pass.
      if !notes.contains(where: { $0.contains("不等於通過") }) {
        notes.append("degraded state; 不等於通過")
      }
    }
    if !trustFailures.isEmpty {
      notes.append("trust checks: \(trustFailures.joined(separator: ","))")
    }
    let conclusion: String
    if outcome == .degraded {
      conclusion = "DEGRADED: \(notes.joined(separator: "; ")); 不等於通過"
    } else if outcome == .passWithSkips {
      conclusion = "PASS_WITH_SKIPS: \(notes.joined(separator: "; ")); not a full pass"
    } else {
      conclusion = notes.isEmpty
        ? outcome.rawValue
        : "\(outcome.rawValue): \(notes.joined(separator: "; "))"
    }

    return TatwoDistributedTestVerificationV1(
      outcome: outcome,
      degraded: degraded,
      conclusion: conclusion,
      missingShardKeys: missing,
      duplicateShardKeys: duplicateKeys,
      unexpectedShardKeys: unexpectedKeys,
      failedShardKeys: failedKeys,
      invalidShardKeys: invalidKeysWithTrust,
      toolchainMismatches: mismatchKeys,
      skippedCount: skippedCount,
      unavailableCapabilities: skippedCapabilities.sorted(),
      trustSource: trustSource)
  }

  public func verify(
    _ results: [TatwoDistributedTestResultV1],
    trust: TatwoLoopJobChannelTrust? = nil,
    allowUnsignedResults: Bool = false
  )
    -> TatwoDistributedTestVerificationV1 {
    verify(
      results: results,
      trust: trust,
      allowUnsignedResults: allowUnsignedResults)
  }
}
