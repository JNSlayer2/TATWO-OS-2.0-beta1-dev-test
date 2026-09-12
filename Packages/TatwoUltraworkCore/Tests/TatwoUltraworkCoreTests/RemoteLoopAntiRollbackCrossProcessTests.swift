import Foundation
import XCTest

@testable import TatwoUltraworkCore

/// Wave 0 package G — true cross-process races (spawn helper + barrier).
/// Uses file create-only store only; never touches production Keychain.
final class RemoteLoopAntiRollbackCrossProcessTests: XCTestCase {
  private let fm = FileManager.default

  // MARK: - G3.1 two processes claim same job → exactly one created

  func testCrossProcessSameJobClaimExactlyOneWinner() throws {
    let root = tempRoot("xp-claim")
    defer { try? fm.removeItem(at: root) }
    let ar = root.appendingPathComponent("ar", isDirectory: true)
    let barrier = root.appendingPathComponent("barrier", isDirectory: true)
    let r1 = root.appendingPathComponent("r1.txt")
    let r2 = root.appendingPathComponent("r2.txt")
    try fm.createDirectory(at: ar, withIntermediateDirectories: true)
    try fm.createDirectory(at: barrier, withIntermediateDirectories: true)

    let jobID = "job-xp-claim-1"
    let nonce = "nonce-xp-1"
    let digest = "sha256:xp-claim-1"
    let p1 = try spawnHelper([
      "claim", "--root", ar.path, "--job-id", jobID, "--nonce", nonce, "--digest", digest,
      "--barrier", barrier.path, "--result", r1.path,
    ])
    let p2 = try spawnHelper([
      "claim", "--root", ar.path, "--job-id", jobID, "--nonce", nonce, "--digest", digest,
      "--barrier", barrier.path, "--result", r2.path,
    ])
    try releaseBarrierWhenReady(barrier, expectedReady: 2)
    try waitProcesses([p1, p2], timeout: 20)

    let outcomes = [
      try String(contentsOf: r1, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      try String(contentsOf: r2, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
    ]
    let created = outcomes.filter { $0 == "created" }.count
    let skipped = outcomes.filter { $0 == "already_claimed" }.count
    XCTAssertEqual(created, 1, "exactly one claim winner, got \(outcomes)")
    XCTAssertEqual(skipped, 1, "exactly one skip, got \(outcomes)")

    let anchor = TatwoLoopGlobalAntiRollbackFileAnchor(rootURL: ar)
    let claim = try XCTUnwrap(try anchor.loadExecutedClaim(jobID: jobID))
    XCTAssertEqual(claim.dispatchNonce, nonce)
    XCTAssertEqual(claim.jobCanonicalDigest, digest)
  }

  // MARK: - G3.2 two processes update different job high-water → both kept, gen not regress

  func testCrossProcessDifferentJobHighWaterBothRetained() throws {
    let root = tempRoot("xp-hw")
    defer { try? fm.removeItem(at: root) }
    let ar = root.appendingPathComponent("ar", isDirectory: true)
    let barrier = root.appendingPathComponent("barrier", isDirectory: true)
    let r1 = root.appendingPathComponent("r1.txt")
    let r2 = root.appendingPathComponent("r2.txt")
    try fm.createDirectory(at: ar, withIntermediateDirectories: true)
    try fm.createDirectory(at: barrier, withIntermediateDirectories: true)

    let anchor = TatwoLoopGlobalAntiRollbackFileAnchor(rootURL: ar)
    try TatwoProductionLayoutLock.enforceStoreGenerationAntiRollback(observed: 7, anchor: anchor)

    let p1 = try spawnHelper([
      "consume", "--root", ar.path, "--job-id", "job-a", "--nonce", "na",
      "--digest", "sha256:a", "--result-digest", "sha256:ra", "--seq", "2",
      "--barrier", barrier.path, "--result", r1.path,
    ])
    let p2 = try spawnHelper([
      "consume", "--root", ar.path, "--job-id", "job-b", "--nonce", "nb",
      "--digest", "sha256:b", "--result-digest", "sha256:rb", "--seq", "5",
      "--barrier", barrier.path, "--result", r2.path,
    ])
    try releaseBarrierWhenReady(barrier, expectedReady: 2)
    try waitProcesses([p1, p2], timeout: 20)

    XCTAssertEqual(
      try String(contentsOf: r1, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      "ok")
    XCTAssertEqual(
      try String(contentsOf: r2, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      "ok")

    let snap = try anchor.loadSnapshot()
    XCTAssertEqual(snap.storeGenerationHighWater, 7, "generation must not regress")
    XCTAssertEqual(snap.consumedJobs["job-a"]?.resultDigest, "sha256:ra")
    XCTAssertEqual(snap.consumedJobs["job-b"]?.resultDigest, "sha256:rb")
    XCTAssertEqual(snap.consumedJobs.count, 2)
  }

  // MARK: - G3.3 hold lock + unlink/replace lock pathname → claim still exclusive

  func testCrossProcessClaimSafeWhenLockInodeUnlinked() throws {
    let root = tempRoot("xp-lock-unlink")
    defer { try? fm.removeItem(at: root) }
    let ar = root.appendingPathComponent("ar", isDirectory: true)
    let barrier = root.appendingPathComponent("barrier", isDirectory: true)
    let r1 = root.appendingPathComponent("r1.txt")
    let r2 = root.appendingPathComponent("r2.txt")
    try fm.createDirectory(at: ar, withIntermediateDirectories: true)
    try fm.createDirectory(at: barrier, withIntermediateDirectories: true)

    let jobID = "job-lock-unlink"
    let nonce = "nonce-lock"
    let digest = "sha256:lock-unlink"
    let anchor = TatwoLoopGlobalAntiRollbackFileAnchor(rootURL: ar)
    let lockPath = anchor.mutationLockURL.appendingPathExtension("lock")

    let holder = try spawnHelper([
      "claim-hold-lock", "--root", ar.path, "--job-id", jobID, "--nonce", nonce,
      "--digest", digest, "--barrier", barrier.path, "--hold-ms", "400",
      "--result", r1.path,
    ])
    let contender = try spawnHelper([
      "claim", "--root", ar.path, "--job-id", jobID, "--nonce", nonce,
      "--digest", digest, "--barrier", barrier.path, "--result", r2.path,
    ])
    try releaseBarrierWhenReady(barrier, expectedReady: 2)

    // While holder sleeps under flock, unlink/replace lock pathname.
    let deadline = Date().addingTimeInterval(5)
    while !fm.fileExists(atPath: lockPath.path), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if fm.fileExists(atPath: lockPath.path) {
      try fm.removeItem(at: lockPath)
      // Replacement inode an attacker could create.
      fm.createFile(atPath: lockPath.path, contents: Data("replacement".utf8))
    }

    try waitProcesses([holder, contender], timeout: 20)
    let outcomes = [
      try String(contentsOf: r1, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      try String(contentsOf: r2, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
    ]
    let created = outcomes.filter { $0 == "created" }.count
    let skipped = outcomes.filter { $0 == "already_claimed" }.count
    XCTAssertEqual(
      created, 1,
      "create-only claim must stay exclusive even if lock inode replaced; got \(outcomes)")
    XCTAssertEqual(skipped, 1, "loser must already_claimed; got \(outcomes)")
    XCTAssertNotNil(try anchor.loadExecutedClaim(jobID: jobID))
  }

  // MARK: - G3.4 two processes simultaneous first seal different channels → one winner

  func testCrossProcessDualFirstSealExactlyOneWinner() throws {
    let root = tempRoot("xp-seal")
    defer { try? fm.removeItem(at: root) }
    let base = root.appendingPathComponent("Library/Application Support", isDirectory: true)
    let channelA = root.appendingPathComponent("channel-a", isDirectory: true)
    let channelB = root.appendingPathComponent("channel-b", isDirectory: true)
    let storeURL = root.appendingPathComponent("install-anchor.json")
    let barrier = root.appendingPathComponent("barrier", isDirectory: true)
    let r1 = root.appendingPathComponent("r1.txt")
    let r2 = root.appendingPathComponent("r2.txt")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    try fm.createDirectory(at: channelA, withIntermediateDirectories: true)
    try fm.createDirectory(at: channelB, withIntermediateDirectories: true)
    try fm.createDirectory(at: barrier, withIntermediateDirectories: true)

    let p1 = try spawnHelper([
      "seal", "--store", storeURL.path, "--channel", channelA.path,
      "--host", "runner-prod", "--app-support-base", base.path,
      "--barrier", barrier.path, "--result", r1.path,
    ])
    let p2 = try spawnHelper([
      "seal", "--store", storeURL.path, "--channel", channelB.path,
      "--host", "runner-prod", "--app-support-base", base.path,
      "--barrier", barrier.path, "--result", r2.path,
    ])
    try releaseBarrierWhenReady(barrier, expectedReady: 2)
    try waitProcesses([p1, p2], timeout: 20)

    let o1 = try String(contentsOf: r1, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let o2 = try String(contentsOf: r2, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let oks = [o1, o2].filter { $0.hasPrefix("ok:") }
    let errs = [o1, o2].filter { $0.hasPrefix("error:") }
    XCTAssertEqual(oks.count, 1, "exactly one seal winner; outcomes=\([o1, o2])")
    XCTAssertEqual(errs.count, 1, "exactly one seal loser; outcomes=\([o1, o2])")

    let store = TatwoProductionInstallAnchorFileStore(url: storeURL)
    let kept = try XCTUnwrap(try store.load())
    let keptPath = URL(fileURLWithPath: kept.jobChannelRoot).standardizedFileURL.path
    let aPath = channelA.standardizedFileURL.path
    let bPath = channelB.standardizedFileURL.path
    XCTAssertTrue(keptPath == aPath || keptPath == bPath)
    XCTAssertNotEqual(aPath, bPath)
  }

  // MARK: - G3.5 / H3 true cross-process crash-after-claim recovery

  /// Process 1 claims then exits (crash). Process 2 recovers with new jobID+nonce via
  /// runner/engine once. Original jobID must never enter the engine.
  func testCrashAfterClaimRecoveryWithNewJobIDAndNonce() throws {
    let root = tempRoot("xp-recovery")
    defer { try? fm.removeItem(at: root) }
    let ar = root.appendingPathComponent("ar", isDirectory: true)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    let sandboxRoot = root.appendingPathComponent("sandbox", isDirectory: true)
    let barrier = root.appendingPathComponent("barrier", isDirectory: true)
    let claimResult = root.appendingPathComponent("claim-p1.txt")
    try fm.createDirectory(at: ar, withIntermediateDirectories: true)
    try fm.createDirectory(at: channelRoot, withIntermediateDirectories: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    try fm.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
    try fm.createDirectory(at: barrier, withIntermediateDirectories: true)
    // Work path inside sandbox for tatwo-loop unlock.
    let nestedWork = sandboxRoot.appendingPathComponent("job-work", isDirectory: true)
    try fm.createDirectory(at: nestedWork, withIntermediateDirectories: true)
    try "probe".write(
      to: nestedWork.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)

    let anchor = TatwoLoopGlobalAntiRollbackFileAnchor(rootURL: ar)
    let testEnv = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]
    let originKeys = MemoryDevicePrivateKeyStore()
    let runnerKeys = MemoryDevicePrivateKeyStore()
    var originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "origin-prod", privateKeyStore: originKeys, environment: testEnv)
    var runnerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "runner-prod", privateKeyStore: runnerKeys, environment: testEnv)
    originTrust = try originTrust.withPin(runnerTrust.localIdentity)
    runnerTrust = try runnerTrust.withPin(originTrust.localIdentity)

    let originChannel = TatwoLoopJobChannel(
      rootURL: channelRoot, trust: originTrust, environment: testEnv,
      globalAntiRollbackAnchor: anchor)
    let runnerChannel = TatwoLoopJobChannel(
      rootURL: channelRoot, trust: runnerTrust, environment: testEnv,
      globalAntiRollbackAnchor: anchor)

    let original = TatwoLoopJobV1(
      jobID: "job-crash-1",
      logicalJobID: "logical-work-42",
      dispatchNonce: "nonce-crash-1",
      contractID: "contract-xl-coding-f51cfabe38f8",
      goalID: "goal-xl-coding-f51cfabe38f8",
      identity: .sub,
      originDeviceID: "origin-prod",
      targetDeviceID: "runner-prod",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: "contract-xl-coding-f51cfabe38f8",
          goalID: "goal-xl-coding-f51cfabe38f8",
          identity: .sub,
          mode: .xl,
          taskDescription: "job-crash-1")),
      workPath: nestedWork.path,
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 2, maxOutputBytes: 4_096),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_100))

    _ = try originChannel.enqueue(original)
    let originalDigest = try original.canonicalDigest()

    // Process 1: claim lands, then process exits (crash before engine).
    let p1 = try spawnHelper([
      "claim", "--root", ar.path, "--job-id", original.jobID,
      "--nonce", original.dispatchNonce, "--digest", originalDigest,
      "--barrier", barrier.path, "--result", claimResult.path,
    ])
    try releaseBarrierWhenReady(barrier, expectedReady: 1)
    try waitProcesses([p1], timeout: 20)
    XCTAssertEqual(
      try String(contentsOf: claimResult, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "created")
    XCTAssertNotNil(try anchor.loadExecutedClaim(jobID: original.jobID))

    // Same jobID re-nonce is binding conflict (not recovery).
    XCTAssertThrowsError(
      try TatwoProductionLayoutLock.claimTargetExecution(
        jobID: original.jobID,
        dispatchNonce: "nonce-crash-2",
        jobCanonicalDigest: originalDigest,
        anchor: anchor)
    ) { error in
      guard case TatwoProductionLayoutError.globalAntiRollbackRegression = error else {
        return XCTFail("expected binding conflict, got \(error)")
      }
    }

    // Process 2 (this process after p1 exit): recovery job via runner/engine once.
    let recovery = original.mintRecoveryDispatch(
      newJobID: "job-crash-1-recovery",
      newDispatchNonce: "nonce-crash-recovery")
    XCTAssertEqual(recovery.logicalJobID, original.logicalJobID)
    XCTAssertNotEqual(recovery.jobID, original.jobID)
    // Put recovery jobID into taskDescription so the counting engine can assert identity.
    let recoveryJob = TatwoLoopJobV1(
      jobID: recovery.jobID,
      logicalJobID: recovery.logicalJobID,
      dispatchNonce: recovery.dispatchNonce,
      contractID: recovery.contractID,
      goalID: recovery.goalID,
      identity: recovery.identity,
      originDeviceID: recovery.originDeviceID,
      targetDeviceID: recovery.targetDeviceID,
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: recovery.contractID,
          goalID: recovery.goalID,
          identity: .sub,
          mode: .xl,
          taskDescription: recovery.jobID)),
      workPath: nestedWork.path,
      resourceCaps: recovery.resourceCaps,
      stopConditions: recovery.stopConditions,
      createdAt: recovery.createdAt)
    _ = try originChannel.enqueue(recoveryJob)

    let engine = CountingLoopEngine()
    let loopEnv = [
      TatwoLoopJobChannelTrust.testModeEnvKey: "1",
      TatwoLoopSandboxUnlock.enableEnvKey: TatwoLoopSandboxUnlock.enableSandboxValue,
      TatwoLoopSandboxUnlock.sandboxRootEnvKey: sandboxRoot.path,
    ]
    let runner = try TatwoLoopRunnerV1(
      channel: runnerChannel,
      deviceID: "runner-prod",
      pollIntervalSec: 0.01,
      environment: loopEnv,
      sandboxRootURL: sandboxRoot,
      engine: engine,
      localRegistry: TatwoDispatchRegistry(
        directoryURL: root.appendingPathComponent("runner-registry", isDirectory: true)),
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: root.appendingPathComponent("runner-registry")))
    let receipts = try runner.runUntilIdle()
    XCTAssertEqual(receipts.count, 1, "only recovery should complete")
    XCTAssertEqual(receipts.first?.jobID, recovery.jobID)
    XCTAssertEqual(receipts.first?.status, .completed, receipts.first?.message ?? "")
    XCTAssertEqual(engine.invocationCount, 1)
    XCTAssertEqual(engine.taskDescriptions, [recovery.jobID])
    XCTAssertFalse(
      engine.taskDescriptions.contains(original.jobID),
      "original jobID must never enter engine after crash-claim")

    // Original remains claimed; re-running runner must not execute original.
    let second = try runner.runUntilIdle()
    XCTAssertTrue(second.isEmpty)
    XCTAssertEqual(engine.invocationCount, 1)
    XCTAssertFalse(engine.taskDescriptions.contains(original.jobID))

    let snap = try anchor.loadSnapshot()
    XCTAssertNotNil(snap.executedClaims[original.jobID], "crash claim must survive process exit")
    XCTAssertNotNil(snap.executedClaims[recovery.jobID])
  }

  // MARK: - helpers

  private func tempRoot(_ name: String) -> URL {
    fm.temporaryDirectory
      .appendingPathComponent("tatwo-xp-\(name)-\(UUID().uuidString)", isDirectory: true)
  }

  private func productsDirectory() throws -> URL {
    #if os(macOS)
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
      return bundle.bundleURL.deletingLastPathComponent()
    }
    #endif
    return Bundle.main.bundleURL
  }

  private func helperURL() throws -> URL {
    if let env = ProcessInfo.processInfo.environment["TATWO_AR_RACE_HELPER"] {
      return URL(fileURLWithPath: env)
    }
    let url = try productsDirectory().appendingPathComponent("tatwo-ar-race-helper")
    if fm.isExecutableFile(atPath: url.path) {
      return url
    }
    // Fallback: common SPM build layouts from package root CWD.
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
    let candidates = [
      cwd.appendingPathComponent(".build/debug/tatwo-ar-race-helper"),
      cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/tatwo-ar-race-helper"),
      cwd.appendingPathComponent(".build/x86_64-apple-macosx/debug/tatwo-ar-race-helper"),
    ]
    for c in candidates where fm.isExecutableFile(atPath: c.path) {
      return c
    }
    throw XCTSkip("tatwo-ar-race-helper not built; set TATWO_AR_RACE_HELPER")
  }

  private func spawnHelper(_ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = try helperURL()
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }

  private func releaseBarrierWhenReady(_ barrier: URL, expectedReady: Int) throws {
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      let names = (try? fm.contentsOfDirectory(atPath: barrier.path)) ?? []
      let ready = names.filter { $0.hasPrefix("ready-") }.count
      if ready >= expectedReady {
        try Data("1".utf8).write(to: barrier.appendingPathComponent("go"))
        return
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    XCTFail("barrier ready timeout (expected \(expectedReady))")
  }

  private func waitProcesses(_ processes: [Process], timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    for p in processes {
      while p.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
      }
      if p.isRunning {
        p.terminate()
        XCTFail("process timed out")
      }
    }
  }
}

// MARK: - test helpers (file-local)

/// Counts tatwo-loop engine entries; records taskDescription (tests embed jobID there).
private final class CountingLoopEngine: TatwoLoopEngineBinding, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var invocationCount = 0
  private(set) var taskDescriptions: [String] = []

  func run(
    task: TatwoLoopEngineTaskV1,
    boundWorkPath: TatwoBoundWorkPath,
    caps: TatwoLoopResourceCapsV1,
    shouldCancel: @Sendable () -> Bool
  ) throws -> TatwoLoopEngineResultV1 {
    _ = boundWorkPath
    lock.lock()
    invocationCount += 1
    taskDescriptions.append(task.taskDescription)
    lock.unlock()
    return TatwoLoopEngineResultV1(
      exitCode: 0,
      outputData: Data("ok\n".utf8))
  }
}

/// In-memory private key store for cross-process recovery tests only.
private final class MemoryDevicePrivateKeyStore:
  @unchecked Sendable,
  TatwoDevicePrivateKeyStore
{
  private let lock = NSLock()
  private var keys: [String: Data] = [:]

  private static func account(deviceID: String, generation: UInt64) -> String {
    "\(deviceID)#\(generation)"
  }

  func loadPrivateKey(deviceID: String, generation: UInt64) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return keys[Self.account(deviceID: deviceID, generation: generation)]
  }

  func storePrivateKey(_ key: Data, deviceID: String, generation: UInt64) throws {
    guard key.count == 32 else { throw TatwoDeviceTrustError.invalidPrivateKey }
    let account = Self.account(deviceID: deviceID, generation: generation)
    lock.lock()
    defer { lock.unlock() }
    if let existing = keys[account], existing != key {
      throw TatwoDeviceTrustError.duplicatePrivateKeyMismatch
    }
    keys[account] = key
  }
}
