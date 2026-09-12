import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoAppPressureServiceTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_786_444_000.0)

  func testSamplerCadenceAndSingleFlightSampling() async throws {
    let clock = LockedClock(base)
    let counter = CountingProvider(readings: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await counter.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))

    let stoppedCadenceBeforeStart = await sampler.nextCadenceSeconds()
    XCTAssertNil(stoppedCadenceBeforeStart)
    await sampler.startMonitoring()
    let idleCadence = await sampler.nextCadenceSeconds()
    XCTAssertEqual(idleCadence, 60)
    await sampler.setActiveLoop(loopID: "loop-active")
    let activeCadence = await sampler.nextCadenceSeconds()
    XCTAssertEqual(activeCadence, 5)

    async let first = sampler.sampleNow(reason: .activeLoopCadence)
    async let second = sampler.sampleNow(reason: .activeLoopCadence)
    let snapshots = await [first, second]
    XCTAssertEqual(snapshots.map(\.classificationForTest), [.green, .green])
    let sampleCount = await counter.count()
    XCTAssertEqual(sampleCount, 1)

    await sampler.stopMonitoring()
    let stoppedCadenceAfterStop = await sampler.nextCadenceSeconds()
    let latestAfterStop = await sampler.latest()
    XCTAssertNil(stoppedCadenceAfterStop)
    XCTAssertNil(latestAfterStop)
  }

  func testDedicatedAdmissionSamplesDoNotCoalesceOrSpin() async throws {
    let clock = LockedClock(base)
    let counter = CountingProvider(readings: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await counter.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    await sampler.startMonitoring()

    async let first = sampler.sampleNow(reason: .preAdmissionImmediate)
    async let second = sampler.sampleNow(reason: .preAdmissionImmediate)
    let snapshots = await [first, second]

    XCTAssertEqual(snapshots.map(\.classificationForTest), [.green, .green])
    let sampleCount = await counter.count()
    XCTAssertEqual(sampleCount, 2)
  }

  func testDoubleStartDuringInFlightSampleKeepsSamplerUsable() async throws {
    let clock = LockedClock(base)
    let counter = CountingProvider(readings: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await counter.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    await sampler.startMonitoring()

    async let inFlight = sampler.sampleNow(reason: .idleCadence)
    await sampler.startMonitoring()
    let first = await inFlight
    let second = await sampler.sampleNow(reason: .idleCadence)

    XCTAssertEqual(first.classificationForTest, .green)
    XCTAssertEqual(second.classificationForTest, .green)
    let sampleCount = await counter.count()
    XCTAssertEqual(sampleCount, 2)
  }

  func testSamplerLifecycleIntentOrderingRejectsStaleStartAndStop() async throws {
    let clock = LockedClock(base)
    let counter = CountingProvider(readings: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await counter.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))

    let startOneApplied = await sampler.startMonitoring(intentGeneration: 1)
    let modeAfterStartOne = await sampler.mode()
    XCTAssertTrue(startOneApplied)
    XCTAssertEqual(modeAfterStartOne, .idle)

    let stopTwoApplied = await sampler.stopMonitoring(intentGeneration: 2)
    let modeAfterStopTwo = await sampler.mode()
    XCTAssertTrue(stopTwoApplied)
    XCTAssertEqual(modeAfterStopTwo, .stopped)

    let staleStartApplied = await sampler.startMonitoring(intentGeneration: 1)
    let modeAfterStaleStart = await sampler.mode()
    let latestAfterStaleStart = await sampler.latest()
    XCTAssertFalse(staleStartApplied)
    XCTAssertEqual(modeAfterStaleStart, .stopped)
    XCTAssertNil(latestAfterStaleStart)

    let startThreeApplied = await sampler.startMonitoring(intentGeneration: 3)
    let staleStopApplied = await sampler.stopMonitoring(intentGeneration: 2)
    let modeAfterStaleStop = await sampler.mode()
    XCTAssertTrue(startThreeApplied)
    XCTAssertFalse(staleStopApplied)
    XCTAssertEqual(modeAfterStaleStop, .idle)
    let fresh = await sampler.sampleNow(reason: .idleCadence)
    XCTAssertEqual(fresh.classificationForTest, .green)
  }

  func testFreshGreenAdmissionEnqueuesAndSpawnsExactlyOnce() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let recorder = AdmissionRecorderProbe()
    let seam = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      recorder: recorder.asRecorder(),
      clock: TatwoPressureClockV1(now: clock.now))
    let request = makeRequest(jobID: "job-green-once", workload: .heavy, at: base)

    let first = await seam.admitAtLastReversiblePoint(request)
    XCTAssertTrue(first.enqueued)
    XCTAssertTrue(first.spawned)
    XCTAssertTrue(first.requestBinding?.verifiesRequest() ?? false)
    XCTAssertEqual(first.reservation?.requestBindingDigest, first.requestBinding?.requestBindingDigest)
    XCTAssertEqual(first.admissionDecision.reasonCode, "pressure_green")
    XCTAssertEqual(first.spawnDecision?.reasonCode, "pressure_green")
    XCTAssertNotNil(first.admissionDecision.requestBindingDigest)
    XCTAssertEqual(first.admissionDecision.requestBindingDigest, first.spawnDecision?.requestBindingDigest)
    let reservation = try XCTUnwrap(first.reservation)
    XCTAssertEqual(first.admissionDecision.reservationID, reservation.reservationID)
    XCTAssertEqual(first.spawnDecision?.reservationID, reservation.reservationID)
    let firstCounts = recorder.counts()
    XCTAssertEqual(firstCounts.enqueues, 1)
    XCTAssertEqual(firstCounts.spawns, 1)

    let second = await seam.admitAtLastReversiblePoint(request)
    XCTAssertFalse(second.enqueued)
    XCTAssertFalse(second.spawned)
    XCTAssertEqual(second.admissionDecision.reasonCode, "admission_already_consumed")
    XCTAssertEqual(second.reservation, first.reservation)
    let secondCounts = recorder.counts()
    XCTAssertEqual(secondCounts.enqueues, 1)
    XCTAssertEqual(secondCounts.spawns, 1)
    let journal = await seam.journalSnapshot()
    XCTAssertEqual(journal.map(\.phase), [.admittedNotSpawned, .spawned])
  }

  func testConcurrentSameJobAdmissionIsReservedBeforeFirstAwait() async throws {
    let clock = LockedClock(base)
    let counter = CountingProvider(readings: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await counter.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now))
    await service.startAppOwnedMonitoring()
    let recorder = AdmissionRecorderProbe()
    let seam = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      recorder: recorder.asRecorder(),
      clock: TatwoPressureClockV1(now: clock.now))
    let request = makeRequest(jobID: "job-concurrent-same-binding", workload: .heavy, at: base)

    async let first = seam.admitAtLastReversiblePoint(request)
    async let second = seam.admitAtLastReversiblePoint(request)
    let results = await [first, second]

    XCTAssertEqual(results.filter(\.spawned).count, 1)
    XCTAssertEqual(
      results.filter { $0.admissionDecision.reasonCode == "admission_outcome_unproven" }.count,
      1)
    let counts = recorder.counts()
    XCTAssertEqual(counts.enqueues, 1)
    XCTAssertEqual(counts.spawns, 1)
    let sampleCount = await counter.count()
    XCTAssertEqual(sampleCount, 2)
  }

  func testYellowRejectsHeavyBeforeEnqueue() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: yellowReadings())
    let recorder = AdmissionRecorderProbe()
    let seam = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      recorder: recorder.asRecorder(),
      clock: TatwoPressureClockV1(now: clock.now))

    let result = await seam.admitAtLastReversiblePoint(
      makeRequest(jobID: "job-yellow-heavy", workload: .heavy, at: base))
    XCTAssertFalse(result.enqueued)
    XCTAssertFalse(result.spawned)
    XCTAssertEqual(result.admissionDecision.classification, .yellow)
    XCTAssertEqual(result.admissionDecision.reasonCode, "pressure_yellow_heavy_rejected")
    let counts = recorder.counts()
    XCTAssertEqual(counts.enqueues, 0)
    XCTAssertEqual(counts.spawns, 0)
    let journal = await seam.journalSnapshot()
    XCTAssertEqual(journal.map(\.phase), [.notAdmitted])
  }

  func testRequestBindingCarriesCanonicalBytesAndRejectsExpectedDigestMismatch() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let request = makeRequest(jobID: "job-binding-exact", workload: .light, at: base)
    let binding = try TatwoLoopAdmissionRequestBindingV1.make(for: request)
    XCTAssertTrue(binding.verifiesRequest())
    XCTAssertEqual(binding.requestBindingDigest, try request.bindingDigest())
    XCTAssertTrue(binding.canonicalRequestJSON.contains("\"jobID\":\"job-binding-exact\""))

    let tampered = TatwoLoopAdmissionRequestBindingV1(
      request: request,
      canonicalRequestJSON: binding.canonicalRequestJSON.replacingOccurrences(
        of: "job-binding-exact",
        with: "job-binding-tampered"),
      requestBindingDigest: binding.requestBindingDigest)
    XCTAssertFalse(tampered.verifiesRequest())

    let missing = await service.admissionDecision(
      for: request,
      refreshPolicy: .sampleImmediately,
      requestBinding: nil)
    XCTAssertFalse(missing.accepted)
    XCTAssertEqual(missing.reasonCode, "request_binding_missing")
    XCTAssertEqual(missing.requestBindingDigest, binding.requestBindingDigest)

    let mismatch = await service.admissionDecision(
      for: request,
      refreshPolicy: .sampleImmediately,
      requestBinding: tampered)
    XCTAssertFalse(mismatch.accepted)
    XCTAssertEqual(mismatch.reasonCode, "request_binding_digest_mismatch")
    XCTAssertEqual(mismatch.requestBindingDigest, binding.requestBindingDigest)
  }

  func testRedRejectsAndTargetsNewestHeaviestWorker() async throws {
    let clock = LockedClock(base)
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { _ in redReadings() },
      clock: TatwoPressureClockV1(now: clock.now))
    await sampler.startMonitoring()
    await sampler.setActiveLoop(
      loopID: "loop-red",
      workers: [
        TatwoPressureWorkerV1(
          workerID: "light-newest",
          workload: .light,
          startedAt: base.addingTimeInterval(10)),
        TatwoPressureWorkerV1(
          workerID: "heavy-oldest",
          workload: .heavy,
          startedAt: base.addingTimeInterval(1)),
        TatwoPressureWorkerV1(
          workerID: "heavy-newest",
          workload: .heavy,
          startedAt: base.addingTimeInterval(2)),
      ])
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now))

    let request = makeRequest(jobID: "job-red", workload: .light, at: base)
    let decision = await service.admissionDecision(
      for: request,
      refreshPolicy: .sampleImmediately,
      requestBinding: try makeBinding(request))
    XCTAssertFalse(decision.accepted)
    XCTAssertEqual(decision.classification, .red)
    XCTAssertEqual(decision.reasonCode, "pressure_red")
    XCTAssertEqual(decision.stopAction, .checkpointAndStopNewestOrHeaviestWorker)
    XCTAssertEqual(decision.targetWorkerID, "heavy-newest")
  }

  func testMissingSensorBecomesMonitorUnknownAndSpawnsNothing() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: missingMemoryReadings())
    let recorder = AdmissionRecorderProbe()
    let seam = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      recorder: recorder.asRecorder(),
      clock: TatwoPressureClockV1(now: clock.now))

    let result = await seam.admitAtLastReversiblePoint(
      makeRequest(jobID: "job-missing-sensor", workload: .light, at: base))
    XCTAssertFalse(result.enqueued)
    XCTAssertFalse(result.spawned)
    XCTAssertEqual(result.admissionDecision.classification, .unknown)
    XCTAssertEqual(result.admissionDecision.reasonCode, "monitor_unknown")
    let counts = recorder.counts()
    XCTAssertEqual(counts.enqueues, 0)
    XCTAssertEqual(counts.spawns, 0)
  }

  func testLastGreenCannotBeReusedAfterSamplerStall() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let request = makeRequest(jobID: "job-stalled-latest", workload: .light, at: base)

    let binding = try makeBinding(request)
    let initial = await acceptedServiceDecision(
      service: service,
      request: request,
      binding: binding)
    XCTAssertTrue(initial.accepted)

    clock.advance(by: 16)
    let stalledRequest = makeRequest(jobID: "job-stalled-latest-2", workload: .light, at: clock.now())
    let stalled = await service.admissionDecision(
      for: stalledRequest,
      refreshPolicy: .latestOnly,
      requestBinding: try makeBinding(stalledRequest))
    XCTAssertFalse(stalled.accepted)
    XCTAssertEqual(stalled.classification, .unknown)
    XCTAssertEqual(stalled.reasonCode, "monitor_unknown")
    XCTAssertNil(stalled.leaseID)
  }

  func testLatestSnapshotLeaseReusesOriginalIssuedAtAndThenExpiresBySnapshotAge() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())

    let initialLease = await service.sampleAndIssueLease(reason: .appLaunch)
    let first = try XCTUnwrap(initialLease)
    XCTAssertEqual(first.issuedAt, base)

    clock.advance(by: 5)
    let reusedLease = await service.issueLeaseFromLatestSnapshot()
    let reused = try XCTUnwrap(reusedLease)
    XCTAssertEqual(reused.leaseID, first.leaseID)
    XCTAssertEqual(reused.issuedAt, first.issuedAt)
    XCTAssertEqual(reused.snapshotObservedAt, first.snapshotObservedAt)

    clock.set(base.addingTimeInterval(16))
    let expiredBySourceSnapshot = await service.issueLeaseFromLatestSnapshot()
    XCTAssertNil(expiredBySourceSnapshot)
    let request = makeRequest(jobID: "job-stale-source-snapshot", workload: .light, at: clock.now())
    let decision = await service.admissionDecision(
      for: request,
      refreshPolicy: .latestOnly,
      requestBinding: try makeBinding(request))
    XCTAssertFalse(decision.accepted)
    XCTAssertEqual(decision.reasonCode, "monitor_unknown")
    XCTAssertNil(decision.leaseID)
  }

  func testLeaseAgeBoundaryAndTTLExpiryFailClosed() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let seedRequest = makeRequest(jobID: "job-boundary-seed", workload: .light, at: base)
    let seedBinding = try makeBinding(seedRequest)
    _ = await acceptedServiceDecision(
      service: service,
      request: seedRequest,
      binding: seedBinding)

    clock.set(base.addingTimeInterval(15))
    let atBoundary = await acceptedServiceDecision(
      service: service,
      request: seedRequest,
      binding: seedBinding,
      refreshPolicy: .latestOnly)
    XCTAssertTrue(atBoundary.accepted)
    XCTAssertEqual(atBoundary.reasonCode, "pressure_green")

    clock.set(base.addingTimeInterval(16))
    let beyondRunnerWindow = await acceptedServiceDecision(
      service: service,
      request: seedRequest,
      binding: seedBinding,
      refreshPolicy: .latestOnly)
    XCTAssertFalse(beyondRunnerWindow.accepted)
    XCTAssertEqual(beyondRunnerWindow.reasonCode, "monitor_unknown")

    let lease = try TatwoPressureLeaseV1.issue(
      for: greenReadings().snapshot(
        deviceID: "mini-A",
        observedAt: base,
        activeLoopID: nil,
        workers: []),
      now: base,
      ttlSeconds: 20)
    let expired = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: "mini-A",
      loopID: "loop-expired-ttl",
      workload: .light,
      lease: lease,
      now: base.addingTimeInterval(21))
    XCTAssertFalse(expired.accepted)
    XCTAssertEqual(lease.freshness(now: base.addingTimeInterval(21)), .expired)
    XCTAssertEqual(expired.reasonCode, "monitor_unknown")
  }

  func testLatestSnapshotLeaseIsRequestScopedAndCannotAuthorizeDifferentRequest() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let seedRequest = makeRequest(jobID: "job-bound-request-seed", workload: .light, at: base)
    let seedBinding = try makeBinding(seedRequest)
    let seedDecision = await acceptedServiceDecision(
      service: service,
      request: seedRequest,
      binding: seedBinding)
    XCTAssertTrue(seedDecision.accepted)
    XCTAssertNotNil(seedDecision.leaseID)

    clock.advance(by: 5)
    let differentRequest = makeRequest(jobID: "job-bound-request-other", workload: .light, at: clock.now())
    let differentDecision = await service.admissionDecision(
      for: differentRequest,
      refreshPolicy: .latestOnly,
      requestBinding: try makeBinding(differentRequest))

    XCTAssertFalse(differentDecision.accepted)
    XCTAssertEqual(differentDecision.reasonCode, "monitor_unknown")
    XCTAssertNil(differentDecision.leaseID)
  }

  func testAdmissionRequestBindingCanonicalJSONPreservesSubsecondRequestedAt() throws {
    let request = makeRequest(
      jobID: "job-fractional-binding",
      workload: .light,
      at: base.addingTimeInterval(0.875),
      dispatchNonce: "dispatch-fractional-binding")
    let binding = try makeBinding(request)

    XCTAssertTrue(binding.verifiesRequest())
    XCTAssertTrue(
      binding.canonicalRequestJSON.contains("\"requestedAt\":\"1786444000.875\""),
      binding.canonicalRequestJSON)

    let sameSecondDifferentFraction = makeRequest(
      jobID: "job-fractional-binding",
      workload: .light,
      at: base.addingTimeInterval(0.125),
      dispatchNonce: "dispatch-fractional-binding")
    XCTAssertNotEqual(try sameSecondDifferentFraction.bindingDigest(), binding.requestBindingDigest)

    let tamperedJSON = binding.canonicalRequestJSON
      .replacingOccurrences(of: "1786444000.875", with: "1786444000.125")
    let tamperedBinding = TatwoLoopAdmissionRequestBindingV1(
      request: request,
      canonicalRequestJSON: tamperedJSON,
      requestBindingDigest: binding.requestBindingDigest)
    XCTAssertFalse(tamperedBinding.verifiesRequest())
  }

  func testAdmissionReceiptJournalCanonicalJSONDateTamperFailsChain() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let request = makeRequest(
      jobID: "job-journal-fractional-date",
      workload: .light,
      at: base.addingTimeInterval(0.5),
      dispatchNonce: "dispatch-journal-fractional-date")
    let binding = try makeBinding(request)
    let receipt = try await service.recordAdmissionReceipt(
      for: request,
      requestBinding: binding,
      runtimeInstanceID: "runtime-service-tests",
      runtimeGeneration: 1,
      admissionAttemptID: request.attemptID,
      reservationID: reservationID(for: request, binding: binding))
    XCTAssertTrue(receipt.verifiesChain(previous: nil))

    let receiptBytes = try TatwoPressureCanonicalJSONV1.data(receipt)
    let reopened = try TatwoPressureCanonicalJSONV1.decoder().decode(
      TatwoHostPressureReceiptV1.self,
      from: receiptBytes)
    XCTAssertTrue(reopened.verifiesChain(previous: nil))

    let tamperedBytes = String(data: receiptBytes, encoding: .utf8)!
      .replacingOccurrences(
        of: "\"recordedAt\":\"1786444000\"",
        with: "\"recordedAt\":\"1786444000.25\"")
      .data(using: .utf8)!
    let tampered = try TatwoPressureCanonicalJSONV1.decoder().decode(
      TatwoHostPressureReceiptV1.self,
      from: tamperedBytes)
    XCTAssertFalse(tampered.verifiesChain(previous: nil))
  }

  func testPressureLeaseDigestPolicyAndDispatchNonceAreVerified() async throws {
    let snapshot = greenReadings().snapshot(
      deviceID: "mini-A",
      observedAt: base,
      activeLoopID: nil,
      workers: [],
      sourceSnapshotSequence: 41,
      sourceSampleAttemptID: "sample-digest-41")
    let request = makeRequest(
      jobID: "job-loop-digest",
      workload: .light,
      at: base,
      dispatchNonce: "dispatch-good")
    let binding = try makeBinding(request)
    let admissionReservationID = reservationID(for: request, binding: binding)
    let lease = try TatwoPressureLeaseV1.issue(
      for: snapshot,
      now: base,
      ttlSeconds: 20,
      runtimeInstanceID: "runtime-service-tests",
      runtimeGeneration: 1,
      admissionAttemptID: request.attemptID,
      admissionRequestBindingDigest: binding.requestBindingDigest,
      dispatchNonce: request.dispatchNonce,
      reservationID: admissionReservationID)

    XCTAssertTrue(lease.verifiesDigest())
    XCTAssertEqual(lease.pressurePolicyVersion, TatwoPressurePolicyVersionV1.current)
    XCTAssertEqual(lease.sourceSnapshotSequence, 41)

    let accepted = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      lease: lease,
      now: base.addingTimeInterval(1),
      requestBindingDigest: binding.requestBindingDigest,
      runtimeInstanceID: "runtime-service-tests",
      runtimeGeneration: 1,
      admissionAttemptID: request.attemptID,
      dispatchNonce: request.dispatchNonce,
      reservationID: admissionReservationID)
    XCTAssertTrue(accepted.accepted)
    XCTAssertTrue(accepted.authorizesSpawn)
    XCTAssertEqual(accepted.dispatchNonce, "dispatch-good")
    XCTAssertEqual(accepted.sourceSnapshotSequence, 41)
    XCTAssertEqual(accepted.leaseDigest, lease.leaseDigest)

    let mismatched = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      lease: lease,
      now: base.addingTimeInterval(1),
      dispatchNonce: "dispatch-bad")
    XCTAssertFalse(mismatched.accepted)
    XCTAssertEqual(mismatched.reasonCode, "pressure_lease_dispatch_nonce_mismatch")

    let unscopedLease = try TatwoPressureLeaseV1.issue(
      for: snapshot,
      now: base,
      ttlSeconds: 20)
    let missingDispatchBinding = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: "mini-A",
      loopID: "loop-digest",
      workload: .light,
      lease: unscopedLease,
      now: base.addingTimeInterval(1),
      dispatchNonce: "dispatch-good")
    XCTAssertFalse(missingDispatchBinding.accepted)
    XCTAssertEqual(missingDispatchBinding.reasonCode, "pressure_lease_dispatch_nonce_mismatch")
  }

  func testQueuedDelayExpiryPreventsSpawnAfterEnqueue() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let recorder = AdmissionRecorderProbe()
    let seam = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      recorder: recorder.asRecorder(),
      clock: TatwoPressureClockV1(now: clock.now))

    let result = await seam.admitAtLastReversiblePoint(
      makeRequest(jobID: "job-delay-expiry", workload: .light, at: base),
      beforeSpawn: {
        clock.advance(by: 16)
        await service.stopAppOwnedMonitoring()
      })
    XCTAssertTrue(result.enqueued)
    XCTAssertFalse(result.spawned)
    XCTAssertEqual(result.spawnDecision?.reasonCode, "monitor_unknown")
    let counts = recorder.counts()
    XCTAssertEqual(counts.enqueues, 1)
    XCTAssertEqual(counts.spawns, 0)
    XCTAssertEqual(counts.cancels, 1)
    let journal = await seam.journalSnapshot()
    XCTAssertEqual(journal.map(\.phase), [.admittedNotSpawned, .terminal])

    let duplicate = await seam.admitAtLastReversiblePoint(
      makeRequest(jobID: "job-delay-expiry", workload: .light, at: base))
    XCTAssertFalse(duplicate.enqueued)
    XCTAssertFalse(duplicate.spawned)
    XCTAssertEqual(duplicate.admissionDecision.reasonCode, "admission_already_consumed")
    let duplicateCounts = recorder.counts()
    XCTAssertEqual(duplicateCounts.enqueues, 1)
    XCTAssertEqual(duplicateCounts.spawns, 0)
    XCTAssertEqual(duplicateCounts.cancels, 1)
  }

  func testPreSpawnRecheckReobservesPressureBeforeSpawn() async throws {
    let clock = LockedClock(base)
    let provider = SequencedProvider(readings: [greenReadings(), redReadings()])
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await provider.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now))
    await service.startAppOwnedMonitoring()
    let recorder = AdmissionRecorderProbe()
    let seam = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      recorder: recorder.asRecorder(),
      clock: TatwoPressureClockV1(now: clock.now))

    let result = await seam.admitAtLastReversiblePoint(
      makeRequest(jobID: "job-red-at-spawn", workload: .light, at: base),
      beforeSpawn: {
        clock.advance(by: 3)
      })
    XCTAssertTrue(result.enqueued)
    XCTAssertFalse(result.spawned)
    XCTAssertEqual(result.admissionDecision.classification, .green)
    XCTAssertEqual(result.spawnDecision?.classification, .red)
    XCTAssertEqual(result.spawnDecision?.reasonCode, "pressure_red")
    let counts = recorder.counts()
    XCTAssertEqual(counts.enqueues, 1)
    XCTAssertEqual(counts.spawns, 0)
    XCTAssertEqual(counts.cancels, 1)
    let sampleCount = await provider.count()
    XCTAssertEqual(sampleCount, 2)
  }

  func testReservationGenerationFencePreventsStaleSpawnCallbackABA() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let recorder = AdmissionRecorderProbe()
    let seam = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      recorder: recorder.asRecorder(),
      clock: TatwoPressureClockV1(now: clock.now))
    let request = makeRequest(jobID: "job-stale-spawn-cas", workload: .light, at: base)

    let result = await seam.admitAtLastReversiblePoint(
      request,
      beforeSpawnWithReservation: { reservation in
        _ = await seam.markOutcomeUnproven(
          reservation: reservation,
          reasonCode: "simulated_stale_callback")
      })

    XCTAssertTrue(result.enqueued)
    XCTAssertFalse(result.spawned)
    XCTAssertEqual(result.spawnDecision?.reasonCode, "admission_reservation_stale")
    let counts = recorder.counts()
    XCTAssertEqual(counts.enqueues, 1)
    XCTAssertEqual(counts.spawns, 0)
    let journal = await seam.journalSnapshot()
    XCTAssertEqual(journal.map(\.phase), [.admittedNotSpawned, .outcomeUnproven])
    let phase = await seam.rehydratedPhase(forJobID: request.jobID)
    XCTAssertEqual(phase, .outcomeUnproven)
  }

  func testRehydratedAdmissionJournalBlocksUnprovenOrCompletedOutcomes() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let firstSeam = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      clock: TatwoPressureClockV1(now: clock.now))
    let request = makeRequest(jobID: "job-rehydrate-admitted", workload: .light, at: base)
    let first = await firstSeam.admitAtLastReversiblePoint(
      request,
      beforeSpawnWithReservation: { reservation in
        _ = await firstSeam.markOutcomeUnproven(
          reservation: reservation,
          reasonCode: "simulated_crash_before_spawn")
      })
    XCTAssertTrue(first.enqueued)
    XCTAssertFalse(first.spawned)
    let journal = await firstSeam.journalSnapshot()

    let recorder = AdmissionRecorderProbe()
    let rehydrated = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      recorder: recorder.asRecorder(),
      clock: TatwoPressureClockV1(now: clock.now),
      rehydratedJournal: journal)
    let rehydratedPhase = await rehydrated.rehydratedPhase(forJobID: request.jobID)
    XCTAssertEqual(rehydratedPhase, .outcomeUnproven)
    let duplicate = await rehydrated.admitAtLastReversiblePoint(request)
    XCTAssertFalse(duplicate.enqueued)
    XCTAssertFalse(duplicate.spawned)
    XCTAssertEqual(duplicate.admissionDecision.reasonCode, "admission_outcome_unproven")
    let counts = recorder.counts()
    XCTAssertEqual(counts.enqueues, 0)
    XCTAssertEqual(counts.spawns, 0)
  }

  func testAdmissionReceiptProducerEmitsDecisionWithBindingProof() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let request = makeRequest(jobID: "job-admission-receipt", workload: .light, at: base)
    let binding = try makeBinding(request)

    let receipt = try await service.recordAdmissionReceipt(
      for: request,
      requestBinding: binding,
      runtimeInstanceID: "runtime-service-tests",
      runtimeGeneration: 1,
      admissionAttemptID: request.attemptID,
      reservationID: reservationID(for: request, binding: binding))

    XCTAssertTrue(receipt.verifiesChain(previous: nil))
    XCTAssertEqual(receipt.admissionDecision?.requestBindingDigest, binding.requestBindingDigest)
    XCTAssertEqual(receipt.admissionRequestBinding, binding)
    XCTAssertTrue(receipt.admissionDecision?.accepted ?? false)
  }

  func testAdmissionJournalEntriesAreHashChainedAndTamperEvident() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let seam = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      clock: TatwoPressureClockV1(now: clock.now))
    let request = makeRequest(jobID: "job-journal-chain", workload: .light, at: base)

    _ = await seam.admitAtLastReversiblePoint(request)
    let journal = await seam.journalSnapshot()

    XCTAssertEqual(journal.count, 2)
    XCTAssertNil(journal[0].previousEntryDigest)
    XCTAssertEqual(journal[1].previousEntryDigest, journal[0].entryDigest)
    XCTAssertTrue(TatwoLocalLoopAdmissionJournalEntryV1.verifiesChain(journal))
    let chainVerifies = await seam.journalChainVerifies()
    XCTAssertTrue(chainVerifies)

    let tampered = [
      TatwoLocalLoopAdmissionJournalEntryV1(
        reservation: journal[0].reservation,
        phase: .notAdmitted,
        recordedAt: journal[0].recordedAt,
        reasonCode: journal[0].reasonCode,
        decisionDigest: journal[0].decisionDigest,
        terminalDigest: journal[0].terminalDigest,
        previousEntryDigest: journal[0].previousEntryDigest,
        entryDigest: journal[0].entryDigest),
      journal[1],
    ]
    XCTAssertFalse(TatwoLocalLoopAdmissionJournalEntryV1.verifiesChain(tampered))
  }

  func testTamperedRehydratedJournalQuarantinesNewAdmission() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let firstSeam = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      clock: TatwoPressureClockV1(now: clock.now))
    let request = makeRequest(jobID: "job-rehydrate-tampered", workload: .light, at: base)
    _ = await firstSeam.admitAtLastReversiblePoint(request)
    var journal = await firstSeam.journalSnapshot()
    journal[0] = TatwoLocalLoopAdmissionJournalEntryV1(
      reservation: journal[0].reservation,
      phase: .notAdmitted,
      recordedAt: journal[0].recordedAt,
      reasonCode: "tampered_phase",
      decisionDigest: journal[0].decisionDigest,
      terminalDigest: journal[0].terminalDigest,
      previousEntryDigest: journal[0].previousEntryDigest,
      entryDigest: journal[0].entryDigest)

    let recorder = AdmissionRecorderProbe()
    let rehydrated = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      recorder: recorder.asRecorder(),
      clock: TatwoPressureClockV1(now: clock.now),
      rehydratedJournal: journal)
    let rehydratedChainVerifies = await rehydrated.journalChainVerifies()
    XCTAssertFalse(rehydratedChainVerifies)

    let other = await rehydrated.admitAtLastReversiblePoint(
      makeRequest(jobID: "job-after-tamper", workload: .light, at: base))
    XCTAssertFalse(other.enqueued)
    XCTAssertFalse(other.spawned)
    XCTAssertEqual(other.admissionDecision.reasonCode, "admission_journal_chain_invalid")
    XCTAssertEqual(recorder.counts().enqueues, 0)
  }

  func testTerminalAdmissionJournalPhaseIsAbsorbing() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let seam = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      clock: TatwoPressureClockV1(now: clock.now))
    let request = makeRequest(jobID: "job-terminal-absorbing", workload: .light, at: base)
    let result = await seam.admitAtLastReversiblePoint(request)
    let reservation = try XCTUnwrap(result.reservation)

    let terminalRecorded = await seam.markTerminal(
      reservation: reservation,
      terminalDigest: "sha256:1111111111111111111111111111111111111111111111111111111111111111")
    XCTAssertTrue(terminalRecorded)
    let reopenedTerminal = await seam.markOutcomeUnproven(
      reservation: reservation,
      reasonCode: "should_not_reopen_terminal")
    XCTAssertFalse(reopenedTerminal)
    let terminalPhase = await seam.rehydratedPhase(forJobID: request.jobID)
    XCTAssertEqual(terminalPhase, .terminal)
    let journal = await seam.journalSnapshot()
    XCTAssertEqual(journal.last?.phase, .terminal)
  }

  func testDecodedRequestAndProjectionUseSanitizingInitializers() throws {
    let requestJSON = """
      {
        "schema": "TatwoLoopAdmissionRequestV1",
        "jobID": "job-json",
        "deviceID": "mini-A",
        "loopID": "/tmp/tatwo2-fixture/private-loop",
        "workload": "light",
        "contractID": "contract-W1B",
        "goalHash": "not-a-real-hash",
        "planHash": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "requestedAt": 1786444000.0
      }
      """
    let request = try JSONDecoder().decode(TatwoLoopAdmissionRequestV1.self, from: Data(requestJSON.utf8))
    XCTAssertEqual(request.loopID, "invalid-loop-id")
    XCTAssertFalse(request.hasExactJobBinding)

    let configurationJSON = """
      {
        "schema": "TatwoAppPressureSamplerConfigurationV1",
        "idleCadenceSeconds": 999,
        "activeLoopCadenceSeconds": 0,
        "leaseCadenceSeconds": -4,
        "receiptSummaryCadenceSeconds": 999,
        "maximumSnapshotAgeForLeaseSeconds": 999
      }
      """
    let configuration = try JSONDecoder().decode(
      TatwoAppPressureSamplerConfigurationV1.self,
      from: Data(configurationJSON.utf8))
    XCTAssertEqual(configuration.idleCadenceSeconds, 60)
    XCTAssertEqual(configuration.activeLoopCadenceSeconds, 5)
    XCTAssertEqual(configuration.leaseCadenceSeconds, 5)
    XCTAssertEqual(configuration.receiptSummaryCadenceSeconds, 120)
    XCTAssertEqual(
      configuration.maximumSnapshotAgeForLeaseSeconds,
      TatwoPressureLeaseV1.defaultRunnerMaxAgeSeconds)

    let projectionJSON = """
      {
        "schema": "TatwoPressureUIProjectionV1",
        "deviceID": "/tmp/tatwo2-fixture/private-device",
        "displayClassification": "green",
        "lastObservedAt": 1786444000.0,
        "activeLoopID": "/tmp/tatwo2-fixture/private-loop",
        "workerIDs": ["/tmp/tatwo2-fixture/private-worker"],
        "stopReason": "failed at /tmp/tatwo2-fixture/private/path with sk-abcdefghijklmnop",
        "canRequestLightLoop": true,
        "canRequestHeavyLoop": true
      }
      """
    let projection = try JSONDecoder().decode(TatwoPressureUIProjectionV1.self, from: Data(projectionJSON.utf8))
    XCTAssertEqual(projection.deviceID, "invalid-device-id")
    XCTAssertEqual(projection.activeLoopID, "invalid-loop-id")
    XCTAssertEqual(projection.workerIDs, ["invalid-worker-id"])
    XCTAssertFalse(projection.stopReason?.contains("/Users") ?? true)
    XCTAssertFalse(projection.stopReason?.contains("sk-abcdefghijklmnop") ?? true)
  }

  func testUIProjectionCannotOverrideAdmissionTruth() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: missingMemoryReadings())
    _ = await service.sampleAndIssueLease(reason: .appLaunch)
    let projection = await service.uiProjection()
    XCTAssertEqual(projection.displayClassification, .unknown)
    XCTAssertFalse(projection.canRequestLightLoop)

    let forgedDisplay = TatwoPressureUIProjectionV1(
      deviceID: "mini-A",
      displayClassification: .green,
      lastObservedAt: base,
      activeLoopID: nil,
      workerIDs: [],
      stopReason: nil,
      canRequestLightLoop: true,
      canRequestHeavyLoop: true)
    XCTAssertEqual(forgedDisplay.displayClassification, .green)

    let request = makeRequest(jobID: "job-ui-forgery", workload: .light, at: base)
    let decision = await service.admissionDecision(
      for: request,
      refreshPolicy: .latestOnly,
      requestBinding: try makeBinding(request))
    XCTAssertFalse(decision.accepted)
    XCTAssertEqual(decision.classification, .unknown)
    XCTAssertEqual(decision.reasonCode, "monitor_unknown")
  }

  func testServiceRestartCannotReuseOldDecisionOrLease() async throws {
    let clock = LockedClock(base)
    let firstService = await makeService(clock: clock, readings: greenReadings())
    let beforeRestart = makeRequest(jobID: "job-before-restart", workload: .light, at: base)
    let beforeRestartBinding = try makeBinding(beforeRestart)
    let accepted = await acceptedServiceDecision(
      service: firstService,
      request: beforeRestart,
      binding: beforeRestartBinding)
    XCTAssertTrue(accepted.accepted)

    let newSampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { _ in greenReadings() },
      clock: TatwoPressureClockV1(now: clock.now))
    await newSampler.startMonitoring()
    let restartedService = TatwoAppPressureServiceV1(
      sampler: newSampler,
      clock: TatwoPressureClockV1(now: clock.now))
    let afterRestartRequest = makeRequest(jobID: "job-after-restart", workload: .light, at: base)
    let afterRestart = await restartedService.admissionDecision(
      for: afterRestartRequest,
      refreshPolicy: .latestOnly,
      requestBinding: try makeBinding(afterRestartRequest))
    XCTAssertFalse(afterRestart.accepted)
    XCTAssertEqual(afterRestart.reasonCode, "monitor_unknown")
    XCTAssertNil(afterRestart.leaseID)
  }

  func testSummaryReceiptsHashChainSamplerTruth() async throws {
    let clock = LockedClock(base)
    let service = await makeService(clock: clock, readings: greenReadings())
    let first = try await service.recordSummaryReceipt(reason: .summaryReceipt)
    XCTAssertTrue(first.verifiesChain(previous: nil))
    clock.advance(by: 5)
    let second = try await service.recordSummaryReceipt(reason: .summaryReceipt)
    XCTAssertTrue(second.verifiesChain(previous: first))
    XCTAssertEqual(second.previousReceiptDigest, first.receiptDigest)
  }

  func testRuntimeLifecycleTicksLeaseSummaryAndStopInvalidatesOldGreen() async throws {
    let clock = LockedClock(base)
    let provider = RecordingProvider(readings: [greenReadings(), greenReadings(), greenReadings()])
    let events = RuntimeEventProbe()
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await provider.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      service: service,
      clock: TatwoPressureClockV1(now: clock.now),
      eventSink: events.sink())

    await runtime.start(reason: .appLaunch, startTimers: false)
    let initialLease = await runtime.currentLease()
    XCTAssertNotNil(initialLease)
    let initialReasons = await provider.reasons()
    XCTAssertEqual(initialReasons, [.appLaunch])

    await runtime.setLoopState(loopID: "loop-runtime", workers: [
      TatwoPressureWorkerV1(
        workerID: "runtime-worker",
        loopID: "loop-runtime",
        workload: .light,
        startedAt: base)
    ])
    _ = await runtime.sampleCadenceTick()
    let activeReasons = await provider.reasons()
    XCTAssertEqual(activeReasons.last, .activeLoopCadence)

    _ = await runtime.leaseCadenceTick()
    let leaseReasons = await provider.reasons()
    XCTAssertEqual(leaseReasons.last, .leaseTick)
    let summaryCandidate = await runtime.summaryCadenceTick()
    let summary = try XCTUnwrap(summaryCandidate)
    XCTAssertTrue(summary.verifiesChain(previous: nil))
    let summaryReasons = await provider.reasons()
    XCTAssertEqual(summaryReasons.last, .summaryReceipt)

    await runtime.stop(reason: .appDidSuspend)
    let stoppedLease = await runtime.currentLease()
    XCTAssertNil(stoppedLease)
    let stoppedProjectionCandidate = await runtime.currentProjection()
    let stoppedProjection = try XCTUnwrap(stoppedProjectionCandidate)
    XCTAssertEqual(stoppedProjection.displayClassification, .unknown)
    XCTAssertFalse(stoppedProjection.canRequestLightLoop)

    let request = makeRequest(jobID: "job-after-runtime-stop", workload: .light, at: clock.now())
    let afterStop = await service.admissionDecision(
      for: request,
      refreshPolicy: .latestOnly,
      requestBinding: try makeBinding(request))
    XCTAssertFalse(afterStop.accepted)
    XCTAssertEqual(afterStop.reasonCode, "monitor_unknown")

    let eventKinds = await events.kinds()
    XCTAssertTrue(eventKinds.contains(.started))
    XCTAssertTrue(eventKinds.contains(.sampled))
    XCTAssertTrue(eventKinds.contains(.leaseIssued))
    XCTAssertTrue(eventKinds.contains(.summaryReceiptRecorded))
    XCTAssertTrue(eventKinds.contains(.stopped))
  }

  func testRuntimeLifecycleLatestIntentWinsAcrossOverlappingStopStart() async throws {
    let clock = LockedClock(base)
    let resetProbe = BlockingLifecycleResetProbe()
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { _ in greenReadings() },
      clock: TatwoPressureClockV1(now: clock.now))
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      service: service,
      clock: TatwoPressureClockV1(now: clock.now),
      lifecycleReset: resetProbe.resetter())

    await runtime.start(reason: .appLaunch, startTimers: false)
    let initialLease = await runtime.currentLease()
    XCTAssertNotNil(initialLease)

    let stopping = Task {
      await runtime.stop(reason: .appDidSuspend)
    }
    try await waitUntil { await resetProbe.isBlocked() }
    let projectionDuringStopCandidate = await runtime.currentProjection()
    let projectionDuringStop = try XCTUnwrap(projectionDuringStopCandidate)
    XCTAssertEqual(projectionDuringStop.displayClassification, .unknown)
    XCTAssertFalse(projectionDuringStop.canRequestLightLoop)
    XCTAssertEqual(projectionDuringStop.stopReason, "app_did_suspend")

    await runtime.start(reason: .manualStart, startTimers: false)
    let restartedLease = await runtime.currentLease()
    XCTAssertNotNil(restartedLease)

    await resetProbe.release()
    await stopping.value

    let isRunning = await runtime.isRunning
    let currentLease = await runtime.currentLease()
    let currentProjection = await runtime.currentProjection()
    XCTAssertTrue(isRunning)
    XCTAssertNotNil(currentLease)
    let projection = try XCTUnwrap(currentProjection)
    XCTAssertEqual(projection.displayClassification, .green)
  }

  func testRuntimeGenerationFencePreventsPostStopLeaseCommit() async throws {
    let clock = LockedClock(base)
    let provider = BlockingAfterFirstProvider(first: greenReadings(), blocked: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await provider.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      service: service,
      clock: TatwoPressureClockV1(now: clock.now))

    await runtime.start(reason: .appLaunch, startTimers: false)
    let initialLease = await runtime.currentLease()
    XCTAssertNotNil(initialLease)

    let tick = Task {
      await runtime.leaseCadenceTick()
    }
    for _ in 0..<100 where !(await provider.isBlocked()) {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let providerBlocked = await provider.isBlocked()
    XCTAssertTrue(providerBlocked)

    await runtime.stop(reason: .appDidSuspend)
    await provider.release()
    let staleOutcome = await tick.value

    XCTAssertEqual(staleOutcome.status, .staleGeneration)
    XCTAssertNil(staleOutcome.lease)
    let currentLease = await runtime.currentLease()
    XCTAssertNil(currentLease)
    let currentProjection = await runtime.currentProjection()
    let projection = try XCTUnwrap(currentProjection)
    XCTAssertEqual(projection.displayClassification, .unknown)
    XCTAssertFalse(projection.canRequestLightLoop)
  }

  func testRuntimeStaleLeaseTickDoesNotClobberRestartedProjection() async throws {
    let clock = LockedClock(base)
    let provider = ConcurrentBlockingSecondProvider(readings: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await provider.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      service: service,
      clock: TatwoPressureClockV1(now: clock.now))

    await runtime.start(reason: .appLaunch, startTimers: false)
    let initialProjectionCandidate = await runtime.currentProjection()
    let initialProjection = try XCTUnwrap(initialProjectionCandidate)
    XCTAssertEqual(initialProjection.displayClassification, .green)

    let staleTick = Task {
      await runtime.leaseCadenceTick()
    }
    try await waitUntil { provider.secondSampleIsBlocked() }

    await runtime.stop(reason: .appDidSuspend)
    await runtime.start(reason: .manualStart, startTimers: false)

    let restartedProjectionCandidate = await runtime.currentProjection()
    let restartedProjection = try XCTUnwrap(restartedProjectionCandidate)
    XCTAssertEqual(restartedProjection.displayClassification, .green)
    let restartedLease = await runtime.currentLease()
    XCTAssertNotNil(restartedLease)

    provider.releaseSecondSample()
    let staleOutcome = await staleTick.value
    XCTAssertEqual(staleOutcome.status, .staleGeneration)
    XCTAssertNil(staleOutcome.lease)

    let afterStaleCompletionCandidate = await runtime.currentProjection()
    let afterStaleCompletion = try XCTUnwrap(afterStaleCompletionCandidate)
    XCTAssertEqual(afterStaleCompletion.displayClassification, .green)
    XCTAssertTrue(afterStaleCompletion.canRequestLightLoop)
    let afterStaleLease = await runtime.currentLease()
    XCTAssertNotNil(afterStaleLease)
  }

  func testRuntimeStaleSampleTickReturnsRestartedProjectionInsteadOfStaleUnknown() async throws {
    let clock = LockedClock(base)
    let provider = ConcurrentBlockingSecondProvider(readings: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await provider.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      service: service,
      clock: TatwoPressureClockV1(now: clock.now))

    await runtime.start(reason: .appLaunch, startTimers: false)
    let staleSampleTick = Task {
      await runtime.sampleCadenceTick()
    }
    try await waitUntil { provider.secondSampleIsBlocked() }

    await runtime.stop(reason: .appDidSuspend)
    await runtime.start(reason: .manualStart, startTimers: false)

    provider.releaseSecondSample()
    let returnedOutcome = await staleSampleTick.value
    XCTAssertEqual(returnedOutcome.status, .staleGeneration)
    XCTAssertEqual(returnedOutcome.projection.displayClassification, .green)
    XCTAssertTrue(returnedOutcome.projection.canRequestLightLoop)

    let currentProjectionCandidate = await runtime.currentProjection()
    let currentProjection = try XCTUnwrap(currentProjectionCandidate)
    XCTAssertEqual(currentProjection.displayClassification, .green)
    XCTAssertTrue(currentProjection.canRequestLightLoop)
  }

  func testRuntimeStaleSampleTickOutcomeIsTypedRejectionNotAppliedSuccess() async throws {
    let clock = LockedClock(base)
    let provider = ConcurrentBlockingSecondProvider(readings: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await provider.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      service: service,
      clock: TatwoPressureClockV1(now: clock.now),
      runtimeInstanceID: "runtime-w1fb1-stale-outcome")

    await runtime.start(reason: .appLaunch, startTimers: false)
    let staleSampleTick = Task {
      await runtime.sampleCadenceTickOutcome()
    }
    try await waitUntil { provider.secondSampleIsBlocked() }

    await runtime.stop(reason: .appDidSuspend)
    await runtime.start(reason: .manualStart, startTimers: false)

    provider.releaseSecondSample()
    let outcome = await staleSampleTick.value
    XCTAssertEqual(outcome.status, .staleGeneration)
    XCTAssertEqual(outcome.runtimeInstanceID, "runtime-w1fb1-stale-outcome")
    XCTAssertNotEqual(outcome.requestedGeneration, outcome.currentGeneration)
    XCTAssertEqual(outcome.projection.displayClassification, .green)
    XCTAssertTrue(outcome.projection.canRequestLightLoop)
    let currentLeaseCandidate = await runtime.currentLease()
    let currentLease = try XCTUnwrap(currentLeaseCandidate)
    XCTAssertEqual(currentLease.sourceSnapshotSequence, 3)
  }

  func testRuntimeSupersededStopRecordsLifecycleRejectedEvent() async throws {
    let clock = LockedClock(base)
    let resetProbe = BlockingLifecycleResetProbe()
    let events = RuntimeEventProbe()
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { _ in greenReadings() },
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now),
      eventSink: events.sink(),
      lifecycleReset: resetProbe.resetter())

    await runtime.start(reason: .appLaunch, startTimers: false)
    let stopping = Task {
      await runtime.stop(reason: .appDidSuspend)
    }
    try await waitUntil { await resetProbe.isBlocked() }

    await runtime.start(reason: .manualStart, startTimers: false)
    await resetProbe.release()
    await stopping.value

    let projectionCandidate = await runtime.currentProjection()
    let projection = try XCTUnwrap(projectionCandidate)
    XCTAssertEqual(projection.displayClassification, .green)
    let recordedEvents = await events.all()
    let eventKinds = recordedEvents.map(\.kind)
    XCTAssertTrue(eventKinds.contains(.lifecycleRejected))
    XCTAssertFalse(eventKinds.contains(.stopped))
    let lifecycleEvent = try XCTUnwrap(recordedEvents.first { $0.kind == .lifecycleRejected })
    XCTAssertEqual(lifecycleEvent.classification, .unknown)
    XCTAssertEqual(lifecycleEvent.reason, "app_did_suspend_superseded_after_reset")
  }

  func testRuntimeRejectedSamplerStopRecordsLifecycleRejectedEvent() async throws {
    let clock = LockedClock(base)
    let events = RuntimeEventProbe()
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { _ in greenReadings() },
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now),
      eventSink: events.sink())

    await runtime.start(reason: .appLaunch, startTimers: false)
    let advancedSamplerIntentApplied = await sampler.startMonitoring(intentGeneration: 99)
    XCTAssertTrue(advancedSamplerIntentApplied)

    await runtime.stop(reason: .appDidSuspend)

    let running = await runtime.isRunning
    XCTAssertFalse(running)
    let projectionCandidate = await runtime.currentProjection()
    let projection = try XCTUnwrap(projectionCandidate)
    XCTAssertEqual(projection.displayClassification, .unknown)
    XCTAssertEqual(projection.stopReason, "app_did_suspend")
    let samplerMode = await sampler.mode()
    XCTAssertEqual(samplerMode, .idle)

    let recordedEvents = await events.all()
    let eventKinds = recordedEvents.map(\.kind)
    XCTAssertTrue(eventKinds.contains(.lifecycleRejected))
    XCTAssertFalse(eventKinds.contains(.stopped))
    let lifecycleEvent = try XCTUnwrap(recordedEvents.first { $0.kind == .lifecycleRejected })
    XCTAssertEqual(lifecycleEvent.classification, .unknown)
    XCTAssertEqual(lifecycleEvent.reason, "app_did_suspend_stop_rejected")
  }

  func testRuntimeTimerTasksEmitIdleActiveLeaseAndSummaryCadence() async throws {
    let clock = LockedClock(base)
    let provider = RecordingProvider(readings: Array(repeating: greenReadings(), count: 32))
    let configuration = TatwoAppPressureSamplerConfigurationV1(
      idleCadenceSeconds: 0.02,
      activeLoopCadenceSeconds: 0.01,
      leaseCadenceSeconds: 0.01,
      receiptSummaryCadenceSeconds: 0.02)
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await provider.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now),
      configuration: configuration)
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now),
      configuration: configuration)
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      service: service,
      clock: TatwoPressureClockV1(now: clock.now),
      configuration: configuration)

    await runtime.start(reason: .appLaunch, startTimers: true)
    try await waitUntil {
      let reasons = await provider.reasons()
      return reasons.contains(.idleCadence)
        && reasons.contains(.leaseTick)
        && reasons.contains(.summaryReceipt)
    }

    await runtime.setLoopState(loopID: "loop-timer", workers: [
      TatwoPressureWorkerV1(
        workerID: "timer-worker",
        loopID: "loop-timer",
        workload: .light,
        startedAt: base)
    ])
    try await waitUntil {
      (await provider.reasons()).contains(.activeLoopCadence)
    }
    await runtime.stop(reason: .appDidSuspend)

    let reasons = await provider.reasons()
    XCTAssertTrue(reasons.contains(.appLaunch))
    XCTAssertTrue(reasons.contains(.idleCadence))
    XCTAssertTrue(reasons.contains(.activeLoopCadence))
    XCTAssertTrue(reasons.contains(.leaseTick))
    XCTAssertTrue(reasons.contains(.summaryReceipt))
  }

  func testRuntimeStoppedPreAdmissionFailsClosedWithoutSampling() async throws {
    let clock = LockedClock(base)
    let counter = CountingProvider(readings: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await counter.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now))
    let request = makeRequest(jobID: "job-runtime-stopped", workload: .heavy, at: base)
    let binding = try makeBinding(request)

    let neverStartedDecision = await runtime.preAdmissionDecision(
      for: request,
      requestBinding: binding)
    XCTAssertFalse(neverStartedDecision.accepted)
    XCTAssertEqual(neverStartedDecision.reasonCode, "monitor_unknown")
    let samplesAfterNeverStartedDecision = await counter.count()
    XCTAssertEqual(samplesAfterNeverStartedDecision, 0)

    await runtime.start(reason: .appLaunch, startTimers: false)
    let samplesAfterStart = await counter.count()
    XCTAssertGreaterThan(samplesAfterStart, 0)
    await runtime.stop(reason: .appDidSuspend)

    let stoppedDecision = await runtime.preAdmissionDecision(
      for: request,
      requestBinding: binding)
    XCTAssertFalse(stoppedDecision.accepted)
    XCTAssertEqual(stoppedDecision.reasonCode, "monitor_unknown")
    let samplesAfterStoppedDecision = await counter.count()
    XCTAssertEqual(samplesAfterStoppedDecision, samplesAfterStart)
  }

  func testRuntimePreAdmissionRequiresAttemptBindingBeforeSampling() async throws {
    let clock = LockedClock(base)
    let counter = CountingProvider(readings: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await counter.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now),
      runtimeInstanceID: "runtime-w1fb1-attempt-required")
    await runtime.start(reason: .appLaunch, startTimers: false)
    let samplesAfterStart = await counter.count()

    let request = makeRequest(
      jobID: "job-runtime-no-attempt",
      includeAttemptBinding: false,
      workload: .light,
      at: base)
    let binding = try makeBinding(request)
    let decision = await runtime.preAdmissionDecision(for: request, requestBinding: binding)

    XCTAssertFalse(decision.accepted)
    XCTAssertEqual(decision.reasonCode, "attempt_binding_missing")
    XCTAssertEqual(decision.runtimeInstanceID, "runtime-w1fb1-attempt-required")
    XCTAssertEqual(decision.requestBindingDigest, binding.requestBindingDigest)
    let samplesAfterDecision = await counter.count()
    XCTAssertEqual(samplesAfterDecision, samplesAfterStart)
  }

  func testRuntimePreAdmissionRejectsInvalidReservationLiteralBeforeSampling() async throws {
    let clock = LockedClock(base)
    let counter = CountingProvider(readings: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await counter.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now),
      runtimeInstanceID: "runtime-w1fb1-invalid-reservation")
    await runtime.start(reason: .appLaunch, startTimers: false)
    let samplesAfterStart = await counter.count()
    let generation = await runtime.currentGeneration

    let request = makeRequest(
      jobID: "job-runtime-invalid-reservation",
      attemptID: "attempt-runtime-invalid-reservation-1",
      workload: .light,
      at: base)
    let binding = try makeBinding(request)
    let invalidReservationIDs = [
      "invalid-reservation-id",
      "sha256:abc123",
      "sha256:gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg",
      " sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
    ]

    for invalidReservationID in invalidReservationIDs {
      let decision = await runtime.preAdmissionDecision(
        for: request,
        requestBinding: binding,
        reservationID: invalidReservationID)
      XCTAssertFalse(decision.accepted, invalidReservationID)
      XCTAssertFalse(decision.authorizesSpawn, invalidReservationID)
      XCTAssertEqual(decision.reasonCode, "pressure_pre_admission_reservation_missing", invalidReservationID)
      XCTAssertEqual(decision.runtimeInstanceID, "runtime-w1fb1-invalid-reservation", invalidReservationID)
      XCTAssertEqual(decision.runtimeGeneration, generation, invalidReservationID)
      XCTAssertEqual(decision.admissionAttemptID, "attempt-runtime-invalid-reservation-1", invalidReservationID)
    }
    let samplesAfterDecisions = await counter.count()
    XCTAssertEqual(samplesAfterDecisions, samplesAfterStart)
  }

  func testRuntimePreAdmissionBindsLeaseDecisionToRuntimeGenerationAndAttempt() async throws {
    let clock = LockedClock(base)
    let counter = CountingProvider(readings: greenReadings())
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { context in
        await counter.sample(context)
      },
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now),
      runtimeInstanceID: "runtime-w1fb1-bound")
    await runtime.start(reason: .appLaunch, startTimers: false)
    clock.advance(by: 1)
    let generation = await runtime.currentGeneration
    let request = makeRequest(
      jobID: "job-runtime-bound",
      attemptID: "attempt-runtime-bound-1",
      workload: .light,
      at: clock.now())
    let binding = try makeBinding(request)

    let decision = await runtime.preAdmissionDecision(
      for: request,
      requestBinding: binding,
      reservationID: reservationID(for: request, binding: binding, generation: generation))

    XCTAssertTrue(decision.accepted)
    XCTAssertEqual(decision.reasonCode, "pressure_green")
    XCTAssertEqual(decision.runtimeInstanceID, "runtime-w1fb1-bound")
    XCTAssertEqual(decision.runtimeGeneration, generation)
    XCTAssertEqual(decision.admissionAttemptID, "attempt-runtime-bound-1")
    XCTAssertEqual(decision.requestBindingDigest, binding.requestBindingDigest)
    XCTAssertNotNil(decision.leaseID)
  }

  func testRuntimeStopInvokesLifecycleResetHook() async throws {
    let clock = LockedClock(base)
    let resetProbe = LifecycleResetProbe()
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { _ in greenReadings() },
      clock: TatwoPressureClockV1(now: clock.now))
    let runtime = TatwoAppPressureRuntimeV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now),
      lifecycleReset: resetProbe.resetter())

    await runtime.start(reason: .appLaunch, startTimers: false)
    let resetCountAfterStart = await resetProbe.count()
    XCTAssertEqual(resetCountAfterStart, 0)
    await runtime.stop(reason: .appDidSuspend)

    let resetCountAfterStop = await resetProbe.count()
    XCTAssertEqual(resetCountAfterStop, 1)
    let stoppedProjectionCandidate = await runtime.currentProjection()
    let stoppedProjection = try XCTUnwrap(stoppedProjectionCandidate)
    XCTAssertEqual(stoppedProjection.displayClassification, .unknown)
    XCTAssertFalse(stoppedProjection.canRequestHeavyLoop)
  }

  func testUnavailableNonFiniteOutOfRangeAndTimeoutReadingsFailClosed() async throws {
    let cases: [(String, TatwoDevicePressureSensorReadingsV1)] = [
      ("permission-denied", TatwoDevicePressureSensorReadingsV1.unavailable("permission_denied")),
      ("parse-failure", TatwoDevicePressureSensorReadingsV1.unavailable("parse_failure")),
      ("timeout", TatwoDevicePressureSensorReadingsV1.unavailable("sensor_timeout")),
      ("non-finite", TatwoDevicePressureSensorReadingsV1(
        memoryFreePercent: .infinity,
        swapFreeMiB: 2_048,
        dataVolumeFreeGiB: 40,
        load1PerCPU: 0.2,
        thermalWarning: false,
        uiLatencyMilliseconds: 20,
        swapGrowthMiBPerMinute: 0)),
      ("out-of-range", TatwoDevicePressureSensorReadingsV1(
        memoryFreePercent: 40,
        swapFreeMiB: -1,
        dataVolumeFreeGiB: 40,
        load1PerCPU: 0.2,
        thermalWarning: false,
        uiLatencyMilliseconds: 20,
        swapGrowthMiBPerMinute: 0)),
    ]

    for (label, readings) in cases {
      let clock = LockedClock(base)
      let service = await makeService(clock: clock, readings: readings)
      let request = makeRequest(jobID: "job-\(label)", workload: .light, at: base)
      let decision = await service.admissionDecision(
        for: request,
        refreshPolicy: .sampleImmediately,
        requestBinding: try makeBinding(request))
      XCTAssertFalse(decision.accepted, label)
      XCTAssertEqual(decision.classification, .unknown, label)
      XCTAssertEqual(decision.reasonCode, "monitor_unknown", label)
      XCTAssertNil(decision.leaseID, label)
    }
  }

  func testUnavailableSensorReasonDiagnosticsSurviveSamplerServiceAndReceiptBoundary() async throws {
    let clock = LockedClock(base)
    let readings = TatwoDevicePressureSensorReadingsV1(
      memoryFreePercent: nil,
      swapFreeMiB: 2_048,
      dataVolumeFreeGiB: nil,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 20,
      swapGrowthMiBPerMinute: 0,
      unavailableSensors: [
        TatwoPressureSensorUnavailableV1(
          sensor: .memoryFreePercent,
          reasonCode: "parse_failure"),
        TatwoPressureSensorUnavailableV1(
          sensor: .dataVolumeFreeGiB,
          reasonCode: "sensor_timeout_inflight_limit")
      ])
    let service = await makeService(clock: clock, readings: readings)
    let receipt = try await service.recordSummaryReceipt(reason: .summaryReceipt)

    XCTAssertEqual(receipt.classification.classification, .unknown)
    XCTAssertTrue(receipt.snapshot.unavailableSensorDiagnostics.contains {
      $0.sensor == .dataVolumeFreeGiB && $0.reasonCode == "sensor_timeout_inflight_limit"
    })
    XCTAssertTrue(receipt.classification.reasonCodes.contains(
      "sensor_unavailable_reason:data_volume_free_gib:sensor_timeout_inflight_limit"))
    XCTAssertTrue(receipt.classification.reasonCodes.contains(
      "sensor_unavailable_reason:memory_free_percent:parse_failure"))
    XCTAssertTrue(receipt.verifiesChain(previous: nil))
  }

  func testProductionAdmissionSeamWithFakeSpawnerMatrix() async throws {
    let matrix: [(String, TatwoDevicePressureSensorReadingsV1, TatwoPressureWorkerClassV1, Int)] = [
      ("green-heavy", greenReadings(), .heavy, 1),
      ("yellow-light-new-loop", yellowReadings(), .light, 0),
      ("yellow-heavy", yellowReadings(), .heavy, 0),
      ("red-light", redReadings(), .light, 0),
      ("unknown-light", missingMemoryReadings(), .light, 0),
      ("timeout-light", TatwoDevicePressureSensorReadingsV1.unavailable("sensor_timeout"), .light, 0),
    ]

    for (label, readings, workload, expectedSpawns) in matrix {
      let clock = LockedClock(base)
      let service = await makeService(clock: clock, readings: readings)
      let fakeSpawner = FakeSpawner()
      let seam = TatwoLocalLoopAdmissionSeamV1(service: service)
      let request = makeRequest(jobID: "job-prod-\(label)", workload: workload, at: base)

      let result = await seam.admitAtLastReversiblePoint(request)
      if result.spawned {
        await fakeSpawner.spawn(request)
      }

      let spawnCount = await fakeSpawner.count()
      XCTAssertEqual(spawnCount, expectedSpawns, label)
      XCTAssertEqual(result.spawned, expectedSpawns == 1, label)
    }
  }

  func testYellowPressureAllowsOnlyExactAlreadySpawnedAttemptContinuationWithoutNewSpawn() async throws {
    let clock = LockedClock(base)
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { _ in yellowReadings() },
      clock: TatwoPressureClockV1(now: clock.now))
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now))
    await service.startAppOwnedMonitoring()
    await sampler.setActiveLoop(loopID: "loop-job-yellow-existing", workers: [
      TatwoPressureWorkerV1(
        workerID: "job-yellow-existing",
        loopID: "loop-job-yellow-existing",
        attemptID: "attempt-yellow-existing",
        workload: .light,
        startedAt: base)
    ])
    let recorder = AdmissionRecorderProbe()
    let seam = TatwoLocalLoopAdmissionSeamV1(
      service: service,
      recorder: recorder.asRecorder())

    let sameLoop = await seam.admitAtLastReversiblePoint(
      makeRequest(
        jobID: "job-yellow-existing",
        attemptID: "attempt-yellow-existing",
        workload: .light,
        at: base))
    XCTAssertFalse(sameLoop.enqueued)
    XCTAssertFalse(sameLoop.spawned)
    XCTAssertEqual(sameLoop.admissionDecision.reasonCode, "pressure_yellow_exact_attempt_continue")
    XCTAssertEqual(sameLoop.admissionDecision.dispatchNonce, sameLoop.request.dispatchNonce)

    clock.advance(by: 1)
    let newLoop = await seam.admitAtLastReversiblePoint(
      makeRequest(
        jobID: "job-yellow-new-loop",
        attemptID: "attempt-yellow-new-loop",
        workload: .light,
        at: base))
    XCTAssertFalse(newLoop.enqueued)
    XCTAssertFalse(newLoop.spawned)
    XCTAssertEqual(newLoop.admissionDecision.reasonCode, "pressure_yellow_exact_attempt_only")
    XCTAssertEqual(recorder.counts().spawns, 0)
  }

  private func makeService(
    clock: LockedClock,
    readings: TatwoDevicePressureSensorReadingsV1
  ) async -> TatwoAppPressureServiceV1 {
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: "mini-A",
      provider: TatwoDevicePressureSensorProviderV1 { _ in readings },
      clock: TatwoPressureClockV1(now: clock.now))
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: TatwoPressureClockV1(now: clock.now))
    await service.startAppOwnedMonitoring()
    return service
  }

  private func makeBinding(
    _ request: TatwoLoopAdmissionRequestV1
  ) throws -> TatwoLoopAdmissionRequestBindingV1 {
    try TatwoLoopAdmissionRequestBindingV1.make(for: request)
  }



  private func reservationID(
    for request: TatwoLoopAdmissionRequestV1,
    binding: TatwoLoopAdmissionRequestBindingV1,
    generation: UInt64 = 1
  ) -> String {
    TatwoLoopJobDigest.sha256(
      Data("test-reservation|\(request.jobID)|\(binding.requestBindingDigest)|\(generation)".utf8))
  }

  private func acceptedServiceDecision(
    service: TatwoAppPressureServiceV1,
    request: TatwoLoopAdmissionRequestV1,
    binding: TatwoLoopAdmissionRequestBindingV1,
    refreshPolicy: TatwoPressureLeaseRefreshPolicyV1 = .sampleImmediately,
    runtimeInstanceID: String = "runtime-service-tests",
    runtimeGeneration: UInt64 = 1
  ) async -> TatwoLoopAdmissionDecisionV1 {
    await service.admissionDecision(
      for: request,
      refreshPolicy: refreshPolicy,
      requestBinding: binding,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: request.attemptID,
      reservationID: reservationID(for: request, binding: binding, generation: runtimeGeneration))
  }
  private func makeRequest(
    jobID: String,
    attemptID: String? = nil,
    includeAttemptBinding: Bool = true,
    workload: TatwoPressureWorkerClassV1,
    at: Date,
    dispatchNonce: String = "dispatch-\(UUID().uuidString.lowercased())"
  ) -> TatwoLoopAdmissionRequestV1 {
    TatwoLoopAdmissionRequestV1(
      jobID: jobID,
      attemptID: includeAttemptBinding ? (attemptID ?? "attempt-\(jobID)") : nil,
      dispatchNonce: dispatchNonce,
      deviceID: "mini-A",
      loopID: "loop-\(jobID)",
      workload: workload,
      contractID: "contract-W1B",
      goalHash: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      planHash: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      requestedAt: at)
  }
}

private extension TatwoDevicePressureSnapshotV1 {
  var classificationForTest: TatwoPressureClassificationV1 {
    classify(now: observedAt).classification
  }
}

private enum TatwoPressureWaitUntilError: Error {
  case timedOut
}

private func waitUntil(
  timeoutSeconds: TimeInterval = 1.0,
  file: StaticString = #filePath,
  line: UInt = #line,
  condition: @escaping () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeoutSeconds)
  while Date() < deadline {
    if await condition() { return }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  XCTFail("condition did not become true before timeout", file: file, line: line)
  throw TatwoPressureWaitUntilError.timedOut
}

private final class LockedClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date {
    lock.withLock { value }
  }

  func set(_ value: Date) {
    lock.withLock { self.value = value }
  }

  func advance(by seconds: TimeInterval) {
    lock.withLock {
      value = value.addingTimeInterval(seconds)
    }
  }
}

private actor CountingProvider {
  private let readings: TatwoDevicePressureSensorReadingsV1
  private var sampleCount = 0

  init(readings: TatwoDevicePressureSensorReadingsV1) {
    self.readings = readings
  }

  func sample(_ context: TatwoPressureSamplingContextV1) async -> TatwoDevicePressureSensorReadingsV1 {
    sampleCount += 1
    try? await Task.sleep(nanoseconds: 20_000_000)
    return readings
  }

  func count() -> Int { sampleCount }
}

private actor SequencedProvider {
  private var readings: [TatwoDevicePressureSensorReadingsV1]
  private var sampleCount = 0

  init(readings: [TatwoDevicePressureSensorReadingsV1]) {
    self.readings = readings
  }

  func sample(_ context: TatwoPressureSamplingContextV1) async -> TatwoDevicePressureSensorReadingsV1 {
    sampleCount += 1
    if readings.count > 1 {
      return readings.removeFirst()
    }
    return readings[0]
  }

  func count() -> Int { sampleCount }
}

private actor RecordingProvider {
  private var readings: [TatwoDevicePressureSensorReadingsV1]
  private var observedReasons: [TatwoPressureSamplingReasonV1] = []

  init(readings: [TatwoDevicePressureSensorReadingsV1]) {
    self.readings = readings
  }

  func sample(_ context: TatwoPressureSamplingContextV1) -> TatwoDevicePressureSensorReadingsV1 {
    observedReasons.append(context.reason)
    if readings.count > 1 {
      return readings.removeFirst()
    }
    return readings[0]
  }

  func reasons() -> [TatwoPressureSamplingReasonV1] { observedReasons }
}

private actor BlockingAfterFirstProvider {
  private let first: TatwoDevicePressureSensorReadingsV1
  private let blocked: TatwoDevicePressureSensorReadingsV1
  private var sampleCount = 0
  private var continuation: CheckedContinuation<Void, Never>?

  init(
    first: TatwoDevicePressureSensorReadingsV1,
    blocked: TatwoDevicePressureSensorReadingsV1
  ) {
    self.first = first
    self.blocked = blocked
  }

  func sample(_ context: TatwoPressureSamplingContextV1) async -> TatwoDevicePressureSensorReadingsV1 {
    sampleCount += 1
    guard sampleCount > 1 else { return first }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
    return blocked
  }

  func isBlocked() -> Bool {
    continuation != nil
  }

  func release() {
    let continuation = continuation
    self.continuation = nil
    continuation?.resume()
  }
}

private final class ConcurrentBlockingSecondProvider: @unchecked Sendable {
  private let lock = NSLock()
  private let readings: TatwoDevicePressureSensorReadingsV1
  private var sampleCount = 0
  private var secondContinuation: CheckedContinuation<Void, Never>?

  init(readings: TatwoDevicePressureSensorReadingsV1) {
    self.readings = readings
  }

  func sample(_ context: TatwoPressureSamplingContextV1) async -> TatwoDevicePressureSensorReadingsV1 {
    let currentCount = lock.withLock {
      sampleCount += 1
      return sampleCount
    }
    if currentCount == 2 {
      await withCheckedContinuation { continuation in
        lock.withLock {
          secondContinuation = continuation
        }
      }
    }
    return readings
  }

  func secondSampleIsBlocked() -> Bool {
    lock.withLock { secondContinuation != nil }
  }

  func releaseSecondSample() {
    let continuation = lock.withLock {
      let continuation = secondContinuation
      secondContinuation = nil
      return continuation
    }
    continuation?.resume()
  }
}

private actor LifecycleResetProbe {
  private var resetCount = 0

  nonisolated func resetter() -> TatwoAppPressureRuntimeLifecycleResetV1 {
    TatwoAppPressureRuntimeLifecycleResetV1 {
      await self.recordReset()
    }
  }

  func recordReset() {
    resetCount += 1
  }

  func count() -> Int {
    resetCount
  }
}

private actor BlockingLifecycleResetProbe {
  private var continuation: CheckedContinuation<Void, Never>?

  nonisolated func resetter() -> TatwoAppPressureRuntimeLifecycleResetV1 {
    TatwoAppPressureRuntimeLifecycleResetV1 {
      await self.blockUntilReleased()
    }
  }

  func blockUntilReleased() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func isBlocked() -> Bool {
    continuation != nil
  }

  func release() {
    let continuation = continuation
    self.continuation = nil
    continuation?.resume()
  }
}

private actor RuntimeEventProbe {
  private var events: [TatwoAppPressureRuntimeEventV1] = []

  nonisolated func sink() -> TatwoAppPressureRuntimeEventSinkV1 {
    TatwoAppPressureRuntimeEventSinkV1 { event in
      await self.record(event)
    }
  }

  func record(_ event: TatwoAppPressureRuntimeEventV1) {
    events.append(event)
  }

  func kinds() -> [TatwoAppPressureRuntimeEventKindV1] {
    events.map(\.kind)
  }

  func all() -> [TatwoAppPressureRuntimeEventV1] {
    events
  }
}

private actor FakeSpawner {
  private var spawned: [TatwoLoopAdmissionRequestV1] = []

  func spawn(_ request: TatwoLoopAdmissionRequestV1) {
    spawned.append(request)
  }

  func count() -> Int { spawned.count }
}

private final class AdmissionRecorderProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var enqueued: [TatwoLoopAdmissionRequestV1] = []
  private var spawned: [TatwoLoopAdmissionRequestV1] = []
  private var cancelled: [TatwoLoopAdmissionRequestV1] = []

  func asRecorder() -> TatwoLocalLoopAdmissionRecorderV1 {
    TatwoLocalLoopAdmissionRecorderV1(
      enqueue: { request, _ in
        self.recordEnqueue(request)
      },
      spawn: { request, _ in
        self.recordSpawn(request)
      },
      cancel: { request, _ in
        self.recordCancel(request)
      })
  }

  func counts() -> (enqueues: Int, spawns: Int, cancels: Int) {
    lock.withLock { (enqueued.count, spawned.count, cancelled.count) }
  }

  private func recordEnqueue(_ request: TatwoLoopAdmissionRequestV1) {
    lock.withLock { enqueued.append(request) }
  }

  private func recordSpawn(_ request: TatwoLoopAdmissionRequestV1) {
    lock.withLock { spawned.append(request) }
  }

  private func recordCancel(_ request: TatwoLoopAdmissionRequestV1) {
    lock.withLock { cancelled.append(request) }
  }
}

private func greenReadings() -> TatwoDevicePressureSensorReadingsV1 {
  TatwoDevicePressureSensorReadingsV1(
    memoryFreePercent: 40,
    swapFreeMiB: 2_048,
    dataVolumeFreeGiB: 40,
    load1PerCPU: 0.2,
    thermalWarning: false,
    uiLatencyMilliseconds: 20,
    swapGrowthMiBPerMinute: 0)
}

private func yellowReadings() -> TatwoDevicePressureSensorReadingsV1 {
  TatwoDevicePressureSensorReadingsV1(
    memoryFreePercent: 20,
    swapFreeMiB: 800,
    dataVolumeFreeGiB: 20,
    load1PerCPU: 0.8,
    thermalWarning: false,
    uiLatencyMilliseconds: 20,
    swapGrowthMiBPerMinute: 0)
}

private func redReadings() -> TatwoDevicePressureSensorReadingsV1 {
  TatwoDevicePressureSensorReadingsV1(
    memoryFreePercent: 10,
    swapFreeMiB: 400,
    dataVolumeFreeGiB: 10,
    load1PerCPU: 0.9,
    thermalWarning: true,
    uiLatencyMilliseconds: 3_000,
    swapGrowthMiBPerMinute: 200)
}

private func missingMemoryReadings() -> TatwoDevicePressureSensorReadingsV1 {
  TatwoDevicePressureSensorReadingsV1(
    memoryFreePercent: nil,
    swapFreeMiB: 2_048,
    dataVolumeFreeGiB: 40,
    load1PerCPU: 0.2,
    thermalWarning: false,
    uiLatencyMilliseconds: 20,
    swapGrowthMiBPerMinute: 0,
    unavailableSensors: [
      TatwoPressureSensorUnavailableV1(
        sensor: .memoryFreePercent,
        reasonCode: "sensor_unavailable")
    ])
}
