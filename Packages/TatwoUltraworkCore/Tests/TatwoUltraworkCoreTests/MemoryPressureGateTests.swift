import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class MemoryPressureGateTests: XCTestCase {
  func testAllowsWhenFreeAboveThreshold() {
    let gate = MemoryPressureGate(
      minFreePercent: 20,
      freePercentProvider: { 55 })
    XCTAssertEqual(gate.evaluate(), .allow)
  }

  func testBlocksWhenFreeBelowThreshold() {
    let gate = MemoryPressureGate(
      minFreePercent: 20,
      freePercentProvider: { 10 })
    let decision = gate.evaluate()
    guard case let .blocked(free, minFree, reason) = decision else {
      return XCTFail("expected blocked")
    }
    XCTAssertEqual(free, 10)
    XCTAssertEqual(minFree, 20)
    XCTAssertTrue(reason.contains("below gate"))
    XCTAssertEqual(decision.failureCode, "resource_gate_blocked")
  }

  func testThresholdZeroDisablesGate() {
    let gate = MemoryPressureGate(
      minFreePercent: 0,
      freePercentProvider: { 1 })
    XCTAssertEqual(gate.evaluate(), .allow)
  }

  func testSensorFailureFailClosed() {
    let gate = MemoryPressureGate(
      minFreePercent: 20,
      freePercentProvider: { nil })
    let decision = gate.evaluate()
    guard case let .blocked(free, minFree, reason) = decision else {
      return XCTFail("expected blocked on sensor failure, got \(decision)")
    }
    XCTAssertNil(free)
    XCTAssertEqual(minFree, 20)
    XCTAssertTrue(reason.contains("sensor unavailable"))
    XCTAssertEqual(decision.failureCode, "sensor_unavailable")
  }

  func testSensorFailureStillAllowsWhenExplicitlyDisabled() {
    // MIN_FREE=0 is the only intentional fail-open path (even if sensor is nil).
    let gate = MemoryPressureGate(
      minFreePercent: 0,
      freePercentProvider: { nil })
    XCTAssertEqual(gate.evaluate(), .allow)
  }

  func testSensorFailureJournalUsesSensorUnavailableCode() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-memory-gate-sensor-\(UUID().uuidString)",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = MemoryPressureGate(
      minFreePercent: 20,
      freePercentProvider: { nil },
      journalDirectoryURL: root)
    let decision = gate.evaluateAndJournal(surface: "job_dispatch")
    XCTAssertFalse(decision.isAllowed)
    let entries = try MemoryPressureGate.readJournal(directoryURL: root)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].code, "sensor_unavailable")
    XCTAssertNil(entries[0].freePercent)
  }

  func testEnvOverrideAndDefault() {
    XCTAssertEqual(
      MemoryPressureGate.threshold(environment: [:]),
      MemoryPressureGate.defaultMinFreePercent)
    XCTAssertEqual(
      MemoryPressureGate.threshold(
        environment: [MemoryPressureGate.minFreeEnvKey: "35"]),
      35)
    XCTAssertEqual(
      MemoryPressureGate.threshold(
        environment: [MemoryPressureGate.minFreeEnvKey: "0"]),
      0)
    XCTAssertEqual(
      MemoryPressureGate.threshold(
        environment: [MemoryPressureGate.minFreeEnvKey: "not-a-number"]),
      MemoryPressureGate.defaultMinFreePercent)
  }

  func testBlockedJournalIsWritten() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-memory-gate-\(UUID().uuidString)",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = MemoryPressureGate(
      minFreePercent: 25,
      freePercentProvider: { 5 },
      journalDirectoryURL: root)
    let decision = gate.evaluateAndJournal(surface: "job_dispatch")
    XCTAssertFalse(decision.isAllowed)
    let entries = try MemoryPressureGate.readJournal(directoryURL: root)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].code, "resource_gate_blocked")
    XCTAssertEqual(entries[0].surface, "job_dispatch")
    XCTAssertEqual(entries[0].freePercent, 5)
    XCTAssertEqual(entries[0].minFreePercent, 25)
  }

  func testParseMemoryPressureOutput() {
    let sample = """
      The system has 17179869184 (1048576 pages with a page size of 16384).
      System-wide memory free percentage: 60%
      """
    XCTAssertEqual(MemoryPressureGate.parseFreePercent(from: sample), 60)
    XCTAssertNil(MemoryPressureGate.parseFreePercent(from: "no free data"))
  }

  func testOriginEnqueueRejectsWhenBlocked() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-memory-gate-enqueue-\(UUID().uuidString)",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let originStore = MemoryDevicePrivateKeyStore()
    let runnerStore = MemoryDevicePrivateKeyStore()
    var originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "origin-sandbox",
      privateKeyStore: originStore)
    var runnerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "runner-sandbox",
      privateKeyStore: runnerStore)
    originTrust = try originTrust.withPin(runnerTrust.localIdentity)
    runnerTrust = try runnerTrust.withPin(originTrust.localIdentity)
    _ = runnerTrust

    let channel = TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel"),
      trust: originTrust)
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state"))
    let gate = MemoryPressureGate(
      minFreePercent: 50,
      freePercentProvider: { 10 },
      journalDirectoryURL: root.appendingPathComponent("origin-state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: channel,
      registry: registry,
      originDeviceID: "origin-sandbox",
      memoryGate: gate)
    let job = TatwoLoopJobV1(
      jobID: "job-blocked",
      logicalJobID: "logical-job-blocked",
      contractID: "contract-xl-coding-f51cfabe38f8",
      goalID: "goal-xl-coding-f51cfabe38f8",
      identity: .sub,
      originDeviceID: "origin-sandbox",
      targetDeviceID: "runner-sandbox",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .true)),
      workPath: work.path,
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 1, maxOutputBytes: 64),
      stopConditions: TatwoLoopStopConditionsV1(),
      createdAt: Date())

    XCTAssertThrowsError(try origin.enqueue(job)) { error in
      guard case let TatwoLoopJobStateError.resourceGateBlocked(reason) = error else {
        return XCTFail("expected resourceGateBlocked, got \(error)")
      }
      XCTAssertTrue(reason.contains("below gate"))
    }
    let entries = try MemoryPressureGate.readJournal(
      directoryURL: root.appendingPathComponent("origin-state"))
    XCTAssertTrue(entries.contains { $0.surface == "job_dispatch" })
  }
}

/// In-memory private key store for unit tests only.
private final class MemoryDevicePrivateKeyStore:
  @unchecked Sendable,
  TatwoDevicePrivateKeyStore
{
  private let lock = NSLock()
  private var keys: [String: Data] = [:]

  func loadPrivateKey(
    deviceID: String,
    generation: UInt64
  ) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return keys["\(deviceID):\(generation)"]
  }

  func storePrivateKey(
    _ key: Data,
    deviceID: String,
    generation: UInt64
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    let slot = "\(deviceID):\(generation)"
    if let existing = keys[slot], existing != key {
      throw TatwoDeviceTrustError.duplicatePrivateKeyMismatch
    }
    keys[slot] = key
  }
}
