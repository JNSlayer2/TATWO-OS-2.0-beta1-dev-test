import Foundation

public enum TatwoPressureSensorNameV1: String, Codable, Sendable, Equatable, CaseIterable {
  case memoryFreePercent = "memory_free_percent"
  case swapFreeMiB = "swap_free_mib"
  case dataVolumeFreeGiB = "data_volume_free_gib"
  case load1PerCPU = "load1_per_cpu"
  case thermalWarning = "thermal_warning"
  case uiLatencyMilliseconds = "ui_latency_ms"
  case swapGrowthMiBPerMinute = "swap_growth_mib_per_minute"
}

public struct TatwoPressureSensorUnavailableV1: Codable, Sendable, Equatable, Hashable {
  public let schema: String
  public let sensor: TatwoPressureSensorNameV1
  public let reasonCode: String

  public init(
    schema: String = "TatwoPressureSensorUnavailableV1",
    sensor: TatwoPressureSensorNameV1,
    reasonCode: String
  ) {
    self.schema = schema
    self.sensor = sensor
    self.reasonCode = TatwoPressureServiceText.safeReasonCode(reasonCode, fallback: "sensor_unavailable")
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decodeIfPresent(String.self, forKey: .schema)
        ?? "TatwoPressureSensorUnavailableV1",
      sensor: try values.decode(TatwoPressureSensorNameV1.self, forKey: .sensor),
      reasonCode: try values.decode(String.self, forKey: .reasonCode))
  }
}

public struct TatwoDevicePressureSensorReadingsV1: Codable, Sendable, Equatable {
  public let schema: String
  public let memoryFreePercent: Double?
  public let swapFreeMiB: Double?
  public let dataVolumeFreeGiB: Double?
  public let load1PerCPU: Double?
  public let thermalWarning: Bool?
  public let uiLatencyMilliseconds: Double?
  public let swapGrowthMiBPerMinute: Double?
  public let unavailableSensors: [TatwoPressureSensorUnavailableV1]
  public let hostInventory: TatwoDeviceHostInventoryV1?

  public init(
    schema: String = "TatwoDevicePressureSensorReadingsV1",
    memoryFreePercent: Double?,
    swapFreeMiB: Double?,
    dataVolumeFreeGiB: Double?,
    load1PerCPU: Double?,
    thermalWarning: Bool?,
    uiLatencyMilliseconds: Double?,
    swapGrowthMiBPerMinute: Double?,
    unavailableSensors: [TatwoPressureSensorUnavailableV1] = [],
    hostInventory: TatwoDeviceHostInventoryV1? = nil
  ) {
    self.schema = schema
    self.memoryFreePercent = memoryFreePercent
    self.swapFreeMiB = swapFreeMiB
    self.dataVolumeFreeGiB = dataVolumeFreeGiB
    self.load1PerCPU = load1PerCPU
    self.thermalWarning = thermalWarning
    self.uiLatencyMilliseconds = uiLatencyMilliseconds
    self.swapGrowthMiBPerMinute = swapGrowthMiBPerMinute
    self.unavailableSensors = Array(Set(unavailableSensors)).sorted { lhs, rhs in
      if lhs.sensor.rawValue != rhs.sensor.rawValue { return lhs.sensor.rawValue < rhs.sensor.rawValue }
      return lhs.reasonCode < rhs.reasonCode
    }
    self.hostInventory = hostInventory?.isEmpty == true ? nil : hostInventory
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decodeIfPresent(String.self, forKey: .schema)
        ?? "TatwoDevicePressureSensorReadingsV1",
      memoryFreePercent: try values.decodeIfPresent(Double.self, forKey: .memoryFreePercent),
      swapFreeMiB: try values.decodeIfPresent(Double.self, forKey: .swapFreeMiB),
      dataVolumeFreeGiB: try values.decodeIfPresent(Double.self, forKey: .dataVolumeFreeGiB),
      load1PerCPU: try values.decodeIfPresent(Double.self, forKey: .load1PerCPU),
      thermalWarning: try values.decodeIfPresent(Bool.self, forKey: .thermalWarning),
      uiLatencyMilliseconds: try values.decodeIfPresent(Double.self, forKey: .uiLatencyMilliseconds),
      swapGrowthMiBPerMinute: try values.decodeIfPresent(Double.self, forKey: .swapGrowthMiBPerMinute),
      unavailableSensors: try values.decodeIfPresent(
        [TatwoPressureSensorUnavailableV1].self,
        forKey: .unavailableSensors) ?? [],
      hostInventory: try values.decodeIfPresent(
        TatwoDeviceHostInventoryV1.self,
        forKey: .hostInventory))
  }

  public func snapshot(
    deviceID: String,
    observedAt: Date,
    activeLoopID: String?,
    workers: [TatwoPressureWorkerV1],
    sourceSnapshotSequence: UInt64? = nil,
    sourceSampleAttemptID: String? = nil
  ) -> TatwoDevicePressureSnapshotV1 {
    let inventory = hostInventory.map { existing in
      TatwoDeviceHostInventoryV1(
        schema: existing.schema,
        hardwareModel: existing.hardwareModel,
        chipName: existing.chipName,
        ramTotalBytes: existing.ramTotalBytes,
        cpuPercent: existing.cpuPercent,
        memoryPressureLevel: existing.memoryPressureLevel,
        connectionStatus: existing.connectionStatus,
        activeLoopCount: existing.activeLoopCount
          ?? TatwoDeviceHostInventoryV1.activeLoopCount(
            workers: workers,
            activeLoopID: activeLoopID))
    }
    return TatwoDevicePressureSnapshotV1(
      pressurePolicyVersion: TatwoPressurePolicyVersionV1.current,
      deviceID: deviceID,
      observedAt: observedAt,
      sourceSnapshotSequence: sourceSnapshotSequence,
      sourceSampleAttemptID: sourceSampleAttemptID,
      memoryFreePercent: memoryFreePercent,
      swapFreeMiB: swapFreeMiB,
      dataVolumeFreeGiB: dataVolumeFreeGiB,
      load1PerCPU: load1PerCPU,
      thermalWarning: thermalWarning,
      uiLatencyMilliseconds: uiLatencyMilliseconds,
      swapGrowthMiBPerMinute: swapGrowthMiBPerMinute,
      unavailableSensors: unavailableSensors.map(\.sensor.rawValue),
      unavailableSensorDiagnostics: unavailableSensors,
      activeLoopID: activeLoopID,
      workers: workers,
      hostInventory: inventory)
  }

  public static func unavailable(
    _ reasonCode: String = "sensor_unavailable"
  ) -> TatwoDevicePressureSensorReadingsV1 {
    TatwoDevicePressureSensorReadingsV1(
      memoryFreePercent: nil,
      swapFreeMiB: nil,
      dataVolumeFreeGiB: nil,
      load1PerCPU: nil,
      thermalWarning: nil,
      uiLatencyMilliseconds: nil,
      swapGrowthMiBPerMinute: nil,
      unavailableSensors: TatwoPressureSensorNameV1.allCases.map {
        TatwoPressureSensorUnavailableV1(sensor: $0, reasonCode: reasonCode)
      })
  }
}

public enum TatwoPressureSamplingReasonV1: String, Codable, Sendable, Equatable {
  case appLaunch
  case idleCadence
  case activeLoopCadence
  case leaseTick
  case preAdmissionImmediate
  case preSpawnRecheck
  case summaryReceipt
  case manual
}

public enum TatwoPressureMonitoringModeV1: String, Codable, Sendable, Equatable {
  case idle
  case activeLoop
  case stopped
}

public struct TatwoPressureSamplingContextV1: Codable, Sendable, Equatable {
  public let schema: String
  public let deviceID: String
  public let observedAt: Date
  public let reason: TatwoPressureSamplingReasonV1
  public let activeLoopID: String?
  public let workers: [TatwoPressureWorkerV1]

  public init(
    schema: String = "TatwoPressureSamplingContextV1",
    deviceID: String,
    observedAt: Date,
    reason: TatwoPressureSamplingReasonV1,
    activeLoopID: String?,
    workers: [TatwoPressureWorkerV1]
  ) {
    self.schema = schema
    self.deviceID = TatwoPressureServiceText.safeIdentifier(deviceID, fallback: "invalid-device-id")
    self.observedAt = observedAt
    self.reason = reason
    self.activeLoopID = activeLoopID.map {
      TatwoPressureServiceText.safeIdentifier($0, fallback: "invalid-loop-id")
    }
    self.workers = workers
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decodeIfPresent(String.self, forKey: .schema)
        ?? "TatwoPressureSamplingContextV1",
      deviceID: try values.decode(String.self, forKey: .deviceID),
      observedAt: try values.decode(Date.self, forKey: .observedAt),
      reason: try values.decode(TatwoPressureSamplingReasonV1.self, forKey: .reason),
      activeLoopID: try values.decodeIfPresent(String.self, forKey: .activeLoopID),
      workers: try values.decodeIfPresent([TatwoPressureWorkerV1].self, forKey: .workers) ?? [])
  }
}

public struct TatwoPressureClockV1: Sendable {
  private let nowHandler: @Sendable () -> Date

  public init(now: @escaping @Sendable () -> Date = Date.init) {
    self.nowHandler = now
  }

  public func now() -> Date {
    nowHandler()
  }
}

/// Injected sensor source owned by the App pressure sampler.
///
/// Real providers must avoid broad process mutation and should check
/// `Task.isCancelled` between slow sysctl/IOKit/filesystem probes. The sampler
/// still fail-closes stale results with an epoch guard when a provider ignores
/// cancellation.
public struct TatwoDevicePressureSensorProviderV1: Sendable {
  private let sampleHandler: @Sendable (TatwoPressureSamplingContextV1) async -> TatwoDevicePressureSensorReadingsV1

  public init(
    sample: @escaping @Sendable (TatwoPressureSamplingContextV1) async -> TatwoDevicePressureSensorReadingsV1
  ) {
    self.sampleHandler = sample
  }

  public func sample(
    context: TatwoPressureSamplingContextV1
  ) async -> TatwoDevicePressureSensorReadingsV1 {
    await sampleHandler(context)
  }
}

public struct TatwoAppPressureSamplerConfigurationV1: Codable, Sendable, Equatable {
  public let schema: String
  public let idleCadenceSeconds: TimeInterval
  public let activeLoopCadenceSeconds: TimeInterval
  public let leaseCadenceSeconds: TimeInterval
  public let receiptSummaryCadenceSeconds: TimeInterval
  public let maximumSnapshotAgeForLeaseSeconds: TimeInterval

  public init(
    schema: String = "TatwoAppPressureSamplerConfigurationV1",
    idleCadenceSeconds: TimeInterval = 60,
    activeLoopCadenceSeconds: TimeInterval = 5,
    leaseCadenceSeconds: TimeInterval = 5,
    receiptSummaryCadenceSeconds: TimeInterval = 120,
    maximumSnapshotAgeForLeaseSeconds: TimeInterval = TatwoPressureLeaseV1.defaultRunnerMaxAgeSeconds
  ) {
    self.schema = schema
    self.idleCadenceSeconds = Self.clampedCadence(
      idleCadenceSeconds,
      defaultValue: 60,
      maximum: 60)
    self.activeLoopCadenceSeconds = Self.clampedCadence(
      activeLoopCadenceSeconds,
      defaultValue: 5,
      maximum: 5)
    self.leaseCadenceSeconds = Self.clampedCadence(
      leaseCadenceSeconds,
      defaultValue: 5,
      maximum: 5)
    self.receiptSummaryCadenceSeconds = Self.clampedCadence(
      receiptSummaryCadenceSeconds,
      defaultValue: 120,
      maximum: 120)
    self.maximumSnapshotAgeForLeaseSeconds = Self.clampedSnapshotAgeForLease(
      maximumSnapshotAgeForLeaseSeconds)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decodeIfPresent(String.self, forKey: .schema)
        ?? "TatwoAppPressureSamplerConfigurationV1",
      idleCadenceSeconds: try values.decodeIfPresent(TimeInterval.self, forKey: .idleCadenceSeconds)
        ?? 60,
      activeLoopCadenceSeconds: try values.decodeIfPresent(
        TimeInterval.self,
        forKey: .activeLoopCadenceSeconds) ?? 5,
      leaseCadenceSeconds: try values.decodeIfPresent(TimeInterval.self, forKey: .leaseCadenceSeconds)
        ?? 5,
      receiptSummaryCadenceSeconds: try values.decodeIfPresent(
        TimeInterval.self,
        forKey: .receiptSummaryCadenceSeconds) ?? 120,
      maximumSnapshotAgeForLeaseSeconds: try values.decodeIfPresent(
        TimeInterval.self,
        forKey: .maximumSnapshotAgeForLeaseSeconds)
        ?? TatwoPressureLeaseV1.defaultRunnerMaxAgeSeconds)
  }

  private static func clampedCadence(
    _ value: TimeInterval,
    defaultValue: TimeInterval,
    maximum: TimeInterval
  ) -> TimeInterval {
    guard value.isFinite, value > 0 else { return defaultValue }
    return min(value, maximum)
  }

  private static func clampedSnapshotAgeForLease(_ value: TimeInterval) -> TimeInterval {
    guard value.isFinite else { return TatwoPressureLeaseV1.defaultRunnerMaxAgeSeconds }
    return min(max(0, value), TatwoPressureLeaseV1.defaultRunnerMaxAgeSeconds)
  }

  public func cadenceSeconds(for mode: TatwoPressureMonitoringModeV1) -> TimeInterval? {
    switch mode {
    case .idle:
      return idleCadenceSeconds
    case .activeLoop:
      return activeLoopCadenceSeconds
    case .stopped:
      return nil
    }
  }
}

public actor TatwoAppPressureSamplerV1 {
  public let deviceID: String
  public let configuration: TatwoAppPressureSamplerConfigurationV1

  private struct InFlightSample: Sendable {
    let epoch: UInt64
    let sequence: UInt64
    let sampleAttemptID: String
    let reason: TatwoPressureSamplingReasonV1
    let task: Task<TatwoDevicePressureSnapshotV1, Never>
  }

  private let provider: TatwoDevicePressureSensorProviderV1
  private let clock: TatwoPressureClockV1
  private var isRunning = false
  private var activeLoopID: String?
  private var workers: [TatwoPressureWorkerV1] = []
  private var latestSnapshot: TatwoDevicePressureSnapshotV1?
  private var inFlight: InFlightSample?
  private var monitorEpoch: UInt64 = 0
  private var sampleSequence: UInt64 = 0
  private var lifecycleIntentGeneration: UInt64 = 0

  public init(
    deviceID: String,
    provider: TatwoDevicePressureSensorProviderV1,
    clock: TatwoPressureClockV1 = TatwoPressureClockV1(),
    configuration: TatwoAppPressureSamplerConfigurationV1 = TatwoAppPressureSamplerConfigurationV1()
  ) {
    self.deviceID = TatwoPressureServiceText.safeIdentifier(deviceID, fallback: "invalid-device-id")
    self.provider = provider
    self.clock = clock
    self.configuration = configuration
  }

  @discardableResult
  public func startMonitoring(intentGeneration: UInt64? = nil) -> Bool {
    let intent = normalizedLifecycleIntent(intentGeneration)
    guard intent >= lifecycleIntentGeneration else { return false }
    lifecycleIntentGeneration = intent
    guard !isRunning else { return true }
    monitorEpoch &+= 1
    isRunning = true
    return true
  }

  @discardableResult
  public func stopMonitoring(intentGeneration: UInt64? = nil) -> Bool {
    let intent = normalizedLifecycleIntent(intentGeneration)
    guard intent >= lifecycleIntentGeneration else { return false }
    lifecycleIntentGeneration = intent
    guard isRunning else {
      inFlight?.task.cancel()
      inFlight = nil
      latestSnapshot = nil
      return true
    }
    monitorEpoch &+= 1
    isRunning = false
    inFlight?.task.cancel()
    inFlight = nil
    latestSnapshot = nil
    return true
  }

  public func setActiveLoop(
    loopID: String?,
    workers: [TatwoPressureWorkerV1] = []
  ) {
    activeLoopID = loopID.map {
      TatwoPressureServiceText.safeIdentifier($0, fallback: "invalid-loop-id")
    }
    self.workers = workers
  }

  public func mode() -> TatwoPressureMonitoringModeV1 {
    guard isRunning else { return .stopped }
    return activeLoopID == nil ? .idle : .activeLoop
  }

  public func nextCadenceSeconds() -> TimeInterval? {
    configuration.cadenceSeconds(for: mode())
  }

  public func currentWorkers() -> [TatwoPressureWorkerV1] {
    workers
  }

  public func latest() -> TatwoDevicePressureSnapshotV1? {
    guard isRunning else { return nil }
    return latestSnapshot
  }

  public func sampleNow(
    reason: TatwoPressureSamplingReasonV1
  ) async -> TatwoDevicePressureSnapshotV1 {
    while true {
      guard isRunning else {
        return stoppedSnapshot()
      }

      if let current = inFlight {
        let snapshot = await current.task.value
        guard isRunning, monitorEpoch == current.epoch else {
          return stoppedSnapshot()
        }
        let completed = finishSampleIfCurrent(current, snapshot: snapshot)
        if Self.requiresDedicatedSample(reason) {
          continue
        }
        return completed
      }

      let observedAt = clock.now()
      let epoch = monitorEpoch
      sampleSequence &+= 1
      let sequence = sampleSequence
      let sampleAttemptID = "sample-\(epoch)-\(sequence)"
      let context = TatwoPressureSamplingContextV1(
        deviceID: deviceID,
        observedAt: observedAt,
        reason: reason,
        activeLoopID: activeLoopID,
        workers: workers)
      let task = Task { [provider] in
        let readings = await provider.sample(context: context)
        return readings.snapshot(
          deviceID: context.deviceID,
          observedAt: context.observedAt,
          activeLoopID: context.activeLoopID,
          workers: context.workers,
          sourceSnapshotSequence: sequence,
          sourceSampleAttemptID: sampleAttemptID)
      }
      let current = InFlightSample(
        epoch: epoch,
        sequence: sequence,
        sampleAttemptID: sampleAttemptID,
        reason: reason,
        task: task)
      inFlight = current
      let snapshot = await task.value
      guard isRunning, monitorEpoch == epoch else {
        return stoppedSnapshot()
      }
      return finishSampleIfCurrent(current, snapshot: snapshot)
    }
  }

  private func finishSampleIfCurrent(
    _ sample: InFlightSample,
    snapshot: TatwoDevicePressureSnapshotV1
  ) -> TatwoDevicePressureSnapshotV1 {
    if inFlight?.epoch == sample.epoch, inFlight?.sequence == sample.sequence {
      inFlight = nil
    }
    if let latestSnapshot, latestSnapshot.observedAt > snapshot.observedAt {
      return latestSnapshot
    }
    latestSnapshot = snapshot
    return snapshot
  }

  private func normalizedLifecycleIntent(_ intentGeneration: UInt64?) -> UInt64 {
    guard let intentGeneration else { return lifecycleIntentGeneration &+ 1 }
    return intentGeneration
  }

  private func stoppedSnapshot() -> TatwoDevicePressureSnapshotV1 {
    Self.unknownSnapshot(
      deviceID: deviceID,
      observedAt: clock.now(),
      reasonCode: "sampler_stopped",
      activeLoopID: activeLoopID,
      workers: workers)
  }

  private static func requiresDedicatedSample(_ reason: TatwoPressureSamplingReasonV1) -> Bool {
    reason == .preAdmissionImmediate || reason == .preSpawnRecheck
  }

  private static func unknownSnapshot(
    deviceID: String,
    observedAt: Date,
    reasonCode: String,
    activeLoopID: String?,
    workers: [TatwoPressureWorkerV1]
  ) -> TatwoDevicePressureSnapshotV1 {
    TatwoDevicePressureSensorReadingsV1.unavailable(reasonCode).snapshot(
      deviceID: deviceID,
      observedAt: observedAt,
      activeLoopID: activeLoopID,
      workers: workers)
  }
}

public enum TatwoPressureLeaseRefreshPolicyV1: String, Codable, Sendable, Equatable {
  case sampleImmediately
  case latestOnly
}

public struct TatwoPressureUIProjectionV1: Codable, Sendable, Equatable {
  public let schema: String
  public let deviceID: String
  public let displayClassification: TatwoPressureClassificationV1
  public let lastObservedAt: Date?
  public let activeLoopID: String?
  public let workerIDs: [String]
  public let stopReason: String?
  public let canRequestLightLoop: Bool
  public let canRequestHeavyLoop: Bool
  public let hostInventory: TatwoDeviceHostInventoryV1?

  public init(
    schema: String = "TatwoPressureUIProjectionV1",
    deviceID: String,
    displayClassification: TatwoPressureClassificationV1,
    lastObservedAt: Date?,
    activeLoopID: String?,
    workerIDs: [String],
    stopReason: String?,
    canRequestLightLoop: Bool,
    canRequestHeavyLoop: Bool,
    hostInventory: TatwoDeviceHostInventoryV1? = nil
  ) {
    self.schema = schema
    self.deviceID = TatwoPressureServiceText.safeIdentifier(deviceID, fallback: "invalid-device-id")
    self.displayClassification = displayClassification
    self.lastObservedAt = lastObservedAt
    self.activeLoopID = activeLoopID.map {
      TatwoPressureServiceText.safeIdentifier($0, fallback: "invalid-loop-id")
    }
    self.workerIDs = workerIDs.map {
      TatwoPressureServiceText.safeIdentifier($0, fallback: "invalid-worker-id")
    }
    self.stopReason = stopReason.map {
      TatwoPressureServiceText.redacted($0)
    }
    self.canRequestLightLoop = canRequestLightLoop
    self.canRequestHeavyLoop = canRequestHeavyLoop
    self.hostInventory = hostInventory?.isEmpty == true ? nil : hostInventory
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decodeIfPresent(String.self, forKey: .schema)
        ?? "TatwoPressureUIProjectionV1",
      deviceID: try values.decode(String.self, forKey: .deviceID),
      displayClassification: try values.decode(
        TatwoPressureClassificationV1.self,
        forKey: .displayClassification),
      lastObservedAt: try values.decodeIfPresent(Date.self, forKey: .lastObservedAt),
      activeLoopID: try values.decodeIfPresent(String.self, forKey: .activeLoopID),
      workerIDs: try values.decodeIfPresent([String].self, forKey: .workerIDs) ?? [],
      stopReason: try values.decodeIfPresent(String.self, forKey: .stopReason),
      canRequestLightLoop: try values.decode(Bool.self, forKey: .canRequestLightLoop),
      canRequestHeavyLoop: try values.decode(Bool.self, forKey: .canRequestHeavyLoop),
      hostInventory: try values.decodeIfPresent(
        TatwoDeviceHostInventoryV1.self,
        forKey: .hostInventory))
  }
}

public struct TatwoLoopAdmissionRequestV1: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let pressurePolicyVersion: String
  public let jobID: String
  public let attemptID: String?
  public let dispatchNonce: String
  public let deviceID: String
  public let loopID: String
  public let workload: TatwoPressureWorkerClassV1
  public let contractID: String
  public let goalHash: String
  public let planHash: String
  public let requestedAt: Date

  public var id: String { jobID }

  public init(
    schema: String = "TatwoLoopAdmissionRequestV1",
    pressurePolicyVersion: String = TatwoPressurePolicyVersionV1.current,
    jobID: String,
    attemptID: String? = nil,
    dispatchNonce: String = "dispatch-\(UUID().uuidString.lowercased())",
    deviceID: String,
    loopID: String,
    workload: TatwoPressureWorkerClassV1,
    contractID: String,
    goalHash: String,
    planHash: String,
    requestedAt: Date
  ) {
    self.schema = schema
    self.pressurePolicyVersion = TatwoPressureServiceText.safeIdentifier(
      pressurePolicyVersion,
      fallback: "invalid-pressure-policy-version")
    self.jobID = TatwoPressureServiceText.safeIdentifier(jobID, fallback: "invalid-job-id")
    self.attemptID = attemptID.map {
      TatwoPressureServiceText.safeIdentifier($0, fallback: "invalid-attempt-id")
    }
    self.dispatchNonce = TatwoPressureServiceText.safeIdentifier(
      dispatchNonce,
      fallback: "invalid-dispatch-nonce")
    self.deviceID = TatwoPressureServiceText.safeIdentifier(deviceID, fallback: "invalid-device-id")
    self.loopID = TatwoPressureServiceText.safeIdentifier(loopID, fallback: "invalid-loop-id")
    self.workload = workload
    self.contractID = TatwoPressureServiceText.safeIdentifier(contractID, fallback: "invalid-contract-id")
    self.goalHash = TatwoPressureServiceText.safeIdentifierOrDigest(goalHash, fallback: "invalid-goal-hash")
    self.planHash = TatwoPressureServiceText.safeIdentifierOrDigest(planHash, fallback: "invalid-plan-hash")
    self.requestedAt = requestedAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decodeIfPresent(String.self, forKey: .schema)
        ?? "TatwoLoopAdmissionRequestV1",
      pressurePolicyVersion: try values.decodeIfPresent(String.self, forKey: .pressurePolicyVersion)
        ?? "invalid-pressure-policy-version",
      jobID: try values.decode(String.self, forKey: .jobID),
      attemptID: try values.decodeIfPresent(String.self, forKey: .attemptID),
      dispatchNonce: try values.decodeIfPresent(String.self, forKey: .dispatchNonce)
        ?? "invalid-dispatch-nonce",
      deviceID: try values.decode(String.self, forKey: .deviceID),
      loopID: try values.decode(String.self, forKey: .loopID),
      workload: try values.decode(TatwoPressureWorkerClassV1.self, forKey: .workload),
      contractID: try values.decode(String.self, forKey: .contractID),
      goalHash: try values.decode(String.self, forKey: .goalHash),
      planHash: try values.decode(String.self, forKey: .planHash),
      requestedAt: try values.decode(Date.self, forKey: .requestedAt))
  }

  public var hasExactJobBinding: Bool {
    schema == "TatwoLoopAdmissionRequestV1"
      && pressurePolicyVersion == TatwoPressurePolicyVersionV1.current
      && ![jobID, dispatchNonce, deviceID, loopID, contractID, goalHash, planHash].contains { value in
        value.hasPrefix("invalid-") || value.isEmpty
      }
      && TatwoPressureServiceText.isSHA256Digest(goalHash)
      && TatwoPressureServiceText.isSHA256Digest(planHash)
  }

  public var hasExactAttemptBinding: Bool {
    guard let attemptID else { return false }
    return hasExactJobBinding
      && !attemptID.hasPrefix("invalid-")
      && !attemptID.isEmpty
  }

  public func bindingDigest() throws -> String {
    try TatwoPressureServiceDigest.canonicalJSONDigest(self)
  }
}

public struct TatwoLoopAdmissionRequestBindingV1: Codable, Sendable, Equatable {
  public let schema: String
  public let request: TatwoLoopAdmissionRequestV1
  public let canonicalRequestJSON: String
  public let requestBindingDigest: String

  public init(
    schema: String = "TatwoLoopAdmissionRequestBindingV1",
    request: TatwoLoopAdmissionRequestV1,
    canonicalRequestJSON: String,
    requestBindingDigest: String
  ) {
    self.schema = schema
    self.request = request
    self.canonicalRequestJSON = String(canonicalRequestJSON.prefix(16_384))
    self.requestBindingDigest = TatwoPressureServiceText.safeSHA256Digest(
      requestBindingDigest,
      fallback: "invalid-request-binding-digest")
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decodeIfPresent(String.self, forKey: .schema)
        ?? "TatwoLoopAdmissionRequestBindingV1",
      request: try values.decode(TatwoLoopAdmissionRequestV1.self, forKey: .request),
      canonicalRequestJSON: try values.decode(String.self, forKey: .canonicalRequestJSON),
      requestBindingDigest: try values.decode(String.self, forKey: .requestBindingDigest))
  }

  public static func make(
    for request: TatwoLoopAdmissionRequestV1
  ) throws -> TatwoLoopAdmissionRequestBindingV1 {
    let canonicalData = try TatwoPressureServiceDigest.canonicalJSONData(request)
    guard let canonicalJSON = String(data: canonicalData, encoding: .utf8) else {
      throw TatwoLoopAdmissionRequestBindingErrorV1.canonicalJSONNotUTF8
    }
    return TatwoLoopAdmissionRequestBindingV1(
      request: request,
      canonicalRequestJSON: canonicalJSON,
      requestBindingDigest: TatwoLoopJobDigest.sha256(canonicalData))
  }

  public func verifiesRequest() -> Bool {
    guard schema == "TatwoLoopAdmissionRequestBindingV1",
      request.hasExactJobBinding,
      !requestBindingDigest.hasPrefix("invalid-"),
      let canonicalData = canonicalRequestJSON.data(using: .utf8),
      TatwoLoopJobDigest.sha256(canonicalData) == requestBindingDigest,
      let recomputedData = try? TatwoPressureServiceDigest.canonicalJSONData(request),
      canonicalData == recomputedData
    else {
      return false
    }
    return true
  }

  public func matches(_ request: TatwoLoopAdmissionRequestV1) -> Bool {
    guard verifiesRequest(),
      self.request == request,
      (try? request.bindingDigest()) == requestBindingDigest
    else {
      return false
    }
    return true
  }
}

public enum TatwoLoopAdmissionRequestBindingErrorV1: Error, Sendable, Equatable {
  case canonicalJSONNotUTF8
}

public enum TatwoPressureAdmissionReceiptErrorV1: Error, Sendable, Equatable {
  case snapshotUnavailable
}

private struct TatwoPressureAdmissionEvaluationV1: Sendable {
  let snapshot: TatwoDevicePressureSnapshotV1?
  let lease: TatwoPressureLeaseV1?
  let decision: TatwoLoopAdmissionDecisionV1
}

public actor TatwoAppPressureServiceV1 {
  private let sampler: TatwoAppPressureSamplerV1

  private let clock: TatwoPressureClockV1
  private let configuration: TatwoAppPressureSamplerConfigurationV1
  private var previousReceiptDigest: String?
  private var lastIssuedLease: TatwoPressureLeaseV1?

  public init(
    sampler: TatwoAppPressureSamplerV1,
    clock: TatwoPressureClockV1 = TatwoPressureClockV1(),
    configuration: TatwoAppPressureSamplerConfigurationV1? = nil
  ) {
    self.sampler = sampler
    self.clock = clock
    self.configuration = configuration ?? sampler.configuration
  }

  @discardableResult
  public func startAppOwnedMonitoring(generation: UInt64? = nil) async -> Bool {
    await sampler.startMonitoring(intentGeneration: generation)
  }

  @discardableResult
  public func stopAppOwnedMonitoring(generation: UInt64? = nil) async -> Bool {
    let didApply = await sampler.stopMonitoring(intentGeneration: generation)
    if didApply {
      previousReceiptDigest = nil
      lastIssuedLease = nil
    }
    return didApply
  }

  public func sampleAndIssueLease(
    reason: TatwoPressureSamplingReasonV1 = .manual,
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64? = nil,
    admissionAttemptID: String? = nil,
    admissionRequestBindingDigest: String? = nil,
    dispatchNonce: String? = nil,
    reservationID: String? = nil
  ) async -> TatwoPressureLeaseV1? {
    let snapshot = await sampler.sampleNow(reason: reason)
    return leaseForSnapshot(
      snapshot,
      now: clock.now(),
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: admissionAttemptID,
      admissionRequestBindingDigest: admissionRequestBindingDigest,
      dispatchNonce: dispatchNonce,
      reservationID: reservationID)
  }

  public func issueLeaseFromLatestSnapshot() async -> TatwoPressureLeaseV1? {
    guard let snapshot = await sampler.latest() else {
      return nil
    }
    return leaseForSnapshot(snapshot, now: clock.now())
  }

  public func admissionDecision(
    for request: TatwoLoopAdmissionRequestV1,
    refreshPolicy: TatwoPressureLeaseRefreshPolicyV1 = .sampleImmediately,
    samplingReason: TatwoPressureSamplingReasonV1? = nil,
    requestBinding: TatwoLoopAdmissionRequestBindingV1?,
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64? = nil,
    admissionAttemptID: String? = nil,
    reservationID: String? = nil
  ) async -> TatwoLoopAdmissionDecisionV1 {
    await evaluateAdmission(
      for: request,
      refreshPolicy: refreshPolicy,
      samplingReason: samplingReason,
      requestBinding: requestBinding,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: admissionAttemptID,
      reservationID: reservationID).decision
  }

  public func recordAdmissionReceipt(
    for request: TatwoLoopAdmissionRequestV1,
    requestBinding: TatwoLoopAdmissionRequestBindingV1,
    samplingReason: TatwoPressureSamplingReasonV1 = .preAdmissionImmediate,
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64? = nil,
    admissionAttemptID: String? = nil,
    reservationID: String? = nil
  ) async throws -> TatwoHostPressureReceiptV1 {
    let evaluation = await evaluateAdmission(
      for: request,
      refreshPolicy: .sampleImmediately,
      samplingReason: samplingReason,
      requestBinding: requestBinding,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: admissionAttemptID,
      reservationID: reservationID)
    guard let snapshot = evaluation.snapshot else {
      throw TatwoPressureAdmissionReceiptErrorV1.snapshotUnavailable
    }
    let receipt = try TatwoHostPressureReceiptV1.make(
      snapshot: snapshot,
      now: evaluation.decision.decidedAt,
      lease: evaluation.lease,
      admissionDecision: evaluation.decision,
      admissionRequestBinding: requestBinding,
      previousReceiptDigest: previousReceiptDigest)
    previousReceiptDigest = receipt.receiptDigest
    return receipt
  }

  private func evaluateAdmission(
    for request: TatwoLoopAdmissionRequestV1,
    refreshPolicy: TatwoPressureLeaseRefreshPolicyV1,
    samplingReason: TatwoPressureSamplingReasonV1?,
    requestBinding: TatwoLoopAdmissionRequestBindingV1?,
    runtimeInstanceID: String?,
    runtimeGeneration: UInt64?,
    admissionAttemptID: String?,
    reservationID: String?
  ) async -> TatwoPressureAdmissionEvaluationV1 {
    let bindingDigest = try? request.bindingDigest()
    let effectiveAdmissionAttemptID = admissionAttemptID ?? request.attemptID
    guard request.hasExactJobBinding else {
      return TatwoPressureAdmissionEvaluationV1(
        snapshot: nil,
        lease: nil,
        decision: TatwoLoopAdmissionDecisionV1(
          deviceID: request.deviceID,
          loopID: request.loopID,
          workload: request.workload,
          decidedAt: clock.now(),
          classification: .unknown,
          accepted: false,
          reasonCode: "job_binding_invalid",
          reason: "pressure admission requires an exact job, contract, goal and plan binding",
          stopAction: .none,
          leaseID: nil,
          requestBindingDigest: bindingDigest,
          runtimeInstanceID: runtimeInstanceID,
          runtimeGeneration: runtimeGeneration,
          admissionAttemptID: effectiveAdmissionAttemptID,
          dispatchNonce: request.dispatchNonce,
          reservationID: reservationID))
    }
    if runtimeInstanceID != nil || runtimeGeneration != nil || admissionAttemptID != nil {
      guard request.hasExactAttemptBinding,
        effectiveAdmissionAttemptID == request.attemptID
      else {
        return TatwoPressureAdmissionEvaluationV1(
          snapshot: nil,
          lease: nil,
          decision: TatwoLoopAdmissionDecisionV1(
            deviceID: request.deviceID,
            loopID: request.loopID,
            workload: request.workload,
            decidedAt: clock.now(),
            classification: .unknown,
            accepted: false,
            reasonCode: "attempt_binding_missing",
            reason: "pressure runtime admission requires an exact job attempt token before sampling or spawn authorization",
            stopAction: .none,
            leaseID: nil,
            requestBindingDigest: bindingDigest,
            runtimeInstanceID: runtimeInstanceID,
            runtimeGeneration: runtimeGeneration,
            admissionAttemptID: effectiveAdmissionAttemptID,
            dispatchNonce: request.dispatchNonce,
            reservationID: reservationID))
      }
    }
    guard let requestBinding else {
      return TatwoPressureAdmissionEvaluationV1(
        snapshot: nil,
        lease: nil,
        decision: TatwoLoopAdmissionDecisionV1(
          deviceID: request.deviceID,
          loopID: request.loopID,
          workload: request.workload,
          decidedAt: clock.now(),
          classification: .unknown,
          accepted: false,
          reasonCode: "request_binding_missing",
          reason: "pressure admission requires canonical request binding proof before sampling or spawn authorization",
          stopAction: .none,
          leaseID: nil,
          requestBindingDigest: bindingDigest,
          runtimeInstanceID: runtimeInstanceID,
          runtimeGeneration: runtimeGeneration,
          admissionAttemptID: effectiveAdmissionAttemptID,
          dispatchNonce: request.dispatchNonce,
          reservationID: reservationID))
    }
    guard requestBinding.matches(request) else {
      return TatwoPressureAdmissionEvaluationV1(
        snapshot: nil,
        lease: nil,
        decision: TatwoLoopAdmissionDecisionV1(
          deviceID: request.deviceID,
          loopID: request.loopID,
          workload: request.workload,
          decidedAt: clock.now(),
          classification: .unknown,
          accepted: false,
          reasonCode: "request_binding_digest_mismatch",
          reason: "pressure admission request bytes do not match the reserved request binding",
          stopAction: .none,
          leaseID: nil,
          requestBindingDigest: bindingDigest,
          runtimeInstanceID: runtimeInstanceID,
          runtimeGeneration: runtimeGeneration,
          admissionAttemptID: effectiveAdmissionAttemptID,
          dispatchNonce: request.dispatchNonce,
          reservationID: reservationID))
    }

    let snapshot: TatwoDevicePressureSnapshotV1?
    switch refreshPolicy {
    case .sampleImmediately:
      snapshot = await sampler.sampleNow(reason: samplingReason ?? .preAdmissionImmediate)
    case .latestOnly:
      snapshot = await sampler.latest()
    }
    guard let snapshot else {
      return TatwoPressureAdmissionEvaluationV1(
        snapshot: nil,
        lease: nil,
        decision: TatwoLoopAdmissionDecisionV1.decide(
          deviceID: request.deviceID,
          loopID: request.loopID,
          workload: request.workload,
          lease: nil,
          now: clock.now(),
          requestBindingDigest: requestBinding.requestBindingDigest,
          runtimeInstanceID: runtimeInstanceID,
          runtimeGeneration: runtimeGeneration,
          admissionAttemptID: effectiveAdmissionAttemptID,
          dispatchNonce: request.dispatchNonce,
          reservationID: reservationID))
    }
    let now = clock.now()
    let lease = leaseForSnapshot(
      snapshot,
      now: now,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: effectiveAdmissionAttemptID,
      admissionRequestBindingDigest: requestBinding.requestBindingDigest,
      dispatchNonce: request.dispatchNonce,
      reservationID: reservationID)
    let rawDecision = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      lease: lease,
      now: now,
      workers: snapshot.workers,
      requestBindingDigest: requestBinding.requestBindingDigest,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: effectiveAdmissionAttemptID,
      dispatchNonce: request.dispatchNonce,
      reservationID: reservationID)
    let decision = enforceProductionYellowExpansionPolicy(
      rawDecision,
      snapshot: snapshot,
      request: request,
      requestBindingDigest: requestBinding.requestBindingDigest)
    return TatwoPressureAdmissionEvaluationV1(
      snapshot: snapshot,
      lease: lease,
      decision: decision)
  }

  private func enforceProductionYellowExpansionPolicy(
    _ decision: TatwoLoopAdmissionDecisionV1,
    snapshot: TatwoDevicePressureSnapshotV1,
    request: TatwoLoopAdmissionRequestV1,
    requestBindingDigest: String
  ) -> TatwoLoopAdmissionDecisionV1 {
    guard decision.classification == .yellow,
      request.workload == .light
    else {
      return decision
    }
    if isExactAlreadySpawnedAttemptContinuation(snapshot: snapshot, request: request) {
      return TatwoLoopAdmissionDecisionV1(
        deviceID: request.deviceID,
        loopID: request.loopID,
        workload: request.workload,
        decidedAt: decision.decidedAt,
        classification: .yellow,
        accepted: true,
        authorizesSpawn: false,
        reasonCode: "pressure_yellow_exact_attempt_continue",
        reason: "yellow pressure permits only the already-spawned exact attempt to continue without enqueue or spawn",
        stopAction: .none,
        leaseID: decision.leaseID,
        requestBindingDigest: requestBindingDigest,
        runtimeInstanceID: decision.runtimeInstanceID,
        runtimeGeneration: decision.runtimeGeneration,
        admissionAttemptID: decision.admissionAttemptID,
        dispatchNonce: decision.dispatchNonce,
        reservationID: decision.reservationID,
        sourceSnapshotSequence: decision.sourceSnapshotSequence,
        sourceSampleAttemptID: decision.sourceSampleAttemptID,
        leaseDigest: decision.leaseDigest)
    }
    return TatwoLoopAdmissionDecisionV1(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      decidedAt: decision.decidedAt,
      classification: .yellow,
      accepted: false,
      reasonCode: "pressure_yellow_exact_attempt_only",
      reason: "yellow pressure allows only the exact already-spawned attempt to continue; new assignments, retries, spawns or loop expansion are rejected",
      stopAction: .none,
      leaseID: decision.leaseID,
      requestBindingDigest: requestBindingDigest,
      runtimeInstanceID: decision.runtimeInstanceID,
      runtimeGeneration: decision.runtimeGeneration,
      admissionAttemptID: decision.admissionAttemptID,
      dispatchNonce: decision.dispatchNonce,
      reservationID: decision.reservationID,
      sourceSnapshotSequence: decision.sourceSnapshotSequence,
      sourceSampleAttemptID: decision.sourceSampleAttemptID,
      leaseDigest: decision.leaseDigest)
  }

  private func isExactAlreadySpawnedAttemptContinuation(
    snapshot: TatwoDevicePressureSnapshotV1,
    request: TatwoLoopAdmissionRequestV1
  ) -> Bool {
    guard request.workload == .light,
      snapshot.activeLoopID == request.loopID,
      let attemptID = request.attemptID
    else {
      return false
    }
    return snapshot.workers.contains { worker in
      worker.workerID == request.jobID
        && worker.loopID == request.loopID
        && worker.attemptID == attemptID
        && worker.workload == request.workload
    }
  }

  public func uiProjection() async -> TatwoPressureUIProjectionV1 {
    let now = clock.now()
    guard let snapshot = await sampler.latest() else {
      return TatwoPressureUIProjectionV1(
        deviceID: sampler.deviceID,
        displayClassification: .unknown,
        lastObservedAt: nil,
        activeLoopID: nil,
        workerIDs: [],
        stopReason: "monitor_unknown",
        canRequestLightLoop: false,
        canRequestHeavyLoop: false)
    }
    let classification = snapshot.classify(now: now)
    let hasFreshLease = anyReusableFreshLeaseForSnapshot(snapshot, now: now) != nil
    return TatwoPressureUIProjectionV1(
      deviceID: snapshot.deviceID,
      displayClassification: hasFreshLease ? classification.classification : .unknown,
      lastObservedAt: snapshot.observedAt,
      activeLoopID: snapshot.activeLoopID,
      workerIDs: snapshot.workers.map(\.workerID),
      stopReason: hasFreshLease && classification.classification == .green
        ? nil
        : (classification.reasonCodes + ["fresh_pressure_lease_unavailable"]).joined(separator: ","),
      canRequestLightLoop: hasFreshLease
        && (classification.classification == .green || classification.classification == .yellow),
      canRequestHeavyLoop: hasFreshLease && classification.classification == .green,
      hostInventory: snapshot.hostInventory)
  }

  public func recordSummaryReceipt(
    reason: TatwoPressureSamplingReasonV1 = .summaryReceipt
  ) async throws -> TatwoHostPressureReceiptV1 {
    let snapshot = await sampler.sampleNow(reason: reason)
    let now = clock.now()
    let lease = leaseForSnapshot(snapshot, now: now)
    let receipt = try TatwoHostPressureReceiptV1.make(
      snapshot: snapshot,
      now: now,
      lease: lease,
      previousReceiptDigest: previousReceiptDigest)
    previousReceiptDigest = receipt.receiptDigest
    return receipt
  }

  private func leaseForSnapshot(
    _ snapshot: TatwoDevicePressureSnapshotV1,
    now: Date,
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64? = nil,
    admissionAttemptID: String? = nil,
    admissionRequestBindingDigest: String? = nil,
    dispatchNonce: String? = nil,
    reservationID: String? = nil
  ) -> TatwoPressureLeaseV1? {
    guard snapshotCanBackFreshLease(snapshot, now: now),
      let snapshotDigest = try? snapshot.canonicalDigest()
    else { return nil }
    if let reusable = reusableFreshLeaseForSnapshot(
      snapshot,
      snapshotDigest: snapshotDigest,
      now: now,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: admissionAttemptID,
      admissionRequestBindingDigest: admissionRequestBindingDigest,
      dispatchNonce: dispatchNonce,
      reservationID: reservationID)
    {
      return reusable
    }
    if let lastIssuedLease,
      lastIssuedLease.snapshotDigest == snapshotDigest,
      lastIssuedLease.snapshotObservedAt == snapshot.observedAt
    {
      return nil
    }
    do {
      let lease = try TatwoPressureLeaseV1.issue(
        for: snapshot,
        now: now,
        ttlSeconds: TatwoPressureLeaseV1.defaultTTLSeconds,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        admissionAttemptID: admissionAttemptID,
        admissionRequestBindingDigest: admissionRequestBindingDigest,
        dispatchNonce: dispatchNonce,
        reservationID: reservationID)
      lastIssuedLease = lease
      return lease
    } catch {
      return nil
    }
  }

  private func reusableFreshLeaseForSnapshot(
    _ snapshot: TatwoDevicePressureSnapshotV1,
    now: Date
  ) -> TatwoPressureLeaseV1? {
    guard let snapshotDigest = try? snapshot.canonicalDigest() else { return nil }
    return reusableFreshLeaseForSnapshot(
      snapshot,
      snapshotDigest: snapshotDigest,
      now: now)
  }

  private func reusableFreshLeaseForSnapshot(
    _ snapshot: TatwoDevicePressureSnapshotV1,
    snapshotDigest: String,
    now: Date,
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64? = nil,
    admissionAttemptID: String? = nil,
    admissionRequestBindingDigest: String? = nil,
    dispatchNonce: String? = nil,
    reservationID: String? = nil
  ) -> TatwoPressureLeaseV1? {
    guard snapshotCanBackFreshLease(snapshot, now: now),
      let lastIssuedLease,
      lastIssuedLease.snapshotDigest == snapshotDigest,
      lastIssuedLease.snapshotObservedAt == snapshot.observedAt,
      lastIssuedLease.runtimeInstanceID == runtimeInstanceID,
      lastIssuedLease.runtimeGeneration == runtimeGeneration,
      lastIssuedLease.admissionAttemptID == admissionAttemptID,
      lastIssuedLease.admissionRequestBindingDigest == admissionRequestBindingDigest,
      lastIssuedLease.dispatchNonce == dispatchNonce,
      lastIssuedLease.reservationID == reservationID,
      lastIssuedLease.freshness(
        now: now,
        maxAgeSeconds: configuration.maximumSnapshotAgeForLeaseSeconds) == .fresh
    else {
      return nil
    }
    return lastIssuedLease
  }

  private func anyReusableFreshLeaseForSnapshot(
    _ snapshot: TatwoDevicePressureSnapshotV1,
    now: Date
  ) -> TatwoPressureLeaseV1? {
    guard snapshotCanBackFreshLease(snapshot, now: now),
      let snapshotDigest = try? snapshot.canonicalDigest(),
      let lastIssuedLease,
      lastIssuedLease.snapshotDigest == snapshotDigest,
      lastIssuedLease.snapshotObservedAt == snapshot.observedAt,
      lastIssuedLease.freshness(
        now: now,
        maxAgeSeconds: configuration.maximumSnapshotAgeForLeaseSeconds) == .fresh
    else {
      return nil
    }
    return lastIssuedLease
  }

  private func snapshotCanBackFreshLease(
    _ snapshot: TatwoDevicePressureSnapshotV1,
    now: Date
  ) -> Bool {
    guard snapshot.observedAt.timeIntervalSince(now) <= 1,
      now.timeIntervalSince(snapshot.observedAt) <= configuration.maximumSnapshotAgeForLeaseSeconds
    else { return false }
    guard snapshot.classify(now: now).classification != .unknown else { return false }
    return true
  }
}

public struct TatwoLocalLoopAdmissionRecorderV1: Sendable {
  private let enqueueHandler: @Sendable (TatwoLoopAdmissionRequestV1, TatwoLoopAdmissionDecisionV1) async -> Void
  private let spawnHandler: @Sendable (TatwoLoopAdmissionRequestV1, TatwoLoopAdmissionDecisionV1) async -> Void
  private let cancelHandler: @Sendable (TatwoLoopAdmissionRequestV1, TatwoLoopAdmissionDecisionV1) async -> Void

  public init(
    enqueue: @escaping @Sendable (TatwoLoopAdmissionRequestV1, TatwoLoopAdmissionDecisionV1) async -> Void = { _, _ in },
    spawn: @escaping @Sendable (TatwoLoopAdmissionRequestV1, TatwoLoopAdmissionDecisionV1) async -> Void = { _, _ in },
    cancel: @escaping @Sendable (TatwoLoopAdmissionRequestV1, TatwoLoopAdmissionDecisionV1) async -> Void = { _, _ in }
  ) {
    self.enqueueHandler = enqueue
    self.spawnHandler = spawn
    self.cancelHandler = cancel
  }

  public func recordEnqueue(
    request: TatwoLoopAdmissionRequestV1,
    decision: TatwoLoopAdmissionDecisionV1
  ) async {
    await enqueueHandler(request, decision)
  }

  public func recordSpawn(
    request: TatwoLoopAdmissionRequestV1,
    decision: TatwoLoopAdmissionDecisionV1
  ) async {
    await spawnHandler(request, decision)
  }

  public func recordCancel(
    request: TatwoLoopAdmissionRequestV1,
    decision: TatwoLoopAdmissionDecisionV1
  ) async {
    await cancelHandler(request, decision)
  }
}

public struct TatwoLocalLoopAdmissionResultV1: Sendable, Equatable {
  public let schema: String
  public let request: TatwoLoopAdmissionRequestV1
  public let requestBinding: TatwoLoopAdmissionRequestBindingV1?
  public let reservation: TatwoLocalLoopAdmissionReservationV1?
  public let admissionDecision: TatwoLoopAdmissionDecisionV1
  public let spawnDecision: TatwoLoopAdmissionDecisionV1?
  public let enqueued: Bool
  public let spawned: Bool

  public init(
    schema: String = "TatwoLocalLoopAdmissionResultV1",
    request: TatwoLoopAdmissionRequestV1,
    requestBinding: TatwoLoopAdmissionRequestBindingV1? = nil,
    reservation: TatwoLocalLoopAdmissionReservationV1? = nil,
    admissionDecision: TatwoLoopAdmissionDecisionV1,
    spawnDecision: TatwoLoopAdmissionDecisionV1?,
    enqueued: Bool,
    spawned: Bool
  ) {
    self.schema = schema
    self.request = request
    self.requestBinding = requestBinding ?? (try? TatwoLoopAdmissionRequestBindingV1.make(for: request))
    self.reservation = reservation
    self.admissionDecision = admissionDecision
    self.spawnDecision = spawnDecision
    self.enqueued = enqueued
    self.spawned = spawned
  }
}

public enum TatwoLocalLoopAdmissionJournalPhaseV1: String, Codable, Sendable, Equatable {
  case notAdmitted = "not_admitted"
  case admittedNotSpawned = "admitted_not_spawned"
  case spawned
  case terminal
  case outcomeUnproven = "outcome_unproven"
}

public typealias TatwoLocalLoopAdmissionSpawnAuthorityFenceV1 = @Sendable (
  TatwoLoopAdmissionRequestV1,
  TatwoLoopAdmissionRequestBindingV1,
  TatwoLocalLoopAdmissionReservationV1,
  TatwoLoopAdmissionDecisionV1
) async -> TatwoLoopAdmissionDecisionV1?

public struct TatwoLocalLoopAdmissionReservationV1: Codable, Sendable, Equatable {
  public let schema: String
  public let jobID: String
  public let requestBindingDigest: String
  public let reservationID: String
  public let generation: UInt64
  public let createdAt: Date

  public init(
    schema: String = "TatwoLocalLoopAdmissionReservationV1",
    jobID: String,
    requestBindingDigest: String,
    reservationID: String,
    generation: UInt64,
    createdAt: Date
  ) {
    self.schema = schema
    self.jobID = TatwoPressureServiceText.safeIdentifier(jobID, fallback: "invalid-job-id")
    self.requestBindingDigest = TatwoPressureServiceText.safeSHA256Digest(
      requestBindingDigest,
      fallback: "invalid-request-binding-digest")
    self.reservationID = TatwoPressureServiceText.safeSHA256Digest(
      reservationID,
      fallback: "invalid-reservation-id")
    self.generation = generation
    self.createdAt = createdAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decodeIfPresent(String.self, forKey: .schema)
        ?? "TatwoLocalLoopAdmissionReservationV1",
      jobID: try values.decode(String.self, forKey: .jobID),
      requestBindingDigest: try values.decode(String.self, forKey: .requestBindingDigest),
      reservationID: try values.decode(String.self, forKey: .reservationID),
      generation: try values.decode(UInt64.self, forKey: .generation),
      createdAt: try values.decode(Date.self, forKey: .createdAt))
  }
}

public struct TatwoLocalLoopAdmissionJournalEntryV1: Codable, Sendable, Equatable {
  public let schema: String
  public let reservation: TatwoLocalLoopAdmissionReservationV1
  public let phase: TatwoLocalLoopAdmissionJournalPhaseV1
  public let recordedAt: Date
  public let reasonCode: String
  public let decisionDigest: String?
  public let terminalDigest: String?
  public let previousEntryDigest: String?
  public private(set) var entryDigest: String?

  public init(
    schema: String = "TatwoLocalLoopAdmissionJournalEntryV1",
    reservation: TatwoLocalLoopAdmissionReservationV1,
    phase: TatwoLocalLoopAdmissionJournalPhaseV1,
    recordedAt: Date,
    reasonCode: String,
    decisionDigest: String? = nil,
    terminalDigest: String? = nil,
    previousEntryDigest: String? = nil,
    entryDigest: String? = nil
  ) {
    self.schema = schema
    self.reservation = reservation
    self.phase = phase
    self.recordedAt = recordedAt
    self.reasonCode = TatwoPressureServiceText.safeReasonCode(
      reasonCode,
      fallback: "admission_journal_update")
    self.decisionDigest = decisionDigest.map {
      TatwoPressureServiceText.safeSHA256Digest($0, fallback: "invalid-decision-digest")
    }
    self.terminalDigest = terminalDigest.map {
      TatwoPressureServiceText.safeSHA256Digest($0, fallback: "invalid-terminal-digest")
    }
    self.previousEntryDigest = previousEntryDigest.map {
      TatwoPressureServiceText.safeSHA256Digest($0, fallback: "invalid-previous-entry-digest")
    }
    self.entryDigest = entryDigest.map {
      TatwoPressureServiceText.safeSHA256Digest($0, fallback: "invalid-entry-digest")
    }
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try values.decodeIfPresent(String.self, forKey: .schema)
        ?? "TatwoLocalLoopAdmissionJournalEntryV1",
      reservation: try values.decode(TatwoLocalLoopAdmissionReservationV1.self, forKey: .reservation),
      phase: try values.decode(TatwoLocalLoopAdmissionJournalPhaseV1.self, forKey: .phase),
      recordedAt: try values.decode(Date.self, forKey: .recordedAt),
      reasonCode: try values.decode(String.self, forKey: .reasonCode),
      decisionDigest: try values.decodeIfPresent(String.self, forKey: .decisionDigest),
      terminalDigest: try values.decodeIfPresent(String.self, forKey: .terminalDigest),
      previousEntryDigest: try values.decodeIfPresent(String.self, forKey: .previousEntryDigest),
      entryDigest: try values.decodeIfPresent(String.self, forKey: .entryDigest))
  }

  public func canonicalDigest() throws -> String {
    var copy = self
    copy.entryDigest = nil
    return try TatwoPressureServiceDigest.canonicalJSONDigest(copy)
  }

  public mutating func seal() throws {
    entryDigest = try canonicalDigest()
  }

  public func verifiesDigest(previousEntryDigest expectedPreviousEntryDigest: String?) -> Bool {
    guard schema == "TatwoLocalLoopAdmissionJournalEntryV1",
      reservation.schema == "TatwoLocalLoopAdmissionReservationV1",
      previousEntryDigest == expectedPreviousEntryDigest,
      let entryDigest,
      !entryDigest.hasPrefix("invalid-"),
      phase != .terminal || terminalDigest != nil
    else {
      return false
    }
    return (try? canonicalDigest()) == entryDigest
  }

  public static func verifiesChain(_ entries: [TatwoLocalLoopAdmissionJournalEntryV1]) -> Bool {
    var previousEntryDigest: String?
    for entry in entries {
      guard entry.verifiesDigest(previousEntryDigest: previousEntryDigest) else {
        return false
      }
      previousEntryDigest = entry.entryDigest
    }
    return true
  }
}

public actor TatwoLocalLoopAdmissionSeamV1 {
  private enum AdmissionAuthority: Sendable {
    case service(TatwoAppPressureServiceV1)
    case appRuntime(TatwoAppPressureRuntimeV1)

    func decision(
      for request: TatwoLoopAdmissionRequestV1,
      samplingReason: TatwoPressureSamplingReasonV1,
      requestBinding: TatwoLoopAdmissionRequestBindingV1,
      runtimeInstanceID: String?,
      runtimeGeneration: UInt64?,
      admissionAttemptID: String?,
      reservationID: String
    ) async -> TatwoLoopAdmissionDecisionV1 {
      switch self {
      case .service(let service):
        return await service.admissionDecision(
          for: request,
          refreshPolicy: .sampleImmediately,
          samplingReason: samplingReason,
          requestBinding: requestBinding,
          runtimeInstanceID: runtimeInstanceID,
          runtimeGeneration: runtimeGeneration,
          admissionAttemptID: admissionAttemptID,
          reservationID: reservationID)
      case .appRuntime(let runtime):
        return await runtime.preAdmissionDecision(
          for: request,
          requestBinding: requestBinding,
          samplingReason: samplingReason,
          reservationID: reservationID)
      }
    }
  }

  private struct ReservationSlot: Sendable {
    let binding: TatwoLoopAdmissionRequestBindingV1?
    let reservation: TatwoLocalLoopAdmissionReservationV1
    var phase: TatwoLocalLoopAdmissionJournalPhaseV1
  }

  private let admissionAuthority: AdmissionAuthority
  private let recorder: TatwoLocalLoopAdmissionRecorderV1
  private let clock: TatwoPressureClockV1
  private let runtimeInstanceID: String?
  private let runtimeGeneration: UInt64?
  private let spawnAuthorityFence: TatwoLocalLoopAdmissionSpawnAuthorityFenceV1?
  private let defersEnqueueRecordUntilSpawnAuthority: Bool
  private var slotsByJobID: [String: ReservationSlot] = [:]
  private var journalEntries: [TatwoLocalLoopAdmissionJournalEntryV1]
  private var journalChainValid: Bool
  private var nextGeneration: UInt64 = 1

  public init(
    service: TatwoAppPressureServiceV1,
    recorder: TatwoLocalLoopAdmissionRecorderV1 = TatwoLocalLoopAdmissionRecorderV1(),
    clock: TatwoPressureClockV1 = TatwoPressureClockV1(),
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64? = nil,
    rehydratedJournal: [TatwoLocalLoopAdmissionJournalEntryV1] = [],
    spawnAuthorityFence: TatwoLocalLoopAdmissionSpawnAuthorityFenceV1? = nil,
    defersEnqueueRecordUntilSpawnAuthority: Bool = false
  ) {
    self.init(
      admissionAuthority: .service(service),
      recorder: recorder,
      clock: clock,
      runtimeInstanceID: runtimeInstanceID ?? "local-loop-admission-seam",
      runtimeGeneration: runtimeGeneration ?? 1,
      rehydratedJournal: rehydratedJournal,
      spawnAuthorityFence: spawnAuthorityFence,
      defersEnqueueRecordUntilSpawnAuthority: defersEnqueueRecordUntilSpawnAuthority)
  }

  public static func appRuntimeBacked(
    runtime: TatwoAppPressureRuntimeV1,
    recorder: TatwoLocalLoopAdmissionRecorderV1 = TatwoLocalLoopAdmissionRecorderV1(),
    clock: TatwoPressureClockV1 = TatwoPressureClockV1(),
    rehydratedJournal: [TatwoLocalLoopAdmissionJournalEntryV1] = [],
    spawnAuthorityFence: TatwoLocalLoopAdmissionSpawnAuthorityFenceV1? = nil
  ) async -> TatwoLocalLoopAdmissionSeamV1 {
    await TatwoLocalLoopAdmissionSeamV1(
      admissionAuthority: .appRuntime(runtime),
      recorder: recorder,
      clock: clock,
      runtimeInstanceID: runtime.runtimeInstanceID,
      runtimeGeneration: runtime.currentGeneration,
      rehydratedJournal: rehydratedJournal,
      spawnAuthorityFence: spawnAuthorityFence,
      defersEnqueueRecordUntilSpawnAuthority: true)
  }

  private init(
    admissionAuthority: AdmissionAuthority,
    recorder: TatwoLocalLoopAdmissionRecorderV1,
    clock: TatwoPressureClockV1,
    runtimeInstanceID: String,
    runtimeGeneration: UInt64,
    rehydratedJournal: [TatwoLocalLoopAdmissionJournalEntryV1],
    spawnAuthorityFence: TatwoLocalLoopAdmissionSpawnAuthorityFenceV1?,
    defersEnqueueRecordUntilSpawnAuthority: Bool
  ) {
    self.admissionAuthority = admissionAuthority
    self.recorder = recorder
    self.clock = clock
    self.runtimeInstanceID = TatwoPressureServiceText.safeIdentifier(
      runtimeInstanceID,
      fallback: "invalid-runtime-instance-id")
    self.runtimeGeneration = runtimeGeneration
    self.spawnAuthorityFence = spawnAuthorityFence
    self.defersEnqueueRecordUntilSpawnAuthority = defersEnqueueRecordUntilSpawnAuthority
    self.journalEntries = rehydratedJournal
    self.journalChainValid = TatwoLocalLoopAdmissionJournalEntryV1.verifiesChain(rehydratedJournal)
    for entry in rehydratedJournal {
      let reservation = entry.reservation
      nextGeneration = max(nextGeneration, reservation.generation &+ 1)
      guard journalChainValid,
        !reservation.jobID.hasPrefix("invalid-"),
        !reservation.requestBindingDigest.hasPrefix("invalid-"),
        !reservation.reservationID.hasPrefix("invalid-")
      else {
        continue
      }
      slotsByJobID[reservation.jobID] = ReservationSlot(
        binding: nil,
        reservation: reservation,
        phase: entry.phase)
    }
  }

  public func admitAtLastReversiblePoint(
    _ request: TatwoLoopAdmissionRequestV1,
    beforeSpawn: @escaping @Sendable () async -> Void = {}
  ) async -> TatwoLocalLoopAdmissionResultV1 {
    await admitAtLastReversiblePoint(
      request,
      beforeSpawnWithReservation: { _ in
        await beforeSpawn()
      })
  }

  public func admitAtLastReversiblePoint(
    _ request: TatwoLoopAdmissionRequestV1,
    beforeSpawnWithReservation: @escaping @Sendable (TatwoLocalLoopAdmissionReservationV1) async -> Void
  ) async -> TatwoLocalLoopAdmissionResultV1 {
    let candidateRequestBinding = try? TatwoLoopAdmissionRequestBindingV1.make(for: request)
    guard journalChainValid else {
      let invalidJournal = journalChainInvalidDecision(
        request: request,
        requestBindingDigest: try? request.bindingDigest())
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: candidateRequestBinding,
        reservation: nil,
        admissionDecision: invalidJournal,
        spawnDecision: nil,
        enqueued: false,
        spawned: false)
    }
    guard let requestBinding = candidateRequestBinding,
      requestBinding.verifiesRequest()
    else {
      let invalid = TatwoLoopAdmissionDecisionV1(
        deviceID: request.deviceID,
        loopID: request.loopID,
        workload: request.workload,
        decidedAt: clock.now(),
        classification: .unknown,
        accepted: false,
        reasonCode: "job_binding_invalid",
        reason: "pressure admission requires exact canonical request bytes and digest",
        stopAction: .none,
        leaseID: nil,
        requestBindingDigest: try? request.bindingDigest())
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: candidateRequestBinding,
        reservation: nil,
        admissionDecision: invalid,
        spawnDecision: nil,
        enqueued: false,
        spawned: false)
    }

    guard slotsByJobID[request.jobID] == nil else {
      let duplicate = duplicateDecision(
        request: request,
        requestBindingDigest: requestBinding.requestBindingDigest,
        existingPhase: slotsByJobID[request.jobID]?.phase)
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: requestBinding,
        reservation: slotsByJobID[request.jobID]?.reservation,
        admissionDecision: duplicate,
        spawnDecision: nil,
        enqueued: false,
        spawned: false)
    }

    let reservation = reserve(request: request, requestBinding: requestBinding)
    let admission = await admissionAuthority.decision(
      for: request,
      samplingReason: .preAdmissionImmediate,
      requestBinding: requestBinding,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: request.attemptID,
      reservationID: reservation.reservationID)
    guard acceptedDecisionMatchesReservation(
      admission,
      request: request,
      requestBinding: requestBinding,
      reservation: reservation)
    else {
      let mismatch = bindingMismatchDecision(request: request, requestBinding: requestBinding)
      guard transition(
        reservation: reservation,
        from: .outcomeUnproven,
        to: .notAdmitted,
        reasonCode: mismatch.reasonCode,
        decision: mismatch)
      else {
        let stale = staleReservationDecision(request: request, requestBinding: requestBinding)
        return TatwoLocalLoopAdmissionResultV1(
          request: request,
          requestBinding: requestBinding,
          reservation: reservation,
          admissionDecision: stale,
          spawnDecision: nil,
          enqueued: false,
          spawned: false)
      }
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: requestBinding,
        reservation: reservation,
        admissionDecision: mismatch,
        spawnDecision: nil,
        enqueued: false,
        spawned: false)
    }
    guard admission.accepted else {
      guard transition(
        reservation: reservation,
        from: .outcomeUnproven,
        to: .notAdmitted,
        reasonCode: admission.reasonCode,
        decision: admission)
      else {
        let stale = staleReservationDecision(request: request, requestBinding: requestBinding)
        return TatwoLocalLoopAdmissionResultV1(
          request: request,
          requestBinding: requestBinding,
          reservation: reservation,
          admissionDecision: stale,
          spawnDecision: nil,
          enqueued: false,
          spawned: false)
      }
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: requestBinding,
        reservation: reservation,
        admissionDecision: admission,
        spawnDecision: nil,
        enqueued: false,
        spawned: false)
    }
    if admission.reasonCode == "pressure_yellow_exact_attempt_continue" {
      guard !admission.authorizesSpawn,
        transition(
        reservation: reservation,
        from: .outcomeUnproven,
        to: .terminal,
        reasonCode: admission.reasonCode,
        decision: admission,
        terminalDigest: decisionDigest(admission))
      else {
        let stale = staleReservationDecision(request: request, requestBinding: requestBinding)
        return TatwoLocalLoopAdmissionResultV1(
          request: request,
          requestBinding: requestBinding,
          reservation: reservation,
          admissionDecision: stale,
          spawnDecision: nil,
          enqueued: false,
          spawned: false)
      }
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: requestBinding,
        reservation: reservation,
        admissionDecision: admission,
        spawnDecision: nil,
        enqueued: false,
        spawned: false)
    }

    guard admission.authorizesSpawn else {
      let unauthorized = spawnNotAuthorizedDecision(
        request: request,
        requestBinding: requestBinding,
        reservation: reservation,
        sourceDecision: admission)
      _ = transition(
        reservation: reservation,
        from: .outcomeUnproven,
        to: .notAdmitted,
        reasonCode: unauthorized.reasonCode,
        decision: unauthorized)
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: requestBinding,
        reservation: reservation,
        admissionDecision: unauthorized,
        spawnDecision: nil,
        enqueued: false,
        spawned: false)
    }

    guard transition(
      reservation: reservation,
      from: .outcomeUnproven,
      to: .admittedNotSpawned,
      reasonCode: admission.reasonCode,
      decision: admission)
    else {
      let stale = staleReservationDecision(request: request, requestBinding: requestBinding)
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: requestBinding,
        reservation: reservation,
        admissionDecision: stale,
        spawnDecision: nil,
        enqueued: false,
        spawned: false)
    }

    var didRecordEnqueue = false
    if !defersEnqueueRecordUntilSpawnAuthority {
      await recorder.recordEnqueue(request: request, decision: admission)
      didRecordEnqueue = true
    }
    await beforeSpawnWithReservation(reservation)

    let spawnDecision = await admissionAuthority.decision(
      for: request,
      samplingReason: .preSpawnRecheck,
      requestBinding: requestBinding,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: request.attemptID,
      reservationID: reservation.reservationID)
    guard acceptedDecisionMatchesReservation(
      spawnDecision,
      request: request,
      requestBinding: requestBinding,
      reservation: reservation)
    else {
      let mismatch = bindingMismatchDecision(request: request, requestBinding: requestBinding)
      guard transition(
        reservation: reservation,
        from: .admittedNotSpawned,
        to: .outcomeUnproven,
        reasonCode: mismatch.reasonCode,
        decision: mismatch)
      else {
        let stale = staleReservationDecision(request: request, requestBinding: requestBinding)
        return TatwoLocalLoopAdmissionResultV1(
          request: request,
          requestBinding: requestBinding,
          reservation: reservation,
          admissionDecision: admission,
          spawnDecision: stale,
          enqueued: didRecordEnqueue,
          spawned: false)
      }
      await recorder.recordCancel(request: request, decision: mismatch)
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: requestBinding,
        reservation: reservation,
        admissionDecision: admission,
        spawnDecision: mismatch,
        enqueued: didRecordEnqueue,
        spawned: false)
    }
    guard spawnDecision.accepted else {
      guard transition(
        reservation: reservation,
        from: .admittedNotSpawned,
        to: .terminal,
        reasonCode: spawnDecision.reasonCode,
        decision: spawnDecision,
        terminalDigest: decisionDigest(spawnDecision))
      else {
        let stale = staleReservationDecision(request: request, requestBinding: requestBinding)
        return TatwoLocalLoopAdmissionResultV1(
          request: request,
          requestBinding: requestBinding,
          reservation: reservation,
          admissionDecision: admission,
          spawnDecision: stale,
          enqueued: didRecordEnqueue,
          spawned: false)
      }
      await recorder.recordCancel(request: request, decision: spawnDecision)
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: requestBinding,
        reservation: reservation,
        admissionDecision: admission,
        spawnDecision: spawnDecision,
        enqueued: didRecordEnqueue,
        spawned: false)
    }

    guard spawnDecision.authorizesSpawn else {
      let unauthorized = spawnNotAuthorizedDecision(
        request: request,
        requestBinding: requestBinding,
        reservation: reservation,
        sourceDecision: spawnDecision)
      guard transition(
        reservation: reservation,
        from: .admittedNotSpawned,
        to: .terminal,
        reasonCode: unauthorized.reasonCode,
        decision: unauthorized,
        terminalDigest: decisionDigest(unauthorized))
      else {
        let stale = staleReservationDecision(request: request, requestBinding: requestBinding)
        return TatwoLocalLoopAdmissionResultV1(
          request: request,
          requestBinding: requestBinding,
          reservation: reservation,
          admissionDecision: admission,
          spawnDecision: stale,
          enqueued: didRecordEnqueue,
          spawned: false)
      }
      await recorder.recordCancel(request: request, decision: unauthorized)
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: requestBinding,
        reservation: reservation,
        admissionDecision: admission,
        spawnDecision: unauthorized,
        enqueued: didRecordEnqueue,
        spawned: false)
    }

    if let authorityRejection = await spawnAuthorityFence?(
      request,
      requestBinding,
      reservation,
      spawnDecision)
    {
      guard transition(
        reservation: reservation,
        from: .admittedNotSpawned,
        to: .terminal,
        reasonCode: authorityRejection.reasonCode,
        decision: authorityRejection,
        terminalDigest: decisionDigest(authorityRejection))
      else {
        let stale = staleReservationDecision(request: request, requestBinding: requestBinding)
        return TatwoLocalLoopAdmissionResultV1(
          request: request,
          requestBinding: requestBinding,
          reservation: reservation,
          admissionDecision: admission,
          spawnDecision: stale,
          enqueued: didRecordEnqueue,
          spawned: false)
      }
      await recorder.recordCancel(request: request, decision: authorityRejection)
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: requestBinding,
        reservation: reservation,
        admissionDecision: admission,
        spawnDecision: authorityRejection,
        enqueued: didRecordEnqueue,
        spawned: false)
    }

    if defersEnqueueRecordUntilSpawnAuthority {
      await recorder.recordEnqueue(request: request, decision: admission)
      didRecordEnqueue = true
    }

    guard transition(
      reservation: reservation,
      from: .admittedNotSpawned,
      to: .spawned,
      reasonCode: spawnDecision.reasonCode,
      decision: spawnDecision)
    else {
      let stale = staleReservationDecision(request: request, requestBinding: requestBinding)
      return TatwoLocalLoopAdmissionResultV1(
        request: request,
        requestBinding: requestBinding,
        reservation: reservation,
        admissionDecision: admission,
        spawnDecision: stale,
        enqueued: didRecordEnqueue,
        spawned: false)
    }

    await recorder.recordSpawn(request: request, decision: spawnDecision)
    return TatwoLocalLoopAdmissionResultV1(
      request: request,
      requestBinding: requestBinding,
      reservation: reservation,
      admissionDecision: admission,
      spawnDecision: spawnDecision,
      enqueued: didRecordEnqueue,
      spawned: true)
  }

  @discardableResult
  public func markOutcomeUnproven(
    reservation: TatwoLocalLoopAdmissionReservationV1,
    reasonCode: String
  ) -> Bool {
    transition(
      reservation: reservation,
      to: .outcomeUnproven,
      reasonCode: reasonCode,
      decision: nil)
  }

  @discardableResult
  public func markTerminal(
    reservation: TatwoLocalLoopAdmissionReservationV1,
    terminalDigest: String,
    reasonCode: String = "terminal_recorded"
  ) -> Bool {
    transition(
      reservation: reservation,
      to: .terminal,
      reasonCode: reasonCode,
      decision: nil,
      terminalDigest: terminalDigest)
  }

  public func journalSnapshot() -> [TatwoLocalLoopAdmissionJournalEntryV1] {
    journalEntries
  }

  public func journalChainVerifies() -> Bool {
    journalChainValid && TatwoLocalLoopAdmissionJournalEntryV1.verifiesChain(journalEntries)
  }

  public func rehydratedPhase(
    forJobID jobID: String
  ) -> TatwoLocalLoopAdmissionJournalPhaseV1? {
    slotsByJobID[jobID]?.phase
  }

  private func reserve(
    request: TatwoLoopAdmissionRequestV1,
    requestBinding: TatwoLoopAdmissionRequestBindingV1
  ) -> TatwoLocalLoopAdmissionReservationV1 {
    let generation = nextGeneration
    nextGeneration &+= 1
    let createdAt = clock.now()
    let reservationID = TatwoLoopJobDigest.sha256(
      Data("\(request.jobID)|\(requestBinding.requestBindingDigest)|\(generation)|\(createdAt.timeIntervalSince1970)".utf8))
    let reservation = TatwoLocalLoopAdmissionReservationV1(
      jobID: request.jobID,
      requestBindingDigest: requestBinding.requestBindingDigest,
      reservationID: reservationID,
      generation: generation,
      createdAt: createdAt)
    slotsByJobID[request.jobID] = ReservationSlot(
      binding: requestBinding,
      reservation: reservation,
      phase: .outcomeUnproven)
    return reservation
  }

  @discardableResult
  private func transition(
    reservation: TatwoLocalLoopAdmissionReservationV1,
    from expectedPhase: TatwoLocalLoopAdmissionJournalPhaseV1? = nil,
    to phase: TatwoLocalLoopAdmissionJournalPhaseV1,
    reasonCode: String,
    decision: TatwoLoopAdmissionDecisionV1?,
    terminalDigest: String? = nil
  ) -> Bool {
    guard journalChainValid,
      var slot = slotsByJobID[reservation.jobID],
      slot.reservation.reservationID == reservation.reservationID,
      slot.reservation.generation == reservation.generation,
      slot.reservation.requestBindingDigest == reservation.requestBindingDigest,
      expectedPhase == nil || slot.phase == expectedPhase,
      slot.phase != .terminal,
      phase != .terminal || terminalDigest != nil
    else {
      return false
    }
    var entry = TatwoLocalLoopAdmissionJournalEntryV1(
      reservation: reservation,
      phase: phase,
      recordedAt: clock.now(),
      reasonCode: reasonCode,
      decisionDigest: decision.flatMap { decisionDigest($0) },
      terminalDigest: terminalDigest,
      previousEntryDigest: journalEntries.last?.entryDigest)
    do {
      try entry.seal()
    } catch {
      journalChainValid = false
      return false
    }
    slot.phase = phase
    slotsByJobID[reservation.jobID] = slot
    journalEntries.append(entry)
    return true
  }

  private func duplicateDecision(
    request: TatwoLoopAdmissionRequestV1,
    requestBindingDigest: String?,
    existingPhase: TatwoLocalLoopAdmissionJournalPhaseV1?
  ) -> TatwoLoopAdmissionDecisionV1 {
    let reasonCode: String
    let reason: String
    switch existingPhase {
    case .admittedNotSpawned, .outcomeUnproven:
      reasonCode = "admission_outcome_unproven"
      reason = "pressure admission has an unproven previous enqueue or in-flight reservation"
    default:
      reasonCode = "admission_already_consumed"
      reason = "pressure admission is single-use per exact job binding"
    }
    return TatwoLoopAdmissionDecisionV1(
        deviceID: request.deviceID,
        loopID: request.loopID,
        workload: request.workload,
        decidedAt: clock.now(),
        classification: .unknown,
        accepted: false,
        reasonCode: reasonCode,
        reason: reason,
        stopAction: .none,
        leaseID: nil,
        requestBindingDigest: requestBindingDigest)
  }

  private func bindingMismatchDecision(
    request: TatwoLoopAdmissionRequestV1,
    requestBinding: TatwoLoopAdmissionRequestBindingV1
  ) -> TatwoLoopAdmissionDecisionV1 {
    TatwoLoopAdmissionDecisionV1(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      decidedAt: clock.now(),
      classification: .unknown,
      accepted: false,
      reasonCode: "request_binding_digest_mismatch",
      reason: "pressure admission request bytes do not match the reserved request binding",
      stopAction: .none,
      leaseID: nil,
      requestBindingDigest: requestBinding.requestBindingDigest)
  }

  private func journalChainInvalidDecision(
    request: TatwoLoopAdmissionRequestV1,
    requestBindingDigest: String?
  ) -> TatwoLoopAdmissionDecisionV1 {
    TatwoLoopAdmissionDecisionV1(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      decidedAt: clock.now(),
      classification: .unknown,
      accepted: false,
      reasonCode: "admission_journal_chain_invalid",
      reason: "pressure admission journal failed tamper-evident chain verification and is quarantined",
      stopAction: .checkpointExistingWork,
      leaseID: nil,
      requestBindingDigest: requestBindingDigest)
  }

  private func acceptedDecisionMatchesReservation(
    _ decision: TatwoLoopAdmissionDecisionV1,
    request: TatwoLoopAdmissionRequestV1,
    requestBinding: TatwoLoopAdmissionRequestBindingV1,
    reservation: TatwoLocalLoopAdmissionReservationV1
  ) -> Bool {
    guard decision.accepted else { return true }
    guard decision.requestBindingDigest == requestBinding.requestBindingDigest,
      decision.dispatchNonce == request.dispatchNonce,
      decision.reservationID == reservation.reservationID
    else {
      return false
    }
    guard let runtimeInstanceID,
      decision.runtimeInstanceID == runtimeInstanceID,
      let runtimeGeneration,
      decision.runtimeGeneration == runtimeGeneration,
      let attemptID = request.attemptID,
      decision.admissionAttemptID == attemptID,
      decision.sourceSnapshotSequence != nil,
      decision.sourceSampleAttemptID != nil
    else {
      return false
    }
    return true
  }

  private func spawnNotAuthorizedDecision(
    request: TatwoLoopAdmissionRequestV1,
    requestBinding: TatwoLoopAdmissionRequestBindingV1,
    reservation: TatwoLocalLoopAdmissionReservationV1,
    sourceDecision: TatwoLoopAdmissionDecisionV1
  ) -> TatwoLoopAdmissionDecisionV1 {
    TatwoLoopAdmissionDecisionV1(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      decidedAt: clock.now(),
      classification: .unknown,
      accepted: false,
      reasonCode: "spawn_not_authorized_by_pressure_decision",
      reason: "pressure admission decision accepted continuation but did not authorize enqueue or spawn",
      stopAction: .none,
      leaseID: sourceDecision.leaseID,
      requestBindingDigest: requestBinding.requestBindingDigest,
      runtimeInstanceID: sourceDecision.runtimeInstanceID,
      runtimeGeneration: sourceDecision.runtimeGeneration,
      admissionAttemptID: sourceDecision.admissionAttemptID,
      dispatchNonce: sourceDecision.dispatchNonce,
      reservationID: reservation.reservationID,
      sourceSnapshotSequence: sourceDecision.sourceSnapshotSequence,
      sourceSampleAttemptID: sourceDecision.sourceSampleAttemptID,
      leaseDigest: sourceDecision.leaseDigest)
  }

  private func decisionDigest(_ decision: TatwoLoopAdmissionDecisionV1) -> String? {
    try? TatwoPressureServiceDigest.canonicalJSONDigest(decision)
  }

  private func staleReservationDecision(
    request: TatwoLoopAdmissionRequestV1,
    requestBinding: TatwoLoopAdmissionRequestBindingV1
  ) -> TatwoLoopAdmissionDecisionV1 {
    TatwoLoopAdmissionDecisionV1(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      decidedAt: clock.now(),
      classification: .unknown,
      accepted: false,
      reasonCode: "admission_reservation_stale",
      reason: "pressure admission spawn callback did not own the current reservation generation",
      stopAction: .checkpointExistingWork,
      leaseID: nil,
      requestBindingDigest: requestBinding.requestBindingDigest)
  }
}

fileprivate enum TatwoPressureServiceText {
  static func safeIdentifier(_ value: String, fallback: String) -> String {
    isSafeIdentifier(value) ? value : fallback
  }

  static func safeIdentifierOrDigest(_ value: String, fallback: String) -> String {
    if isSafeIdentifier(value) || isSHA256Digest(value) { return value }
    return fallback
  }

  static func safeSHA256Digest(_ value: String, fallback: String) -> String {
    isSHA256Digest(value) ? value : fallback
  }

  static func safeReasonCode(_ value: String, fallback: String) -> String {
    let redacted = redacted(value)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "_")
      .replacingOccurrences(of: "-", with: "_")
    let allowed = redacted.filter { character in
      character.isLetter || character.isNumber || character == "_" || character == ":" || character == "."
    }
    return allowed.isEmpty ? fallback : String(allowed.prefix(160))
  }

  static func redacted(_ value: String) -> String {
    String(TatwoPrivacyRedactor.redacted(value).prefix(512))
  }

  static func isSHA256Digest(_ value: String) -> Bool {
    let allowedHex = Set("0123456789abcdef")
    return value.hasPrefix("sha256:")
      && value.count == 71
      && value.dropFirst("sha256:".count).allSatisfy { character in
        allowedHex.contains(character)
      }
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && !value.contains("\0")
      && value.count <= 128
      && value.range(of: #"^[A-Za-z0-9._:\-]+$"#, options: .regularExpression) != nil
  }
}


fileprivate enum TatwoPressureServiceDigest {
  static func canonicalJSONData<T: Encodable>(_ value: T) throws -> Data {
    try TatwoPressureCanonicalJSONV1.data(value)
  }

  static func canonicalJSONDigest<T: Encodable>(_ value: T) throws -> String {
    try TatwoPressureCanonicalJSONV1.digest(value)
  }
}
