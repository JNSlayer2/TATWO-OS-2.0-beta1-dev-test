import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoDeviceHostInventoryCollectorTests: XCTestCase {
  func testCollectOnceReadsHardwareModelRAMAndLocalConnection() {
    let inventory = TatwoDeviceHostInventoryCollector.collectOnce(
      activeLoopCount: 2,
      connectionStatus: .local)
    #if os(macOS)
    let collected = inventory
    XCTAssertNotNil(collected)
    XCTAssertEqual(collected?.connectionStatus, .local)
    XCTAssertEqual(collected?.activeLoopCount, 2)
    XCTAssertFalse(collected?.hardwareModel?.isEmpty ?? true)
    XCTAssertFalse(collected?.chipName?.isEmpty ?? true)
    XCTAssertGreaterThan(collected?.ramTotalBytes ?? 0, 0)
    XCTAssertNil(collected?.cpuPercent, "first collect has no prior HOST_CPU_LOAD_INFO sample")
    #else
    _ = inventory
    #endif
  }

  func testSecondCollectCanProduceCPUPercentAndPressureMapping() {
    var collector = TatwoDeviceHostInventoryCollector()
    _ = collector.collect(activeLoopCount: 0, connectionStatus: .local)
    let second = collector.collect(activeLoopCount: 1, connectionStatus: .online)
    #if os(macOS)
    XCTAssertEqual(second?.connectionStatus, .online)
    XCTAssertEqual(second?.activeLoopCount, 1)
    if let cpu = second?.cpuPercent {
      XCTAssertGreaterThanOrEqual(cpu, 0)
      XCTAssertLessThanOrEqual(cpu, 100)
    }
    #else
    _ = second
    #endif

    XCTAssertEqual(TatwoDeviceHostInventoryCollector.memoryPressureLevel(fromRawValue: 0), .normal)
    XCTAssertEqual(TatwoDeviceHostInventoryCollector.memoryPressureLevel(fromRawValue: 1), .warn)
    XCTAssertEqual(TatwoDeviceHostInventoryCollector.memoryPressureLevel(fromRawValue: 2), .urgent)
    XCTAssertEqual(TatwoDeviceHostInventoryCollector.memoryPressureLevel(fromRawValue: 4), .critical)
    XCTAssertEqual(TatwoDeviceHostInventoryCollector.memoryPressureLevel(fromRawValue: 99), .unknown)
  }

  func testActiveLoopCountUsesUniqueLoopIDs() {
    let workers = [
      TatwoPressureWorkerV1(workerID: "w1", loopID: "loop-a", workload: .light),
      TatwoPressureWorkerV1(workerID: "w2", loopID: "loop-a", workload: .light),
      TatwoPressureWorkerV1(workerID: "w3", loopID: "loop-b", workload: .heavy),
    ]
    XCTAssertEqual(
      TatwoDeviceHostInventoryV1.activeLoopCount(workers: workers, activeLoopID: "loop-a"),
      2)
    XCTAssertEqual(
      TatwoDeviceHostInventoryV1.activeLoopCount(workers: [], activeLoopID: "loop-only"),
      1)
    XCTAssertEqual(
      TatwoDeviceHostInventoryV1.activeLoopCount(workers: [], activeLoopID: nil),
      0)
  }

  func testHostInventoryDoesNotChangeAdmissionClassificationOrNilDigest() throws {
    let base = Date(timeIntervalSince1970: 1_786_438_000.25)
    let without = TatwoDevicePressureSnapshotV1(
      deviceID: "mini-A",
      observedAt: base,
      memoryFreePercent: 40,
      swapFreeMiB: 2_048,
      dataVolumeFreeGiB: 40,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 20,
      swapGrowthMiBPerMinute: 0)
    let with = TatwoDevicePressureSnapshotV1(
      deviceID: "mini-A",
      observedAt: base,
      memoryFreePercent: 40,
      swapFreeMiB: 2_048,
      dataVolumeFreeGiB: 40,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 20,
      swapGrowthMiBPerMinute: 0,
      hostInventory: TatwoDeviceHostInventoryV1(
        hardwareModel: "Mac15,9",
        chipName: "Apple M2",
        ramTotalBytes: 32_212_254_720,
        cpuPercent: 12.5,
        memoryPressureLevel: .normal,
        connectionStatus: .local,
        activeLoopCount: 1))

    XCTAssertEqual(without.classify(now: base.addingTimeInterval(1)).classification, .green)
    XCTAssertEqual(with.classify(now: base.addingTimeInterval(1)).classification, .green)
    XCTAssertNotEqual(try without.canonicalDigest(), try with.canonicalDigest())

    let encodedWithout = try TatwoPressureCanonicalJSONV1.data(without)
    let json = String(data: encodedWithout, encoding: .utf8) ?? ""
    XCTAssertFalse(json.contains("hostInventory"), json)
    XCTAssertNil(without.hostInventory)

    let decoded = try TatwoPressureCanonicalJSONV1.decoder().decode(
      TatwoDevicePressureSnapshotV1.self,
      from: encodedWithout)
    XCTAssertNil(decoded.hostInventory)
    XCTAssertEqual(try decoded.canonicalDigest(), try without.canonicalDigest())

    let encodedWith = try TatwoPressureCanonicalJSONV1.data(with)
    let withJSON = String(data: encodedWith, encoding: .utf8) ?? ""
    XCTAssertTrue(withJSON.contains("\"hardwareModel\":\"Mac15,9\""), withJSON)
    XCTAssertTrue(withJSON.contains("\"cpuPercent\":"), withJSON)
  }

  func testReadingsSnapshotCopiesHostInventoryAndFillsActiveLoopCount() {
    let readings = TatwoDevicePressureSensorReadingsV1(
      memoryFreePercent: 40,
      swapFreeMiB: 2_048,
      dataVolumeFreeGiB: 40,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 20,
      swapGrowthMiBPerMinute: 0,
      hostInventory: TatwoDeviceHostInventoryV1(
        hardwareModel: "Mac16,1",
        connectionStatus: .online))
    let snapshot = readings.snapshot(
      deviceID: "macbook",
      observedAt: Date(timeIntervalSince1970: 10),
      activeLoopID: "loop-z",
      workers: [
        TatwoPressureWorkerV1(workerID: "w1", loopID: "loop-z", workload: .light)
      ])
    XCTAssertEqual(snapshot.hostInventory?.hardwareModel, "Mac16,1")
    XCTAssertEqual(snapshot.hostInventory?.connectionStatus, .online)
    XCTAssertEqual(snapshot.hostInventory?.activeLoopCount, 1)

    let projection = TatwoPressureUIProjectionV1(
      deviceID: snapshot.deviceID,
      displayClassification: .green,
      lastObservedAt: snapshot.observedAt,
      activeLoopID: snapshot.activeLoopID,
      workerIDs: ["w1"],
      stopReason: nil,
      canRequestLightLoop: true,
      canRequestHeavyLoop: true,
      hostInventory: snapshot.hostInventory)
    XCTAssertEqual(projection.hostInventory?.hardwareModel, "Mac16,1")
    XCTAssertEqual(projection.hostInventory?.activeLoopCount, 1)
  }
}
