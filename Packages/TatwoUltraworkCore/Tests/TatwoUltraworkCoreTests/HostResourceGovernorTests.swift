import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class HostResourceGovernorTests: XCTestCase {
  private let gibibyte: UInt64 = 1_073_741_824

  func testM3aTierMappingUsesTenPercentToleranceAtEveryBoundary() {
    XCTAssertEqual(tier(8, factor: 1.1), .ram8GB)
    XCTAssertEqual(tier(8, factor: 1.1001), .ram16GB)
    XCTAssertEqual(tier(16, factor: 1.1), .ram16GB)
    XCTAssertEqual(tier(16, factor: 1.1001), .ram32GB)
    XCTAssertEqual(tier(32, factor: 1.1), .ram32GB)
    XCTAssertEqual(tier(32, factor: 1.1001), .ram64GB)
    XCTAssertEqual(tier(64, factor: 1.1), .ram64GB)
    XCTAssertEqual(tier(64, factor: 1.1001), .ram128GBPlus)
    XCTAssertEqual(tier(128, factor: 1), .ram128GBPlus)
  }

  func testM3aTierParametersMatchD6() {
    XCTAssertEqual(TatwoHostResourceTier.allCases.map(\.concurrentRuntimeLimit), [1, 2, 4, 6, 8])
    XCTAssertEqual(TatwoHostResourceTier.allCases.map(\.idleReclamationInterval), [60, 300, 600, 900, nil])
    XCTAssertFalse(TatwoHostResourceTier.ram8GB.allowsConcurrentBuilds)
    XCTAssertTrue(TatwoHostResourceTier.ram16GB.allowsConcurrentBuilds)
  }

  func testM3aPreferenceStorePreservesManualOverrideAcrossLaunchDetection() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("m3a-preferences-\(UUID().uuidString)")
    let store = TatwoPreferenceStore(
      fileURL: root.appendingPathComponent("preferences.json"))
    try store.save(TatwoUserPreferences(
      hostResourceTierOverride: .ram64GB))

    let profile = try store.reconcileHostResourceProfileAtLaunch(
      physicalMemoryBytes: 16 * gibibyte,
      detectedAt: Date(timeIntervalSince1970: 123))

    XCTAssertEqual(profile.detectedTier, .ram16GB)
    XCTAssertEqual(profile.overrideTier, .ram64GB)
    XCTAssertEqual(profile.effectiveTier, .ram64GB)
    XCTAssertEqual(try store.load().detectedHostResourceTier, .ram16GB)
  }

  func testM3aGovernorQueuesFIFOAndExposesWaitReason() async throws {
    let governor = TatwoRuntimeGovernor(tier: .ram8GB)
    let first = try await governor.acquireChatRuntime()
    let waits = LockedValues<String>()
    let starts = LockedValues<String>()

    let secondTask = Task {
      let lease = try await governor.acquireChatRuntime {
        waits.append($0.machineReadableCode)
      }
      starts.append("second")
      return lease
    }
    await waitForQueuedCount(1, governor: governor)
    let thirdTask = Task {
      let lease = try await governor.acquireChatRuntime {
        waits.append($0.machineReadableCode)
      }
      starts.append("third")
      return lease
    }
    await waitForQueuedCount(2, governor: governor)

    XCTAssertEqual(governor.snapshot().queuedRuntimeCount, 2)
    XCTAssertEqual(
      waits.values,
      ["tier_concurrency_limit:8G", "tier_concurrency_limit:8G"])

    governor.release(first)
    let second = try await secondTask.value
    XCTAssertEqual(starts.values, ["second"])
    governor.release(second)
    let third = try await thirdTask.value
    XCTAssertEqual(starts.values, ["second", "third"])
    governor.release(third)
  }

  func testM3aIdleReclamationUsesInjectedClockAndGentleTermination() {
    let clock = TestClock()
    let governor = TatwoRuntimeGovernor(tier: .ram8GB, now: clock.now)
    let terminations = LockedValues<String>()
    let persistent = governor.registerExternalRuntime(
      kind: .chatPersistentSession,
      gentleTermination: { terminations.append("terminated") })

    clock.advance(by: 59)
    XCTAssertTrue(governor.reclaimIdlePersistentSessions().isEmpty)
    clock.advance(by: 1)
    XCTAssertEqual(governor.reclaimIdlePersistentSessions(), [persistent])
    XCTAssertEqual(terminations.values, ["terminated"])
    XCTAssertEqual(governor.snapshot().activeLeases, [persistent])
    governor.release(persistent)
    XCTAssertTrue(governor.snapshot().activeLeases.isEmpty)
  }

  func testM3aXXLSpawnCountsWithoutBeingQueuedOrKilled() async throws {
    let governor = TatwoRuntimeGovernor(tier: .ram8GB)
    let xxl = governor.registerExternalRuntime(kind: .xxlGoalSpawn)
    XCTAssertEqual(governor.snapshot().activeRuntimeCount, 1)

    let chat = Task {
      try await governor.acquireChatRuntime()
    }
    await waitForQueuedCount(1, governor: governor)

    governor.release(xxl)
    let admitted = try await chat.value
    XCTAssertEqual(admitted.kind, .chatPerTurn)
    governor.release(admitted)
  }

  private func tier(_ nominalGB: UInt64, factor: Double) -> TatwoHostResourceTier {
    TatwoHostResourceTier.detected(
      physicalMemoryBytes:
        UInt64((Double(nominalGB * gibibyte) * factor).rounded(.down)))
  }

  private func waitForQueuedCount(
    _ count: Int,
    governor: TatwoRuntimeGovernor
  ) async {
    for _ in 0..<100 where governor.snapshot().queuedRuntimeCount != count {
      await Task.yield()
    }
    XCTAssertEqual(governor.snapshot().queuedRuntimeCount, count)
  }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 0)

  var now: @Sendable () -> Date {
    { [weak self] in
      guard let self else { return .distantPast }
      self.lock.lock()
      defer { self.lock.unlock() }
      return self.value
    }
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    value = value.addingTimeInterval(interval)
    lock.unlock()
  }
}

private final class LockedValues<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Value] = []

  var values: [Value] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ value: Value) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }
}
