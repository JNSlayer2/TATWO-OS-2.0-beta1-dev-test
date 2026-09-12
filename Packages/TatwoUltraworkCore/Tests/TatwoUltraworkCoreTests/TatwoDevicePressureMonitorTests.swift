import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoDevicePressureMonitorTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_786_438_000.25)

  func testGreenClassificationRequiresAllSensorsHealthy() throws {
    let snapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let result = snapshot.classify(now: base.addingTimeInterval(1))
    XCTAssertEqual(result.classification, .green)
    XCTAssertEqual(result.reasonCodes, ["within_green_thresholds"])
    XCTAssertTrue(try snapshot.canonicalDigest().hasPrefix("sha256:"))
  }

  func testNegativeSwapGrowthIsHealthyRecoveryNotUnknown() {
    let snapshot = makeSnapshot(
      memory: 40,
      swap: 2_048,
      data: 40,
      load: 0.2,
      swapGrowth: -64)
    let result = snapshot.classify(now: base.addingTimeInterval(1))
    XCTAssertEqual(result.classification, .green)
    XCTAssertFalse(result.reasonCodes.contains("sensor_out_of_range:swap_growth_mib_per_minute"))
  }

  func testPressureCanonicalDigestPreservesSubsecondObservationTime() throws {
    let first = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let second = TatwoDevicePressureSnapshotV1(
      deviceID: "mini-A",
      observedAt: base.addingTimeInterval(0.25),
      memoryFreePercent: 40,
      swapFreeMiB: 2_048,
      dataVolumeFreeGiB: 40,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 20,
      swapGrowthMiBPerMinute: 0)
    XCTAssertNotEqual(try first.canonicalDigest(), try second.canonicalDigest())
  }

  func testPressureCanonicalJSONUsesVersionedFractionalDateEncoding() throws {
    XCTAssertEqual(TatwoPressurePolicyVersionV1.canonicalization, "TatwoPressureCanonicalJSONV1")
    XCTAssertTrue(TatwoPressurePolicyVersionV1.current.contains("canonical-json-v1"))
    XCTAssertEqual(TatwoPressureCanonicalJSONV1.encodeDate(base), "1786438000.25")

    let snapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let canonical = try String(
      data: TatwoPressureCanonicalJSONV1.data(snapshot),
      encoding: .utf8) ?? ""
    XCTAssertTrue(canonical.contains("\"observedAt\":\"1786438000.25\""), canonical)
    XCTAssertFalse(canonical.contains("2026-"), canonical)

    let decoded = try TatwoPressureCanonicalJSONV1.decoder().decode(
      TatwoDevicePressureSnapshotV1.self,
      from: Data(canonical.utf8))
    XCTAssertEqual(decoded.observedAt.timeIntervalSince1970, base.timeIntervalSince1970, accuracy: 0.000_001)
    XCTAssertEqual(try decoded.canonicalDigest(), try snapshot.canonicalDigest())
  }

  func testPressureLeaseCanonicalRoundTripKeepsTTLBoundaries() throws {
    let snapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let issuedAt = base.addingTimeInterval(0.125)
    let request = makeRequest(loopID: "loop-fractional-ttl", workload: .light)
    let requestBinding = try binding(loopID: "loop-fractional-ttl", workload: .light)
    let lease = try scopedLease(
      for: snapshot,
      request: request,
      binding: requestBinding,
      now: issuedAt,
      ttlSeconds: 20)

    let data = try TatwoPressureCanonicalJSONV1.data(lease)
    let json = String(data: data, encoding: .utf8) ?? ""
    XCTAssertTrue(json.contains("\"issuedAt\":\"1786438000.375\""), json)
    XCTAssertTrue(json.contains("\"expiresAt\":\"1786438020.375\""), json)

    let decoded = try TatwoPressureCanonicalJSONV1.decoder().decode(TatwoPressureLeaseV1.self, from: data)
    XCTAssertTrue(decoded.verifiesDigest())
    XCTAssertEqual(decoded.freshness(now: issuedAt.addingTimeInterval(15)), .fresh)
    XCTAssertEqual(decoded.freshness(now: issuedAt.addingTimeInterval(15.000_1)), .stale)
    XCTAssertEqual(decoded.freshness(now: issuedAt.addingTimeInterval(20.000_1)), .expired)
  }

  func testUnknownClassificationFailsClosedWhenAnySensorMissingOrUnavailable() {
    let snapshot = TatwoDevicePressureSnapshotV1(
      deviceID: "mini-A",
      observedAt: base,
      memoryFreePercent: nil,
      swapFreeMiB: 2_048,
      dataVolumeFreeGiB: 40,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 10,
      swapGrowthMiBPerMinute: 0,
      unavailableSensors: ["thermal warning", "/tmp/tatwo2-fixture/private-sensor"])
    let result = snapshot.classify(now: base.addingTimeInterval(1))
    XCTAssertEqual(result.classification, .unknown)
    XCTAssertTrue(result.reasonCodes.contains("sensor_missing:memory_free_percent"))
    XCTAssertTrue(result.reasonCodes.contains("sensor_unavailable:thermal_warning"))
    XCTAssertTrue(result.reasonCodes.contains("sensor_unavailable:other"))
    XCTAssertFalse(result.reasonCodes.contains { $0.contains("Users") })
  }

  func testSnapshotNormalizesUnavailableSensorsBeforeReceiptEncoding() throws {
    let snapshot = TatwoDevicePressureSnapshotV1(
      deviceID: "mini-A",
      observedAt: base,
      memoryFreePercent: nil,
      swapFreeMiB: 2_048,
      dataVolumeFreeGiB: 40,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 10,
      swapGrowthMiBPerMinute: 0,
      unavailableSensors: ["/tmp/tatwo2-fixture/private-sensor", "thermal warning"],
      activeLoopID: "/tmp/tatwo2-fixture/private-loop")
    XCTAssertEqual(snapshot.unavailableSensors, ["other", "thermal_warning"])
    XCTAssertEqual(snapshot.activeLoopID, "invalid-loop-id")
    let receipt = try TatwoHostPressureReceiptV1.make(
      snapshot: snapshot,
      now: base.addingTimeInterval(1))
    let data = try JSONEncoder().encode(receipt)
    let encoded = String(data: data, encoding: .utf8) ?? ""
    XCTAssertFalse(encoded.contains("/Users"))
    XCTAssertFalse(encoded.contains("private-sensor"))
  }

  func testUnavailableSensorDiagnosticsCarryReasonCodesIntoClassificationAndReceipt() throws {
    let snapshot = TatwoDevicePressureSnapshotV1(
      deviceID: "mini-A",
      observedAt: base,
      memoryFreePercent: nil,
      swapFreeMiB: nil,
      dataVolumeFreeGiB: nil,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 10,
      swapGrowthMiBPerMinute: 0,
      unavailableSensors: ["memory free percent"],
      unavailableSensorDiagnostics: [
        TatwoPressureSensorUnavailableV1(
          sensor: .dataVolumeFreeGiB,
          reasonCode: "sensor_timeout_inflight_limit"),
        TatwoPressureSensorUnavailableV1(
          sensor: .swapFreeMiB,
          reasonCode: "permission denied /tmp/tatwo2-fixture/private-pressure-probe")
      ])

    XCTAssertEqual(
      snapshot.unavailableSensors,
      ["data_volume_free_gib", "memory_free_percent", "swap_free_mib"])
    XCTAssertTrue(snapshot.unavailableSensorDiagnostics.contains {
      $0.sensor == .dataVolumeFreeGiB && $0.reasonCode == "sensor_timeout_inflight_limit"
    })

    let result = snapshot.classify(now: base.addingTimeInterval(1))
    XCTAssertEqual(result.classification, .unknown)
    XCTAssertTrue(result.reasonCodes.contains("sensor_unavailable:data_volume_free_gib"))
    XCTAssertTrue(result.reasonCodes.contains(
      "sensor_unavailable_reason:data_volume_free_gib:sensor_timeout_inflight_limit"))
    XCTAssertFalse(result.reasonCodes.contains { $0.contains("/Users") || $0.contains("layer2") })

    let receipt = try TatwoHostPressureReceiptV1.make(
      snapshot: snapshot,
      now: base.addingTimeInterval(1))
    XCTAssertEqual(receipt.snapshot.unavailableSensorDiagnostics, snapshot.unavailableSensorDiagnostics)
    let encoded = String(data: try JSONEncoder().encode(receipt), encoding: .utf8) ?? ""
    XCTAssertTrue(encoded.contains("sensor_timeout_inflight_limit"))
    XCTAssertFalse(encoded.contains("/Users"))
    XCTAssertFalse(encoded.contains("layer2"))
  }

  func testUnavailableSensorDiagnosticsAreCanonicalAndReceiptTamperEvident() throws {
    let first = TatwoDevicePressureSnapshotV1(
      deviceID: "mini-A",
      observedAt: base,
      memoryFreePercent: nil,
      swapFreeMiB: nil,
      dataVolumeFreeGiB: 40,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 10,
      swapGrowthMiBPerMinute: 0,
      unavailableSensorDiagnostics: [
        TatwoPressureSensorUnavailableV1(sensor: .swapFreeMiB, reasonCode: "parse_failure"),
        TatwoPressureSensorUnavailableV1(sensor: .memoryFreePercent, reasonCode: "sensor_timeout")
      ])
    let reordered = TatwoDevicePressureSnapshotV1(
      deviceID: "mini-A",
      observedAt: base,
      memoryFreePercent: nil,
      swapFreeMiB: nil,
      dataVolumeFreeGiB: 40,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 10,
      swapGrowthMiBPerMinute: 0,
      unavailableSensorDiagnostics: [
        TatwoPressureSensorUnavailableV1(sensor: .memoryFreePercent, reasonCode: "sensor_timeout"),
        TatwoPressureSensorUnavailableV1(sensor: .swapFreeMiB, reasonCode: "parse_failure")
      ])
    let tamperedReason = TatwoDevicePressureSnapshotV1(
      deviceID: "mini-A",
      observedAt: base,
      memoryFreePercent: nil,
      swapFreeMiB: nil,
      dataVolumeFreeGiB: 40,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 10,
      swapGrowthMiBPerMinute: 0,
      unavailableSensorDiagnostics: [
        TatwoPressureSensorUnavailableV1(sensor: .memoryFreePercent, reasonCode: "baseline_missing"),
        TatwoPressureSensorUnavailableV1(sensor: .swapFreeMiB, reasonCode: "parse_failure")
      ])

    XCTAssertEqual(first.unavailableSensorDiagnostics, reordered.unavailableSensorDiagnostics)
    XCTAssertEqual(first.unavailableSensors, reordered.unavailableSensors)
    XCTAssertEqual(try first.canonicalDigest(), try reordered.canonicalDigest())
    XCTAssertNotEqual(try first.canonicalDigest(), try tamperedReason.canonicalDigest())

    let receipt = try TatwoHostPressureReceiptV1.make(
      snapshot: first,
      now: base.addingTimeInterval(1))
    XCTAssertTrue(receipt.verifiesDigest())
    XCTAssertTrue(receipt.verifiesChain(previous: nil))

    let tamperedReceipt = TatwoHostPressureReceiptV1(
      receiptID: receipt.receiptID,
      deviceID: receipt.deviceID,
      observedAt: receipt.observedAt,
      recordedAt: receipt.recordedAt,
      snapshot: tamperedReason,
      classification: tamperedReason.classify(now: receipt.recordedAt),
      lease: receipt.lease,
      admissionDecision: receipt.admissionDecision,
      admissionRequestBinding: receipt.admissionRequestBinding,
      previousReceiptDigest: receipt.previousReceiptDigest,
      receiptDigest: receipt.receiptDigest)
    XCTAssertFalse(tamperedReceipt.verifiesDigest())
    XCTAssertFalse(tamperedReceipt.verifiesChain(previous: nil))
  }

  func testStaleSnapshotIsUnknownNotGreen() {
    let snapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let result = snapshot.classify(now: base.addingTimeInterval(21))
    XCTAssertEqual(result.classification, .unknown)
    XCTAssertTrue(result.reasonCodes.contains("monitor_stale"))
  }

  func testClockSkewAndInvalidNumericSensorsAreUnknown() {
    let future = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
      .copy(observedAt: base.addingTimeInterval(2))
    let skew = future.classify(now: base)
    XCTAssertEqual(skew.classification, .unknown)
    XCTAssertTrue(skew.reasonCodes.contains("monitor_clock_skew"))

    let invalid = makeSnapshot(memory: .nan, swap: -1, data: 40, load: 0.2)
    let result = invalid.classify(now: base.addingTimeInterval(1))
    XCTAssertEqual(result.classification, .unknown)
    XCTAssertTrue(result.reasonCodes.contains("sensor_invalid:memory_free_percent"))
    XCTAssertTrue(result.reasonCodes.contains("sensor_out_of_range:swap_free_mib"))
  }

  func testRedClassificationTakesPrecedenceAndCarriesStopReasons() {
    let snapshot = makeSnapshot(
      memory: 10,
      swap: 400,
      data: 10,
      load: 1.2,
      thermal: true,
      uiLatency: 3_000,
      swapGrowth: 200)
    let result = snapshot.classify(now: base.addingTimeInterval(1))
    XCTAssertEqual(result.classification, .red)
    XCTAssertTrue(result.reasonCodes.contains("memory_free_below_15_percent"))
    XCTAssertTrue(result.reasonCodes.contains("swap_free_below_512_mib"))
    XCTAssertTrue(result.reasonCodes.contains("data_volume_free_below_15_gib"))
    XCTAssertTrue(result.reasonCodes.contains("thermal_warning"))
    XCTAssertTrue(result.reasonCodes.contains("ui_latency_at_or_over_3s"))
    XCTAssertTrue(result.reasonCodes.contains("swap_growth_rapid"))
    XCTAssertFalse(result.reasonCodes.contains("load1_per_cpu_at_or_above_0_7"))
  }

  func testYellowClassificationBlocksHeavyButAllowsBoundLightContinuationWithoutSpawnAuthorization() throws {
    let snapshot = makeSnapshot(memory: 20, swap: 800, data: 20, load: 0.8)
    let heavyLease = try TatwoPressureLeaseV1.issue(
      for: snapshot,
      now: base.addingTimeInterval(1))
    XCTAssertEqual(heavyLease.classification, .yellow)

    let heavy = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: "mini-A",
      loopID: "loop-heavy",
      workload: .heavy,
      lease: heavyLease,
      now: base.addingTimeInterval(2))
    XCTAssertFalse(heavy.accepted)
    XCTAssertFalse(heavy.authorizesSpawn)
    XCTAssertEqual(heavy.reasonCode, "pressure_yellow_heavy_rejected")
    XCTAssertEqual(heavy.stopAction, .none)

    let request = makeRequest(loopID: "loop-light", workload: .light)
    let requestBinding = try TatwoLoopAdmissionRequestBindingV1.make(for: request)
    let lightLease = try scopedLease(
      for: snapshot,
      request: request,
      binding: requestBinding,
      now: base.addingTimeInterval(1))
    let light = scopedDecision(
      for: request,
      binding: requestBinding,
      lease: lightLease,
      now: base.addingTimeInterval(2))
    XCTAssertFalse(light.accepted)
    XCTAssertFalse(light.authorizesSpawn)
    XCTAssertEqual(light.reasonCode, "pressure_yellow_light_only")
  }

  func testGreenLeaseAcceptsBoundHeavyAndLightAdmissionWithSpawnAuthorization() throws {
    let snapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    for workload in [TatwoPressureWorkerClassV1.heavy, .light] {
      let request = makeRequest(loopID: "loop-green-\(workload.rawValue)", workload: workload)
      let requestBinding = try TatwoLoopAdmissionRequestBindingV1.make(for: request)
      let lease = try scopedLease(
        for: snapshot,
        request: request,
        binding: requestBinding,
        now: base)
      let decision = scopedDecision(
        for: request,
        binding: requestBinding,
        lease: lease,
        now: base.addingTimeInterval(1))
      XCTAssertTrue(decision.accepted)
      XCTAssertTrue(decision.authorizesSpawn)
      XCTAssertEqual(decision.reasonCode, "pressure_green")
      XCTAssertEqual(decision.stopAction, .none)
    }
  }

  func testInvalidRuntimeSentinelCannotAuthorizeAcceptedAdmissionOrReceipt() throws {
    let snapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let request = makeRequest(loopID: "loop-invalid-runtime", workload: .heavy)
    let requestBinding = try TatwoLoopAdmissionRequestBindingV1.make(for: request)
    let sentinelRuntimeID = "invalid-runtime-instance-id"
    let lease = try scopedLease(
      for: snapshot,
      request: request,
      binding: requestBinding,
      now: base,
      runtimeInstanceID: sentinelRuntimeID)

    let decision = scopedDecision(
      for: request,
      binding: requestBinding,
      lease: lease,
      now: base.addingTimeInterval(1),
      runtimeInstanceID: sentinelRuntimeID)
    XCTAssertFalse(decision.accepted)
    XCTAssertFalse(decision.authorizesSpawn)
    XCTAssertEqual(decision.reasonCode, "pressure_lease_runtime_missing")

    let forgedAccepted = TatwoLoopAdmissionDecisionV1(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      decidedAt: base.addingTimeInterval(1),
      classification: .green,
      accepted: true,
      authorizesSpawn: true,
      reasonCode: "pressure_green",
      reason: "forged accepted decision over invalid runtime sentinel",
      stopAction: .none,
      leaseID: lease.leaseID,
      requestBindingDigest: requestBinding.requestBindingDigest,
      runtimeInstanceID: sentinelRuntimeID,
      runtimeGeneration: 1,
      admissionAttemptID: request.attemptID,
      dispatchNonce: request.dispatchNonce,
      reservationID: reservationID(for: request, binding: requestBinding),
      sourceSnapshotSequence: lease.sourceSnapshotSequence,
      sourceSampleAttemptID: lease.sourceSampleAttemptID,
      leaseDigest: lease.leaseDigest)
    XCTAssertThrowsError(
      try TatwoHostPressureReceiptV1.make(
        snapshot: snapshot,
        now: base.addingTimeInterval(1),
        lease: lease,
        admissionDecision: forgedAccepted,
        admissionRequestBinding: requestBinding)) { error in
      XCTAssertEqual(error as? TatwoPressureReceiptError, .decisionLeaseMismatch)
    }
  }

  func testMissingStaleUnknownRedMismatchAndInvalidLeasesRejectAssignments() throws {
    let missing = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: "mini-A",
      loopID: "loop-missing",
      workload: .light,
      lease: nil,
      now: base)
    XCTAssertFalse(missing.accepted)
    XCTAssertEqual(missing.reasonCode, "monitor_unknown")

    let greenLease = try TatwoPressureLeaseV1.issue(
      for: makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2),
      now: base)
    let stale = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: "mini-A",
      loopID: "loop-stale",
      workload: .light,
      lease: greenLease,
      now: base.addingTimeInterval(16))
    XCTAssertFalse(stale.accepted)
    XCTAssertEqual(stale.reasonCode, "monitor_unknown")
    XCTAssertEqual(stale.stopAction, .checkpointExistingWork)

    let notYetValid = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: "mini-A",
      loopID: "loop-future",
      workload: .light,
      lease: greenLease,
      now: base.addingTimeInterval(-2))
    XCTAssertFalse(notYetValid.accepted)
    XCTAssertEqual(notYetValid.reasonCode, "monitor_unknown")

    let mismatch = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: "macbook-B",
      loopID: "loop-mismatch",
      workload: .light,
      lease: greenLease,
      now: base.addingTimeInterval(1))
    XCTAssertFalse(mismatch.accepted)
    XCTAssertEqual(mismatch.reasonCode, "pressure_lease_device_mismatch")

    let invalidID = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: "mini-A",
      loopID: "/tmp/tatwo2-fixture/private-loop",
      workload: .light,
      lease: greenLease,
      now: base.addingTimeInterval(1))
    XCTAssertFalse(invalidID.accepted)
    XCTAssertEqual(invalidID.reasonCode, "monitor_unknown")
    XCTAssertEqual(invalidID.loopID, "invalid-loop-id")

    let unknownLease = try TatwoPressureLeaseV1.issue(
      for: TatwoDevicePressureSnapshotV1(
        deviceID: "mini-A",
        observedAt: base,
        memoryFreePercent: nil,
        swapFreeMiB: 2_048,
        dataVolumeFreeGiB: 40,
        load1PerCPU: 0.2,
        thermalWarning: false,
        uiLatencyMilliseconds: 10,
        swapGrowthMiBPerMinute: 0),
      now: base.addingTimeInterval(1))
    let unknown = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: "mini-A",
      loopID: "loop-unknown",
      workload: .light,
      lease: unknownLease,
      now: base.addingTimeInterval(2))
    XCTAssertFalse(unknown.accepted)
    XCTAssertEqual(unknown.reasonCode, "monitor_unknown")

    let redLease = try TatwoPressureLeaseV1.issue(
      for: makeSnapshot(memory: 10, swap: 400, data: 10, load: 0.2),
      now: base.addingTimeInterval(1))
    let workers = [
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
    ]
    let red = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: "mini-A",
      loopID: "loop-red",
      workload: .light,
      lease: redLease,
      now: base.addingTimeInterval(2),
      workers: workers)
    XCTAssertFalse(red.accepted)
    XCTAssertEqual(red.reasonCode, "pressure_red")
    XCTAssertEqual(red.stopAction, .checkpointAndStopNewestOrHeaviestWorker)
    XCTAssertEqual(red.targetWorkerID, "heavy-newest")
    let redWithoutWorkers = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: "mini-A",
      loopID: "loop-red-empty",
      workload: .light,
      lease: redLease,
      now: base.addingTimeInterval(2))
    XCTAssertFalse(redWithoutWorkers.accepted)
    XCTAssertEqual(redWithoutWorkers.stopAction, .checkpointExistingWork)
    XCTAssertNil(redWithoutWorkers.targetWorkerID)
  }

  func testLeaseTTLRunnerFreshnessAndSnapshotAgeAreDistinct() throws {
    let lease = try TatwoPressureLeaseV1.issue(
      for: makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2),
      now: base,
      ttlSeconds: 20)
    XCTAssertEqual(lease.freshness(now: base.addingTimeInterval(15)), .fresh)
    XCTAssertEqual(lease.freshness(now: base.addingTimeInterval(16)), .stale)
    XCTAssertEqual(lease.freshness(now: base.addingTimeInterval(21)), .expired)
    XCTAssertEqual(lease.freshness(now: base.addingTimeInterval(-2)), .notYetValid)
    XCTAssertEqual(lease.freshness(now: base.addingTimeInterval(1), maxAgeSeconds: 3_600), .fresh)
    XCTAssertEqual(lease.freshness(now: base.addingTimeInterval(16), maxAgeSeconds: 3_600), .stale)

    let oldSnapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let stackedLease = try TatwoPressureLeaseV1.issue(
      for: oldSnapshot,
      now: base.addingTimeInterval(20),
      ttlSeconds: 20)
    let decision = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: "mini-A",
      loopID: "loop-stacked",
      workload: .light,
      lease: stackedLease,
      now: base.addingTimeInterval(35))
    XCTAssertFalse(decision.accepted)
    XCTAssertEqual(decision.reasonCode, "monitor_unknown")
    XCTAssertTrue(decision.reason.contains("snapshot is stale"))
  }

  func testHostPressureReceiptIsHashChainedAndVerifiable() throws {
    let snapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let request = makeRequest(loopID: "loop-green", workload: .heavy)
    let requestBinding = try TatwoLoopAdmissionRequestBindingV1.make(for: request)
    let lease = try scopedLease(
      for: snapshot,
      request: request,
      binding: requestBinding,
      now: base)
    let decision = scopedDecision(
      for: request,
      binding: requestBinding,
      lease: lease,
      now: base.addingTimeInterval(1))
    XCTAssertTrue(decision.authorizesSpawn)
    let first = try TatwoHostPressureReceiptV1.make(
      snapshot: snapshot,
      now: base.addingTimeInterval(1),
      lease: lease,
      admissionDecision: decision,
      admissionRequestBinding: requestBinding)
    XCTAssertTrue(first.verifiesDigest())
    XCTAssertTrue(first.verifiesChain(previous: nil))
    XCTAssertNotNil(first.receiptDigest)
    XCTAssertEqual(first.observedAt, snapshot.observedAt)
    XCTAssertEqual(first.recordedAt, base.addingTimeInterval(1))

    let tampered = TatwoHostPressureReceiptV1(
      receiptID: first.receiptID,
      deviceID: first.deviceID,
      observedAt: first.observedAt,
      recordedAt: first.recordedAt,
      snapshot: first.snapshot,
      classification: first.classification,
      lease: first.lease,
      admissionDecision: first.admissionDecision,
      admissionRequestBinding: first.admissionRequestBinding,
      previousReceiptDigest: first.previousReceiptDigest,
      receiptDigest: "sha256:tampered")
    XCTAssertFalse(tampered.verifiesDigest())

    let second = try TatwoHostPressureReceiptV1.make(
      snapshot: snapshot,
      now: base.addingTimeInterval(2),
      lease: lease,
      admissionDecision: decision,
      admissionRequestBinding: requestBinding,
      previousReceiptDigest: first.receiptDigest)
    XCTAssertTrue(second.verifiesDigest())
    XCTAssertTrue(second.verifiesChain(previous: first))
    XCTAssertEqual(second.previousReceiptDigest, first.receiptDigest)
    XCTAssertNotEqual(second.receiptDigest, first.receiptDigest)
  }

  func testReceiptChainRejectsCrossDeviceAndOutOfOrderLinks() throws {
    let miniSnapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let first = try TatwoHostPressureReceiptV1.make(
      snapshot: miniSnapshot,
      now: base.addingTimeInterval(1))
    let macbookSnapshot = TatwoDevicePressureSnapshotV1(
      deviceID: "macbook-B",
      observedAt: base,
      memoryFreePercent: 40,
      swapFreeMiB: 2_048,
      dataVolumeFreeGiB: 40,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 20,
      swapGrowthMiBPerMinute: 0)
    let crossDevice = try TatwoHostPressureReceiptV1.make(
      snapshot: macbookSnapshot,
      now: base.addingTimeInterval(2),
      previousReceiptDigest: first.receiptDigest)
    XCTAssertTrue(crossDevice.verifiesDigest())
    XCTAssertFalse(crossDevice.verifiesChain(previous: first))

    let outOfOrder = try TatwoHostPressureReceiptV1.make(
      snapshot: miniSnapshot,
      now: base.addingTimeInterval(0.5),
      previousReceiptDigest: first.receiptDigest)
    XCTAssertTrue(outOfOrder.verifiesDigest())
    XCTAssertFalse(outOfOrder.verifiesChain(previous: first))
  }

  func testReceiptRejectsTopLevelFieldForgeryEvenWithRecomputedDigest() throws {
    let snapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let receipt = try TatwoHostPressureReceiptV1.make(
      snapshot: snapshot,
      now: base.addingTimeInterval(1))

    let wrongDevice = try resignForTest(TatwoHostPressureReceiptV1(
      receiptID: receipt.receiptID,
      deviceID: "macbook-B",
      observedAt: receipt.observedAt,
      recordedAt: receipt.recordedAt,
      snapshot: receipt.snapshot,
      classification: receipt.classification,
      lease: receipt.lease,
      admissionDecision: receipt.admissionDecision,
      previousReceiptDigest: receipt.previousReceiptDigest))
    XCTAssertFalse(wrongDevice.verifiesDigest())

    let wrongObservedAt = try resignForTest(TatwoHostPressureReceiptV1(
      receiptID: receipt.receiptID,
      deviceID: receipt.deviceID,
      observedAt: base.addingTimeInterval(0.5),
      recordedAt: receipt.recordedAt,
      snapshot: receipt.snapshot,
      classification: receipt.classification,
      lease: receipt.lease,
      admissionDecision: receipt.admissionDecision,
      previousReceiptDigest: receipt.previousReceiptDigest))
    XCTAssertFalse(wrongObservedAt.verifiesDigest())

    let wrongReceiptID = try resignForTest(TatwoHostPressureReceiptV1(
      receiptID: receipt.receiptDigest ?? receipt.receiptID,
      deviceID: receipt.deviceID,
      observedAt: receipt.observedAt,
      recordedAt: receipt.recordedAt,
      snapshot: receipt.snapshot,
      classification: receipt.classification,
      lease: receipt.lease,
      admissionDecision: receipt.admissionDecision,
      previousReceiptDigest: receipt.previousReceiptDigest))
    XCTAssertFalse(wrongReceiptID.verifiesDigest())
  }

  func testReceiptRejectsMismatchedLeaseAndDecisionEvidence() throws {
    let greenSnapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let redSnapshot = makeSnapshot(memory: 10, swap: 400, data: 10, load: 0.2)
    let greenLease = try TatwoPressureLeaseV1.issue(for: greenSnapshot, now: base)
    XCTAssertThrowsError(
      try TatwoHostPressureReceiptV1.make(
        snapshot: redSnapshot,
        now: base.addingTimeInterval(1),
        lease: greenLease)) { error in
      XCTAssertEqual(error as? TatwoPressureReceiptError, .leaseSnapshotMismatch)
    }

    let forgedClassification = TatwoPressureClassificationResultV1(
      classification: .green,
      reasonCodes: ["within_green_thresholds"],
      classifiedAt: base)
    let forgedReceipt = TatwoHostPressureReceiptV1(
      receiptID: "sha256:forged",
      deviceID: redSnapshot.deviceID,
      observedAt: redSnapshot.observedAt,
      recordedAt: base,
      snapshot: redSnapshot,
      classification: forgedClassification,
      lease: nil,
      admissionDecision: nil,
      previousReceiptDigest: nil,
      receiptDigest: "sha256:forged")
    XCTAssertFalse(forgedReceipt.verifiesDigest())

    let badDecision = TatwoLoopAdmissionDecisionV1(
      deviceID: "mini-A",
      loopID: "loop-bad",
      workload: .light,
      decidedAt: base,
      classification: .green,
      accepted: true,
      reasonCode: "pressure_green",
      reason: "ok",
      stopAction: .none,
      leaseID: "sha256:other",
      requestBindingDigest: try bindingDigest(loopID: "loop-bad", workload: .light),
      dispatchNonce: "dispatch-loop-bad")
    XCTAssertThrowsError(
      try TatwoHostPressureReceiptV1.make(
        snapshot: greenSnapshot,
        now: base.addingTimeInterval(1),
        lease: greenLease,
        admissionDecision: badDecision,
        admissionRequestBinding: try binding(loopID: "loop-bad", workload: .light))) { error in
      XCTAssertEqual(error as? TatwoPressureReceiptError, .decisionLeaseMismatch)
    }

    let acceptedMissingRequestBinding = TatwoLoopAdmissionDecisionV1(
      deviceID: "mini-A",
      loopID: "loop-missing-request-binding",
      workload: .light,
      decidedAt: base.addingTimeInterval(1),
      classification: .green,
      accepted: true,
      authorizesSpawn: true,
      reasonCode: "pressure_green",
      reason: "forged",
      stopAction: .none,
      leaseID: greenLease.leaseID,
      dispatchNonce: "dispatch-loop-missing-request-binding",
      leaseDigest: greenLease.leaseDigest)
    XCTAssertThrowsError(
      try TatwoHostPressureReceiptV1.make(
        snapshot: greenSnapshot,
        now: base.addingTimeInterval(1),
        lease: greenLease,
        admissionDecision: acceptedMissingRequestBinding)) { error in
      XCTAssertEqual(error as? TatwoPressureReceiptError, .decisionRequestBindingDigestMismatch)
    }
  }

  func testReceiptRecomputesAdmissionRequestBindingInsteadOfAcceptingShaShapeOnly() throws {
    let snapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let request = makeRequest(loopID: "loop-request-binding", workload: .light)
    let binding = try TatwoLoopAdmissionRequestBindingV1.make(for: request)
    let lease = try scopedLease(
      for: snapshot,
      request: request,
      binding: binding,
      now: base)
    let decision = scopedDecision(
      for: request,
      binding: binding,
      lease: lease,
      now: base.addingTimeInterval(1))
    XCTAssertTrue(decision.accepted)

    let receipt = try TatwoHostPressureReceiptV1.make(
      snapshot: snapshot,
      now: base.addingTimeInterval(1),
      lease: lease,
      admissionDecision: decision,
      admissionRequestBinding: binding)
    XCTAssertTrue(receipt.verifiesDigest())

    let tamperedBinding = TatwoLoopAdmissionRequestBindingV1(
      request: request,
      canonicalRequestJSON: binding.canonicalRequestJSON.replacingOccurrences(
        of: request.loopID,
        with: "loop-tampered"),
      requestBindingDigest: binding.requestBindingDigest)
    XCTAssertThrowsError(
      try TatwoHostPressureReceiptV1.make(
        snapshot: snapshot,
        now: base.addingTimeInterval(1),
        lease: lease,
        admissionDecision: decision,
        admissionRequestBinding: tamperedBinding)) { error in
      XCTAssertEqual(error as? TatwoPressureReceiptError, .admissionRequestBindingMismatch)
    }
  }

  func testReceiptRejectsAcceptedDecisionLegalityForgery() throws {
    let greenSnapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let greenLease = try TatwoPressureLeaseV1.issue(for: greenSnapshot, now: base)
    let acceptedWithoutLease = TatwoLoopAdmissionDecisionV1(
      deviceID: "mini-A",
      loopID: "loop-no-lease",
      workload: .light,
      decidedAt: base.addingTimeInterval(1),
      classification: .green,
      accepted: true,
      reasonCode: "pressure_green",
      reason: "forged",
      stopAction: .none,
      leaseID: nil,
      requestBindingDigest: try bindingDigest(loopID: "loop-no-lease", workload: .light),
      dispatchNonce: "dispatch-loop-no-lease")
    XCTAssertThrowsError(
      try TatwoHostPressureReceiptV1.make(
        snapshot: greenSnapshot,
        now: base.addingTimeInterval(1),
        admissionDecision: acceptedWithoutLease,
        admissionRequestBinding: try binding(loopID: "loop-no-lease", workload: .light))) { error in
      XCTAssertEqual(error as? TatwoPressureReceiptError, .decisionLeaseMismatch)
    }

    let redSnapshot = makeSnapshot(memory: 10, swap: 400, data: 10, load: 0.2)
    let greenOverRed = TatwoLoopAdmissionDecisionV1(
      deviceID: "mini-A",
      loopID: "loop-red-forged-green",
      workload: .light,
      decidedAt: base.addingTimeInterval(1),
      classification: .green,
      accepted: true,
      reasonCode: "pressure_green",
      reason: "forged",
      stopAction: .none,
      leaseID: greenLease.leaseID,
      requestBindingDigest: try bindingDigest(loopID: "loop-red-forged-green", workload: .light),
      dispatchNonce: "dispatch-loop-red-forged-green",
      leaseDigest: greenLease.leaseDigest)
    XCTAssertThrowsError(
      try TatwoHostPressureReceiptV1.make(
        snapshot: redSnapshot,
        now: base.addingTimeInterval(1),
        lease: greenLease,
        admissionDecision: greenOverRed,
        admissionRequestBinding: try binding(loopID: "loop-red-forged-green", workload: .light))) { error in
      XCTAssertEqual(error as? TatwoPressureReceiptError, .leaseSnapshotMismatch)
    }

    let redLease = try TatwoPressureLeaseV1.issue(for: redSnapshot, now: base)
    let acceptedGreenOnRedLease = TatwoLoopAdmissionDecisionV1(
      deviceID: "mini-A",
      loopID: "loop-red-lease-forged-green",
      workload: .light,
      decidedAt: base.addingTimeInterval(1),
      classification: .green,
      accepted: true,
      reasonCode: "pressure_green",
      reason: "forged",
      stopAction: .none,
      leaseID: redLease.leaseID,
      requestBindingDigest: try bindingDigest(loopID: "loop-red-lease-forged-green", workload: .light),
      dispatchNonce: "dispatch-loop-red-lease-forged-green",
      leaseDigest: redLease.leaseDigest)
    XCTAssertThrowsError(
      try TatwoHostPressureReceiptV1.make(
        snapshot: redSnapshot,
        now: base.addingTimeInterval(1),
        lease: redLease,
        admissionDecision: acceptedGreenOnRedLease,
        admissionRequestBinding: try binding(loopID: "loop-red-lease-forged-green", workload: .light))) { error in
      XCTAssertEqual(error as? TatwoPressureReceiptError, .decisionClassificationMismatch)
    }

    let yellowSnapshot = makeSnapshot(memory: 20, swap: 800, data: 20, load: 0.8)
    let yellowLease = try TatwoPressureLeaseV1.issue(for: yellowSnapshot, now: base)
    let acceptedYellowHeavy = TatwoLoopAdmissionDecisionV1(
      deviceID: "mini-A",
      loopID: "loop-yellow-heavy",
      workload: .heavy,
      decidedAt: base.addingTimeInterval(1),
      classification: .yellow,
      accepted: true,
      reasonCode: "pressure_yellow_light_only",
      reason: "forged",
      stopAction: .none,
      leaseID: yellowLease.leaseID,
      requestBindingDigest: try bindingDigest(loopID: "loop-yellow-heavy", workload: .heavy),
      dispatchNonce: "dispatch-loop-yellow-heavy",
      leaseDigest: yellowLease.leaseDigest)
    XCTAssertThrowsError(
      try TatwoHostPressureReceiptV1.make(
        snapshot: yellowSnapshot,
        now: base.addingTimeInterval(1),
        lease: yellowLease,
        admissionDecision: acceptedYellowHeavy,
        admissionRequestBinding: try binding(loopID: "loop-yellow-heavy", workload: .heavy))) { error in
      XCTAssertEqual(error as? TatwoPressureReceiptError, .decisionClassificationMismatch)
    }

    let staleAccepted = TatwoLoopAdmissionDecisionV1(
      deviceID: "mini-A",
      loopID: "loop-stale-accepted",
      workload: .light,
      decidedAt: base.addingTimeInterval(16),
      classification: .green,
      accepted: true,
      reasonCode: "pressure_green",
      reason: "forged",
      stopAction: .none,
      leaseID: greenLease.leaseID,
      requestBindingDigest: try bindingDigest(loopID: "loop-stale-accepted", workload: .light),
      dispatchNonce: "dispatch-loop-stale-accepted",
      leaseDigest: greenLease.leaseDigest)
    XCTAssertThrowsError(
      try TatwoHostPressureReceiptV1.make(
        snapshot: greenSnapshot,
        now: base.addingTimeInterval(16),
        lease: greenLease,
        admissionDecision: staleAccepted,
        admissionRequestBinding: try binding(loopID: "loop-stale-accepted", workload: .light))) { error in
      XCTAssertEqual(error as? TatwoPressureReceiptError, .decisionLeaseMismatch)
    }
  }

  func testBoundLeaseCannotAuthorizeNilExpectedRequestOrDispatch() throws {
    let snapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let request = makeRequest(loopID: "loop-bound-nil", workload: .light)
    let binding = try TatwoLoopAdmissionRequestBindingV1.make(for: request)
    let lease = try TatwoPressureLeaseV1.issue(
      for: snapshot,
      now: base,
      admissionRequestBindingDigest: binding.requestBindingDigest,
      dispatchNonce: request.dispatchNonce)

    let missingRequestDigest = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      lease: lease,
      now: base.addingTimeInterval(1),
      dispatchNonce: request.dispatchNonce)
    XCTAssertFalse(missingRequestDigest.accepted)
    XCTAssertFalse(missingRequestDigest.authorizesSpawn)
    XCTAssertEqual(missingRequestDigest.reasonCode, "pressure_lease_request_binding_missing")

    let missingDispatch = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      lease: lease,
      now: base.addingTimeInterval(1),
      requestBindingDigest: binding.requestBindingDigest)
    XCTAssertFalse(missingDispatch.accepted)
    XCTAssertEqual(missingDispatch.reasonCode, "pressure_lease_dispatch_nonce_missing")
  }

  func testReceiptRejectsAcceptedDecisionWithUnscopedLeaseBinding() throws {
    let snapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let lease = try TatwoPressureLeaseV1.issue(for: snapshot, now: base)
    let binding = try binding(loopID: "loop-unscoped-lease", workload: .light)
    let forgedAccepted = TatwoLoopAdmissionDecisionV1(
      deviceID: "mini-A",
      loopID: binding.request.loopID,
      workload: binding.request.workload,
      decidedAt: base.addingTimeInterval(1),
      classification: .green,
      accepted: true,
      reasonCode: "pressure_green",
      reason: "forged request-scoped decision over unscoped lease",
      stopAction: .none,
      leaseID: lease.leaseID,
      requestBindingDigest: binding.requestBindingDigest,
      dispatchNonce: binding.request.dispatchNonce,
      leaseDigest: lease.leaseDigest)

    XCTAssertThrowsError(
      try TatwoHostPressureReceiptV1.make(
        snapshot: snapshot,
        now: base.addingTimeInterval(1),
        lease: lease,
        admissionDecision: forgedAccepted,
        admissionRequestBinding: binding)) { error in
      XCTAssertEqual(error as? TatwoPressureReceiptError, .decisionLeaseMismatch)
    }
  }

  func testDecodedDecisionRedactsReasonAndIdentifiers() throws {
    let json = """
      {
        "accepted": false,
        "classification": "unknown",
        "decidedAt": 1786438000.25,
        "deviceID": "mini-A",
        "leaseID": "sha256:abc",
        "loopID": "/tmp/tatwo2-fixture/private-loop",
        "reason": "failed at /tmp/tatwo2-fixture/private/path with sk-abcdefghijklmnop",
        "reasonCode": "monitor_unknown",
        "schema": "TatwoLoopAdmissionDecisionV1",
        "stopAction": "checkpointExistingWork",
        "targetWorkerID": null,
        "workload": "light"
      }
      """
    let decoded = try JSONDecoder().decode(
      TatwoLoopAdmissionDecisionV1.self,
      from: Data(json.utf8))
    XCTAssertEqual(decoded.loopID, "invalid-loop-id")
    XCTAssertFalse(decoded.reason.contains("/Users"))
    XCTAssertFalse(decoded.reason.contains("sk-abcdefghijklmnop"))
  }

  func testDecodedLeaseAndClassificationNormalizeReasonCodes() throws {
    let leaseJSON = """
      {
        "classification": "unknown",
        "deviceID": "mini-A",
        "expiresAt": 1786438020.25,
        "issuedAt": 1786438000.25,
        "issuer": "tatwo-app",
        "leaseID": "sha256:abc",
        "reasonCodes": ["sensor_unavailable:/tmp/tatwo2-fixture/private", "sensor_unavailable:/tmp/tatwo2-fixture/private"],
        "schema": "TatwoPressureLeaseV1",
        "snapshotDigest": "sha256:def",
        "snapshotObservedAt": 1786438000.25
      }
      """
    let lease = try JSONDecoder().decode(TatwoPressureLeaseV1.self, from: Data(leaseJSON.utf8))
    XCTAssertEqual(lease.reasonCodes.count, 1)
    XCTAssertFalse(lease.reasonCodes[0].contains("/Users"))

    let resultJSON = """
      {
        "classification": "unknown",
        "classifiedAt": 1786438000.25,
        "reasonCodes": ["sensor_unavailable:/tmp/tatwo2-fixture/private"],
        "schema": "TatwoPressureClassificationResultV1"
      }
      """
    let result = try JSONDecoder().decode(
      TatwoPressureClassificationResultV1.self,
      from: Data(resultJSON.utf8))
    XCTAssertFalse(result.reasonCodes[0].contains("/Users"))
  }

  func testCodableRoundTripKeepsCanonicalSchemaNames() throws {
    let snapshot = makeSnapshot(memory: 40, swap: 2_048, data: 40, load: 0.2)
    let lease = try TatwoPressureLeaseV1.issue(for: snapshot, now: base)
    let receipt = try TatwoHostPressureReceiptV1.make(
      snapshot: snapshot,
      now: base,
      lease: lease)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(receipt)
    let decoded = try JSONDecoder().decode(TatwoHostPressureReceiptV1.self, from: data)
    XCTAssertEqual(decoded.schema, "TatwoHostPressureReceiptV1")
    XCTAssertEqual(decoded.snapshot.schema, "TatwoDevicePressureSnapshotV1")
    XCTAssertEqual(decoded.lease?.schema, "TatwoPressureLeaseV1")
    XCTAssertEqual(decoded, receipt)
  }

  private func makeSnapshot(
    memory: Double,
    swap: Double,
    data: Double,
    load: Double,
    thermal: Bool = false,
    uiLatency: Double = 20,
    swapGrowth: Double = 0
  ) -> TatwoDevicePressureSnapshotV1 {
      TatwoDevicePressureSnapshotV1(
        deviceID: "mini-A",
        observedAt: base,
        sourceSnapshotSequence: 1,
        sourceSampleAttemptID: "sample-\(memory)-\(swap)-\(data)-\(load)",
        memoryFreePercent: memory,
        swapFreeMiB: swap,
        dataVolumeFreeGiB: data,
        load1PerCPU: load,
        thermalWarning: thermal,
        uiLatencyMilliseconds: uiLatency,
        swapGrowthMiBPerMinute: swapGrowth)
  }

  private func resignForTest(
    _ receipt: TatwoHostPressureReceiptV1
  ) throws -> TatwoHostPressureReceiptV1 {
    TatwoHostPressureReceiptV1(
      receiptID: receipt.receiptID,
      deviceID: receipt.deviceID,
      observedAt: receipt.observedAt,
      recordedAt: receipt.recordedAt,
      snapshot: receipt.snapshot,
      classification: receipt.classification,
      lease: receipt.lease,
      admissionDecision: receipt.admissionDecision,
      admissionRequestBinding: receipt.admissionRequestBinding,
      previousReceiptDigest: receipt.previousReceiptDigest,
      receiptDigest: try receipt.canonicalDigest())
  }

  private func reservationID(
    for request: TatwoLoopAdmissionRequestV1,
    binding: TatwoLoopAdmissionRequestBindingV1,
    generation: UInt64 = 1
  ) -> String {
    TatwoLoopJobDigest.sha256(
      Data("monitor-test-reservation|\(request.jobID)|\(binding.requestBindingDigest)|\(generation)".utf8))
  }

  private func scopedLease(
    for snapshot: TatwoDevicePressureSnapshotV1,
    request: TatwoLoopAdmissionRequestV1,
    binding: TatwoLoopAdmissionRequestBindingV1,
    now: Date,
    ttlSeconds: TimeInterval = TatwoPressureLeaseV1.defaultTTLSeconds,
    runtimeInstanceID: String = "runtime-monitor-tests",
    runtimeGeneration: UInt64 = 1
  ) throws -> TatwoPressureLeaseV1 {
    try TatwoPressureLeaseV1.issue(
      for: snapshot,
      now: now,
      ttlSeconds: ttlSeconds,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: request.attemptID,
      admissionRequestBindingDigest: binding.requestBindingDigest,
      dispatchNonce: request.dispatchNonce,
      reservationID: reservationID(for: request, binding: binding, generation: runtimeGeneration))
  }

  private func scopedDecision(
    for request: TatwoLoopAdmissionRequestV1,
    binding: TatwoLoopAdmissionRequestBindingV1,
    lease: TatwoPressureLeaseV1,
    now: Date,
    runtimeInstanceID: String = "runtime-monitor-tests",
    runtimeGeneration: UInt64 = 1
  ) -> TatwoLoopAdmissionDecisionV1 {
    TatwoLoopAdmissionDecisionV1.decide(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      lease: lease,
      now: now,
      requestBindingDigest: binding.requestBindingDigest,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: request.attemptID,
      dispatchNonce: request.dispatchNonce,
      reservationID: reservationID(for: request, binding: binding, generation: runtimeGeneration))
  }

  private func makeRequest(
    loopID: String,
    workload: TatwoPressureWorkerClassV1
  ) -> TatwoLoopAdmissionRequestV1 {
    TatwoLoopAdmissionRequestV1(
      jobID: "job-\(loopID)",
      attemptID: "attempt-\(loopID)",
      dispatchNonce: "dispatch-\(loopID)",
      deviceID: "mini-A",
      loopID: loopID,
      workload: workload,
      contractID: "contract-W1C",
      goalHash: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      planHash: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      requestedAt: base)
  }

  private func binding(
    loopID: String,
    workload: TatwoPressureWorkerClassV1
  ) throws -> TatwoLoopAdmissionRequestBindingV1 {
    try TatwoLoopAdmissionRequestBindingV1.make(for: makeRequest(loopID: loopID, workload: workload))
  }

  private func bindingDigest(
    loopID: String,
    workload: TatwoPressureWorkerClassV1
  ) throws -> String {
    try binding(loopID: loopID, workload: workload).requestBindingDigest
  }
}

extension TatwoDevicePressureSnapshotV1 {
  fileprivate func copy(observedAt: Date) -> TatwoDevicePressureSnapshotV1 {
    TatwoDevicePressureSnapshotV1(
      schema: schema,
      deviceID: deviceID,
      observedAt: observedAt,
      memoryFreePercent: memoryFreePercent,
      swapFreeMiB: swapFreeMiB,
      dataVolumeFreeGiB: dataVolumeFreeGiB,
      load1PerCPU: load1PerCPU,
      thermalWarning: thermalWarning,
      uiLatencyMilliseconds: uiLatencyMilliseconds,
      swapGrowthMiBPerMinute: swapGrowthMiBPerMinute,
      unavailableSensors: unavailableSensors,
      unavailableSensorDiagnostics: unavailableSensorDiagnostics,
      activeLoopID: activeLoopID,
      workers: workers)
  }
}
