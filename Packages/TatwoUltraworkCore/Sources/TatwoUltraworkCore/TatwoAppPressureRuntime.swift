import Foundation

public enum TatwoAppPressureRuntimeLifecycleReasonV1: String, Codable, Sendable, Equatable {
  case appLaunch = "app_launch"
  case manualStart = "manual_start"
  case appWillTerminate = "app_will_terminate"
  case appDidSuspend = "app_did_suspend"
  case serviceRestart = "service_restart"
  case test = "test"
}

public enum TatwoAppPressureRuntimeEventKindV1: String, Codable, Sendable, Equatable {
  case started
  case stopped
  case sampled
  case leaseIssued = "lease_issued"
  case leaseUnavailable = "lease_unavailable"
  case lifecycleRejected = "lifecycle_rejected"
  case summaryReceiptRecorded = "summary_receipt_recorded"
  case summaryReceiptFailed = "summary_receipt_failed"
}

public struct TatwoAppPressureRuntimeEventV1: Codable, Sendable, Equatable {
  public let schema: String
  public let kind: TatwoAppPressureRuntimeEventKindV1
  public let recordedAt: Date
  public let reason: String
  public let samplingReason: TatwoPressureSamplingReasonV1?
  public let classification: TatwoPressureClassificationV1?
  public let leaseID: String?
  public let receiptDigest: String?

  public init(
    schema: String = "TatwoAppPressureRuntimeEventV1",
    kind: TatwoAppPressureRuntimeEventKindV1,
    recordedAt: Date,
    reason: String,
    samplingReason: TatwoPressureSamplingReasonV1? = nil,
    classification: TatwoPressureClassificationV1? = nil,
    leaseID: String? = nil,
    receiptDigest: String? = nil
  ) {
    self.schema = schema
    self.kind = kind
    self.recordedAt = recordedAt
    self.reason = TatwoAppPressureRuntimeText.safeReasonCode(
      reason,
      fallback: "pressure_runtime_event")
    self.samplingReason = samplingReason
    self.classification = classification
    self.leaseID = leaseID.map {
      TatwoAppPressureRuntimeText.safeSHA256Digest($0, fallback: "invalid-lease-id")
    }
    self.receiptDigest = receiptDigest.map {
      TatwoAppPressureRuntimeText.safeSHA256Digest($0, fallback: "invalid-receipt-digest")
    }
  }
}

public struct TatwoAppPressureRuntimeEventSinkV1: Sendable {
  private let recordHandler: @Sendable (TatwoAppPressureRuntimeEventV1) async -> Void

  public init(
    record: @escaping @Sendable (TatwoAppPressureRuntimeEventV1) async -> Void = { _ in }
  ) {
    self.recordHandler = record
  }

  public func record(_ event: TatwoAppPressureRuntimeEventV1) async {
    await recordHandler(event)
  }
}

public struct TatwoAppPressureRuntimeLifecycleResetV1: Sendable {
  private let resetHandler: @Sendable () async -> Void

  public init(
    reset: @escaping @Sendable () async -> Void = {}
  ) {
    self.resetHandler = reset
  }

  public func reset() async {
    await resetHandler()
  }
}

public enum TatwoAppPressureRuntimeOperationStatusV1: String, Codable, Sendable, Equatable {
  case applied
  case monitorStopped = "monitor_stopped"
  case staleGeneration = "stale_generation"
}

public struct TatwoAppPressureRuntimeProjectionOutcomeV1: Codable, Sendable, Equatable {
  public let schema: String
  public let status: TatwoAppPressureRuntimeOperationStatusV1
  public let runtimeInstanceID: String
  public let requestedGeneration: UInt64
  public let currentGeneration: UInt64
  public let projection: TatwoPressureUIProjectionV1

  public init(
    schema: String = "TatwoAppPressureRuntimeProjectionOutcomeV1",
    status: TatwoAppPressureRuntimeOperationStatusV1,
    runtimeInstanceID: String,
    requestedGeneration: UInt64,
    currentGeneration: UInt64,
    projection: TatwoPressureUIProjectionV1
  ) {
    self.schema = schema
    self.status = status
    self.runtimeInstanceID = TatwoAppPressureRuntimeText.safeIdentifier(
      runtimeInstanceID,
      fallback: "invalid-runtime-instance-id")
    self.requestedGeneration = requestedGeneration
    self.currentGeneration = currentGeneration
    self.projection = projection
  }
}

public struct TatwoAppPressureRuntimeLeaseOutcomeV1: Codable, Sendable, Equatable {
  public let schema: String
  public let status: TatwoAppPressureRuntimeOperationStatusV1
  public let runtimeInstanceID: String
  public let requestedGeneration: UInt64
  public let currentGeneration: UInt64
  public let lease: TatwoPressureLeaseV1?
  public let projection: TatwoPressureUIProjectionV1?

  public init(
    schema: String = "TatwoAppPressureRuntimeLeaseOutcomeV1",
    status: TatwoAppPressureRuntimeOperationStatusV1,
    runtimeInstanceID: String,
    requestedGeneration: UInt64,
    currentGeneration: UInt64,
    lease: TatwoPressureLeaseV1?,
    projection: TatwoPressureUIProjectionV1?
  ) {
    self.schema = schema
    self.status = status
    self.runtimeInstanceID = TatwoAppPressureRuntimeText.safeIdentifier(
      runtimeInstanceID,
      fallback: "invalid-runtime-instance-id")
    self.requestedGeneration = requestedGeneration
    self.currentGeneration = currentGeneration
    self.lease = lease
    self.projection = projection
  }
}

public struct TatwoAppPressureRuntimeAuthoritySnapshotV1: Sendable, Equatable {
  public let runtimeInstanceID: String
  public let currentGeneration: UInt64
  public let isRunning: Bool

  public init(
    runtimeInstanceID: String,
    currentGeneration: UInt64,
    isRunning: Bool
  ) {
    self.runtimeInstanceID = TatwoAppPressureRuntimeText.safeIdentifier(
      runtimeInstanceID,
      fallback: "invalid-runtime-instance-id")
    self.currentGeneration = currentGeneration
    self.isRunning = isRunning
  }
}

public enum TatwoAppPressureRuntimeSpawnAuthorityValidationFailureV1: String, Error, Sendable, Equatable {
  case runtimeNotRunning = "runtime_not_running"
  case runtimeInstanceMismatch = "runtime_instance_mismatch"
  case runtimeGenerationMismatch = "runtime_generation_mismatch"
}

private final class TatwoAppPressureRuntimeAuthorityCellV1: @unchecked Sendable {
  private let lock = NSLock()
  private let runtimeInstanceID: String
  private var generation: UInt64
  private var running: Bool

  init(
    runtimeInstanceID: String,
    generation: UInt64 = 0,
    running: Bool = false
  ) {
    self.runtimeInstanceID = runtimeInstanceID
    self.generation = generation
    self.running = running
  }

  func update(generation: UInt64, running: Bool) {
    lock.withLock {
      self.generation = generation
      self.running = running
    }
  }

  func snapshot() -> TatwoAppPressureRuntimeAuthoritySnapshotV1 {
    lock.withLock {
      TatwoAppPressureRuntimeAuthoritySnapshotV1(
        runtimeInstanceID: runtimeInstanceID,
        currentGeneration: generation,
        isRunning: running)
    }
  }

  func validateForSpawnAuthority<T>(
    expectedRuntimeInstanceID: String,
    expectedGeneration: UInt64,
    _ body: () -> T
  ) -> T? {
    switch validateForSpawnAuthorityResult(
      expectedRuntimeInstanceID: expectedRuntimeInstanceID,
      expectedGeneration: expectedGeneration,
      body) {
    case .success(let value):
      return value
    case .failure:
      return nil
    }
  }

  func validateForSpawnAuthorityResult<T>(
    expectedRuntimeInstanceID: String,
    expectedGeneration: UInt64,
    _ body: () -> T
  ) -> Result<T, TatwoAppPressureRuntimeSpawnAuthorityValidationFailureV1> {
    lock.withLock {
      guard running else {
        return .failure(.runtimeNotRunning)
      }
      guard runtimeInstanceID == expectedRuntimeInstanceID else {
        return .failure(.runtimeInstanceMismatch)
      }
      guard generation == expectedGeneration else {
        return .failure(.runtimeGenerationMismatch)
      }
      return .success(body())
    }
  }
}

/// App-owned monitor runtime that binds sampler lifecycle, cadence ticks, lease
/// signing, and hash-chained summaries into one authority surface.
///
/// The runtime never grants admission from UI state. UI projection is derived
/// from the service's latest sampler truth only, and `stop`/`restart` clears the
/// service snapshot so old green leases cannot be reused after App lifecycle
/// changes.
public actor TatwoAppPressureRuntimeV1 {
  private let sampler: TatwoAppPressureSamplerV1
  private let service: TatwoAppPressureServiceV1
  public let configuration: TatwoAppPressureSamplerConfigurationV1
  public let runtimeInstanceID: String

  private let clock: TatwoPressureClockV1
  private let eventSink: TatwoAppPressureRuntimeEventSinkV1
  private let lifecycleReset: TatwoAppPressureRuntimeLifecycleResetV1
  private var sampleCadenceTask: Task<Void, Never>?
  private var leaseCadenceTask: Task<Void, Never>?
  private var summaryCadenceTask: Task<Void, Never>?
  private var running = false
  private var generation: UInt64 = 0
  private var latestLease: TatwoPressureLeaseV1?
  private var latestProjection: TatwoPressureUIProjectionV1?
  private var latestSummaryReceipt: TatwoHostPressureReceiptV1?
  private let authorityCell: TatwoAppPressureRuntimeAuthorityCellV1

  public init(
    sampler: TatwoAppPressureSamplerV1,
    service: TatwoAppPressureServiceV1? = nil,
    clock: TatwoPressureClockV1 = TatwoPressureClockV1(),
    configuration: TatwoAppPressureSamplerConfigurationV1? = nil,
    eventSink: TatwoAppPressureRuntimeEventSinkV1 = TatwoAppPressureRuntimeEventSinkV1(),
    lifecycleReset: TatwoAppPressureRuntimeLifecycleResetV1 = TatwoAppPressureRuntimeLifecycleResetV1(),
    runtimeInstanceID: String = "runtime-\(UUID().uuidString.lowercased())"
  ) {
    let sanitizedRuntimeInstanceID = TatwoAppPressureRuntimeText.safeIdentifier(
      runtimeInstanceID,
      fallback: "invalid-runtime-instance-id")
    self.sampler = sampler
    self.configuration = configuration ?? sampler.configuration
    self.runtimeInstanceID = sanitizedRuntimeInstanceID
    self.clock = clock
    self.service = service ?? TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: clock,
      configuration: configuration)
    self.eventSink = eventSink
    self.lifecycleReset = lifecycleReset
    self.authorityCell = TatwoAppPressureRuntimeAuthorityCellV1(
      runtimeInstanceID: sanitizedRuntimeInstanceID)
  }

  public var isRunning: Bool { running }

  public var currentGeneration: UInt64 { generation }

  public func currentLease() -> TatwoPressureLeaseV1? { latestLease }

  public func currentProjection() -> TatwoPressureUIProjectionV1? { latestProjection }

  public func freshProjection() async -> TatwoPressureUIProjectionV1? {
    let capturedGeneration = generation
    guard running else {
      return latestProjection ?? stoppedProjection(reason: "monitor_stopped")
    }
    let projection = await service.uiProjection()
    guard running, generation == capturedGeneration else {
      return latestProjection ?? stoppedProjection(reason: "monitor_generation_stale")
    }
    latestProjection = projection
    return projection
  }

  public func currentSummaryReceipt() -> TatwoHostPressureReceiptV1? { latestSummaryReceipt }

  public func authoritySnapshot() -> TatwoAppPressureRuntimeAuthoritySnapshotV1 {
    TatwoAppPressureRuntimeAuthoritySnapshotV1(
      runtimeInstanceID: runtimeInstanceID,
      currentGeneration: generation,
      isRunning: running)
  }

  public nonisolated func validateSynchronousSpawnAuthority<T>(
    runtimeInstanceID expectedRuntimeInstanceID: String,
    generation expectedGeneration: UInt64,
    _ body: () -> T
  ) -> T? {
    authorityCell.validateForSpawnAuthority(
      expectedRuntimeInstanceID: TatwoAppPressureRuntimeText.safeIdentifier(
        expectedRuntimeInstanceID,
        fallback: "invalid-runtime-instance-id"),
      expectedGeneration: expectedGeneration,
      body)
  }

  public nonisolated func validateSynchronousSpawnAuthorityResult<T>(
    runtimeInstanceID expectedRuntimeInstanceID: String,
    generation expectedGeneration: UInt64,
    _ body: () -> T
  ) -> Result<T, TatwoAppPressureRuntimeSpawnAuthorityValidationFailureV1> {
    authorityCell.validateForSpawnAuthorityResult(
      expectedRuntimeInstanceID: TatwoAppPressureRuntimeText.safeIdentifier(
        expectedRuntimeInstanceID,
        fallback: "invalid-runtime-instance-id"),
      expectedGeneration: expectedGeneration,
      body)
  }

  public func start(
    reason: TatwoAppPressureRuntimeLifecycleReasonV1 = .appLaunch,
    startTimers: Bool = true
  ) async {
    guard !running else { return }
    generation &+= 1
    let startGeneration = generation
    running = true
    authorityCell.update(generation: generation, running: running)
    let startApplied = await service.startAppOwnedMonitoring(generation: startGeneration)
    guard startApplied, running, generation == startGeneration else {
      if generation == startGeneration {
        running = false
        authorityCell.update(generation: generation, running: running)
        latestLease = nil
        latestSummaryReceipt = nil
        latestProjection = stoppedProjection(reason: "monitor_generation_stale")
      }
      return
    }
    await eventSink.record(TatwoAppPressureRuntimeEventV1(
      kind: .started,
      recordedAt: clock.now(),
      reason: reason.rawValue))
    _ = await sampleAndPublish(reason: .appLaunch, generation: startGeneration)
    if startTimers {
      startCadenceTasks(generation: startGeneration)
    }
  }

  public func stop(
    reason: TatwoAppPressureRuntimeLifecycleReasonV1 = .appWillTerminate
  ) async {
    guard running else { return }
    generation &+= 1
    let stopGeneration = generation
    stopCadenceTasks()
    running = false
    authorityCell.update(generation: generation, running: running)
    latestLease = nil
    latestSummaryReceipt = nil
    latestProjection = stoppedProjection(reason: reason.rawValue)
    let stopApplied = await service.stopAppOwnedMonitoring(generation: stopGeneration)
    guard stopApplied else {
      await recordLifecycleRejected(
        reason: "\(reason.rawValue)_stop_rejected",
        generation: stopGeneration)
      return
    }
    guard generation == stopGeneration, !running else {
      await recordLifecycleRejected(
        reason: "\(reason.rawValue)_superseded",
        generation: stopGeneration)
      return
    }
    await lifecycleReset.reset()
    guard generation == stopGeneration, !running else {
      await recordLifecycleRejected(
        reason: "\(reason.rawValue)_superseded_after_reset",
        generation: stopGeneration)
      return
    }
    latestProjection = stoppedProjection(reason: reason.rawValue)
    await eventSink.record(TatwoAppPressureRuntimeEventV1(
      kind: .stopped,
      recordedAt: clock.now(),
      reason: reason.rawValue,
      classification: .unknown))
  }

  public func restart(
    reason: TatwoAppPressureRuntimeLifecycleReasonV1 = .serviceRestart,
    startTimers: Bool = true
  ) async {
    await stop(reason: reason)
    await start(reason: reason, startTimers: startTimers)
  }

  public func setLoopState(
    loopID: String?,
    workers: [TatwoPressureWorkerV1]
  ) async {
    await sampler.setActiveLoop(loopID: loopID, workers: workers)
  }

  @discardableResult
  public func sampleCadenceTick() async -> TatwoAppPressureRuntimeProjectionOutcomeV1 {
    let capturedGeneration = generation
    let reason: TatwoPressureSamplingReasonV1 = await sampler.mode() == .activeLoop
      ? .activeLoopCadence
      : .idleCadence
    return await sampleAndPublish(reason: reason, generation: capturedGeneration)
  }

  @discardableResult
  public func sampleCadenceTickOutcome() async -> TatwoAppPressureRuntimeProjectionOutcomeV1 {
    await sampleCadenceTick()
  }

  @discardableResult
  public func leaseCadenceTick() async -> TatwoAppPressureRuntimeLeaseOutcomeV1 {
    let capturedGeneration = generation
    guard running else {
      latestLease = nil
      return TatwoAppPressureRuntimeLeaseOutcomeV1(
        status: .monitorStopped,
        runtimeInstanceID: runtimeInstanceID,
        requestedGeneration: capturedGeneration,
        currentGeneration: generation,
        lease: nil,
        projection: latestProjection ?? stoppedProjection(reason: "monitor_stopped"))
    }
    let lease = await service.sampleAndIssueLease(
      reason: .leaseTick,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: capturedGeneration)
    guard running, generation == capturedGeneration else {
      return TatwoAppPressureRuntimeLeaseOutcomeV1(
        status: .staleGeneration,
        runtimeInstanceID: runtimeInstanceID,
        requestedGeneration: capturedGeneration,
        currentGeneration: generation,
        lease: nil,
        projection: latestProjection ?? stoppedProjection(reason: "monitor_generation_stale"))
    }
    latestLease = lease
    let projection = await service.uiProjection()
    guard running, generation == capturedGeneration else {
      return TatwoAppPressureRuntimeLeaseOutcomeV1(
        status: .staleGeneration,
        runtimeInstanceID: runtimeInstanceID,
        requestedGeneration: capturedGeneration,
        currentGeneration: generation,
        lease: nil,
        projection: latestProjection ?? stoppedProjection(reason: "monitor_generation_stale"))
    }
    latestProjection = projection
    await eventSink.record(TatwoAppPressureRuntimeEventV1(
      kind: lease == nil ? .leaseUnavailable : .leaseIssued,
      recordedAt: clock.now(),
      reason: "lease_tick",
      samplingReason: .leaseTick,
      classification: latestProjection?.displayClassification,
      leaseID: lease?.leaseID))
    return TatwoAppPressureRuntimeLeaseOutcomeV1(
      status: .applied,
      runtimeInstanceID: runtimeInstanceID,
      requestedGeneration: capturedGeneration,
      currentGeneration: generation,
      lease: lease,
      projection: projection)
  }

  @discardableResult
  public func leaseCadenceTickOutcome() async -> TatwoAppPressureRuntimeLeaseOutcomeV1 {
    await leaseCadenceTick()
  }

  @discardableResult
  public func summaryCadenceTick() async -> TatwoHostPressureReceiptV1? {
    let capturedGeneration = generation
    guard running else { return nil }
    do {
      let receipt = try await service.recordSummaryReceipt(reason: .summaryReceipt)
      guard running, generation == capturedGeneration else {
        return nil
      }
      latestSummaryReceipt = receipt
      let projection = await service.uiProjection()
      guard running, generation == capturedGeneration else {
        return nil
      }
      latestProjection = projection
      await eventSink.record(TatwoAppPressureRuntimeEventV1(
        kind: .summaryReceiptRecorded,
        recordedAt: clock.now(),
        reason: "summary_receipt",
        samplingReason: .summaryReceipt,
        classification: receipt.classification.classification,
        leaseID: receipt.lease?.leaseID,
        receiptDigest: receipt.receiptDigest))
      return receipt
    } catch {
      await eventSink.record(TatwoAppPressureRuntimeEventV1(
        kind: .summaryReceiptFailed,
        recordedAt: clock.now(),
        reason: "summary_receipt_failed",
        samplingReason: .summaryReceipt,
        classification: .unknown))
      return nil
    }
  }

  @discardableResult
  public func preAdmissionDecision(
    for request: TatwoLoopAdmissionRequestV1,
    requestBinding: TatwoLoopAdmissionRequestBindingV1,
    samplingReason: TatwoPressureSamplingReasonV1 = .preAdmissionImmediate,
    reservationID: String? = nil
  ) async -> TatwoLoopAdmissionDecisionV1 {
    let capturedGeneration = generation
    guard running else {
      return stoppedDecision(
        for: request,
        requestBindingDigest: requestBinding.requestBindingDigest,
        reasonCode: "monitor_unknown",
        reason: "Tatwo App pressure runtime is not running")
    }
    guard request.hasExactAttemptBinding else {
      return attemptBindingMissingDecision(
        for: request,
        requestBindingDigest: requestBinding.requestBindingDigest,
        generation: capturedGeneration)
    }
    guard let reservationID,
      TatwoAppPressureRuntimeText.isSHA256Digest(reservationID)
    else {
      return stoppedDecision(
        for: request,
        requestBindingDigest: requestBinding.requestBindingDigest,
        reasonCode: "pressure_pre_admission_reservation_missing",
        reason: "Tatwo App pressure runtime pre-admission cannot authorize spawn without a well-formed reservation digest",
        runtimeGeneration: capturedGeneration,
        admissionAttemptID: request.attemptID)
    }
    let decision = await service.admissionDecision(
      for: request,
      refreshPolicy: .sampleImmediately,
      samplingReason: samplingReason == .preSpawnRecheck ? .preSpawnRecheck : .preAdmissionImmediate,
      requestBinding: requestBinding,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: capturedGeneration,
      admissionAttemptID: request.attemptID,
      reservationID: reservationID)
    guard running, generation == capturedGeneration else {
      return stoppedDecision(
        for: request,
        requestBindingDigest: requestBinding.requestBindingDigest,
        reasonCode: "monitor_generation_stale",
        reason: "Tatwo App pressure runtime generation changed before admission could be consumed",
        runtimeGeneration: capturedGeneration,
        admissionAttemptID: request.attemptID)
    }
    return decision
  }

  @discardableResult
  private func sampleAndPublish(
    reason: TatwoPressureSamplingReasonV1,
    generation capturedGeneration: UInt64
  ) async -> TatwoAppPressureRuntimeProjectionOutcomeV1 {
    guard running, generation == capturedGeneration else {
      return projectionOutcome(
        status: running ? .staleGeneration : .monitorStopped,
        requestedGeneration: capturedGeneration,
        projection: staleCompletionProjection(
        fallbackReason: "monitor_stopped",
        generation: capturedGeneration))
    }
    let lease = await service.sampleAndIssueLease(
      reason: reason,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: capturedGeneration)
    guard running, generation == capturedGeneration else {
      return projectionOutcome(
        status: .staleGeneration,
        requestedGeneration: capturedGeneration,
        projection: staleCompletionProjection(
        fallbackReason: "monitor_generation_stale",
        generation: capturedGeneration))
    }
    latestLease = lease
    let projection = await service.uiProjection()
    guard running, generation == capturedGeneration else {
      return projectionOutcome(
        status: .staleGeneration,
        requestedGeneration: capturedGeneration,
        projection: staleCompletionProjection(
        fallbackReason: "monitor_generation_stale",
        generation: capturedGeneration))
    }
    latestProjection = projection
    await eventSink.record(TatwoAppPressureRuntimeEventV1(
      kind: .sampled,
      recordedAt: clock.now(),
      reason: reason.rawValue,
      samplingReason: reason,
      classification: projection.displayClassification,
      leaseID: lease?.leaseID))
    if reason == .leaseTick {
      await eventSink.record(TatwoAppPressureRuntimeEventV1(
        kind: lease == nil ? .leaseUnavailable : .leaseIssued,
        recordedAt: clock.now(),
        reason: reason.rawValue,
        samplingReason: reason,
        classification: projection.displayClassification,
        leaseID: lease?.leaseID))
    }
    return projectionOutcome(
      status: .applied,
      requestedGeneration: capturedGeneration,
      projection: projection)
  }

  private func startCadenceTasks(generation taskGeneration: UInt64) {
    stopCadenceTasks()
    sampleCadenceTask = Task { [configuration] in
      while !Task.isCancelled {
        let mode = await self.sampler.mode()
        let cadence = configuration.cadenceSeconds(for: mode) ?? configuration.idleCadenceSeconds
        await TatwoAppPressureRuntimeV1.sleep(seconds: cadence)
        guard !Task.isCancelled else { return }
        await self.sampleCadenceTick(generation: taskGeneration)
      }
    }
    leaseCadenceTask = Task { [configuration] in
      while !Task.isCancelled {
        await TatwoAppPressureRuntimeV1.sleep(seconds: configuration.leaseCadenceSeconds)
        guard !Task.isCancelled else { return }
        await self.leaseCadenceTick(generation: taskGeneration)
      }
    }
    summaryCadenceTask = Task { [configuration] in
      while !Task.isCancelled {
        await TatwoAppPressureRuntimeV1.sleep(seconds: configuration.receiptSummaryCadenceSeconds)
        guard !Task.isCancelled else { return }
        _ = await self.summaryCadenceTick(generation: taskGeneration)
      }
    }
  }

  @discardableResult
  private func sampleCadenceTick(generation taskGeneration: UInt64) async -> TatwoPressureUIProjectionV1 {
    let reason: TatwoPressureSamplingReasonV1 = await sampler.mode() == .activeLoop
      ? .activeLoopCadence
      : .idleCadence
    return await sampleAndPublish(reason: reason, generation: taskGeneration).projection
  }

  @discardableResult
  private func leaseCadenceTick(generation taskGeneration: UInt64) async -> TatwoPressureLeaseV1? {
    guard running, generation == taskGeneration else {
      if generation == taskGeneration {
        latestLease = nil
      }
      return nil
    }
    let lease = await service.sampleAndIssueLease(
      reason: .leaseTick,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: taskGeneration)
    guard running, generation == taskGeneration else {
      return nil
    }
    latestLease = lease
    let projection = await service.uiProjection()
    guard running, generation == taskGeneration else {
      return nil
    }
    latestProjection = projection
    await eventSink.record(TatwoAppPressureRuntimeEventV1(
      kind: lease == nil ? .leaseUnavailable : .leaseIssued,
      recordedAt: clock.now(),
      reason: "lease_tick",
      samplingReason: .leaseTick,
      classification: latestProjection?.displayClassification,
      leaseID: lease?.leaseID))
    return lease
  }

  @discardableResult
  private func summaryCadenceTick(generation taskGeneration: UInt64) async -> TatwoHostPressureReceiptV1? {
    guard running, generation == taskGeneration else { return nil }
    do {
      let receipt = try await service.recordSummaryReceipt(reason: .summaryReceipt)
      guard running, generation == taskGeneration else {
        return nil
      }
      latestSummaryReceipt = receipt
      let projection = await service.uiProjection()
      guard running, generation == taskGeneration else {
        return nil
      }
      latestProjection = projection
      await eventSink.record(TatwoAppPressureRuntimeEventV1(
        kind: .summaryReceiptRecorded,
        recordedAt: clock.now(),
        reason: "summary_receipt",
        samplingReason: .summaryReceipt,
        classification: receipt.classification.classification,
        leaseID: receipt.lease?.leaseID,
        receiptDigest: receipt.receiptDigest))
      return receipt
    } catch {
      await eventSink.record(TatwoAppPressureRuntimeEventV1(
        kind: .summaryReceiptFailed,
        recordedAt: clock.now(),
        reason: "summary_receipt_failed",
        samplingReason: .summaryReceipt,
        classification: .unknown))
      return nil
    }
  }

  private func stopCadenceTasks() {
    sampleCadenceTask?.cancel()
    leaseCadenceTask?.cancel()
    summaryCadenceTask?.cancel()
    sampleCadenceTask = nil
    leaseCadenceTask = nil
    summaryCadenceTask = nil
  }

  private func staleCompletionProjection(
    fallbackReason: String,
    generation capturedGeneration: UInt64
  ) -> TatwoPressureUIProjectionV1 {
    guard generation == capturedGeneration else {
      return latestProjection ?? stoppedProjection(reason: fallbackReason)
    }
    let projection = stoppedProjection(reason: fallbackReason)
    latestLease = nil
    latestProjection = projection
    return projection
  }

  private func recordLifecycleRejected(
    reason: String,
    generation _: UInt64
  ) async {
    await eventSink.record(TatwoAppPressureRuntimeEventV1(
      kind: .lifecycleRejected,
      recordedAt: clock.now(),
      reason: reason,
      classification: .unknown))
  }

  nonisolated private static func sleep(seconds: TimeInterval) async {
    let bounded = max(0.001, min(seconds, 86_400))
    let nanoseconds = UInt64((bounded * 1_000_000_000).rounded())
    try? await Task.sleep(nanoseconds: nanoseconds)
  }

  private func stoppedProjection(reason: String) -> TatwoPressureUIProjectionV1 {
    TatwoPressureUIProjectionV1(
      deviceID: sampler.deviceID,
      displayClassification: .unknown,
      lastObservedAt: nil,
      activeLoopID: nil,
      workerIDs: [],
      stopReason: reason,
      canRequestLightLoop: false,
      canRequestHeavyLoop: false)
  }

  private func stoppedDecision(
    for request: TatwoLoopAdmissionRequestV1,
    requestBindingDigest: String?,
    reasonCode: String = "monitor_unknown",
    reason: String = "Tatwo App pressure runtime is not admitting work",
    runtimeGeneration: UInt64? = nil,
    admissionAttemptID: String? = nil
  ) -> TatwoLoopAdmissionDecisionV1 {
    TatwoLoopAdmissionDecisionV1(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      decidedAt: clock.now(),
      classification: .unknown,
      accepted: false,
      reasonCode: reasonCode,
      reason: reason,
      stopAction: .checkpointExistingWork,
      leaseID: nil,
      requestBindingDigest: requestBindingDigest,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: admissionAttemptID ?? request.attemptID)
  }

  private func attemptBindingMissingDecision(
    for request: TatwoLoopAdmissionRequestV1,
    requestBindingDigest: String?,
    generation: UInt64
  ) -> TatwoLoopAdmissionDecisionV1 {
    TatwoLoopAdmissionDecisionV1(
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
      requestBindingDigest: requestBindingDigest,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: generation,
      admissionAttemptID: request.attemptID)
  }

  private func projectionOutcome(
    status: TatwoAppPressureRuntimeOperationStatusV1,
    requestedGeneration: UInt64,
    projection: TatwoPressureUIProjectionV1
  ) -> TatwoAppPressureRuntimeProjectionOutcomeV1 {
    TatwoAppPressureRuntimeProjectionOutcomeV1(
      status: status,
      runtimeInstanceID: runtimeInstanceID,
      requestedGeneration: requestedGeneration,
      currentGeneration: generation,
      projection: projection)
  }
}


private enum TatwoAppPressureRuntimeText {
  static func safeReasonCode(_ value: String, fallback: String) -> String {
    let normalized = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "_")
      .replacingOccurrences(of: "-", with: "_")
    let allowed = normalized.filter { character in
      character.isLetter || character.isNumber || character == "_" || character == ":" || character == "."
    }
    return allowed.isEmpty ? fallback : String(allowed.prefix(160))
  }

  static func safeSHA256Digest(_ value: String, fallback: String) -> String {
    isSHA256Digest(value) ? value : fallback
  }

  static func safeIdentifier(_ value: String, fallback: String) -> String {
    isSafeIdentifier(value) ? value : fallback
  }

  static func isSHA256Digest(_ value: String) -> Bool {
    let allowedHex = Set("0123456789abcdef")
    return value.hasPrefix("sha256:")
      && value.count == 71
      && value.dropFirst("sha256:".count).allSatisfy { allowedHex.contains($0) }
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && !value.contains("\0")
      && value.count <= 128
      && value.range(of: #"^[A-Za-z0-9._:\-]+$"#, options: .regularExpression) != nil
  }
}
