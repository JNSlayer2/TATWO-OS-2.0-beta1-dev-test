import Foundation

public enum TatwoPressurePolicyVersionV1 {
  /// Protocol bump: pressure authority-bearing digests and persisted pressure
  /// permit/ledger bytes use TatwoPressureCanonicalJSONV1 (sorted JSON with
  /// deterministic fractional-second Date encoding).
  public static let canonicalization = "TatwoPressureCanonicalJSONV1"
  public static let current = "TatwoPressurePolicyV1-20260812-canonical-json-v1"
}

public enum TatwoPressureClassificationV1: String, Codable, Sendable, Equatable {
  case green
  case yellow
  case red
  case unknown
}

public enum TatwoPressureWorkerClassV1: String, Codable, Sendable, Equatable {
  case light
  case heavy
}

public struct TatwoPressureWorkerV1: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let workerID: String
  public let loopID: String?
  public let attemptID: String?
  public let workload: TatwoPressureWorkerClassV1
  public let pid: Int?
  public let startedAt: Date?

  public var id: String { workerID }

  public init(
    schema: String = "TatwoPressureWorkerV1",
    workerID: String,
    loopID: String? = nil,
    attemptID: String? = nil,
    workload: TatwoPressureWorkerClassV1,
    pid: Int? = nil,
    startedAt: Date? = nil
  ) {
    self.schema = schema
    self.workerID = TatwoPressureText.safeReceiptIdentifier(workerID, fallback: "invalid-worker-id")
    self.loopID = loopID.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-loop-id")
    }
    self.attemptID = attemptID.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-attempt-id")
    }
    self.workload = workload
    self.pid = pid
    self.startedAt = startedAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decode(String.self, forKey: .schema),
      workerID: try values.decode(String.self, forKey: .workerID),
      loopID: try values.decodeIfPresent(String.self, forKey: .loopID),
      attemptID: try values.decodeIfPresent(String.self, forKey: .attemptID),
      workload: try values.decode(TatwoPressureWorkerClassV1.self, forKey: .workload),
      pid: try values.decodeIfPresent(Int.self, forKey: .pid),
      startedAt: try values.decodeIfPresent(Date.self, forKey: .startedAt))
  }
}

public struct TatwoPressureClassificationResultV1: Codable, Sendable, Equatable {
  public let schema: String
  public let classification: TatwoPressureClassificationV1
  public let reasonCodes: [String]
  public let classifiedAt: Date

  public init(
    schema: String = "TatwoPressureClassificationResultV1",
    classification: TatwoPressureClassificationV1,
    reasonCodes: [String],
    classifiedAt: Date
  ) {
    self.schema = schema
    self.classification = classification
    self.reasonCodes = TatwoPressureText.normalizedReasonCodes(reasonCodes)
    self.classifiedAt = classifiedAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decode(String.self, forKey: .schema),
      classification: try values.decode(TatwoPressureClassificationV1.self, forKey: .classification),
      reasonCodes: try values.decode([String].self, forKey: .reasonCodes),
      classifiedAt: try values.decode(Date.self, forKey: .classifiedAt))
  }
}

/// App-owned host pressure truth for loop admission.
///
/// This is intentionally stricter than the older memory-only gate: every sensor
/// that participates in the safety decision must be fresh and available. Missing
/// values classify as `unknown`, and `unknown` is rejected by admission.
public struct TatwoDevicePressureSnapshotV1: Codable, Sendable, Equatable {
  public static let defaultStaleAfterSeconds: TimeInterval = 20
  public static let rapidSwapGrowthMiBPerMinute: Double = 128
  public static let yellowUILatencyMilliseconds: Double = 1_000
  public static let redUILatencyMilliseconds: Double = 3_000

  public let schema: String
  public let pressurePolicyVersion: String
  public let deviceID: String
  public let observedAt: Date
  public let sourceSnapshotSequence: UInt64?
  public let sourceSampleAttemptID: String?
  public let memoryFreePercent: Double?
  public let swapFreeMiB: Double?
  public let dataVolumeFreeGiB: Double?
  public let load1PerCPU: Double?
  public let thermalWarning: Bool?
  public let uiLatencyMilliseconds: Double?
  public let swapGrowthMiBPerMinute: Double?
  public let unavailableSensors: [String]
  public let unavailableSensorDiagnostics: [TatwoPressureSensorUnavailableV1]
  public let activeLoopID: String?
  public let workers: [TatwoPressureWorkerV1]
  /// Display/readiness host facts. Omitted from canonical JSON when nil so
  /// existing admission digests stay stable.
  public let hostInventory: TatwoDeviceHostInventoryV1?

  private enum CodingKeys: String, CodingKey {
    case schema
    case pressurePolicyVersion
    case deviceID
    case observedAt
    case sourceSnapshotSequence
    case sourceSampleAttemptID
    case memoryFreePercent
    case swapFreeMiB
    case dataVolumeFreeGiB
    case load1PerCPU
    case thermalWarning
    case uiLatencyMilliseconds
    case swapGrowthMiBPerMinute
    case unavailableSensors
    case unavailableSensorDiagnostics
    case activeLoopID
    case workers
    case hostInventory
  }

  public init(
    schema: String = "TatwoDevicePressureSnapshotV1",
    pressurePolicyVersion: String = TatwoPressurePolicyVersionV1.current,
    deviceID: String,
    observedAt: Date,
    sourceSnapshotSequence: UInt64? = nil,
    sourceSampleAttemptID: String? = nil,
    memoryFreePercent: Double?,
    swapFreeMiB: Double?,
    dataVolumeFreeGiB: Double?,
    load1PerCPU: Double?,
    thermalWarning: Bool?,
    uiLatencyMilliseconds: Double?,
    swapGrowthMiBPerMinute: Double?,
    unavailableSensors: [String] = [],
    unavailableSensorDiagnostics: [TatwoPressureSensorUnavailableV1] = [],
    activeLoopID: String? = nil,
    workers: [TatwoPressureWorkerV1] = [],
    hostInventory: TatwoDeviceHostInventoryV1? = nil
  ) {
    self.schema = schema
    self.pressurePolicyVersion = TatwoPressureText.safeReceiptIdentifier(
      pressurePolicyVersion,
      fallback: "invalid-pressure-policy-version")
    self.deviceID = TatwoPressureText.safeReceiptIdentifier(deviceID, fallback: "invalid-device-id")
    self.observedAt = observedAt
    self.sourceSnapshotSequence = sourceSnapshotSequence
    self.sourceSampleAttemptID = sourceSampleAttemptID.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-sample-attempt-id")
    }
    self.memoryFreePercent = memoryFreePercent
    self.swapFreeMiB = swapFreeMiB
    self.dataVolumeFreeGiB = dataVolumeFreeGiB
    self.load1PerCPU = load1PerCPU
    self.thermalWarning = thermalWarning
    self.uiLatencyMilliseconds = uiLatencyMilliseconds
    self.swapGrowthMiBPerMinute = swapGrowthMiBPerMinute
    let normalizedDiagnostics = TatwoPressureText.normalizedUnavailableSensorDiagnostics(
      unavailableSensorDiagnostics)
    self.unavailableSensorDiagnostics = normalizedDiagnostics
    self.unavailableSensors = TatwoPressureText.normalizedSensorNames(
      unavailableSensors + normalizedDiagnostics.map { $0.sensor.rawValue })
    self.activeLoopID = activeLoopID.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-loop-id")
    }
    self.workers = workers
    self.hostInventory = hostInventory?.isEmpty == true ? nil : hostInventory
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decode(String.self, forKey: .schema),
      pressurePolicyVersion: try values.decodeIfPresent(String.self, forKey: .pressurePolicyVersion)
        ?? TatwoPressurePolicyVersionV1.current,
      deviceID: try values.decode(String.self, forKey: .deviceID),
      observedAt: try values.decode(Date.self, forKey: .observedAt),
      sourceSnapshotSequence: try values.decodeIfPresent(UInt64.self, forKey: .sourceSnapshotSequence),
      sourceSampleAttemptID: try values.decodeIfPresent(String.self, forKey: .sourceSampleAttemptID),
      memoryFreePercent: try values.decodeIfPresent(Double.self, forKey: .memoryFreePercent),
      swapFreeMiB: try values.decodeIfPresent(Double.self, forKey: .swapFreeMiB),
      dataVolumeFreeGiB: try values.decodeIfPresent(Double.self, forKey: .dataVolumeFreeGiB),
      load1PerCPU: try values.decodeIfPresent(Double.self, forKey: .load1PerCPU),
      thermalWarning: try values.decodeIfPresent(Bool.self, forKey: .thermalWarning),
      uiLatencyMilliseconds: try values.decodeIfPresent(Double.self, forKey: .uiLatencyMilliseconds),
      swapGrowthMiBPerMinute: try values.decodeIfPresent(Double.self, forKey: .swapGrowthMiBPerMinute),
      unavailableSensors: try values.decode([String].self, forKey: .unavailableSensors),
      unavailableSensorDiagnostics: try values.decodeIfPresent(
        [TatwoPressureSensorUnavailableV1].self,
        forKey: .unavailableSensorDiagnostics) ?? [],
      activeLoopID: try values.decodeIfPresent(String.self, forKey: .activeLoopID),
      workers: try values.decode([TatwoPressureWorkerV1].self, forKey: .workers),
      hostInventory: try values.decodeIfPresent(
        TatwoDeviceHostInventoryV1.self,
        forKey: .hostInventory))
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schema, forKey: .schema)
    try values.encode(pressurePolicyVersion, forKey: .pressurePolicyVersion)
    try values.encode(deviceID, forKey: .deviceID)
    try values.encode(observedAt, forKey: .observedAt)
    try values.encode(sourceSnapshotSequence, forKey: .sourceSnapshotSequence)
    try values.encode(sourceSampleAttemptID, forKey: .sourceSampleAttemptID)
    try values.encode(memoryFreePercent, forKey: .memoryFreePercent)
    try values.encode(swapFreeMiB, forKey: .swapFreeMiB)
    try values.encode(dataVolumeFreeGiB, forKey: .dataVolumeFreeGiB)
    try values.encode(load1PerCPU, forKey: .load1PerCPU)
    try values.encode(thermalWarning, forKey: .thermalWarning)
    try values.encode(uiLatencyMilliseconds, forKey: .uiLatencyMilliseconds)
    try values.encode(swapGrowthMiBPerMinute, forKey: .swapGrowthMiBPerMinute)
    try values.encode(unavailableSensors, forKey: .unavailableSensors)
    try values.encode(unavailableSensorDiagnostics, forKey: .unavailableSensorDiagnostics)
    try values.encode(activeLoopID, forKey: .activeLoopID)
    try values.encode(workers, forKey: .workers)
    try values.encodeIfPresent(hostInventory, forKey: .hostInventory)
  }

  public func classify(
    now: Date,
    staleAfterSeconds: TimeInterval = Self.defaultStaleAfterSeconds
  ) -> TatwoPressureClassificationResultV1 {
    let effectiveStaleAfter = min(
      max(0, staleAfterSeconds),
      Self.defaultStaleAfterSeconds)
    var unknown: [String] = []
    if schema != "TatwoDevicePressureSnapshotV1" {
      unknown.append("invalid_schema")
    }
    if pressurePolicyVersion != TatwoPressurePolicyVersionV1.current {
      unknown.append("pressure_policy_version_mismatch")
    }
    if !TatwoPressureText.isSafeIdentifier(deviceID) || deviceID == "invalid-device-id" {
      unknown.append("invalid_device_id")
    }
    if now.timeIntervalSince(observedAt) > effectiveStaleAfter {
      unknown.append("monitor_stale")
    }
    if observedAt.timeIntervalSince(now) > 1 {
      unknown.append("monitor_clock_skew")
    }
    unknown.append(contentsOf: TatwoPressureText.unavailableSensorReasonCodes(unavailableSensors))
    unknown.append(contentsOf: TatwoPressureText.unavailableSensorDiagnosticReasonCodes(
      unavailableSensorDiagnostics))

    let requiredSensors: [(String, Any?)] = [
      ("memory_free_percent", memoryFreePercent),
      ("swap_free_mib", swapFreeMiB),
      ("data_volume_free_gib", dataVolumeFreeGiB),
      ("load1_per_cpu", load1PerCPU),
      ("thermal_warning", thermalWarning),
      ("ui_latency_ms", uiLatencyMilliseconds),
      ("swap_growth_mib_per_minute", swapGrowthMiBPerMinute),
    ]
    for (name, value) in requiredSensors where value == nil {
      unknown.append("sensor_missing:\(name)")
    }
    unknown.append(contentsOf: numericValidationReasons())
    if !unknown.isEmpty {
      return TatwoPressureClassificationResultV1(
        classification: .unknown,
        reasonCodes: unknown,
        classifiedAt: now)
    }

    let memory = memoryFreePercent!
    let swap = swapFreeMiB!
    let data = dataVolumeFreeGiB!
    let load = load1PerCPU!
    let thermal = thermalWarning!
    let uiLatency = uiLatencyMilliseconds!
    let swapGrowth = swapGrowthMiBPerMinute!

    var red: [String] = []
    if memory < 15 { red.append("memory_free_below_15_percent") }
    if swap < 512 { red.append("swap_free_below_512_mib") }
    if data < 15 { red.append("data_volume_free_below_15_gib") }
    if swapGrowth >= Self.rapidSwapGrowthMiBPerMinute {
      red.append("swap_growth_rapid")
    }
    if thermal { red.append("thermal_warning") }
    if uiLatency >= Self.redUILatencyMilliseconds {
      red.append("ui_latency_at_or_over_3s")
    }
    if !red.isEmpty {
      return TatwoPressureClassificationResultV1(
        classification: .red,
        reasonCodes: red,
        classifiedAt: now)
    }

    var yellow: [String] = []
    if memory < 25 { yellow.append("memory_free_below_25_percent") }
    if swap < 1_024 { yellow.append("swap_free_below_1_gib") }
    if data < 25 { yellow.append("data_volume_free_below_25_gib") }
    if load >= 0.7 { yellow.append("load1_per_cpu_at_or_above_0_7") }
    if uiLatency >= Self.yellowUILatencyMilliseconds {
      yellow.append("ui_latency_elevated")
    }
    if !yellow.isEmpty {
      return TatwoPressureClassificationResultV1(
        classification: .yellow,
        reasonCodes: yellow,
        classifiedAt: now)
    }

    return TatwoPressureClassificationResultV1(
      classification: .green,
      reasonCodes: ["within_green_thresholds"],
      classifiedAt: now)
  }

  public func canonicalDigest() throws -> String {
    try TatwoPressureDigest.canonicalJSONDigest(self)
  }

  public func newestOrHeaviestWorker() -> TatwoPressureWorkerV1? {
    Self.newestOrHeaviestWorker(in: workers)
  }

  public static func newestOrHeaviestWorker(
    in workers: [TatwoPressureWorkerV1]
  ) -> TatwoPressureWorkerV1? {
    workers.sorted { lhs, rhs in
      if lhs.workload != rhs.workload {
        return lhs.workload == .heavy
      }
      switch (lhs.startedAt, rhs.startedAt) {
      case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
        return lhsDate > rhsDate
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        return lhs.workerID < rhs.workerID
      }
    }.first
  }

  private func numericValidationReasons() -> [String] {
    var reasons: [String] = []
    func validate(_ name: String, _ value: Double?, min: Double? = nil, max: Double? = nil) {
      guard let value else { return }
      guard value.isFinite else {
        reasons.append("sensor_invalid:\(name)")
        return
      }
      if let min, value < min { reasons.append("sensor_out_of_range:\(name)") }
      if let max, value > max { reasons.append("sensor_out_of_range:\(name)") }
    }
    validate("memory_free_percent", memoryFreePercent, min: 0, max: 100)
    validate("swap_free_mib", swapFreeMiB, min: 0)
    validate("data_volume_free_gib", dataVolumeFreeGiB, min: 0)
    validate("load1_per_cpu", load1PerCPU, min: 0)
    validate("ui_latency_ms", uiLatencyMilliseconds, min: 0)
    validate("swap_growth_mib_per_minute", swapGrowthMiBPerMinute)
    return reasons
  }
}

public enum TatwoPressureLeaseFreshnessV1: String, Codable, Sendable, Equatable {
  case fresh
  case stale
  case notYetValid
  case expired
}

public struct TatwoPressureLeaseV1: Codable, Sendable, Equatable {
  public static let defaultTTLSeconds: TimeInterval = 20
  public static let defaultRunnerMaxAgeSeconds: TimeInterval = 15

  public let schema: String
  public let pressurePolicyVersion: String
  public let leaseID: String
  public let deviceID: String
  public let issuer: String
  public let issuedAt: Date
  public let expiresAt: Date
  public let snapshotObservedAt: Date
  public let snapshotDigest: String
  public let sourceSnapshotSequence: UInt64?
  public let sourceSampleAttemptID: String?
  public let classification: TatwoPressureClassificationV1
  public let reasonCodes: [String]
  public let runtimeInstanceID: String?
  public let runtimeGeneration: UInt64?
  public let admissionAttemptID: String?
  public let admissionRequestBindingDigest: String?
  public let dispatchNonce: String?
  public let reservationID: String?
  public private(set) var leaseDigest: String?

  public init(
    schema: String = "TatwoPressureLeaseV1",
    pressurePolicyVersion: String = TatwoPressurePolicyVersionV1.current,
    leaseID: String,
    deviceID: String,
    issuer: String = "tatwo-app",
    issuedAt: Date,
    expiresAt: Date,
    snapshotObservedAt: Date,
    snapshotDigest: String,
    sourceSnapshotSequence: UInt64? = nil,
    sourceSampleAttemptID: String? = nil,
    classification: TatwoPressureClassificationV1,
    reasonCodes: [String],
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64? = nil,
    admissionAttemptID: String? = nil,
    admissionRequestBindingDigest: String? = nil,
    dispatchNonce: String? = nil,
    reservationID: String? = nil,
    leaseDigest: String? = nil
  ) {
    self.schema = schema
    self.pressurePolicyVersion = TatwoPressureText.safeReceiptIdentifier(
      pressurePolicyVersion,
      fallback: "invalid-pressure-policy-version")
    self.leaseID = TatwoPressureText.safeReceiptIdentifier(leaseID, fallback: "invalid-lease-id")
    self.deviceID = TatwoPressureText.safeReceiptIdentifier(deviceID, fallback: "invalid-device-id")
    self.issuer = TatwoPressureText.safeReceiptIdentifier(issuer, fallback: "invalid-issuer")
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.snapshotObservedAt = snapshotObservedAt
    self.snapshotDigest = TatwoPressureText.safeSHA256Digest(
      snapshotDigest,
      fallback: "invalid-snapshot-digest")
    self.sourceSnapshotSequence = sourceSnapshotSequence
    self.sourceSampleAttemptID = sourceSampleAttemptID.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-sample-attempt-id")
    }
    self.classification = classification
    self.reasonCodes = TatwoPressureText.normalizedReasonCodes(reasonCodes)
    self.runtimeInstanceID = runtimeInstanceID.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-runtime-instance-id")
    }
    self.runtimeGeneration = runtimeGeneration
    self.admissionAttemptID = admissionAttemptID.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-attempt-id")
    }
    self.admissionRequestBindingDigest = admissionRequestBindingDigest.map {
      TatwoPressureText.safeSHA256Digest($0, fallback: "invalid-request-binding-digest")
    }
    self.dispatchNonce = dispatchNonce.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-dispatch-nonce")
    }
    self.reservationID = reservationID.map {
      TatwoPressureText.safeSHA256Digest($0, fallback: "invalid-reservation-id")
    }
    self.leaseDigest = leaseDigest.map {
      TatwoPressureText.safeSHA256Digest($0, fallback: "invalid-lease-digest")
    }
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decode(String.self, forKey: .schema),
      pressurePolicyVersion: try values.decodeIfPresent(String.self, forKey: .pressurePolicyVersion)
        ?? TatwoPressurePolicyVersionV1.current,
      leaseID: try values.decode(String.self, forKey: .leaseID),
      deviceID: try values.decode(String.self, forKey: .deviceID),
      issuer: try values.decode(String.self, forKey: .issuer),
      issuedAt: try values.decode(Date.self, forKey: .issuedAt),
      expiresAt: try values.decode(Date.self, forKey: .expiresAt),
      snapshotObservedAt: try values.decode(Date.self, forKey: .snapshotObservedAt),
      snapshotDigest: try values.decode(String.self, forKey: .snapshotDigest),
      sourceSnapshotSequence: try values.decodeIfPresent(UInt64.self, forKey: .sourceSnapshotSequence),
      sourceSampleAttemptID: try values.decodeIfPresent(String.self, forKey: .sourceSampleAttemptID),
      classification: try values.decode(TatwoPressureClassificationV1.self, forKey: .classification),
      reasonCodes: try values.decode([String].self, forKey: .reasonCodes),
      runtimeInstanceID: try values.decodeIfPresent(String.self, forKey: .runtimeInstanceID),
      runtimeGeneration: try values.decodeIfPresent(UInt64.self, forKey: .runtimeGeneration),
      admissionAttemptID: try values.decodeIfPresent(String.self, forKey: .admissionAttemptID),
      admissionRequestBindingDigest: try values.decodeIfPresent(
        String.self,
        forKey: .admissionRequestBindingDigest),
      dispatchNonce: try values.decodeIfPresent(String.self, forKey: .dispatchNonce),
      reservationID: try values.decodeIfPresent(String.self, forKey: .reservationID),
      leaseDigest: try values.decodeIfPresent(String.self, forKey: .leaseDigest))
  }

  public static func issue(
    for snapshot: TatwoDevicePressureSnapshotV1,
    now: Date,
    ttlSeconds: TimeInterval = defaultTTLSeconds,
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64? = nil,
    admissionAttemptID: String? = nil,
    admissionRequestBindingDigest: String? = nil,
    dispatchNonce: String? = nil,
    reservationID: String? = nil
  ) throws -> TatwoPressureLeaseV1 {
    let classification = snapshot.classify(now: now)
    let snapshotDigest = try snapshot.canonicalDigest()
    let seed = [
      TatwoPressurePolicyVersionV1.current,
      snapshot.deviceID,
      snapshotDigest,
      snapshot.sourceSnapshotSequence.map(String.init) ?? "no-snapshot-sequence",
      snapshot.sourceSampleAttemptID ?? "no-sample-attempt",
      "\(now.timeIntervalSince1970)",
      "\(ttlSeconds)",
      runtimeInstanceID ?? "no-runtime",
      runtimeGeneration.map(String.init) ?? "no-generation",
      admissionAttemptID ?? "no-attempt",
      admissionRequestBindingDigest ?? "no-request-binding",
      dispatchNonce ?? "no-dispatch-nonce",
      reservationID ?? "no-reservation",
    ].joined(separator: "|")
    var lease = TatwoPressureLeaseV1(
      pressurePolicyVersion: TatwoPressurePolicyVersionV1.current,
      leaseID: TatwoLoopJobDigest.sha256(Data(seed.utf8)),
      deviceID: snapshot.deviceID,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(ttlSeconds),
      snapshotObservedAt: snapshot.observedAt,
      snapshotDigest: snapshotDigest,
      sourceSnapshotSequence: snapshot.sourceSnapshotSequence,
      sourceSampleAttemptID: snapshot.sourceSampleAttemptID,
      classification: classification.classification,
      reasonCodes: classification.reasonCodes,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: admissionAttemptID,
      admissionRequestBindingDigest: admissionRequestBindingDigest,
      dispatchNonce: dispatchNonce,
      reservationID: reservationID)
    lease.leaseDigest = try lease.canonicalDigest()
    return lease
  }

  public func freshness(
    now: Date,
    maxAgeSeconds: TimeInterval = defaultRunnerMaxAgeSeconds
  ) -> TatwoPressureLeaseFreshnessV1 {
    let effectiveMaxAge = min(max(0, maxAgeSeconds), Self.defaultRunnerMaxAgeSeconds)
    if issuedAt.timeIntervalSince(now) > 1 { return .notYetValid }
    if now > expiresAt { return .expired }
    if now.timeIntervalSince(issuedAt) > effectiveMaxAge { return .stale }
    return .fresh
  }

  public func canonicalDigest() throws -> String {
    var copy = self
    copy.leaseDigest = nil
    return try TatwoPressureDigest.canonicalJSONDigest(copy)
  }

  public func verifiesDigest() -> Bool {
    guard schema == "TatwoPressureLeaseV1",
      pressurePolicyVersion == TatwoPressurePolicyVersionV1.current,
      let leaseDigest,
      !leaseDigest.hasPrefix("invalid-")
    else { return false }
    return (try? canonicalDigest()) == leaseDigest
  }
}

public enum TatwoLoopAdmissionStopActionV1: String, Codable, Sendable, Equatable {
  case none
  case checkpointExistingWork
  case checkpointAndStopNewestOrHeaviestWorker
}

public struct TatwoLoopAdmissionDecisionV1: Codable, Sendable, Equatable {
  public let schema: String
  public let pressurePolicyVersion: String
  public let deviceID: String
  public let loopID: String
  public let workload: TatwoPressureWorkerClassV1
  public let decidedAt: Date
  public let classification: TatwoPressureClassificationV1
  public let accepted: Bool
  public let authorizesSpawn: Bool
  public let reasonCode: String
  public let reason: String
  public let stopAction: TatwoLoopAdmissionStopActionV1
  public let targetWorkerID: String?
  public let leaseID: String?
  public let requestBindingDigest: String?
  public let runtimeInstanceID: String?
  public let runtimeGeneration: UInt64?
  public let admissionAttemptID: String?
  public let dispatchNonce: String?
  public let reservationID: String?
  public let sourceSnapshotSequence: UInt64?
  public let sourceSampleAttemptID: String?
  public let leaseDigest: String?

  public init(
    schema: String = "TatwoLoopAdmissionDecisionV1",
    pressurePolicyVersion: String = TatwoPressurePolicyVersionV1.current,
    deviceID: String,
    loopID: String,
    workload: TatwoPressureWorkerClassV1,
    decidedAt: Date,
    classification: TatwoPressureClassificationV1,
    accepted: Bool,
    authorizesSpawn: Bool = false,
    reasonCode: String,
    reason: String,
    stopAction: TatwoLoopAdmissionStopActionV1,
    targetWorkerID: String? = nil,
    leaseID: String?,
    requestBindingDigest: String? = nil,
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64? = nil,
    admissionAttemptID: String? = nil,
    dispatchNonce: String? = nil,
    reservationID: String? = nil,
    sourceSnapshotSequence: UInt64? = nil,
    sourceSampleAttemptID: String? = nil,
    leaseDigest: String? = nil
  ) {
    self.schema = schema
    self.pressurePolicyVersion = TatwoPressureText.safeReceiptIdentifier(
      pressurePolicyVersion,
      fallback: "invalid-pressure-policy-version")
    self.deviceID = TatwoPressureText.safeReceiptIdentifier(deviceID, fallback: "invalid-device-id")
    self.loopID = TatwoPressureText.safeReceiptIdentifier(loopID, fallback: "invalid-loop-id")
    self.workload = workload
    self.decidedAt = decidedAt
    self.classification = classification
    self.accepted = accepted
    self.authorizesSpawn = accepted && authorizesSpawn
    self.reasonCode = TatwoPressureText.safeReceiptIdentifier(reasonCode, fallback: "invalid_reason_code")
    self.reason = TatwoPressureText.redacted(reason)
    self.stopAction = stopAction
    self.targetWorkerID = targetWorkerID.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-worker-id")
    }
    self.leaseID = leaseID.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-lease-id")
    }
    self.requestBindingDigest = requestBindingDigest.map {
      TatwoPressureText.safeSHA256Digest($0, fallback: "invalid-request-binding-digest")
    }
    self.runtimeInstanceID = runtimeInstanceID.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-runtime-instance-id")
    }
    self.runtimeGeneration = runtimeGeneration
    self.admissionAttemptID = admissionAttemptID.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-attempt-id")
    }
    self.dispatchNonce = dispatchNonce.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-dispatch-nonce")
    }
    self.reservationID = reservationID.map {
      TatwoPressureText.safeSHA256Digest($0, fallback: "invalid-reservation-id")
    }
    self.sourceSnapshotSequence = sourceSnapshotSequence
    self.sourceSampleAttemptID = sourceSampleAttemptID.map {
      TatwoPressureText.safeReceiptIdentifier($0, fallback: "invalid-sample-attempt-id")
    }
    self.leaseDigest = leaseDigest.map {
      TatwoPressureText.safeSHA256Digest($0, fallback: "invalid-lease-digest")
    }
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decode(String.self, forKey: .schema),
      pressurePolicyVersion: try values.decodeIfPresent(String.self, forKey: .pressurePolicyVersion)
        ?? TatwoPressurePolicyVersionV1.current,
      deviceID: try values.decode(String.self, forKey: .deviceID),
      loopID: try values.decode(String.self, forKey: .loopID),
      workload: try values.decode(TatwoPressureWorkerClassV1.self, forKey: .workload),
      decidedAt: try values.decode(Date.self, forKey: .decidedAt),
      classification: try values.decode(TatwoPressureClassificationV1.self, forKey: .classification),
      accepted: try values.decode(Bool.self, forKey: .accepted),
      authorizesSpawn: try values.decodeIfPresent(Bool.self, forKey: .authorizesSpawn) ?? false,
      reasonCode: try values.decode(String.self, forKey: .reasonCode),
      reason: try values.decode(String.self, forKey: .reason),
      stopAction: try values.decode(TatwoLoopAdmissionStopActionV1.self, forKey: .stopAction),
      targetWorkerID: try values.decodeIfPresent(String.self, forKey: .targetWorkerID),
      leaseID: try values.decodeIfPresent(String.self, forKey: .leaseID),
      requestBindingDigest: try values.decodeIfPresent(String.self, forKey: .requestBindingDigest),
      runtimeInstanceID: try values.decodeIfPresent(String.self, forKey: .runtimeInstanceID),
      runtimeGeneration: try values.decodeIfPresent(UInt64.self, forKey: .runtimeGeneration),
      admissionAttemptID: try values.decodeIfPresent(String.self, forKey: .admissionAttemptID),
      dispatchNonce: try values.decodeIfPresent(String.self, forKey: .dispatchNonce),
      reservationID: try values.decodeIfPresent(String.self, forKey: .reservationID),
      sourceSnapshotSequence: try values.decodeIfPresent(UInt64.self, forKey: .sourceSnapshotSequence),
      sourceSampleAttemptID: try values.decodeIfPresent(String.self, forKey: .sourceSampleAttemptID),
      leaseDigest: try values.decodeIfPresent(String.self, forKey: .leaseDigest))
  }

  func withRequestBindingDigest(_ digest: String?) -> TatwoLoopAdmissionDecisionV1 {
    TatwoLoopAdmissionDecisionV1(
      schema: schema,
      pressurePolicyVersion: pressurePolicyVersion,
      deviceID: deviceID,
      loopID: loopID,
      workload: workload,
      decidedAt: decidedAt,
      classification: classification,
      accepted: accepted,
      authorizesSpawn: authorizesSpawn,
      reasonCode: reasonCode,
      reason: reason,
      stopAction: stopAction,
      targetWorkerID: targetWorkerID,
      leaseID: leaseID,
      requestBindingDigest: digest,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: admissionAttemptID,
      dispatchNonce: dispatchNonce,
      reservationID: reservationID,
      sourceSnapshotSequence: sourceSnapshotSequence,
      sourceSampleAttemptID: sourceSampleAttemptID,
      leaseDigest: leaseDigest)
  }

  public static func decide(
    deviceID: String,
    loopID: String,
    workload: TatwoPressureWorkerClassV1,
    lease: TatwoPressureLeaseV1?,
    now: Date,
    maxLeaseAgeSeconds: TimeInterval = TatwoPressureLeaseV1.defaultRunnerMaxAgeSeconds,
    workers: [TatwoPressureWorkerV1] = [],
    requestBindingDigest: String? = nil,
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64? = nil,
    admissionAttemptID: String? = nil,
    dispatchNonce: String? = nil,
    reservationID: String? = nil
  ) -> TatwoLoopAdmissionDecisionV1 {
    guard TatwoPressureText.isSafeIdentifier(deviceID),
      TatwoPressureText.isSafeIdentifier(loopID)
    else {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "monitor_unknown",
        reason: "invalid pressure admission identifier",
        stopAction: .none,
        leaseID: nil,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID)
    }
    guard let lease else {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "monitor_unknown",
        reason: "missing fresh Tatwo App pressure lease",
        stopAction: .none,
        leaseID: nil,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID)
    }
    guard lease.schema == "TatwoPressureLeaseV1" else {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "monitor_unknown",
        reason: "pressure lease schema is invalid",
        stopAction: .none,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }
    guard lease.pressurePolicyVersion == TatwoPressurePolicyVersionV1.current,
      lease.verifiesDigest()
    else {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "pressure_lease_digest_invalid",
        reason: "pressure lease policy version or digest is not verifiable",
        stopAction: .checkpointExistingWork,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }
    guard lease.deviceID == deviceID else {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "pressure_lease_device_mismatch",
        reason: "pressure lease device does not match admission target",
        stopAction: .none,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }
    if let dispatchNonce, lease.dispatchNonce != dispatchNonce {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "pressure_lease_dispatch_nonce_mismatch",
        reason: "pressure lease dispatch nonce does not match admission request",
        stopAction: .checkpointExistingWork,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }
    if let reservationID, lease.reservationID != reservationID {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "pressure_lease_reservation_mismatch",
        reason: "pressure lease reservation does not match admission reservation",
        stopAction: .checkpointExistingWork,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }
    if let runtimeInstanceID, lease.runtimeInstanceID != runtimeInstanceID {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "pressure_lease_runtime_mismatch",
        reason: "pressure lease runtime instance does not match admission runtime",
        stopAction: .checkpointExistingWork,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }
    if let runtimeGeneration, lease.runtimeGeneration != runtimeGeneration {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "pressure_lease_generation_mismatch",
        reason: "pressure lease runtime generation does not match admission runtime",
        stopAction: .checkpointExistingWork,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }
    if let admissionAttemptID, lease.admissionAttemptID != admissionAttemptID {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "pressure_lease_attempt_mismatch",
        reason: "pressure lease admission attempt does not match request attempt",
        stopAction: .checkpointExistingWork,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }
    if let requestBindingDigest, lease.admissionRequestBindingDigest != requestBindingDigest {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "pressure_lease_request_binding_mismatch",
        reason: "pressure lease request binding does not match admission request",
        stopAction: .checkpointExistingWork,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }
    let freshness = lease.freshness(now: now, maxAgeSeconds: maxLeaseAgeSeconds)
    guard freshness == .fresh else {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "monitor_unknown",
        reason: "pressure lease is \(freshness.rawValue)",
        stopAction: .checkpointExistingWork,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }
    if now.timeIntervalSince(lease.snapshotObservedAt) > maxLeaseAgeSeconds {
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "monitor_unknown",
        reason: "pressure lease snapshot is stale",
        stopAction: .checkpointExistingWork,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }

    switch lease.classification {
    case .green:
      if let scopedRejection = acceptedLeaseScopeRejectionIfNeeded(
        lease: lease,
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID)
      {
        return scopedRejection
      }
      return acceptedDecision(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .green,
        authorizesSpawn: true,
        reasonCode: "pressure_green",
        reason: "pressure lease is fresh and green",
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    case .yellow:
      if workload == .heavy {
        return rejected(
          deviceID: deviceID,
          loopID: loopID,
          workload: workload,
          decidedAt: now,
          classification: .yellow,
          reasonCode: "pressure_yellow_heavy_rejected",
          reason: "yellow pressure forbids new heavy work and concurrency expansion",
          stopAction: .none,
          leaseID: lease.leaseID,
          requestBindingDigest: requestBindingDigest,
          runtimeInstanceID: runtimeInstanceID,
          runtimeGeneration: runtimeGeneration,
          admissionAttemptID: admissionAttemptID,
          dispatchNonce: dispatchNonce,
          reservationID: reservationID,
          sourceSnapshotSequence: lease.sourceSnapshotSequence,
          sourceSampleAttemptID: lease.sourceSampleAttemptID,
          leaseDigest: lease.leaseDigest)
      }
      if let scopedRejection = acceptedLeaseScopeRejectionIfNeeded(
        lease: lease,
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID)
      {
        return scopedRejection
      }
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .yellow,
        reasonCode: "pressure_yellow_light_only",
        reason: "yellow pressure never authorizes a new admission directly; only the service seam may upgrade an exact already-spawned light attempt to continuation",
        stopAction: .none,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    case .red:
      let targetWorker = TatwoDevicePressureSnapshotV1.newestOrHeaviestWorker(in: workers)
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .red,
        reasonCode: "pressure_red",
        reason: "red pressure rejects new assignment and requires newest/heaviest worker to converge at a safe checkpoint",
        stopAction: targetWorker == nil
          ? .checkpointExistingWork
          : .checkpointAndStopNewestOrHeaviestWorker,
        targetWorkerID: targetWorker?.workerID,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    case .unknown:
      return rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: now,
        classification: .unknown,
        reasonCode: "monitor_unknown",
        reason: "pressure classification is unknown; fail closed",
        stopAction: .checkpointExistingWork,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }
  }

  private static func acceptedLeaseScopeRejectionIfNeeded(
    lease: TatwoPressureLeaseV1,
    deviceID: String,
    loopID: String,
    workload: TatwoPressureWorkerClassV1,
    decidedAt: Date,
    requestBindingDigest: String?,
    runtimeInstanceID: String?,
    runtimeGeneration: UInt64?,
    admissionAttemptID: String?,
    dispatchNonce: String?,
    reservationID: String?
  ) -> TatwoLoopAdmissionDecisionV1? {
    func scopeRejected(
      reasonCode: String,
      reason: String
    ) -> TatwoLoopAdmissionDecisionV1 {
      rejected(
        deviceID: deviceID,
        loopID: loopID,
        workload: workload,
        decidedAt: decidedAt,
        classification: .unknown,
        reasonCode: reasonCode,
        reason: reason,
        stopAction: .checkpointExistingWork,
        leaseID: lease.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID,
        sourceSnapshotSequence: lease.sourceSnapshotSequence,
        sourceSampleAttemptID: lease.sourceSampleAttemptID,
        leaseDigest: lease.leaseDigest)
    }

    guard let requestBindingDigest,
      TatwoPressureText.isSHA256Digest(requestBindingDigest),
      let leaseRequestBindingDigest = lease.admissionRequestBindingDigest,
      leaseRequestBindingDigest == requestBindingDigest
    else {
      return scopeRejected(
        reasonCode: "pressure_lease_request_binding_missing",
        reason: "accepted pressure admission requires a lease bound to the canonical admission request digest")
    }
    guard let dispatchNonce,
      TatwoPressureText.isSafeIdentifier(dispatchNonce),
      let leaseDispatchNonce = lease.dispatchNonce,
      leaseDispatchNonce == dispatchNonce
    else {
      return scopeRejected(
        reasonCode: "pressure_lease_dispatch_nonce_missing",
        reason: "accepted pressure admission requires a lease bound to the dispatch nonce")
    }
    guard let reservationID,
      TatwoPressureText.isSHA256Digest(reservationID),
      let leaseReservationID = lease.reservationID,
      leaseReservationID == reservationID
    else {
      return scopeRejected(
        reasonCode: "pressure_lease_reservation_missing",
        reason: "accepted pressure admission requires a lease bound to the current reservation")
    }
    guard let runtimeInstanceID,
      TatwoPressureText.isValidRuntimeInstanceID(runtimeInstanceID),
      let leaseRuntimeInstanceID = lease.runtimeInstanceID,
      TatwoPressureText.isValidRuntimeInstanceID(leaseRuntimeInstanceID),
      leaseRuntimeInstanceID == runtimeInstanceID,
      let runtimeGeneration,
      let leaseRuntimeGeneration = lease.runtimeGeneration,
      leaseRuntimeGeneration == runtimeGeneration,
      let admissionAttemptID,
      TatwoPressureText.isSafeIdentifier(admissionAttemptID),
      let leaseAdmissionAttemptID = lease.admissionAttemptID,
      leaseAdmissionAttemptID == admissionAttemptID
    else {
      return scopeRejected(
        reasonCode: "pressure_lease_runtime_missing",
        reason: "accepted pressure admission requires runtime instance, generation and exact attempt bindings")
    }
    guard lease.sourceSnapshotSequence != nil,
      let sourceSampleAttemptID = lease.sourceSampleAttemptID,
      TatwoPressureText.isSafeIdentifier(sourceSampleAttemptID)
    else {
      return scopeRejected(
        reasonCode: "pressure_lease_source_binding_missing",
        reason: "accepted pressure admission requires source snapshot sequence and sample attempt bindings")
    }
    return nil
  }

  private static func acceptedDecision(
    deviceID: String,
    loopID: String,
    workload: TatwoPressureWorkerClassV1,
    decidedAt: Date,
    classification: TatwoPressureClassificationV1,
    authorizesSpawn: Bool,
    reasonCode: String,
    reason: String,
    leaseID: String?,
    requestBindingDigest: String? = nil,
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64? = nil,
    admissionAttemptID: String? = nil,
    dispatchNonce: String? = nil,
    reservationID: String? = nil,
    sourceSnapshotSequence: UInt64? = nil,
    sourceSampleAttemptID: String? = nil,
    leaseDigest: String? = nil
  ) -> TatwoLoopAdmissionDecisionV1 {
    TatwoLoopAdmissionDecisionV1(
      deviceID: deviceID,
      loopID: loopID,
      workload: workload,
      decidedAt: decidedAt,
      classification: classification,
      accepted: true,
      authorizesSpawn: authorizesSpawn,
      reasonCode: reasonCode,
      reason: reason,
      stopAction: .none,
      leaseID: leaseID,
      requestBindingDigest: requestBindingDigest,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: admissionAttemptID,
      dispatchNonce: dispatchNonce,
      reservationID: reservationID,
      sourceSnapshotSequence: sourceSnapshotSequence,
      sourceSampleAttemptID: sourceSampleAttemptID,
      leaseDigest: leaseDigest)
  }

  private static func rejected(
    deviceID: String,
    loopID: String,
    workload: TatwoPressureWorkerClassV1,
    decidedAt: Date,
    classification: TatwoPressureClassificationV1,
    reasonCode: String,
    reason: String,
    stopAction: TatwoLoopAdmissionStopActionV1,
    targetWorkerID: String? = nil,
    leaseID: String?,
    requestBindingDigest: String? = nil,
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64? = nil,
    admissionAttemptID: String? = nil,
    dispatchNonce: String? = nil,
    reservationID: String? = nil,
    sourceSnapshotSequence: UInt64? = nil,
    sourceSampleAttemptID: String? = nil,
    leaseDigest: String? = nil
  ) -> TatwoLoopAdmissionDecisionV1 {
    TatwoLoopAdmissionDecisionV1(
      deviceID: deviceID,
      loopID: loopID,
      workload: workload,
      decidedAt: decidedAt,
      classification: classification,
      accepted: false,
      reasonCode: reasonCode,
      reason: reason,
      stopAction: stopAction,
      targetWorkerID: targetWorkerID,
      leaseID: leaseID,
      requestBindingDigest: requestBindingDigest,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: admissionAttemptID,
      dispatchNonce: dispatchNonce,
      reservationID: reservationID,
      sourceSnapshotSequence: sourceSnapshotSequence,
      sourceSampleAttemptID: sourceSampleAttemptID,
      leaseDigest: leaseDigest)
  }
}

public enum TatwoPressureReceiptError: Error, LocalizedError, Sendable, Equatable {
  case invalidSchema(String)
  case leaseSnapshotMismatch
  case leaseDeviceMismatch
  case leaseClassificationMismatch
  case decisionLeaseMismatch
  case decisionDeviceMismatch
  case classificationMismatch
  case decisionClassificationMismatch
  case decisionRequestBindingDigestMismatch
  case admissionRequestBindingMismatch
  case previousDigestMismatch
  case receiptIDMismatch

  public var errorDescription: String? {
    switch self {
    case .invalidSchema(let schema):
      return "pressure receipt schema invalid: \(schema)"
    case .leaseSnapshotMismatch:
      return "pressure lease snapshot digest does not match receipt snapshot"
    case .leaseDeviceMismatch:
      return "pressure lease device does not match receipt snapshot"
    case .leaseClassificationMismatch:
      return "pressure lease classification does not match receipt snapshot"
    case .decisionLeaseMismatch:
      return "pressure admission decision lease does not match receipt lease"
    case .decisionDeviceMismatch:
      return "pressure admission decision device does not match receipt snapshot"
    case .classificationMismatch:
      return "pressure receipt classification does not match snapshot"
    case .decisionClassificationMismatch:
      return "pressure admission decision classification is not legal for the receipt evidence"
    case .decisionRequestBindingDigestMismatch:
      return "pressure admission decision request binding digest is missing or invalid"
    case .admissionRequestBindingMismatch:
      return "pressure admission request binding does not match canonical request bytes or decision"
    case .previousDigestMismatch:
      return "pressure receipt previous digest mismatch"
    case .receiptIDMismatch:
      return "pressure receipt id does not match receipt evidence"
    }
  }
}

public struct TatwoHostPressureReceiptV1: Codable, Sendable, Equatable {
  public let schema: String
  public let receiptID: String
  public let deviceID: String
  /// Actual sensor observation time.
  public let observedAt: Date
  /// Receipt construction time.
  public let recordedAt: Date
  public let snapshot: TatwoDevicePressureSnapshotV1
  public let classification: TatwoPressureClassificationResultV1
  public let lease: TatwoPressureLeaseV1?
  public let admissionDecision: TatwoLoopAdmissionDecisionV1?
  public let admissionRequestBinding: TatwoLoopAdmissionRequestBindingV1?
  public let previousReceiptDigest: String?
  public private(set) var receiptDigest: String?

  public init(
    schema: String = "TatwoHostPressureReceiptV1",
    receiptID: String,
    deviceID: String,
    observedAt: Date,
    recordedAt: Date,
    snapshot: TatwoDevicePressureSnapshotV1,
    classification: TatwoPressureClassificationResultV1,
    lease: TatwoPressureLeaseV1?,
    admissionDecision: TatwoLoopAdmissionDecisionV1?,
    admissionRequestBinding: TatwoLoopAdmissionRequestBindingV1? = nil,
    previousReceiptDigest: String?,
    receiptDigest: String? = nil
  ) {
    self.schema = schema
    self.receiptID = TatwoPressureText.safeSHA256Digest(receiptID, fallback: "invalid-receipt-id")
    self.deviceID = TatwoPressureText.safeReceiptIdentifier(deviceID, fallback: "invalid-device-id")
    self.observedAt = observedAt
    self.recordedAt = recordedAt
    self.snapshot = snapshot
    self.classification = classification
    self.lease = lease
    self.admissionDecision = admissionDecision
    self.admissionRequestBinding = admissionRequestBinding
    self.previousReceiptDigest = previousReceiptDigest.map {
      TatwoPressureText.safeSHA256Digest($0, fallback: "invalid-previous-receipt-digest")
    }
    self.receiptDigest = receiptDigest.map {
      TatwoPressureText.safeSHA256Digest($0, fallback: "invalid-receipt-digest")
    }
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decode(String.self, forKey: .schema),
      receiptID: try values.decode(String.self, forKey: .receiptID),
      deviceID: try values.decode(String.self, forKey: .deviceID),
      observedAt: try values.decode(Date.self, forKey: .observedAt),
      recordedAt: try values.decode(Date.self, forKey: .recordedAt),
      snapshot: try values.decode(TatwoDevicePressureSnapshotV1.self, forKey: .snapshot),
      classification: try values.decode(TatwoPressureClassificationResultV1.self, forKey: .classification),
      lease: try values.decodeIfPresent(TatwoPressureLeaseV1.self, forKey: .lease),
      admissionDecision: try values.decodeIfPresent(
        TatwoLoopAdmissionDecisionV1.self,
        forKey: .admissionDecision),
      admissionRequestBinding: try values.decodeIfPresent(
        TatwoLoopAdmissionRequestBindingV1.self,
        forKey: .admissionRequestBinding),
      previousReceiptDigest: try values.decodeIfPresent(String.self, forKey: .previousReceiptDigest),
      receiptDigest: try values.decodeIfPresent(String.self, forKey: .receiptDigest))
  }

  public static func make(
    snapshot: TatwoDevicePressureSnapshotV1,
    now: Date,
    lease: TatwoPressureLeaseV1? = nil,
    admissionDecision: TatwoLoopAdmissionDecisionV1? = nil,
    admissionRequestBinding: TatwoLoopAdmissionRequestBindingV1? = nil,
    previousReceiptDigest: String? = nil
  ) throws -> TatwoHostPressureReceiptV1 {
    let classification = snapshot.classify(now: now)
    let snapshotDigest = try snapshot.canonicalDigest()
    let seed = "\(snapshot.deviceID)|\(snapshotDigest)|\(now.timeIntervalSince1970)|\(previousReceiptDigest ?? "root")"
    let receiptID = TatwoLoopJobDigest.sha256(Data(seed.utf8))
    try validateInternalConsistency(
      snapshot: snapshot,
      snapshotDigest: snapshotDigest,
      classification: classification,
      receiptID: receiptID,
      receiptDeviceID: snapshot.deviceID,
      receiptObservedAt: snapshot.observedAt,
      previousReceiptDigest: previousReceiptDigest,
      recordedAt: now,
      lease: lease,
      admissionDecision: admissionDecision,
      admissionRequestBinding: admissionRequestBinding)
    var receipt = TatwoHostPressureReceiptV1(
      receiptID: receiptID,
      deviceID: snapshot.deviceID,
      observedAt: snapshot.observedAt,
      recordedAt: now,
      snapshot: snapshot,
      classification: classification,
      lease: lease,
      admissionDecision: admissionDecision,
      admissionRequestBinding: admissionRequestBinding,
      previousReceiptDigest: previousReceiptDigest)
    receipt.receiptDigest = try receipt.canonicalDigest()
    return receipt
  }

  public func canonicalDigest() throws -> String {
    var copy = self
    copy.receiptDigest = nil
    return try TatwoPressureDigest.canonicalJSONDigest(copy)
  }

  public func verifiesDigest() -> Bool {
    guard schema == "TatwoHostPressureReceiptV1",
      snapshot.schema == "TatwoDevicePressureSnapshotV1",
      let receiptDigest,
      (try? Self.validateInternalConsistency(
        snapshot: snapshot,
        snapshotDigest: snapshot.canonicalDigest(),
        classification: classification,
        receiptID: receiptID,
        receiptDeviceID: deviceID,
        receiptObservedAt: observedAt,
        previousReceiptDigest: previousReceiptDigest,
        recordedAt: recordedAt,
        lease: lease,
        admissionDecision: admissionDecision,
        admissionRequestBinding: admissionRequestBinding)) != nil
    else {
      return false
    }
    return (try? canonicalDigest()) == receiptDigest
  }

  public func verifiesChain(previous: TatwoHostPressureReceiptV1?) -> Bool {
    guard verifiesDigest() else { return false }
    switch (previous, previousReceiptDigest) {
    case (nil, nil):
      return true
    case let (previous?, digest?):
      return previous.verifiesDigest()
        && previous.receiptDigest == digest
        && previous.deviceID == deviceID
        && previous.recordedAt <= recordedAt
    default:
      return false
    }
  }

  private static func validateInternalConsistency(
    snapshot: TatwoDevicePressureSnapshotV1,
    snapshotDigest: String,
    classification: TatwoPressureClassificationResultV1,
    receiptID: String,
    receiptDeviceID: String,
    receiptObservedAt: Date,
    previousReceiptDigest: String?,
    recordedAt: Date,
    lease: TatwoPressureLeaseV1?,
    admissionDecision: TatwoLoopAdmissionDecisionV1?,
    admissionRequestBinding: TatwoLoopAdmissionRequestBindingV1?
  ) throws {
    guard snapshot.schema == "TatwoDevicePressureSnapshotV1" else {
      throw TatwoPressureReceiptError.invalidSchema(snapshot.schema)
    }
    guard classification.schema == "TatwoPressureClassificationResultV1" else {
      throw TatwoPressureReceiptError.invalidSchema(classification.schema)
    }
    let expectedClassification = snapshot.classify(now: recordedAt)
    guard classification == expectedClassification else {
      throw TatwoPressureReceiptError.classificationMismatch
    }
    guard TatwoPressureText.isSHA256Digest(receiptID) else {
      throw TatwoPressureReceiptError.receiptIDMismatch
    }
    guard receiptDeviceID == snapshot.deviceID,
      receiptObservedAt == snapshot.observedAt
    else {
      throw TatwoPressureReceiptError.leaseDeviceMismatch
    }
    if let previousReceiptDigest,
      !TatwoPressureText.isSHA256Digest(previousReceiptDigest)
    {
      throw TatwoPressureReceiptError.previousDigestMismatch
    }
    let expectedReceiptSeed = "\(snapshot.deviceID)|\(snapshotDigest)|\(recordedAt.timeIntervalSince1970)|\(previousReceiptDigest ?? "root")"
    guard receiptID == TatwoLoopJobDigest.sha256(Data(expectedReceiptSeed.utf8)) else {
      throw TatwoPressureReceiptError.receiptIDMismatch
    }
    if let lease {
      guard lease.schema == "TatwoPressureLeaseV1" else {
        throw TatwoPressureReceiptError.invalidSchema(lease.schema)
      }
      guard lease.verifiesDigest() else {
        throw TatwoPressureReceiptError.decisionLeaseMismatch
      }
      guard lease.deviceID == snapshot.deviceID else {
        throw TatwoPressureReceiptError.leaseDeviceMismatch
      }
      guard lease.snapshotDigest == snapshotDigest,
        lease.snapshotObservedAt == snapshot.observedAt
      else {
        throw TatwoPressureReceiptError.leaseSnapshotMismatch
      }
      let expectedLeaseClassification = snapshot.classify(now: lease.issuedAt)
      guard lease.classification == expectedLeaseClassification.classification,
        lease.reasonCodes == expectedLeaseClassification.reasonCodes
      else {
        throw TatwoPressureReceiptError.leaseClassificationMismatch
      }
    }
    if let decision = admissionDecision {
      guard decision.schema == "TatwoLoopAdmissionDecisionV1" else {
        throw TatwoPressureReceiptError.invalidSchema(decision.schema)
      }
      if let requestBindingDigest = decision.requestBindingDigest {
        guard TatwoPressureText.isSHA256Digest(requestBindingDigest) else {
          throw TatwoPressureReceiptError.decisionRequestBindingDigestMismatch
        }
        if let admissionRequestBinding {
          guard admissionRequestBinding.verifiesRequest(),
            admissionRequestBinding.requestBindingDigest == requestBindingDigest,
            admissionRequestBinding.request.deviceID == decision.deviceID,
            admissionRequestBinding.request.loopID == decision.loopID,
            admissionRequestBinding.request.workload == decision.workload,
            admissionRequestBinding.request.dispatchNonce == decision.dispatchNonce,
            admissionRequestBinding.request.pressurePolicyVersion == decision.pressurePolicyVersion
          else {
            throw TatwoPressureReceiptError.admissionRequestBindingMismatch
          }
        } else if decision.accepted {
          throw TatwoPressureReceiptError.admissionRequestBindingMismatch
        }
      } else if decision.accepted {
        throw TatwoPressureReceiptError.decisionRequestBindingDigestMismatch
      }
      guard decision.deviceID == snapshot.deviceID else {
        throw TatwoPressureReceiptError.decisionDeviceMismatch
      }
      if decision.authorizesSpawn && !decision.accepted {
        throw TatwoPressureReceiptError.decisionClassificationMismatch
      }
      if decision.accepted && (decision.classification == .unknown || decision.classification == .red) {
        throw TatwoPressureReceiptError.decisionClassificationMismatch
      }
      if decision.accepted && decision.classification != classification.classification {
        throw TatwoPressureReceiptError.decisionClassificationMismatch
      }
      if decision.accepted && decision.classification == .yellow && decision.workload == .heavy {
        throw TatwoPressureReceiptError.decisionClassificationMismatch
      }
      if decision.accepted && decision.stopAction != .none {
        throw TatwoPressureReceiptError.decisionClassificationMismatch
      }
      if let lease {
        guard decision.leaseID == lease.leaseID else {
          throw TatwoPressureReceiptError.decisionLeaseMismatch
        }
        guard decision.leaseDigest == lease.leaseDigest else {
          throw TatwoPressureReceiptError.decisionLeaseMismatch
        }
        if decision.accepted {
          guard let requestBindingDigest = decision.requestBindingDigest,
            let leaseRequestBindingDigest = lease.admissionRequestBindingDigest,
            leaseRequestBindingDigest == requestBindingDigest
          else {
            throw TatwoPressureReceiptError.decisionLeaseMismatch
          }
          guard let dispatchNonce = decision.dispatchNonce,
            let leaseDispatchNonce = lease.dispatchNonce,
            leaseDispatchNonce == dispatchNonce
          else {
            throw TatwoPressureReceiptError.decisionLeaseMismatch
          }
          guard let reservationID = decision.reservationID,
            TatwoPressureText.isSHA256Digest(reservationID),
            let leaseReservationID = lease.reservationID,
            leaseReservationID == reservationID,
            let runtimeInstanceID = decision.runtimeInstanceID,
            TatwoPressureText.isValidRuntimeInstanceID(runtimeInstanceID),
            let leaseRuntimeInstanceID = lease.runtimeInstanceID,
            TatwoPressureText.isValidRuntimeInstanceID(leaseRuntimeInstanceID),
            leaseRuntimeInstanceID == runtimeInstanceID,
            let runtimeGeneration = decision.runtimeGeneration,
            let leaseRuntimeGeneration = lease.runtimeGeneration,
            leaseRuntimeGeneration == runtimeGeneration,
            let admissionAttemptID = decision.admissionAttemptID,
            TatwoPressureText.isSafeIdentifier(admissionAttemptID),
            let leaseAdmissionAttemptID = lease.admissionAttemptID,
            leaseAdmissionAttemptID == admissionAttemptID,
            lease.sourceSnapshotSequence != nil,
            decision.sourceSnapshotSequence == lease.sourceSnapshotSequence,
            let sourceSampleAttemptID = decision.sourceSampleAttemptID,
            TatwoPressureText.isSafeIdentifier(sourceSampleAttemptID),
            sourceSampleAttemptID == lease.sourceSampleAttemptID
          else {
            throw TatwoPressureReceiptError.decisionLeaseMismatch
          }
          guard lease.freshness(now: decision.decidedAt) == .fresh,
            decision.decidedAt.timeIntervalSince(lease.snapshotObservedAt)
              <= TatwoDevicePressureSnapshotV1.defaultStaleAfterSeconds
          else {
            throw TatwoPressureReceiptError.decisionLeaseMismatch
          }
          guard decision.classification == lease.classification else {
            throw TatwoPressureReceiptError.decisionClassificationMismatch
          }
          switch decision.classification {
          case .green:
            guard decision.reasonCode == "pressure_green",
              decision.authorizesSpawn
            else {
              throw TatwoPressureReceiptError.decisionClassificationMismatch
            }
          case .yellow:
            guard decision.workload == .light,
              decision.reasonCode == "pressure_yellow_exact_attempt_continue",
              !decision.authorizesSpawn
            else {
              throw TatwoPressureReceiptError.decisionClassificationMismatch
            }
          case .red, .unknown:
            throw TatwoPressureReceiptError.decisionClassificationMismatch
          }
        }
        guard decision.classification == lease.classification || decision.classification == .unknown else {
          throw TatwoPressureReceiptError.decisionClassificationMismatch
        }
      } else if decision.leaseID != nil || decision.accepted {
        throw TatwoPressureReceiptError.decisionLeaseMismatch
      }
    }
  }
}

fileprivate enum TatwoPressureText {
  private static let allowedSensors: Set<String> = [
    "data_volume_free_gib",
    "load1_per_cpu",
    "memory_free_percent",
    "swap_free_mib",
    "swap_growth_mib_per_minute",
    "thermal_warning",
    "ui_latency_ms",
  ]

  static func unavailableSensorReasonCodes(_ values: [String]) -> [String] {
    normalizedReasonCodes(normalizedSensorNames(values).map { "sensor_unavailable:\($0)" })
  }

  static func unavailableSensorDiagnosticReasonCodes(
    _ values: [TatwoPressureSensorUnavailableV1]
  ) -> [String] {
    normalizedReasonCodes(
      normalizedUnavailableSensorDiagnostics(values).map {
        "sensor_unavailable_reason:\($0.sensor.rawValue):\($0.reasonCode)"
      })
  }

  static func normalizedSensorNames(_ values: [String]) -> [String] {
    Array(Set(values.prefix(16).map(normalizedSensorName))).sorted()
  }

  static func normalizedUnavailableSensorDiagnostics(
    _ values: [TatwoPressureSensorUnavailableV1]
  ) -> [TatwoPressureSensorUnavailableV1] {
    Array(Set(values.prefix(32).map { value in
      TatwoPressureSensorUnavailableV1(
        sensor: value.sensor,
        reasonCode: redactedReasonCode(value.reasonCode))
    })).sorted { lhs, rhs in
      if lhs.sensor.rawValue != rhs.sensor.rawValue {
        return lhs.sensor.rawValue < rhs.sensor.rawValue
      }
      return lhs.reasonCode < rhs.reasonCode
    }
  }

  static func normalizedReasonCodes(_ values: [String]) -> [String] {
    Array(Set(values.map(redactedReasonCode).filter { !$0.isEmpty })).sorted()
  }

  static func redacted(_ value: String) -> String {
    String(TatwoPrivacyRedactor.redacted(value).prefix(512))
  }

  static func safeReceiptIdentifier(_ value: String, fallback: String) -> String {
    isSafeIdentifier(value) ? value : fallback
  }

  static func safeSHA256Digest(_ value: String, fallback: String) -> String {
    isSHA256Digest(value) ? value : fallback
  }

  static func isSHA256Digest(_ value: String) -> Bool {
    let allowedHex = Set("0123456789abcdef")
    return value.hasPrefix("sha256:")
      && value.count == 71
      && value.dropFirst("sha256:".count).allSatisfy { character in
        allowedHex.contains(character)
      }
  }

  static func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && !value.contains("\0")
      && value.count <= 128
      && value.range(of: #"^[A-Za-z0-9._:\-]+$"#, options: .regularExpression) != nil
  }

  static func isValidRuntimeInstanceID(_ value: String) -> Bool {
    isSafeIdentifier(value) && value != "invalid-runtime-instance-id"
  }

  private static func normalizedSensorName(_ value: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "_")
      .replacingOccurrences(of: "-", with: "_")
    return allowedSensors.contains(normalized) ? normalized : "other"
  }

  private static func redactedReasonCode(_ value: String) -> String {
    let redacted = redacted(value)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "_")
    let allowed = redacted.filter { character in
      character.isLetter || character.isNumber || character == "_" || character == ":" || character == "."
    }
    return String(allowed.prefix(160))
  }
}

public enum TatwoPressureCanonicalJSONV1 {
  /// Stable pressure-wire Date representation. Foundation `.iso8601` drops
  /// fractional seconds, so pressure authority never uses it for signed/digested
  /// bytes. The decimal seconds string is deterministic and preserves
  /// sub-second observation/lease/receipt boundaries.
  public static func encodeDate(_ date: Date) -> String {
    let raw = date.timeIntervalSince1970
    guard raw.isFinite else { return "0" }
    let micros = Int64((raw * 1_000_000).rounded())
    let sign = micros < 0 ? "-" : ""
    let magnitude = micros < 0 ? -micros : micros
    let seconds = magnitude / 1_000_000
    let fraction = magnitude % 1_000_000
    if fraction == 0 {
      return "\(sign)\(seconds)"
    }
    var fractionText = String(format: "%06lld", fraction)
    while fractionText.last == "0" { fractionText.removeLast() }
    return "\(sign)\(seconds).\(fractionText)"
  }

  public static func decodeDate(_ value: String) throws -> Date {
    guard let seconds = TimeInterval(value), seconds.isFinite else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: [],
          debugDescription: "invalid TatwoPressureCanonicalJSONV1 date: \(value)"))
    }
    return Date(timeIntervalSince1970: seconds)
  }

  public static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(encodeDate(date))
    }
    encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      if let string = try? container.decode(String.self) {
        return try decodeDate(string)
      }
      let seconds = try container.decode(Double.self)
      guard seconds.isFinite else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "invalid TatwoPressureCanonicalJSONV1 numeric date")
      }
      return Date(timeIntervalSince1970: seconds)
    }
    return decoder
  }

  public static func data<T: Encodable>(_ value: T) throws -> Data {
    try encoder().encode(value)
  }

  public static func digest<T: Encodable>(_ value: T) throws -> String {
    try TatwoLoopJobDigest.sha256(data(value))
  }
}

fileprivate enum TatwoPressureDigest {
  static func canonicalJSONData<T: Encodable>(_ value: T) throws -> Data {
    try TatwoPressureCanonicalJSONV1.data(value)
  }

  static func canonicalJSONDigest<T: Encodable>(_ value: T) throws -> String {
    try TatwoPressureCanonicalJSONV1.digest(value)
  }
}
