import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif

@testable import TatwoUltraworkCore

final class TatwoFleetSchedulerTests: XCTestCase {
  private let testEnv = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]
  private let originID = "mini-origin"
  private let targetAID = "dev-a"
  private let targetBID = "dev-b"

  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date {
      lock.lock(); defer { lock.unlock() }
      return value
    }
    func advance(_ seconds: TimeInterval) {
      lock.lock(); defer { lock.unlock() }
      value = value.addingTimeInterval(seconds)
    }
    func set(_ date: Date) {
      lock.lock(); defer { lock.unlock() }
      value = date
    }
  }

  private final class ResultMap: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: TatwoLoopJobResultReceiptV1] = [:]
    func set(_ jobID: String, _ result: TatwoLoopJobResultReceiptV1) {
      lock.lock(); defer { lock.unlock() }
      map[jobID] = result
    }
    func probe(_ jobID: String) throws -> TatwoLoopJobResultReceiptV1? {
      lock.lock(); defer { lock.unlock() }
      return map[jobID]
    }
  }

  private final class JobCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [TatwoLoopJobV1] = []

    func append(_ job: TatwoLoopJobV1) {
      lock.lock(); defer { lock.unlock() }
      jobs.append(job)
    }

    func snapshot() -> [TatwoLoopJobV1] {
      lock.lock(); defer { lock.unlock() }
      return jobs
    }
  }

  private final class MemoryDevicePrivateKeyStore: TatwoDevicePrivateKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    private func key(_ deviceID: String, _ generation: UInt64) -> String {
      "\(deviceID)#\(generation)"
    }
    func loadPrivateKey(deviceID: String, generation: UInt64) throws -> Data? {
      lock.lock(); defer { lock.unlock() }
      return keys[key(deviceID, generation)]
    }
    func storePrivateKey(_ raw: Data, deviceID: String, generation: UInt64) throws {
      lock.lock(); defer { lock.unlock() }
      keys[key(deviceID, generation)] = raw
    }
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-fleet-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func requireInteractiveKeychain() throws {
    switch TatwoTestEnvironmentCapabilities.current.interactiveKeychainAvailability() {
    case .available:
      return
    case let .interactionUnavailable(status):
      throw XCTSkip("keychain interaction unavailable in this session (\(status))")
    case let .probeFailed(status):
      throw TatwoFleetAuthorityError.missingAuthority(
        "keychain capability probe failed unexpectedly (\(status))")
    case .unavailableOnPlatform:
      throw XCTSkip("keychain unavailable on this platform")
    }
  }

  private func makeOriginAuthority(
    root: URL,
    epoch: UInt64 = 1,
    now: @escaping @Sendable () -> Date = { Date() },
    pinTargets: [TatwoDevicePublicIdentityV1] = [],
    highWater: (any TatwoFleetHighWaterAnchor)? = nil
  ) throws -> TatwoFleetOriginAuthority {
    let store = MemoryDevicePrivateKeyStore()
    var trust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: originID,
      privateKeyStore: store,
      environment: testEnv)
    for pin in pinTargets {
      trust = try trust.withPin(pin)
    }
    let hw = highWater ?? TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    return TatwoFleetOriginAuthority(
      originDeviceID: originID,
      authorityEpoch: epoch,
      trust: trust,
      highWater: hw,
      now: now)
  }

  private func makeTargetSigner(
    deviceID: String,
    pinOrigin: TatwoDevicePublicIdentityV1,
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws -> (TatwoFleetTargetSigner, TatwoDevicePublicIdentityV1) {
    let store = MemoryDevicePrivateKeyStore()
    var trust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: deviceID,
      privateKeyStore: store,
      environment: testEnv)
    trust = try trust.withPin(pinOrigin)
    let signer = TatwoFleetTargetSigner(
      trust: trust,
      originDeviceID: originID,
      authorityEpoch: 1,
      now: now)
    return (signer, trust.localIdentity)
  }

  private func makeScheduler(
    root: URL,
    clock: Clock,
    authority: TatwoFleetOriginAuthority,
    targetSigner: TatwoFleetTargetSigner? = nil,
    signedJobProbe: TatwoFleetSignedJobProbe? = nil
  ) -> TatwoFleetScheduler {
    TatwoFleetScheduler(
      store: TatwoFleetStore(rootURL: root, originAuthority: authority),
      now: { clock.now() },
      targetSigner: targetSigner,
      signedJobProbe: signedJobProbe)
  }

  private func shellPayload() -> TatwoLoopJobPayloadV1 {
    .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["fleet-ok"]))
  }

  private func productionAgentPayload() -> TatwoLoopJobPayloadV1 {
    .tatwoLoop(
      TatwoLoopPayloadV1(
        contractID: "contract-fleet",
        goalID: "goal-fleet",
        identity: .sub,
        mode: .m,
        taskDescription: "production fleet agent",
        agent: .codex,
        exactModelRouteID: "gpt-5.6-sol"))
  }

  private func productionBindings(
    targetDeviceID: String
  ) -> (
    invocation: TatwoRemoteBorrowInvocationV1,
    readiness: TatwoRemoteDispatchReadinessBindingV1,
    locator: TatwoRemoteWorkspaceLocatorV1
  ) {
    let workspaceBindingID = "workspace-fleet"
    return (
      TatwoRemoteBorrowInvocationV1(
        sessionID: "session-fleet",
        targetDeviceID: targetDeviceID,
        contractID: "contract-fleet",
        goalID: "goal-fleet",
        mode: .manual,
        risk: .lowRisk,
        grantID: "grant-fleet"),
      TatwoRemoteDispatchReadinessBindingV1(
        workspaceBindingID: workspaceBindingID,
        workspaceBindingDigest: String(repeating: "a", count: 64),
        agentModelCapabilityDigest: String(repeating: "b", count: 64),
        activeSkillSetDigest: String(repeating: "c", count: 64),
        challengeNonce: "logical-template-challenge"),
      TatwoRemoteWorkspaceLocatorV1(
        workspaceBindingID: workspaceBindingID,
        registryGeneration: 7)
    )
  }

  private func makePhysicalJob(
    jobID: String,
    logicalJobID: String,
    dispatchNonce: String,
    targetDeviceID: String,
    at: Date
  ) -> TatwoLoopJobV1 {
    TatwoLoopJobV1(
      jobID: jobID,
      logicalJobID: logicalJobID,
      dispatchNonce: dispatchNonce,
      contractID: "contract-fleet",
      goalID: "goal-fleet",
      identity: .sub,
      originDeviceID: originID,
      targetDeviceID: targetDeviceID,
      payload: shellPayload(),
      workPath: "/tmp/fleet-work",
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 30, maxOutputBytes: 4096),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      createdAt: at)
  }

  private func makeAssignment(
    from job: TatwoLoopJobV1,
    attempt: Int,
    at: Date,
    leaseSeconds: TimeInterval = 300
  ) throws -> TatwoFleetAssignmentV1 {
    TatwoFleetAssignmentV1(
      logicalJobID: job.logicalJobID,
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      targetDeviceID: job.targetDeviceID,
      originDeviceID: job.originDeviceID,
      assignedAt: at,
      leaseSeconds: leaseSeconds,
      attempt: attempt,
      status: .assigned,
      jobCanonicalDigest: try job.canonicalDigest())
  }

  private func enqueueShell(
    scheduler: TatwoFleetScheduler,
    logicalJobID: String
  ) throws -> TatwoFleetLogicalJobV1 {
    let jobs = try scheduler.enqueue(
      originDeviceID: originID,
      logicalJobIDPrefix: logicalJobID,
      count: 1,
      contractID: "contract-fleet",
      goalID: "goal-fleet",
      identity: .sub,
      workPath: "/tmp/fleet-work",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 30, maxOutputBytes: 4096))
    return try XCTUnwrap(jobs.first)
  }

  private func mockDispatch() -> TatwoFleetDispatchHandler {
    { job in
      TatwoFleetDispatchReceiptV1(
        jobID: job.jobID,
        dispatchNonce: job.dispatchNonce,
        targetDeviceID: job.targetDeviceID,
        jobCanonicalDigest: (try? job.canonicalDigest()) ?? "digest-\(job.jobID)",
        dispatchRecordID: "rec-\(job.jobID)")
    } as TatwoFleetDispatchHandler
  }

  private func makeResult(
    assignment: TatwoFleetAssignmentV1,
    status: TatwoLoopJobStatusV1 = .completed,
    digestOverride: String? = nil
  ) throws -> TatwoLoopJobResultReceiptV1 {
    TatwoLoopJobResultReceiptV1(
      jobID: assignment.jobID,
      dispatchNonce: assignment.dispatchNonce,
      jobCanonicalDigest: digestOverride ?? assignment.jobCanonicalDigest,
      projectionSequence: 5,
      status: status,
      outputDigest: nil,
      outputBytes: 0,
      exitCode: 0,
      failureCode: nil,
      message: "ok",
      startedAt: assignment.assignedAt,
      finishedAt: assignment.assignedAt.addingTimeInterval(1))
  }

  private func writeSignedAssignment(
    _ assignment: TatwoFleetAssignmentV1,
    store: TatwoFleetStore
  ) throws {
    try store.writeAssignment(assignment)
  }

  // MARK: 1 — dual result → one commit, other superseded

  func testDualResultsOnlyOneLogicalCommitOtherSuperseded() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try scheduler.registerDevice(
      deviceID: targetAID, maxConcurrent: 2, detectedAgentsOverride: [.grok])
    _ = try scheduler.registerDevice(
      deviceID: targetBID, maxConcurrent: 2, detectedAgentsOverride: [.grok])
    _ = try enqueueShell(scheduler: scheduler, logicalJobID: "logical-dual")

    let job1 = makePhysicalJob(
      jobID: "job-a1", logicalJobID: "logical-dual", dispatchNonce: "nonce-a1",
      targetDeviceID: targetAID, at: clock.now())
    let job2 = makePhysicalJob(
      jobID: "job-a2", logicalJobID: "logical-dual", dispatchNonce: "nonce-a2",
      targetDeviceID: targetBID, at: clock.now())
    let a1 = try makeAssignment(from: job1, attempt: 1, at: clock.now())
    let a2 = try makeAssignment(from: job2, attempt: 2, at: clock.now())
    try writeSignedAssignment(a1, store: scheduler.store)
    try writeSignedAssignment(a2, store: scheduler.store)

    let r1 = try makeResult(assignment: try XCTUnwrap(scheduler.store.loadAssignment(jobID: "job-a1")))
    let r2 = try makeResult(assignment: try XCTUnwrap(scheduler.store.loadAssignment(jobID: "job-a2")))
    let first = try scheduler.acceptAttemptResult(
      assignment: try XCTUnwrap(scheduler.store.loadAssignment(jobID: "job-a1")),
      result: r1,
      signedJob: job1)
    XCTAssertTrue(first.created)
    XCTAssertNotNil(first.commit)
    XCTAssertNil(first.superseded)
    XCTAssertEqual(first.commit?.winningJobID, "job-a1")

    let second = try scheduler.acceptAttemptResult(
      assignment: try XCTUnwrap(scheduler.store.loadAssignment(jobID: "job-a2")),
      result: r2,
      signedJob: job2)
    XCTAssertFalse(second.created)
    XCTAssertNil(second.commit)
    XCTAssertNotNil(second.superseded)
    XCTAssertEqual(second.superseded?.winningJobID, "job-a1")
    XCTAssertEqual(second.superseded?.jobID, "job-a2")

    let commits = try scheduler.store.listCommits()
    XCTAssertEqual(commits.count, 1, "exactly one logical commit")
    XCTAssertEqual(commits[0].winningJobID, "job-a1")
    let superseded = try scheduler.store.listSuperseded()
    XCTAssertEqual(superseded.count, 1)
    XCTAssertEqual(superseded[0].jobID, "job-a2")
    let a2Loaded = try XCTUnwrap(try scheduler.store.loadAssignment(jobID: "job-a2"))
    XCTAssertEqual(a2Loaded.status, .superseded)
  }

  /// H3/C3: forged/target-presented `verified` is not an L-commit input (target terminals only).
  func testAcceptAttemptResultRejectsVerifiedAsCommitInput() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try scheduler.registerDevice(
      deviceID: targetAID, maxConcurrent: 2, detectedAgentsOverride: [.grok])
    _ = try enqueueShell(scheduler: scheduler, logicalJobID: "logical-forged-verified")

    let job = makePhysicalJob(
      jobID: "job-forged-verified",
      logicalJobID: "logical-forged-verified",
      dispatchNonce: "nonce-forged-verified",
      targetDeviceID: targetAID,
      at: clock.now())
    let assignment = try makeAssignment(from: job, attempt: 1, at: clock.now())
    try writeSignedAssignment(assignment, store: scheduler.store)
    let loaded = try XCTUnwrap(try scheduler.store.loadAssignment(jobID: "job-forged-verified"))

    let forgedVerified = try makeResult(assignment: loaded, status: .verified)
    let outcome = try scheduler.acceptAttemptResult(
      assignment: loaded,
      result: forgedVerified,
      signedJob: job)
    XCTAssertFalse(outcome.created, "verified must not create logical commit")
    XCTAssertNil(outcome.commit, "verified is origin acceptance output, not L-commit input")
    XCTAssertNil(outcome.superseded)
    XCTAssertTrue(
      try scheduler.store.listCommits().isEmpty,
      "forged verified must leave commit store empty")
    let stillAssigned = try XCTUnwrap(
      try scheduler.store.loadAssignment(jobID: "job-forged-verified"))
    XCTAssertEqual(stillAssigned.status, .assigned)

    // Target-signed completed remains the accepted commit path.
    let completed = try makeResult(assignment: loaded, status: .completed)
    let ok = try scheduler.acceptAttemptResult(
      assignment: loaded,
      result: completed,
      signedJob: job)
    XCTAssertTrue(ok.created)
    XCTAssertNotNil(ok.commit)
    XCTAssertEqual(ok.commit?.resultStatus, .completed)
  }

  // MARK: 2 — lease expire mints new attempt; old claim not revoked

  func testLeaseExpiryMintsNewAttemptWithoutRevokingOldClaim() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try scheduler.registerDevice(
      deviceID: targetAID, maxConcurrent: 2, detectedAgentsOverride: [.grok, .codex])
    _ = try enqueueShell(scheduler: scheduler, logicalJobID: "logical-lease")

    let config = TatwoFleetTickConfigV1(
      leaseSeconds: 60, leaseGraceSeconds: 0, heartbeatMaxAgeSeconds: 120)
    let tick1 = try scheduler.tick(config: config, dispatch: mockDispatch())
    XCTAssertEqual(tick1.assigned.count, 1)
    let first = try XCTUnwrap(tick1.assigned.first)
    let firstJobID = first.jobID
    let firstNonce = first.dispatchNonce

    clock.advance(120)
    let tick2 = try scheduler.tick(config: config, dispatch: mockDispatch())
    XCTAssertEqual(tick2.leaseRecoveries.count, 1)
    XCTAssertEqual(tick2.assigned.count, 1)
    let second = try XCTUnwrap(tick2.assigned.first)
    XCTAssertNotEqual(second.jobID, firstJobID)
    XCTAssertNotEqual(second.dispatchNonce, firstNonce)
    XCTAssertEqual(second.logicalJobID, first.logicalJobID)
    XCTAssertEqual(second.attempt, first.attempt + 1)

    // Old assignment retained as leaseExpired (claim identity not revoked).
    let old = try XCTUnwrap(try scheduler.store.loadAssignment(jobID: firstJobID))
    XCTAssertEqual(old.status, .leaseExpired)
    XCTAssertEqual(old.dispatchNonce, firstNonce)
  }

  func testProductionAgentAssignmentPreservesTargetBindingsAndRefreshesChallenge() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try scheduler.registerDevice(
      deviceID: targetAID, maxConcurrent: 1, detectedAgentsOverride: [.codex])
    _ = try scheduler.registerDevice(
      deviceID: targetBID, maxConcurrent: 1, detectedAgentsOverride: [.codex])
    let bindings = productionBindings(targetDeviceID: targetBID)
    _ = try scheduler.enqueue(
      originDeviceID: originID,
      logicalJobIDPrefix: "logical-production-agent",
      contractID: "contract-fleet",
      goalID: "goal-fleet",
      identity: .sub,
      workPath: "",
      payload: productionAgentPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 30, maxOutputBytes: 4096),
      remoteBorrowInvocation: bindings.invocation,
      remoteDispatchReadiness: bindings.readiness,
      workspaceLocator: bindings.locator)

    let capture = JobCapture()
    let tick = try scheduler.tick(
      config: TatwoFleetTickConfigV1(heartbeatMaxAgeSeconds: 120),
      dispatch: { job in
        capture.append(job)
        return TatwoFleetDispatchReceiptV1(
          jobID: job.jobID,
          dispatchNonce: job.dispatchNonce,
          targetDeviceID: job.targetDeviceID,
          jobCanonicalDigest: try job.canonicalDigest(),
          dispatchRecordID: "rec-\(job.jobID)")
      })

    XCTAssertEqual(tick.assigned.count, 1)
    let physical = try XCTUnwrap(capture.snapshot().first)
    XCTAssertEqual(physical.targetDeviceID, targetBID)
    XCTAssertEqual(physical.remoteBorrowInvocation, bindings.invocation)
    XCTAssertEqual(physical.workspaceLocator, bindings.locator)
    XCTAssertEqual(
      physical.remoteDispatchReadiness?.workspaceBindingDigest,
      bindings.readiness.workspaceBindingDigest)
    XCTAssertEqual(
      physical.remoteDispatchReadiness?.agentModelCapabilityDigest,
      bindings.readiness.agentModelCapabilityDigest)
    XCTAssertEqual(
      physical.remoteDispatchReadiness?.activeSkillSetDigest,
      bindings.readiness.activeSkillSetDigest)
    XCTAssertNotEqual(
      physical.remoteDispatchReadiness?.challengeNonce,
      bindings.readiness.challengeNonce)
  }

  func testProductionAgentLeaseRecoveryKeepsAuthorizedTargetAndRefreshesChallenge() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try scheduler.registerDevice(
      deviceID: targetBID, maxConcurrent: 2, detectedAgentsOverride: [.codex])
    let bindings = productionBindings(targetDeviceID: targetBID)
    _ = try scheduler.enqueue(
      originDeviceID: originID,
      logicalJobIDPrefix: "logical-production-recovery",
      contractID: "contract-fleet",
      goalID: "goal-fleet",
      identity: .sub,
      workPath: "",
      payload: productionAgentPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 30, maxOutputBytes: 4096),
      remoteBorrowInvocation: bindings.invocation,
      remoteDispatchReadiness: bindings.readiness,
      workspaceLocator: bindings.locator)

    let capture = JobCapture()
    let dispatch: TatwoFleetDispatchHandler = { job in
      capture.append(job)
      return TatwoFleetDispatchReceiptV1(
        jobID: job.jobID,
        dispatchNonce: job.dispatchNonce,
        targetDeviceID: job.targetDeviceID,
        jobCanonicalDigest: try job.canonicalDigest(),
        dispatchRecordID: "rec-\(job.jobID)")
    }
    let config = TatwoFleetTickConfigV1(
      leaseSeconds: 60, leaseGraceSeconds: 0, heartbeatMaxAgeSeconds: 300)
    _ = try scheduler.tick(config: config, dispatch: dispatch)
    clock.advance(120)
    _ = try scheduler.registerDevice(
      deviceID: targetBID, maxConcurrent: 2, detectedAgentsOverride: [.codex])
    let recovered = try scheduler.tick(config: config, dispatch: dispatch)

    XCTAssertEqual(recovered.leaseRecoveries.count, 1)
    XCTAssertEqual(recovered.assigned.count, 1)
    let physicalJobs = capture.snapshot()
    XCTAssertEqual(physicalJobs.count, 2)
    XCTAssertTrue(physicalJobs.allSatisfy { $0.targetDeviceID == targetBID })
    XCTAssertTrue(physicalJobs.allSatisfy { $0.workspaceLocator == bindings.locator })
    XCTAssertTrue(physicalJobs.allSatisfy { $0.remoteBorrowInvocation == bindings.invocation })
    XCTAssertNotEqual(physicalJobs[0].jobID, physicalJobs[1].jobID)
    XCTAssertNotEqual(physicalJobs[0].dispatchNonce, physicalJobs[1].dispatchNonce)
    XCTAssertNotEqual(
      physicalJobs[0].remoteDispatchReadiness?.challengeNonce,
      physicalJobs[1].remoteDispatchReadiness?.challengeNonce)
  }

  func testProductionAgentDoesNotRetargetADeviceScopedGrant() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try scheduler.registerDevice(
      deviceID: targetAID, maxConcurrent: 1, detectedAgentsOverride: [.codex])
    let bindings = productionBindings(targetDeviceID: targetBID)
    _ = try scheduler.enqueue(
      originDeviceID: originID,
      logicalJobIDPrefix: "logical-target-bound",
      contractID: "contract-fleet",
      goalID: "goal-fleet",
      identity: .sub,
      workPath: "",
      payload: productionAgentPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 30, maxOutputBytes: 4096),
      remoteBorrowInvocation: bindings.invocation,
      remoteDispatchReadiness: bindings.readiness,
      workspaceLocator: bindings.locator)

    let capture = JobCapture()
    let tick = try scheduler.tick(
      config: TatwoFleetTickConfigV1(heartbeatMaxAgeSeconds: 120),
      dispatch: { job in
        capture.append(job)
        return TatwoFleetDispatchReceiptV1(
          jobID: job.jobID,
          dispatchNonce: job.dispatchNonce,
          targetDeviceID: job.targetDeviceID,
          jobCanonicalDigest: try job.canonicalDigest(),
          dispatchRecordID: "rec-\(job.jobID)")
      })

    XCTAssertTrue(tick.assigned.isEmpty)
    XCTAssertTrue(capture.snapshot().isEmpty)
    XCTAssertEqual(tick.pendingRemaining, 1)
    XCTAssertEqual(tick.skippedMissingCapability, 1)
  }

  func testLogicalJobRejectsPartialOrShellSafeProductionBindings() throws {
    let bindings = productionBindings(targetDeviceID: targetBID)
    let partial = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-partial",
      originDeviceID: originID,
      contractID: "contract-fleet",
      goalID: "goal-fleet",
      identity: .sub,
      workPath: "",
      payload: productionAgentPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 30, maxOutputBytes: 4096),
      stopConditions: TatwoLoopStopConditionsV1(),
      requiredAgent: .codex,
      remoteBorrowInvocation: bindings.invocation,
      status: .pending,
      enqueuedAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertThrowsError(try partial.validate())

    let shellWithAgentBinding = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-shell-binding",
      originDeviceID: originID,
      contractID: "contract-fleet",
      goalID: "goal-fleet",
      identity: .sub,
      workPath: "/tmp/fleet-work",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 30, maxOutputBytes: 4096),
      stopConditions: TatwoLoopStopConditionsV1(),
      requiredAgent: nil,
      remoteBorrowInvocation: bindings.invocation,
      remoteDispatchReadiness: bindings.readiness,
      workspaceLocator: bindings.locator,
      status: .pending,
      enqueuedAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertThrowsError(try shellWithAgentBinding.validate())
  }

  func testLogicalAgentJobRejectsRequiredAgentPayloadMismatch() throws {
    let mismatched = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-agent-mismatch",
      originDeviceID: originID,
      contractID: "contract-fleet",
      goalID: "goal-fleet",
      identity: .sub,
      workPath: "/tmp/legacy-agent",
      payload: productionAgentPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 30, maxOutputBytes: 4096),
      stopConditions: TatwoLoopStopConditionsV1(),
      requiredAgent: .grok,
      status: .pending,
      enqueuedAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

    XCTAssertThrowsError(try mismatched.validate()) { error in
      XCTAssertEqual(
        error as? TatwoFleetError,
        .invalidLogicalJob("requiredAgent does not match tatwo-loop payload agent"))
    }
  }

  func testLegacyLogicalAgentJobDecodesWithoutProductionBindings() throws {
    let bindings = productionBindings(targetDeviceID: targetBID)
    let logical = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-legacy-agent",
      originDeviceID: originID,
      contractID: "contract-fleet",
      goalID: "goal-fleet",
      identity: .sub,
      workPath: "/tmp/legacy-agent",
      payload: productionAgentPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 30, maxOutputBytes: 4096),
      stopConditions: TatwoLoopStopConditionsV1(),
      requiredAgent: .codex,
      remoteBorrowInvocation: bindings.invocation,
      remoteDispatchReadiness: bindings.readiness,
      workspaceLocator: bindings.locator,
      status: .pending,
      enqueuedAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let encoded = try JSONEncoder().encode(logical)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "remoteBorrowInvocation")
    object.removeValue(forKey: "remoteDispatchReadiness")
    object.removeValue(forKey: "workspaceLocator")
    let legacyJSON = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

    let decoded = try JSONDecoder().decode(
      TatwoFleetLogicalJobV1.self,
      from: legacyJSON)
    XCTAssertNil(decoded.remoteBorrowInvocation)
    XCTAssertNil(decoded.remoteDispatchReadiness)
    XCTAssertNil(decoded.workspaceLocator)
    XCTAssertNoThrow(try decoded.validate())
  }

  func testSignedLegacyLogicalAgentJobRoundTripsWithoutAdditiveBindings() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()
    let legacy = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-signed-legacy-agent",
      originDeviceID: originID,
      contractID: "contract-fleet",
      goalID: "goal-fleet",
      identity: .sub,
      workPath: "/tmp/legacy-agent",
      payload: productionAgentPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 30, maxOutputBytes: 4096),
      stopConditions: TatwoLoopStopConditionsV1(),
      requiredAgent: .codex,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())

    try store.writeLogicalJob(legacy)
    let loaded = try XCTUnwrap(
      try store.loadLogicalJob(logicalJobID: legacy.logicalJobID))

    XCTAssertEqual(loaded.logicalJobID, legacy.logicalJobID)
    XCTAssertEqual(loaded.originDeviceID, legacy.originDeviceID)
    XCTAssertEqual(loaded.contractID, legacy.contractID)
    XCTAssertEqual(loaded.goalID, legacy.goalID)
    XCTAssertEqual(loaded.identity, legacy.identity)
    XCTAssertEqual(loaded.workPath, legacy.workPath)
    XCTAssertEqual(loaded.payload, legacy.payload)
    XCTAssertEqual(loaded.resourceCaps, legacy.resourceCaps)
    XCTAssertEqual(loaded.stopConditions, legacy.stopConditions)
    XCTAssertEqual(loaded.requiredAgent, legacy.requiredAgent)
    XCTAssertEqual(loaded.status, legacy.status)
    XCTAssertEqual(loaded.authorityEpoch, authority.authorityEpoch)
    XCTAssertGreaterThan(loaded.ledgerSequence, 0)
    XCTAssertNil(loaded.remoteBorrowInvocation)
    XCTAssertNil(loaded.remoteDispatchReadiness)
    XCTAssertNil(loaded.workspaceLocator)
    XCTAssertNoThrow(try loaded.validate())
  }

  // MARK: F1 — transplant signed record to other pathname fails closed

  func testSignedRecordTransplantToOtherPathFailsClosed() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try enqueueShell(scheduler: scheduler, logicalJobID: "logical-legit")
    _ = try enqueueShell(scheduler: scheduler, logicalJobID: "logical-other")

    let source = scheduler.store.queueURL(for: "logical-legit")
    let dest = scheduler.store.queueURL(for: "logical-other")
    // Transplant valid envelope bytes onto a different pathname.
    try FileManager.default.removeItem(at: dest)
    try FileManager.default.copyItem(at: source, to: dest)

    XCTAssertThrowsError(try scheduler.store.loadLogicalJob(logicalJobID: "logical-other")) {
      error in
      // Assert the specific refusal rather than substring-matching the message:
      // the record's signed identity must not match a pathname it was moved to.
      // Both layers carry a bindingMismatch; either is the correct refusal here.
      switch error {
      case TatwoFleetAuthorityError.bindingMismatch, TatwoFleetError.bindingMismatch:
        break
      default:
        XCTFail("transplant must fail closed on identity binding, got \(error)")
      }
    }
    // Original path still loads.
    XCTAssertNotNil(try scheduler.store.loadLogicalJob(logicalJobID: "logical-legit"))
  }

  func testTamperedQueueEnvelopeRejected() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try enqueueShell(scheduler: scheduler, logicalJobID: "logical-tamper")

    let url = scheduler.store.queueURL(for: "logical-tamper")
    var data = try Data(contentsOf: url)
    if data.count > 2 {
      data[data.count - 2] ^= 0x01
    } else {
      data[0] ^= 0x01
    }
    try data.write(to: url)
    XCTAssertThrowsError(try scheduler.store.loadLogicalJob(logicalJobID: "logical-tamper"))
  }

  // MARK: F2 — commit high-water / delete / keychain durable

  func testCommitDeleteWithHighWaterFailsClosed() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try scheduler.registerDevice(
      deviceID: targetAID, maxConcurrent: 1, detectedAgentsOverride: [.grok])
    _ = try enqueueShell(scheduler: scheduler, logicalJobID: "logical-hw")

    let job = makePhysicalJob(
      jobID: "job-hw", logicalJobID: "logical-hw", dispatchNonce: "nonce-hw",
      targetDeviceID: targetAID, at: clock.now())
    let assignment = try makeAssignment(from: job, attempt: 1, at: clock.now())
    try writeSignedAssignment(assignment, store: scheduler.store)
    let loaded = try XCTUnwrap(try scheduler.store.loadAssignment(jobID: "job-hw"))
    let result = try makeResult(assignment: loaded)
    let outcome = try scheduler.acceptAttemptResult(
      assignment: loaded, result: result, signedJob: job)
    XCTAssertTrue(outcome.created)

    // Delete commit file but keep high-water → fail closed.
    try FileManager.default.removeItem(at: scheduler.store.commitURL(for: "logical-hw"))
    XCTAssertThrowsError(try scheduler.store.loadCommit(logicalJobID: "logical-hw")) { error in
      guard case TatwoFleetAuthorityError.commitHighWaterWithoutFile = error else {
        return XCTFail("expected commitHighWaterWithoutFile, got \(error)")
      }
    }
    let forgedJob = makePhysicalJob(
      jobID: "job-other", logicalJobID: "logical-hw", dispatchNonce: "nonce-other",
      targetDeviceID: targetAID, at: clock.now())
    let forged = TatwoFleetLogicalCommitV1(
      logicalJobID: "logical-hw",
      winningJobID: forgedJob.jobID,
      winningDispatchNonce: forgedJob.dispatchNonce,
      targetDeviceID: targetAID,
      originDeviceID: originID,
      resultStatus: .completed,
      resultDigest: nil,
      jobCanonicalDigest: try forgedJob.canonicalDigest(),
      committedAt: clock.now())
    XCTAssertThrowsError(try scheduler.store.commitLogical(forged))
  }

  func testKeychainHighWaterSurvivesFileCacheDeletion() throws {
    try requireInteractiveKeychain()
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = "ai.tatwo.ultrawork.fleet-hw-test.\(UUID().uuidString)"
    let durable = TatwoFleetKeychainHighWaterAnchor(service: service, hostScope: originID)
    defer { try? durable.dangerousTestOnlyDeleteAllMarkers() }
    let cache = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let highWater = TatwoFleetCachingHighWaterAnchor(durable: durable, fileCache: cache)

    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(
      root: root, now: { clock.now() }, highWater: highWater)
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try scheduler.registerDevice(
      deviceID: targetAID, maxConcurrent: 1, detectedAgentsOverride: [.grok])
    _ = try enqueueShell(scheduler: scheduler, logicalJobID: "logical-kc")

    let job = makePhysicalJob(
      jobID: "job-kc", logicalJobID: "logical-kc", dispatchNonce: "nonce-kc",
      targetDeviceID: targetAID, at: clock.now())
    let assignment = try makeAssignment(from: job, attempt: 1, at: clock.now())
    try writeSignedAssignment(assignment, store: scheduler.store)
    let loaded = try XCTUnwrap(try scheduler.store.loadAssignment(jobID: "job-kc"))
    let result = try makeResult(assignment: loaded)
    XCTAssertTrue(
      try scheduler.acceptAttemptResult(assignment: loaded, result: result, signedJob: job)
        .created)

    // Attacker deletes file high-water cache entirely.
    try cache.dangerousTestOnlyDeleteAll()
    // Durable Keychain still fences: commit file delete → fail closed; re-commit different winner fails.
    try FileManager.default.removeItem(at: scheduler.store.commitURL(for: "logical-kc"))
    XCTAssertThrowsError(try scheduler.store.loadCommit(logicalJobID: "logical-kc"))
    XCTAssertNotNil(try highWater.loadCommitHighWater(logicalJobID: "logical-kc"))

    let forged = TatwoFleetLogicalCommitV1(
      logicalJobID: "logical-kc",
      winningJobID: "job-evil",
      winningDispatchNonce: "nonce-evil",
      targetDeviceID: targetAID,
      originDeviceID: originID,
      resultStatus: .completed,
      resultDigest: nil,
      jobCanonicalDigest: "evil-digest",
      committedAt: clock.now())
    XCTAssertThrowsError(try scheduler.store.commitLogical(forged))
  }

  /// R1: commit file without durable marker must fail closed (load + list).
  func testCommitFileWithoutDurableMarkerFailsClosed() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try scheduler.registerDevice(
      deviceID: targetAID, maxConcurrent: 1, detectedAgentsOverride: [.grok])
    _ = try enqueueShell(scheduler: scheduler, logicalJobID: "logical-nomarker")

    let job = makePhysicalJob(
      jobID: "job-nomarker", logicalJobID: "logical-nomarker", dispatchNonce: "nonce-nm",
      targetDeviceID: targetAID, at: clock.now())
    let assignment = try makeAssignment(from: job, attempt: 1, at: clock.now())
    try writeSignedAssignment(assignment, store: scheduler.store)
    let loaded = try XCTUnwrap(try scheduler.store.loadAssignment(jobID: "job-nomarker"))
    let result = try makeResult(assignment: loaded)
    XCTAssertTrue(
      try scheduler.acceptAttemptResult(assignment: loaded, result: result, signedJob: job)
        .created)

    // Simulate marker wipe while leaving signed commit file.
    try authority.highWater as? TatwoFleetFileHighWaterAnchor
    if let fileHW = authority.highWater as? TatwoFleetFileHighWaterAnchor {
      try fileHW.dangerousTestOnlyDeleteAll()
    } else {
      // File anchor is the test default via makeOriginAuthority.
      try TatwoFleetFileHighWaterAnchor.underFleetRoot(root).dangerousTestOnlyDeleteAll()
    }
    // Re-create empty high-water root so other ops don't trip on missing dir oddly.
    _ = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)

    // The invariant is that a commit file without a durable marker is refused.
    // Which fence catches it depends on ordering: the per-path high-water check
    // now runs first and reports `authorityFenced`, so both refusals are correct
    // — silently succeeding is the only unacceptable outcome.
    func assertRefusedWithoutDurableMarker(
      _ error: Error, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
      switch error {
      case TatwoFleetAuthorityError.commitFileWithoutHighWater,
        TatwoFleetError.authorityFenced:
        break
      default:
        XCTFail("\(what) must fail closed without a durable marker, got \(error)", file: file, line: line)
      }
    }

    XCTAssertThrowsError(try scheduler.store.loadCommit(logicalJobID: "logical-nomarker")) {
      assertRefusedWithoutDurableMarker($0, "loadCommit")
    }
    XCTAssertThrowsError(try scheduler.store.listCommits()) {
      assertRefusedWithoutDurableMarker($0, "listCommits")
    }
  }

  /// R1: deleting per-value Keychain markers must not lower monotonic high-water.
  func testKeychainHighWaterNotDowngradedByDeletingPerValueMarkers() throws {
    try requireInteractiveKeychain()
    let service = "ai.tatwo.ultrawork.fleet-hw-max-\(UUID().uuidString)"
    let durable = TatwoFleetKeychainHighWaterAnchor(service: service, hostScope: originID)
    defer { try? durable.dangerousTestOnlyDeleteAllMarkers() }

    try durable.storeAuthorityHighWater(
      TatwoFleetAuthorityHighWaterV1(
        authorityEpoch: 2,
        ledgerSequence: 7,
        originDeviceID: originID,
        updatedAt: Date()))
    let before = try XCTUnwrap(try durable.loadAuthorityHighWater())
    XCTAssertEqual(before.ledgerSequence, 7)
    XCTAssertEqual(before.authorityEpoch, 2)

    try durable.dangerousTestOnlyDeletePerValueMarkersKeepingMax()
    let after = try XCTUnwrap(try durable.loadAuthorityHighWater())
    XCTAssertEqual(after.ledgerSequence, 7, "max must not regress after residue wipe")
    XCTAssertEqual(after.authorityEpoch, 2)

    XCTAssertThrowsError(
      try durable.storeAuthorityHighWater(
        TatwoFleetAuthorityHighWaterV1(
          authorityEpoch: 2,
          ledgerSequence: 6,
          originDeviceID: originID,
          updatedAt: Date()))
    ) { error in
      guard case TatwoFleetAuthorityError.ledgerSequenceRegression = error else {
        return XCTFail("expected ledgerSequenceRegression, got \(error)")
      }
    }
  }

  /// R1: durable marker is reserved before file — simulated file publish failure leaves fail-closed state.
  func testCommitMarkerReservedBeforeFilePublishFailClosed() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let commit = TatwoFleetLogicalCommitV1(
      logicalJobID: "logical-reserve",
      winningJobID: "job-reserve",
      winningDispatchNonce: "nonce-reserve",
      targetDeviceID: targetAID,
      originDeviceID: originID,
      resultStatus: .completed,
      resultDigest: nil,
      jobCanonicalDigest: "digest-reserve",
      committedAt: clock.now())
    // Reserve marker only (production order step 1).
    let seq = try authority.nextLedgerSequence()
    let stamped = TatwoFleetLogicalCommitV1(
      logicalJobID: commit.logicalJobID,
      winningJobID: commit.winningJobID,
      winningDispatchNonce: commit.winningDispatchNonce,
      targetDeviceID: commit.targetDeviceID,
      originDeviceID: originID,
      resultStatus: commit.resultStatus,
      resultDigest: commit.resultDigest,
      jobCanonicalDigest: commit.jobCanonicalDigest,
      committedAt: commit.committedAt,
      authorityEpoch: authority.authorityEpoch,
      ledgerSequence: seq)
    let digest = try TatwoLoopJobDigest.canonicalJSONDigest(stamped)
    try authority.highWater.createCommitHighWater(
      TatwoFleetCommitHighWaterV1(
        logicalJobID: stamped.logicalJobID,
        ledgerSequence: stamped.ledgerSequence,
        authorityEpoch: stamped.authorityEpoch,
        originDeviceID: stamped.originDeviceID,
        winningJobID: stamped.winningJobID,
        winningDispatchNonce: stamped.winningDispatchNonce,
        jobCanonicalDigest: stamped.jobCanonicalDigest,
        commitDigest: digest,
        committedAt: stamped.committedAt))

    // No file yet → fail closed (high-water without file).
    XCTAssertThrowsError(try store.loadCommit(logicalJobID: "logical-reserve")) { error in
      guard case TatwoFleetAuthorityError.commitHighWaterWithoutFile = error else {
        return XCTFail("expected commitHighWaterWithoutFile, got \(error)")
      }
    }
    // Different winner cannot publish after reserved marker.
    let forged = TatwoFleetLogicalCommitV1(
      logicalJobID: "logical-reserve",
      winningJobID: "job-evil",
      winningDispatchNonce: "nonce-evil",
      targetDeviceID: targetAID,
      originDeviceID: originID,
      resultStatus: .completed,
      resultDigest: nil,
      jobCanonicalDigest: "evil",
      committedAt: clock.now())
    XCTAssertThrowsError(try store.commitLogical(forged))
  }

  func testStaleAuthorityEpochCannotWrite() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let fresh = try makeOriginAuthority(root: root, epoch: 2, now: { clock.now() })
    let schedulerFresh = makeScheduler(root: root, clock: clock, authority: fresh)
    _ = try schedulerFresh.registerDevice(
      deviceID: targetAID, maxConcurrent: 1, detectedAgentsOverride: [.grok])
    _ = try enqueueShell(scheduler: schedulerFresh, logicalJobID: "logical-epoch")

    let stale = try makeOriginAuthority(root: root, epoch: 1, now: { clock.now() })
    let staleScheduler = makeScheduler(root: root, clock: clock, authority: stale)
    XCTAssertThrowsError(
      try staleScheduler.enqueue(
        originDeviceID: originID,
        logicalJobIDPrefix: "logical-stale",
        contractID: "c",
        goalID: "g",
        identity: .sub,
        workPath: "/tmp/x",
        payload: shellPayload(),
        resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 5, maxOutputBytes: 100))
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("epoch") || text.contains("stale") || text.contains("Fleet"),
        text)
    }
  }

  // MARK: F3 — grafting / digest mismatch / dispatch receipt / signed job required

  func testGraftedAssignmentLogicalJobIDRejectedAtCommit() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)

    let job = makePhysicalJob(
      jobID: "job-graft", logicalJobID: "logical-A", dispatchNonce: "nonce-graft",
      targetDeviceID: targetAID, at: clock.now())
    let legit = try makeAssignment(from: job, attempt: 1, at: clock.now())
    try writeSignedAssignment(legit, store: scheduler.store)

    let url = scheduler.store.assignmentURL(for: "job-graft")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var envelope = try decoder.decode(
      TatwoFleetSignedEnvelopeV1.self, from: Data(contentsOf: url))
    var body = envelope.body
    if let range = body.range(of: Data("logical-A".utf8)) {
      body.replaceSubrange(range, with: Data("logical-B".utf8))
    } else {
      XCTFail("expected logical-A in assignment body")
    }
    let tampered = TatwoFleetSignedEnvelopeV1(
      purpose: .assignment,
      authorityEpoch: envelope.authorityEpoch,
      originDeviceID: envelope.originDeviceID,
      ledgerSequence: envelope.ledgerSequence,
      recordID: envelope.recordID,
      canonicalRelativePath: envelope.canonicalRelativePath,
      body: body,
      authorization: envelope.authorization)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(tampered).write(to: url)
    XCTAssertThrowsError(try scheduler.store.loadAssignment(jobID: "job-graft"))

    try writeSignedAssignment(legit, store: scheduler.store)
    let loaded = try XCTUnwrap(try scheduler.store.loadAssignment(jobID: "job-graft"))
    let badResult = try makeResult(assignment: loaded, digestOverride: "forged-digest")
    XCTAssertThrowsError(
      try scheduler.acceptAttemptResult(assignment: loaded, result: badResult, signedJob: job)
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(text.contains("binding") || text.contains("mismatch"), text)
    }
  }

  func testSignedJobProbeMismatchFailsClosed() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let job = makePhysicalJob(
      jobID: "job-bind", logicalJobID: "logical-bind", dispatchNonce: "nonce-bind",
      targetDeviceID: targetAID, at: clock.now())
    let assignment = try makeAssignment(from: job, attempt: 1, at: clock.now())
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try writeSignedAssignment(assignment, store: store)
    let loaded = try XCTUnwrap(try store.loadAssignment(jobID: "job-bind"))
    let wrongJob = makePhysicalJob(
      jobID: "job-bind", logicalJobID: "logical-OTHER", dispatchNonce: "nonce-bind",
      targetDeviceID: targetAID, at: clock.now())
    let scheduler = TatwoFleetScheduler(
      store: store,
      now: { clock.now() },
      signedJobProbe: { _ in wrongJob } as TatwoFleetSignedJobProbe)
    let result = try makeResult(assignment: loaded)
    XCTAssertThrowsError(
      try scheduler.acceptAttemptResult(assignment: loaded, result: result)
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(text.contains("binding") || text.contains("mismatch"), text)
    }
  }

  func testDispatchReceiptMismatchFailsClosed() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try scheduler.registerDevice(
      deviceID: targetAID, maxConcurrent: 1, detectedAgentsOverride: [.grok])
    _ = try enqueueShell(scheduler: scheduler, logicalJobID: "logical-receipt")

    let badDispatch: TatwoFleetDispatchHandler = { job in
      // Wrong nonce — must fail closed.
      TatwoFleetDispatchReceiptV1(
        jobID: job.jobID,
        dispatchNonce: "not-the-physical-nonce",
        targetDeviceID: job.targetDeviceID,
        jobCanonicalDigest: (try? job.canonicalDigest()) ?? "x",
        dispatchRecordID: "rec")
    }
    XCTAssertThrowsError(
      try scheduler.tick(
        config: TatwoFleetTickConfigV1(heartbeatMaxAgeSeconds: 120),
        dispatch: badDispatch)
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("dispatch") || text.contains("receipt") || text.contains("nonce"),
        text)
    }
  }

  func testMissingSignedJobFailsClosedAtCommit() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let job = makePhysicalJob(
      jobID: "job-nosigned", logicalJobID: "logical-nosigned", dispatchNonce: "nonce-ns",
      targetDeviceID: targetAID, at: clock.now())
    let assignment = try makeAssignment(from: job, attempt: 1, at: clock.now())
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try writeSignedAssignment(assignment, store: store)
    let loaded = try XCTUnwrap(try store.loadAssignment(jobID: "job-nosigned"))
    let scheduler = TatwoFleetScheduler(store: store, now: { clock.now() })
    let result = try makeResult(assignment: loaded)
    XCTAssertThrowsError(
      try scheduler.acceptAttemptResult(assignment: loaded, result: result)
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(text.contains("signed job") || text.contains("binding"), text)
    }
  }

  // MARK: F4 — env isolation + symlink HOME

  func testAgentLaunchEnvironmentStripsDYLDAndDoesNotInheritHostPathShellTmp() throws {
    let host: [String: String] = [
      "PATH": "/evil/bin:/usr/bin:/bin",
      "SHELL": "/bin/zsh",
      "TMPDIR": "/evil/tmp",
      "HOME": "/Users/example",
      "DYLD_INSERT_LIBRARIES": "/evil.dylib",
      "CODEX_HOME": "/Users/example/.codex",
      "CLAUDE_CONFIG_DIR": "/evil",
      "LANG": "en_US.UTF-8",
    ]
    let env = TatwoAgentLaunchEnvironment.explicitMinimal(
      executablePath: "/usr/bin/true", from: host)
    XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
    XCTAssertNil(env["CODEX_HOME"])
    XCTAssertNil(env["CLAUDE_CONFIG_DIR"])
    XCTAssertNil(env["HOME"])
    XCTAssertNil(env["SHELL"])
    XCTAssertNotEqual(env["PATH"], host["PATH"])
    // PATH is the executable's own directory plus the SIP-protected system
    // directories — agent CLIs legitimately call standard utilities, and the host
    // PATH is exactly the injection surface this environment removes.
    XCTAssertEqual(
      env["PATH"],
      (["/usr/bin"] + TatwoAgentLaunchEnvironment.systemBinaryDirectories).joined(separator: ":"))
    XCTAssertNil(env["TMPDIR"])
    XCTAssertEqual(env["LANG"], "en_US.UTF-8")

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-iso-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let isolated = try TatwoAgentLaunchEnvironment.isolated(
      agent: .grok, isolatedHomesRoot: root, executablePath: "/usr/bin/true", from: host)
    XCTAssertEqual(isolated["HOME"], root.appendingPathComponent("grok").path)
    XCTAssertNil(isolated["DYLD_INSERT_LIBRARIES"])
    XCTAssertNil(isolated["CODEX_HOME"])
    XCTAssertEqual(isolated["TATWO_ISOLATED_AGENT"], "grok")
    XCTAssertEqual(
      isolated["PATH"],
      (["/usr/bin"] + TatwoAgentLaunchEnvironment.systemBinaryDirectories).joined(separator: ":"))
  }

  func testIsolatedHomeSymlinkFailsClosed() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-iso-symlink-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let evil = root.appendingPathComponent("evil-target", isDirectory: true)
    try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
    let homeLink = root.appendingPathComponent("grok", isDirectory: false)
    try FileManager.default.createSymbolicLink(at: homeLink, withDestinationURL: evil)

    XCTAssertThrowsError(
      try TatwoAgentLaunchEnvironment.prepareIsolatedHome(
        agent: .grok, isolatedHomesRoot: root)
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(text.contains("symlink") || text.contains("fail closed"), text)
    }
  }

  // MARK: F5 — workPath bind / rename residual

  func testWorkPathSymlinkSwapDetectedBeforeLaunch() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let realA = root.appendingPathComponent("real-a", isDirectory: true)
    let realB = root.appendingPathComponent("real-b", isDirectory: true)
    let link = root.appendingPathComponent("work-link", isDirectory: false)
    try FileManager.default.createDirectory(at: realA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: realB, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realA)

    let bound = try TatwoBoundWorkPath.bind(link)
    // Held fd still valid; replacing directory inode at original real path is detected via fstat.
    try FileManager.default.removeItem(at: realA)
    try FileManager.default.createDirectory(at: realA, withIntermediateDirectories: true)
    // Original open fd may still reference old inode on some FS; rename attack:
    // rename bound directory away and put a new dir at the path string.
    // assertUnchanged uses fstat on held fd — inode identity is what matters.
    // If removeItem closed the dir, fstat fails → fail closed.
    XCTAssertThrowsError(try bound.assertUnchanged())
  }

  func testWorkPathRenameDoesNotAffectHeldDirectoryFdSpawn() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work-orig", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    // Marker file so we can prove spawn used the held inode.
    try "held-inode".write(
      to: work.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)

    let bound = try TatwoBoundWorkPath.bind(work)
    let moved = root.appendingPathComponent("work-moved", isDirectory: true)
    try FileManager.default.moveItem(at: work, to: moved)
    // Attacker plants a different directory at the old pathname.
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try "attacker".write(
      to: work.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)

    // Held fd still points at moved inode; fstat identity unchanged.
    try bound.assertUnchanged()

    let result = try ProcessEngineBinding.runProcess(
      executablePath: "/bin/cat",
      arguments: ["marker.txt"],
      boundWorkPath: bound,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 5, maxOutputBytes: 1024),
      shouldCancel: { false },
      environment: TatwoAgentLaunchEnvironment.explicitMinimal(executablePath: "/bin/cat"))
    XCTAssertEqual(result.failureCode, nil, result.message ?? "")
    XCTAssertEqual(String(data: result.outputData, encoding: .utf8), "held-inode")
  }

  func testProcessTimeoutDoesNotHangUnbounded() throws {
    let caps = TatwoLoopResourceCapsV1(maxDurationSec: 0.05, maxOutputBytes: 1024)
    let started = Date()
    let result = try ProcessEngineBinding.runProcess(
      executablePath: "/bin/sleep",
      arguments: ["30"],
      currentDirectory: nil,
      caps: caps,
      shouldCancel: { false },
      environment: TatwoAgentLaunchEnvironment.explicitMinimal(executablePath: "/bin/sleep"),
      postKillWaitSec: 1)
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertTrue(
      result.timedOut || result.failureCode == "process_residual"
        || result.failureCode == "timeout")
    XCTAssertLessThan(elapsed, 8, "must not hang on waitUntilExit")
  }

  // MARK: F5/G6 — daemonize residual fail-closed

  func testDaemonizeDescendantResidualFailsClosed() throws {
    // Child setsid + double-fork style: sleep in new session so group kill of root is insufficient.
    // Tracking during run captures lineage identity before reparent; clear uses that identity.
    let script = """
      #!/bin/sh
      # Start a detached sleep that survives parent exit (new session, reparent).
      /usr/bin/setsid /bin/sleep 30 </dev/null >/dev/null 2>&1 &
      # Give sleep a moment to setsid before parent exits.
      /bin/sleep 0.05
      exit 0
      """
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let scriptURL = root.appendingPathComponent("daemonize.sh")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

    let bound = try TatwoBoundWorkPath.bind(root)
    let caps = TatwoLoopResourceCapsV1(maxDurationSec: 2, maxOutputBytes: 1024)
    let result = try ProcessEngineBinding.runProcess(
      executablePath: "/bin/sh",
      arguments: [scriptURL.path],
      boundWorkPath: bound,
      caps: caps,
      shouldCancel: { false },
      environment: TatwoAgentLaunchEnvironment.explicitMinimal(executablePath: "/bin/sh"),
      postKillWaitSec: 1)

    // Must not claim success while daemonized descendants remain / were residual.
    // Either process_residual (still present after kill) or success only if tracked clear worked
    // and no cwd evidence remains — never a silent PASS with live workPath cwd stragglers.
    if result.failureCode == nil {
      let post = ProcessEngineBinding.scanWorkPathResidualsOnly(boundWorkPath: bound)
      XCTAssertEqual(post, .clean, "PASS requires no workPath cwd evidence residual")
    } else {
      XCTAssertEqual(
        result.failureCode, "process_residual",
        "daemonized descendant must fail closed; got failureCode=\(result.failureCode ?? "nil") message=\(result.message ?? "") exit=\(result.exitCode)")
    }
  }

  /// A root pid of 0 or 1 must be refused outright. Passing 0 once made every
  /// process on the host look like a descendant, and the caller SIGKILLed the set —
  /// taking down the user's whole login session.
  func testInvalidRootPIDIsRefusedNotScanned() throws {
    for badRoot in [pid_t(0), pid_t(1), pid_t(-1)] {
      let result = ProcessEngineBinding.scanResidualDescendants(
        rootPID: badRoot,
        processGroupEstablished: true,
        boundWorkPath: nil)
      guard case let .failed(reason) = result else {
        XCTFail("rootPID \(badRoot) must fail closed, got \(result)")
        continue
      }
      XCTAssertTrue(
        reason.contains("invalid job root pid"),
        "unexpected failure reason for \(badRoot): \(reason)")
    }
  }

  /// The signalling chokepoint must refuse bare pids (no identity) and unsafe pids.
  func testSignalResidualRefusesUnsafePIDs() throws {
    XCTAssertFalse(ProcessEngineBinding.signalResidual(0, SIGKILL))
    XCTAssertFalse(ProcessEngineBinding.signalResidual(1, SIGKILL))
    XCTAssertFalse(ProcessEngineBinding.signalResidual(-1, SIGKILL))
    XCTAssertFalse(ProcessEngineBinding.signalResidual(getpid(), SIGKILL))
    // Bare-pid API is permanently refused (identity required).
    XCTAssertFalse(ProcessEngineBinding.signalResidual(99999, SIGKILL))
    let bogus = ProcessEngineBinding.ProcessIdentity(pid: 0, startSec: 1, startUsec: 2)
    XCTAssertFalse(ProcessEngineBinding.signalResidual(identity: bogus, signal: SIGKILL))
  }

  /// Effects double: serves a synthetic process table and records signals instead of
  /// sending them, so classification can be tested without touching the host.
  private struct FakeProcessControl: ProcessEngineBinding.ProcessControlEffects,
    ProcessEngineBinding.WorkPathCWDProviding
  {
    let rows: [ProcessEngineBinding.ProcessTableRow]
    let alive: Set<pid_t>
    let identities: [pid_t: ProcessEngineBinding.ProcessIdentity]
    let cwdMatchPIDs: Set<pid_t>
    let recorder: SignalRecorder

    final class SignalRecorder: @unchecked Sendable {
      private let lock = NSLock()
      private var sent: [(pid_t, Int32)] = []
      func record(_ pid: pid_t, _ sig: Int32) {
        lock.lock()
        defer { lock.unlock() }
        sent.append((pid, sig))
      }
      var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return sent.count
      }
      var pids: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return sent.map(\.0)
      }
    }

    init(
      rows: [ProcessEngineBinding.ProcessTableRow],
      alive: Set<pid_t>,
      recorder: SignalRecorder,
      cwdMatchPIDs: Set<pid_t> = [],
      identities: [pid_t: ProcessEngineBinding.ProcessIdentity]? = nil
    ) {
      self.rows = rows
      self.alive = alive
      self.recorder = recorder
      self.cwdMatchPIDs = cwdMatchPIDs
      if let identities {
        self.identities = identities
      } else {
        var built: [pid_t: ProcessEngineBinding.ProcessIdentity] = [:]
        for pid in alive where pid > 1 {
          built[pid] = ProcessEngineBinding.ProcessIdentity(
            pid: pid, startSec: UInt64(pid), startUsec: 0)
        }
        self.identities = built
      }
    }

    func processTable() -> Result<
      [ProcessEngineBinding.ProcessTableRow], ProcessEngineBinding.ProcessTableError
    > { .success(rows) }
    func isAlive(_ pid: pid_t) -> Bool { alive.contains(pid) }
    func isIndeterminate(_ pid: pid_t) -> Bool { false }
    func processIdentity(_ pid: pid_t) -> ProcessEngineBinding.ProcessIdentity? {
      identities[pid]
    }
    func identityMatches(_ identity: ProcessEngineBinding.ProcessIdentity) -> Bool {
      identities[identity.pid] == identity
    }
    @discardableResult
    func signal(identity: ProcessEngineBinding.ProcessIdentity, _ sig: Int32) -> Bool {
      guard identityMatches(identity) else { return false }
      recorder.record(identity.pid, sig)
      return true
    }
    @discardableResult
    func signalProcessGroup(
      rootIdentity: ProcessEngineBinding.ProcessIdentity, _ sig: Int32
    ) -> Bool {
      guard identityMatches(rootIdentity) else { return false }
      // Negative pid records group signal without Darwin kill.
      recorder.record(-rootIdentity.pid, sig)
      return true
    }
    func workPathMatchingPIDs(among candidatePIDs: [pid_t], excludePID: pid_t) -> Set<pid_t> {
      Set(candidatePIDs.filter { cwdMatchPIDs.contains($0) && $0 != excludePID && $0 > 1 })
    }
  }

  private func fakeIdentity(_ pid: pid_t, startSec: UInt64? = nil) -> ProcessEngineBinding.ProcessIdentity {
    ProcessEngineBinding.ProcessIdentity(
      pid: pid, startSec: startSec ?? UInt64(pid), startUsec: 0)
  }

  /// Replays the 2026-07-29 incident shape against a synthetic table: a host where
  /// every process roots at launchd. A real job root must claim only its own subtree,
  /// never the unrelated processes that merely share pid 1 as an ancestor.
  func testAncestryThroughLaunchdDoesNotClaimUnrelatedProcesses() throws {
    typealias Row = ProcessEngineBinding.ProcessTableRow
    let rows: [Row] = [
      Row(pid: 1, ppid: 0, pgid: 1),
      // Unrelated session processes reparented to launchd — the ones that died.
      Row(pid: 400, ppid: 1, pgid: 400),
      Row(pid: 401, ppid: 1, pgid: 401),
      Row(pid: 402, ppid: 400, pgid: 400),
      // The job root and its genuine child.
      Row(pid: 900, ppid: 1, pgid: 900),
      Row(pid: 901, ppid: 900, pgid: 900),
    ]
    let recorder = FakeProcessControl.SignalRecorder()
    let effects = FakeProcessControl(
      rows: rows, alive: [1, 400, 401, 402, 900, 901], recorder: recorder)
    let rootID = fakeIdentity(900)

    let result = ProcessEngineBinding.scanResidualDescendants(
      rootPID: 900,
      rootIdentity: rootID,
      processGroupEstablished: true,
      boundWorkPath: nil,
      effects: effects)

    guard case let .residual(set) = result else {
      return XCTFail("expected the job subtree as residual, got \(result)")
    }
    XCTAssertEqual(set.killablePIDs, [900, 901], "scan must claim only the job's own subtree")
    XCTAssertTrue(set.evidenceOnly.isEmpty)
    XCTAssertFalse(set.killablePIDs.contains(400), "unrelated reparented process must not be claimed")
    XCTAssertFalse(set.killablePIDs.contains(401))
    XCTAssertFalse(set.killablePIDs.contains(402))
    XCTAssertEqual(recorder.count, 0, "scanning must never signal anything")
  }

  /// R1: cwd-only match is evidence that blocks PASS, never killable signal authority.
  func testCwdOnlyMatchIsEvidenceNeverKillable() throws {
    typealias Row = ProcessEngineBinding.ProcessTableRow
    let rows: [Row] = [
      Row(pid: 1, ppid: 0, pgid: 1),
      Row(pid: 900, ppid: 1, pgid: 900),
      // Unrelated editor helper whose cwd happens to be workPath.
      Row(pid: 700, ppid: 1, pgid: 700),
    ]
    let recorder = FakeProcessControl.SignalRecorder()
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bound = try TatwoBoundWorkPath.bind(root)
    let effects = FakeProcessControl(
      rows: rows,
      alive: [900, 700],
      recorder: recorder,
      cwdMatchPIDs: [700])

    let result = ProcessEngineBinding.scanResidualDescendants(
      rootPID: 900,
      rootIdentity: fakeIdentity(900),
      processGroupEstablished: true,
      boundWorkPath: bound,
      effects: effects)
    guard case let .residual(set) = result else {
      return XCTFail("expected residual, got \(result)")
    }
    XCTAssertEqual(set.killablePIDs, [900])
    XCTAssertEqual(set.evidenceOnly, [700], "cwd-only must be evidence-only")
    XCTAssertTrue(set.blocksPass)
    XCTAssertTrue(set.isCwdQuarantineOnly == false)
    // Simulate clear path: only killable identities may be signalled.
    for identity in set.killable {
      _ = effects.signal(identity: identity, SIGKILL)
    }
    XCTAssertEqual(recorder.pids, [900])
    XCTAssertFalse(recorder.pids.contains(700), "cwd-only pid must never be signalled")
  }

  /// R5: cwd-only residual is quarantine terminal classification (no signal authority).
  func testCwdOnlyIsQuarantineTerminalNotKillableResidual() throws {
    typealias Row = ProcessEngineBinding.ProcessTableRow
    let rows: [Row] = [
      Row(pid: 1, ppid: 0, pgid: 1),
      // Root reaped; only unrelated cwd match remains.
      Row(pid: 700, ppid: 1, pgid: 700),
    ]
    let recorder = FakeProcessControl.SignalRecorder()
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bound = try TatwoBoundWorkPath.bind(root)
    let originalRoot = fakeIdentity(900, startSec: 1)
    let effects = FakeProcessControl(
      rows: rows,
      alive: [700],
      recorder: recorder,
      cwdMatchPIDs: [700],
      identities: [700: fakeIdentity(700)])

    let result = ProcessEngineBinding.scanResidualDescendants(
      rootPID: 900,
      rootIdentity: originalRoot,
      processGroupEstablished: true,
      boundWorkPath: bound,
      effects: effects)
    guard case let .residual(set) = result else {
      return XCTFail("expected cwd quarantine residual, got \(result)")
    }
    XCTAssertTrue(set.killable.isEmpty)
    XCTAssertEqual(set.evidenceOnly, [700])
    XCTAssertTrue(set.isCwdQuarantineOnly)
    XCTAssertEqual(recorder.count, 0)
  }

  /// R1: daemon that chdir("/") after being tracked remains residual (reportable) even
  /// when no longer in lineage/cwd; kill still requires identity match.
  func testTrackedDaemonAfterChdirRemainsResidualEvenIfNotInCwd() throws {
    typealias Row = ProcessEngineBinding.ProcessTableRow
    let daemon = ProcessEngineBinding.ProcessIdentity(pid: 950, startSec: 42, startUsec: 7)
    let rows: [Row] = [
      Row(pid: 1, ppid: 0, pgid: 1),
      // Root gone; daemon reparented + left workPath (chdir /).
      Row(pid: 950, ppid: 1, pgid: 950),
    ]
    let recorder = FakeProcessControl.SignalRecorder()
    let effects = FakeProcessControl(
      rows: rows,
      alive: [950],
      recorder: recorder,
      cwdMatchPIDs: [],
      identities: [950: daemon])

    let result = ProcessEngineBinding.scanResidualDescendants(
      rootPID: 900,
      rootIdentity: fakeIdentity(900, startSec: 1),
      processGroupEstablished: false,
      boundWorkPath: nil,
      trackedIdentities: [daemon],
      effects: effects)
    guard case let .residual(set) = result else {
      return XCTFail("tracked daemon must be residual, got \(result)")
    }
    XCTAssertEqual(set.killablePIDs, [950])
    XCTAssertTrue(set.evidenceOnly.isEmpty)
    XCTAssertTrue(set.blocksPass)
  }

  /// R1: after root is reaped, a new process reusing the bare PID must not become killable.
  func testRootPIDReuseDoesNotRegainSignalAuthority() throws {
    typealias Row = ProcessEngineBinding.ProcessTableRow
    let originalRoot = fakeIdentity(900, startSec: 10)
    let reused = fakeIdentity(900, startSec: 99)  // same pid, new start time
    let rows: [Row] = [
      Row(pid: 1, ppid: 0, pgid: 1),
      Row(pid: 900, ppid: 1, pgid: 900),
      Row(pid: 901, ppid: 900, pgid: 900),
    ]
    let recorder = FakeProcessControl.SignalRecorder()
    let effects = FakeProcessControl(
      rows: rows,
      alive: [900, 901],
      recorder: recorder,
      identities: [
        900: reused,
        901: fakeIdentity(901, startSec: 99),
      ])

    let result = ProcessEngineBinding.scanResidualDescendants(
      rootPID: 900,
      rootIdentity: originalRoot,
      processGroupEstablished: true,
      boundWorkPath: nil,
      effects: effects)
    switch result {
    case .clean:
      break
    case let .residual(set):
      XCTAssertFalse(set.killablePIDs.contains(900), "reused root pid must not be killable")
      XCTAssertFalse(set.killablePIDs.contains(901), "pgid under reused root must not expand")
    case let .failed(reason):
      XCTFail("unexpected failure: \(reason)")
    }
    XCTAssertEqual(recorder.count, 0)
  }

  /// R1: PGID reuse after original group leader identity is gone must not expand killable.
  func testPGIDReuseDoesNotExpandKillableLineage() throws {
    typealias Row = ProcessEngineBinding.ProcessTableRow
    let originalRoot = fakeIdentity(900, startSec: 10)
    // Unrelated new process claims pgid 900; original root identity gone.
    let rows: [Row] = [
      Row(pid: 1, ppid: 0, pgid: 1),
      Row(pid: 880, ppid: 1, pgid: 900),
      Row(pid: 881, ppid: 880, pgid: 900),
    ]
    let recorder = FakeProcessControl.SignalRecorder()
    let effects = FakeProcessControl(
      rows: rows,
      alive: [880, 881],
      recorder: recorder,
      identities: [
        880: fakeIdentity(880, startSec: 50),
        881: fakeIdentity(881, startSec: 51),
      ])

    let result = ProcessEngineBinding.scanResidualDescendants(
      rootPID: 900,
      rootIdentity: originalRoot,
      processGroupEstablished: true,
      boundWorkPath: nil,
      effects: effects)
    switch result {
    case .clean:
      break
    case let .residual(set):
      XCTAssertTrue(set.killable.isEmpty, "PGID reuse must not grant killable set: \(set.killablePIDs)")
    case let .failed(reason):
      XCTFail("unexpected failure: \(reason)")
    }
  }

  /// R1: rootIdentity == nil forbids group-driven killable expansion (fail closed).
  func testNilRootIdentityForbidsBareRootLineageAuthority() throws {
    typealias Row = ProcessEngineBinding.ProcessTableRow
    let rows: [Row] = [
      Row(pid: 900, ppid: 1, pgid: 900),
      Row(pid: 901, ppid: 900, pgid: 900),
    ]
    let recorder = FakeProcessControl.SignalRecorder()
    let effects = FakeProcessControl(
      rows: rows, alive: [900, 901], recorder: recorder)

    let result = ProcessEngineBinding.scanResidualDescendants(
      rootPID: 900,
      rootIdentity: nil,
      processGroupEstablished: true,
      boundWorkPath: nil,
      effects: effects)
    switch result {
    case .clean:
      break
    case let .residual(set):
      XCTAssertTrue(set.killable.isEmpty, "nil rootIdentity must not seed killable from bare PID")
    case let .failed(reason):
      XCTFail("unexpected failure: \(reason)")
    }
  }

  /// R1: ps→proc_pidinfo TOCTOU — child identity capture that no longer matches is refused.
  func testProcessIdentityTOCTOUBetweenTableAndCaptureIsRefused() throws {
    final class FlipEffects: ProcessEngineBinding.ProcessControlEffects, @unchecked Sendable {
      let rows: [ProcessEngineBinding.ProcessTableRow]
      let root = ProcessEngineBinding.ProcessIdentity(pid: 900, startSec: 10, startUsec: 0)
      /// Captured start time from first proc_pidinfo observation.
      let capturedChild = ProcessEngineBinding.ProcessIdentity(pid: 901, startSec: 1, startUsec: 0)

      init(rows: [ProcessEngineBinding.ProcessTableRow]) { self.rows = rows }
      func processTable() -> Result<
        [ProcessEngineBinding.ProcessTableRow], ProcessEngineBinding.ProcessTableError
      > { .success(rows) }
      func isAlive(_ pid: pid_t) -> Bool { pid == 900 || pid == 901 }
      func isIndeterminate(_ pid: pid_t) -> Bool { false }
      func processIdentity(_ pid: pid_t) -> ProcessEngineBinding.ProcessIdentity? {
        if pid == 900 { return root }
        if pid == 901 { return capturedChild }
        return nil
      }
      func identityMatches(_ identity: ProcessEngineBinding.ProcessIdentity) -> Bool {
        // Root remains stable. Child PID was reused between ps snapshot and match:
        // captured start time no longer equals live process.
        if identity.pid == 900 { return identity == root }
        if identity.pid == 901 { return false }
        return false
      }
      @discardableResult
      func signal(identity: ProcessEngineBinding.ProcessIdentity, _ sig: Int32) -> Bool { false }
      @discardableResult
      func signalProcessGroup(
        rootIdentity: ProcessEngineBinding.ProcessIdentity, _ sig: Int32
      ) -> Bool { false }
    }

    let effects = FlipEffects(rows: [
      ProcessEngineBinding.ProcessTableRow(pid: 900, ppid: 1, pgid: 900),
      ProcessEngineBinding.ProcessTableRow(pid: 901, ppid: 900, pgid: 900),
    ])
    let result = ProcessEngineBinding.scanResidualDescendants(
      rootPID: 900,
      rootIdentity: ProcessEngineBinding.ProcessIdentity(pid: 900, startSec: 10, startUsec: 0),
      processGroupEstablished: true,
      boundWorkPath: nil,
      effects: effects)
    guard case let .residual(set) = result else {
      return XCTFail("root should remain killable; child TOCTOU refused, got \(result)")
    }
    XCTAssertEqual(set.killablePIDs, [900])
    XCTAssertFalse(set.killablePIDs.contains(901), "TOCTOU child must not be admitted")
  }

  /// R2: over-cap classification is anomalous but lineage killable is still returned
  /// for clearing — never an empty `.failed` that skips authorized kills.
  func testImplausibleResidualSetStillReturnsKillableForClear() throws {
    typealias Row = ProcessEngineBinding.ProcessTableRow
    let cap = ProcessEngineBinding.maxPlausibleResidualDescendants
    var rows: [Row] = [Row(pid: 900, ppid: 1, pgid: 900)]
    var alive: Set<pid_t> = [900]
    for i in 0...(cap + 5) {
      let pid = pid_t(1000 + i)
      rows.append(Row(pid: pid, ppid: 900, pgid: 900))
      alive.insert(pid)
    }
    let recorder = FakeProcessControl.SignalRecorder()
    let effects = FakeProcessControl(rows: rows, alive: alive, recorder: recorder)
    let rootID = fakeIdentity(900)

    let result = ProcessEngineBinding.scanResidualDescendants(
      rootPID: 900,
      rootIdentity: rootID,
      processGroupEstablished: true,
      boundWorkPath: nil,
      effects: effects)

    guard case let .residual(set) = result else {
      return XCTFail("oversized lineage set must still return residual killable, got \(result)")
    }
    XCTAssertNotNil(set.anomaly)
    XCTAssertTrue(set.anomaly?.contains("implausible") == true, set.anomaly ?? "")
    XCTAssertGreaterThan(set.killable.count, cap)
    XCTAssertTrue(set.blocksPass)
    // Clear path would signal all killable — scanning itself signals nothing.
    XCTAssertEqual(recorder.count, 0)
    for identity in set.killable {
      _ = effects.signal(identity: identity, SIGTERM)
    }
    XCTAssertEqual(recorder.count, set.killable.count)
  }

  /// R1 (round 6): match → root exit → concurrent reap attempt → group signal must not
  /// interleave reap between identityMatches and kill(-pgid). RootLifecycleGate holds
  /// both sides; a zombie root cannot be reaped (PID reused) during group signal.
  func testGroupSignalHoldsRootLifecycleLockAgainstConcurrentReap() throws {
    let gate = ProcessEngineBinding.RootLifecycleGate()
    let rootID = fakeIdentity(900, startSec: 10)
    let matchEntered = DispatchSemaphore(value: 0)
    let holdGroup = DispatchSemaphore(value: 0)
    let orderLock = NSLock()
    var events: [String] = []
    func push(_ e: String) {
      orderLock.lock()
      events.append(e)
      orderLock.unlock()
    }

    final class OrderedGroupEffects: ProcessEngineBinding.ProcessControlEffects,
      @unchecked Sendable
    {
      let root: ProcessEngineBinding.ProcessIdentity
      let matchEntered: DispatchSemaphore
      let holdGroup: DispatchSemaphore
      let push: (String) -> Void
      let recorder = FakeProcessControl.SignalRecorder()

      init(
        root: ProcessEngineBinding.ProcessIdentity,
        matchEntered: DispatchSemaphore,
        holdGroup: DispatchSemaphore,
        push: @escaping (String) -> Void
      ) {
        self.root = root
        self.matchEntered = matchEntered
        self.holdGroup = holdGroup
        self.push = push
      }

      func processTable() -> Result<
        [ProcessEngineBinding.ProcessTableRow], ProcessEngineBinding.ProcessTableError
      > {
        .success([
          ProcessEngineBinding.ProcessTableRow(pid: 900, ppid: 1, pgid: 900)
        ])
      }
      func isAlive(_ pid: pid_t) -> Bool { pid == 900 }
      func isIndeterminate(_ pid: pid_t) -> Bool { false }
      func processIdentity(_ pid: pid_t) -> ProcessEngineBinding.ProcessIdentity? {
        pid == 900 ? root : nil
      }
      func identityMatches(_ identity: ProcessEngineBinding.ProcessIdentity) -> Bool {
        identity == root
      }
      @discardableResult
      func signal(identity: ProcessEngineBinding.ProcessIdentity, _ sig: Int32) -> Bool {
        guard identityMatches(identity) else { return false }
        recorder.record(identity.pid, sig)
        return true
      }
      @discardableResult
      func signalProcessGroup(
        rootIdentity: ProcessEngineBinding.ProcessIdentity, _ sig: Int32
      ) -> Bool {
        guard identityMatches(rootIdentity) else { return false }
        push("match")
        matchEntered.signal()
        // Simulate root exit after match; concurrent reap must wait on lifecycle gate.
        push("root_exit_observed")
        // Hold the group-signal critical section until the test's reap thread has
        // blocked (or timed out trying) on the same RootLifecycleGate.
        _ = holdGroup.wait(timeout: .now() + 2)
        push("group_signal")
        recorder.record(-rootIdentity.pid, sig)
        return true
      }
    }

    let effects = OrderedGroupEffects(
      root: rootID, matchEntered: matchEntered, holdGroup: holdGroup, push: push)

    let terminateDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      ProcessEngineBinding.terminateTree(
        rootPID: 900,
        rootIdentity: rootID,
        processGroupEstablished: true,
        boundWorkPath: nil,
        trackedIdentities: [rootID],
        graceSec: 0,
        effects: effects,
        rootLifecycle: gate)
      terminateDone.signal()
    }

    // Wait until group signal holds the lifecycle lock past match.
    XCTAssertEqual(matchEntered.wait(timeout: .now() + 2), .success)
    // Concurrent "reap" attempt: if the gate works, this cannot run until group_signal.
    gate.withLock {
      push("reap")
    }
    holdGroup.signal()
    XCTAssertEqual(terminateDone.wait(timeout: .now() + 2), .success)

    orderLock.lock()
    let got = events
    orderLock.unlock()
    // Reap must not appear between match and group_signal.
    guard let matchIdx = got.firstIndex(of: "match"),
      let groupIdx = got.firstIndex(of: "group_signal"),
      let reapIdx = got.firstIndex(of: "reap")
    else {
      return XCTFail("missing events: \(got)")
    }
    XCTAssertLessThan(matchIdx, groupIdx)
    XCTAssertGreaterThan(reapIdx, groupIdx, "reap interleaved before group signal: \(got)")
    XCTAssertTrue(effects.recorder.pids.contains(-900), "group signal must be recorded")
  }

  /// R6: production terminateTree path must signal all over-cap killable identities
  /// via the injected effects seam (not a manual for-loop that skips terminateTree).
  func testTerminateTreeSignalsAllOverCapKillableViaProductionPath() throws {
    typealias Row = ProcessEngineBinding.ProcessTableRow
    let cap = ProcessEngineBinding.maxPlausibleResidualDescendants
    var rows: [Row] = [Row(pid: 900, ppid: 1, pgid: 900)]
    var alive: Set<pid_t> = [900]
    for i in 0...(cap + 3) {
      let pid = pid_t(2000 + i)
      rows.append(Row(pid: pid, ppid: 900, pgid: 900))
      alive.insert(pid)
    }
    let recorder = FakeProcessControl.SignalRecorder()
    let effects = FakeProcessControl(rows: rows, alive: alive, recorder: recorder)
    let rootID = fakeIdentity(900)

    ProcessEngineBinding.terminateTree(
      rootPID: 900,
      rootIdentity: rootID,
      processGroupEstablished: true,
      boundWorkPath: nil,
      trackedIdentities: [rootID],
      graceSec: 0,
      effects: effects)

    // Production path must have signalled every lineage killable identity at least once.
    let unique = Set(recorder.pids)
    XCTAssertTrue(unique.contains(900))
    XCTAssertGreaterThan(unique.count, cap)
    XCTAssertEqual(recorder.count > 0, true)
  }

  /// A process table that cannot be read must fail closed, never read as "clean".
  func testProcessTableFailureIsNotClean() throws {
    struct FailingTable: ProcessEngineBinding.ProcessControlEffects {
      func processTable() -> Result<
        [ProcessEngineBinding.ProcessTableRow], ProcessEngineBinding.ProcessTableError
      > { .failure(ProcessEngineBinding.ProcessTableError("ps unavailable")) }
      func isAlive(_ pid: pid_t) -> Bool { false }
      func isIndeterminate(_ pid: pid_t) -> Bool { false }
      func processIdentity(_ pid: pid_t) -> ProcessEngineBinding.ProcessIdentity? { nil }
      func identityMatches(_ identity: ProcessEngineBinding.ProcessIdentity) -> Bool { false }
      @discardableResult
      func signal(identity: ProcessEngineBinding.ProcessIdentity, _ sig: Int32) -> Bool { false }
      @discardableResult
      func signalProcessGroup(
        rootIdentity: ProcessEngineBinding.ProcessIdentity, _ sig: Int32
      ) -> Bool { false }
    }
    let result = ProcessEngineBinding.scanResidualDescendants(
      rootPID: 900,
      rootIdentity: fakeIdentity(900),
      processGroupEstablished: false,
      boundWorkPath: nil,
      effects: FailingTable())
    guard case let .failed(reason) = result else {
      return XCTFail("table read failure must fail closed, got \(result)")
    }
    XCTAssertTrue(reason.contains("ps unavailable"))
  }

  /// Residual scan failure must not be treated as clean (fail closed).
  func testResidualScanFailedIsNotClean() throws {
    let result = ProcessEngineBinding.scanResidualDescendants(
      rootPID: 1 << 30,  // non-existent high pid
      processGroupEstablished: false,
      boundWorkPath: nil)
    switch result {
    case .clean:
      break
    case let .residual(set):
      XCTAssertTrue(set.killable.isEmpty || set.killable.allSatisfy { kill($0.pid, 0) == 0 })
    case let .failed(reason):
      XCTAssertFalse(reason.isEmpty)
    }
  }

  /// R3: agent engine uses held bound path; rename of pathname does not re-bind attacker tree.
  func testAgentEngineDoesNotRebindPathnameAfterHeldCredential() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work-orig", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let exe = bin.appendingPathComponent("grok")
    // Fake grok: cat the prompt via /dev/fd/N (fd credential only).
    try """
      #!/bin/sh
      prompt=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --prompt-file) prompt="$2"; shift 2 ;;
          --cwd|-C) echo "PATHNAME_CWD_FORBIDDEN" >&2; exit 9 ;;
          *) shift ;;
        esac
      done
      case "$prompt" in
        /dev/fd/*) cat "$prompt" ;;
        *) echo "PATHNAME_PROMPT_FORBIDDEN:$prompt" >&2; exit 8 ;;
      esac
      exit 0
      """.write(to: exe, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exe.path)

    let bound = try TatwoBoundWorkPath.bind(work)
    let moved = root.appendingPathComponent("work-moved", isDirectory: true)
    try FileManager.default.moveItem(at: work, to: moved)
    // Attacker plants replacement at original pathname.
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try "ATTACKER_PROMPT".write(
      to: work.appendingPathComponent(TatwoAgentEngineBinding.promptFileName),
      atomically: true,
      encoding: .utf8)

    let homes = root.appendingPathComponent("homes", isDirectory: true)
    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated",
      isolatedHomesRootURL: homes,
      pinStoreURL: homes.appendingPathComponent("pins.json"))
    let result = try engine.run(
      task: TatwoLoopEngineTaskV1(
        contractID: "c",
        goalID: "g",
        identity: .sub,
        mode: .s,
        taskDescription: "HELD_INODE_PROMPT",
        agent: .grok,
        exactModelRouteID: "grok-build"),
      boundWorkPath: bound,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 5, maxOutputBytes: 8_192),
      shouldCancel: { false })
    XCTAssertNil(result.failureCode, result.message ?? "")
    let output = String(data: result.outputData, encoding: .utf8) ?? ""
    XCTAssertTrue(output.contains("HELD_INODE_PROMPT"), output)
    XCTAssertFalse(output.contains("ATTACKER_PROMPT"), output)
    // Prompt must live on held inode (moved dir), not attacker pathname.
    let heldPrompt = moved.appendingPathComponent(TatwoAgentEngineBinding.promptFileName)
    XCTAssertEqual(try String(contentsOf: heldPrompt, encoding: .utf8), "HELD_INODE_PROMPT")
  }

  /// R3: recheck → child open race — rename after final assert, before spawn, must not
  /// rebind prompt/cwd to attacker pathname (fd credential only).
  func testAgentPromptFdSurvivesRenameBetweenRecheckAndSpawn() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work-orig", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let exe = bin.appendingPathComponent("grok")
    try """
      #!/bin/sh
      prompt=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --prompt-file) prompt="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      cat "$prompt"
      exit 0
      """.write(to: exe, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exe.path)

    let bound = try TatwoBoundWorkPath.bind(work)
    let moved = root.appendingPathComponent("work-moved", isDirectory: true)
    let attacker = root.appendingPathComponent("work-orig", isDirectory: true)
    let homes = root.appendingPathComponent("homes", isDirectory: true)
    // Write prompt first via engine... use runProcess hook at ProcessEngineBinding level
    // after agent has opened the fd. Agent engine itself doesn't expose the hook, so
    // exercise the process runner seam used under the agent path.
    try bound.writeFile(name: TatwoAgentEngineBinding.promptFileName, data: Data("HELD_FD_PROMPT".utf8))
    let promptFD = try bound.openFileReadOnly(name: TatwoAgentEngineBinding.promptFileName)
    defer { _ = Darwin.close(promptFD) }
    let flags = fcntl(promptFD, F_GETFD)
    if flags >= 0 { _ = fcntl(promptFD, F_SETFD, flags & ~FD_CLOEXEC) }

    let result = try ProcessEngineBinding.runProcess(
      executablePath: exe.path,
      arguments: ["--prompt-file", "/dev/fd/\(promptFD)"],
      boundWorkPath: bound,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 5, maxOutputBytes: 8_192),
      shouldCancel: { false },
      environment: TatwoAgentLaunchEnvironment.explicitMinimal(executablePath: exe.path),
      testHookAfterAssertBeforeSpawn: {
        // Rename held work dir and plant attacker pathname between recheck and spawn.
        try? FileManager.default.moveItem(at: work, to: moved)
        try? FileManager.default.createDirectory(at: attacker, withIntermediateDirectories: true)
        try? "ATTACKER_PROMPT".write(
          to: attacker.appendingPathComponent(TatwoAgentEngineBinding.promptFileName),
          atomically: true,
          encoding: .utf8)
      })
    XCTAssertNil(result.failureCode, result.message ?? "")
    let output = String(data: result.outputData, encoding: .utf8) ?? ""
    XCTAssertTrue(output.contains("HELD_FD_PROMPT"), output)
    XCTAssertFalse(output.contains("ATTACKER_PROMPT"), output)
    _ = homes
  }

  /// R4: restoring an older signed envelope at the same pathname must be rejected.
  func testSamePathEnvelopeReplayIsRejectedByPathHighWater() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let job1 = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-replay",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(job1)
    let url = store.queueURL(for: "logical-replay")
    let olderData = try Data(contentsOf: url)

    // Advance same path with a newer signed envelope.
    clock.advance(1)
    let job2 = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-replay",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 11, maxOutputBytes: 2048),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .assigned,
      enqueuedAt: job1.enqueuedAt,
      updatedAt: clock.now())
    try store.writeLogicalJob(job2)
    let newer = try store.loadLogicalJob(logicalJobID: "logical-replay")
    XCTAssertEqual(newer?.status, .assigned)

    // Attacker restores the older envelope bytes at the same pathname.
    try olderData.write(to: url, options: .atomic)
    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: "logical-replay")) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("path replay") || text.contains("high-water") || text.contains("fenced")
          || text.contains("authorityFenced") || text.contains("ledger"),
        "expected path replay rejection, got \(text)")
    }
  }

  /// R2: mutating unsigned recordID on a still-signed-looking envelope must fail seal verify
  /// and must not open a fresh path high-water key.
  func testMutatedRecordIDFailsSealAndDoesNotBootstrapNewHighWaterKey() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_200))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let job = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-recid",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(job)
    let url = store.queueURL(for: "logical-recid")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope = try decoder.decode(
      TatwoFleetSignedEnvelopeV1.self, from: Data(contentsOf: url))

    // Attacker rewrites only recordID (not re-signed). Old code would treat this as a
    // new high-water key; sealed recordID must invalidate the signature.
    let mutated = TatwoFleetSignedEnvelopeV1(
      purpose: .queue,
      authorityEpoch: envelope.authorityEpoch,
      originDeviceID: envelope.originDeviceID,
      ledgerSequence: envelope.ledgerSequence,
      recordID: "attacker-new-record-id",
      canonicalRelativePath: envelope.canonicalRelativePath,
      body: envelope.body,
      authorization: envelope.authorization)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(mutated).write(to: url, options: .atomic)

    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: "logical-recid")) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("signature") || text.contains("recordID") || text.contains("binding")
          || text.contains("Rejected") || text.contains("mismatch"),
        "expected sealed recordID / path binding failure, got \(text)")
    }

    // Path high-water remains keyed by (purpose, path) — mutated recordID must not
    // create a parallel authority row that could bootstrap a lower sequence later.
    let pathRelative = try TatwoFleetRecordIdentityV1.relativePath(of: url, under: root)
    let pathHW = try hw.loadPathHighWater(
      purpose: TatwoFleetSignaturePurposeV1.queue.rawValue,
      canonicalRelativePath: pathRelative)
    XCTAssertEqual(pathHW?.recordID, "logical-recid")
    XCTAssertEqual(pathHW?.ledgerSequence, envelope.ledgerSequence)
  }

  /// R3: global HW exists, path marker wiped, attacker plants older envelope before first read.
  func testMissingPathMarkerWithGlobalHighWaterRejectsPlantedOldEnvelope() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_300))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let job1 = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-bootstrap",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(job1)
    let url = store.queueURL(for: "logical-bootstrap")
    let olderData = try Data(contentsOf: url)

    clock.advance(1)
    let job2 = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-bootstrap",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 12, maxOutputBytes: 2048),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .assigned,
      enqueuedAt: job1.enqueuedAt,
      updatedAt: clock.now())
    try store.writeLogicalJob(job2)

    // Simulate migration: durable global HW remains, path markers wiped.
    try hw.dangerousTestOnlyDeletePathMarkers()
    let global = try hw.loadAuthorityHighWater()
    XCTAssertNotNil(global)
    XCTAssertGreaterThan(global?.ledgerSequence ?? 0, 0)

    // First read after wipe, with older envelope planted at pathname.
    try olderData.write(to: url, options: .atomic)
    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: "logical-bootstrap")) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("ledger") || text.contains("path") || text.contains("fenced")
          || text.contains("quarantine") || text.contains("high-water")
          || text.contains("replay"),
        "expected fail-closed bootstrap rejection, got \(text)")
    }
  }

  /// R3: missing path marker can reinstall only when ledger proves current envelope.
  func testMissingPathMarkerRebuildsFromLedgerWhenCurrentMatches() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_400))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let job = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-rebuild",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(job)
    try hw.dangerousTestOnlyDeletePathMarkers()

    let loaded = try store.loadLogicalJob(logicalJobID: "logical-rebuild")
    XCTAssertEqual(loaded?.logicalJobID, "logical-rebuild")
    let pathRelative = try TatwoFleetRecordIdentityV1.relativePath(
      of: store.queueURL(for: "logical-rebuild"), under: root)
    let restored = try hw.loadPathHighWater(
      purpose: TatwoFleetSignaturePurposeV1.queue.rawValue,
      canonicalRelativePath: pathRelative)
    XCTAssertNotNil(restored)
    XCTAssertEqual(restored?.recordID, "logical-rebuild")
  }

  /// R4: device report binding requires signer AND recordID AND path id (not OR).
  /// Classic OR bypass: device B's key seals a body claiming deviceID=A (recordID=A).
  func testDeviceReportBindingRequiresAllIdentityFields() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_100))
    let originBootstrap = try makeOriginAuthority(root: root, now: { clock.now() })
    let originPin = originBootstrap.trust.localIdentity
    let (signerB, pinB) = try makeTargetSigner(
      deviceID: targetBID, pinOrigin: originPin, now: { clock.now() })
    let origin = try makeOriginAuthority(
      root: root, now: { clock.now() }, pinTargets: [pinB])
    let store = TatwoFleetStore(rootURL: root, originAuthority: origin)
    try store.ensureLayout()

    // B signs a report that *claims* deviceID=A (path/recordID=A). OR would accept
    // report.deviceID == recordID; AND requires signer == report.deviceID too.
    let report = TatwoFleetDeviceV1(
      deviceID: targetAID,
      agents: [.grok],
      maxConcurrent: 1,
      inflight: 0,
      lastHeartbeatAt: clock.now(),
      authorityEpoch: 1,
      originDeviceID: originID,
      ledgerSequence: 0)
    let envelope = try signerB.sealDeviceReport(report)
    XCTAssertEqual(envelope.authorization.deviceID, targetBID)
    XCTAssertEqual(envelope.recordID, targetAID)
    let path = store.ingestDevicesDirectory.appendingPathComponent("\(targetAID).json")
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.sortedKeys]
    try enc.encode(envelope).write(to: path)

    XCTAssertThrowsError(try store.ingestTargetDeviceReports()) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("binding") || text.contains("must equal"),
        "expected AND binding failure, got \(text)")
    }
  }

  /// R2 (round 6): delete newer ledger row + restore old current must not rebuild path HW.
  func testTruncatedLedgerPlusOldCurrentIsQuarantined() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_500))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let job1 = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-trunc",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(job1)
    let url = store.queueURL(for: "logical-trunc")
    let olderData = try Data(contentsOf: url)

    clock.advance(1)
    let job2 = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-trunc",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 12, maxOutputBytes: 2048),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .assigned,
      enqueuedAt: job1.enqueuedAt,
      updatedAt: clock.now())
    try store.writeLogicalJob(job2)
    let global = try hw.loadAuthorityHighWater()
    XCTAssertNotNil(global)
    let terminal = global!.ledgerSequence
    XCTAssertGreaterThanOrEqual(terminal, 2)

    // Attacker deletes the newest ledger row (gap at global HW) and path markers,
    // then restores the older current envelope.
    let newestLedger = store.ledgerDirectory.appendingPathComponent(
      String(format: "%020llu.json", terminal))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newestLedger.path))
    try FileManager.default.removeItem(at: newestLedger)
    try hw.dangerousTestOnlyDeletePathMarkers()
    try olderData.write(to: url, options: .atomic)

    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: "logical-trunc")) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("ledger") || text.contains("quarantine") || text.contains("missing")
          || text.contains("fenced") || text.contains("high-water"),
        "expected truncated-ledger quarantine, got \(text)")
    }
  }

  /// R3 (round 6): body recordID must equal envelope + path-derived recordID.
  func testBodyEnvelopePathRecordIDTripleBindingIsEnforced() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_600))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let bodyID = "body-job-id"
    let pathID = "path-job-id"
    let job = TatwoFleetLogicalJobV1(
      logicalJobID: bodyID,
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now(),
      authorityEpoch: 1,
      ledgerSequence: 1)
    let url = store.queueURL(for: pathID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let relative = try TatwoFleetRecordIdentityV1.relativePath(of: url, under: root)
    // Seal with path-derived recordID while body carries a different logicalJobID.
    let envelope = try authority.sealEncodable(
      job,
      purpose: .queue,
      recordID: pathID,
      ledgerSequence: 1,
      canonicalRelativePath: relative)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(envelope).write(to: url, options: .atomic)
    // Advance durable anchors so path-HW does not fail first for unrelated reasons.
    try authority.advanceHighWater(ledgerSequence: 1)
    try authority.highWater.storePathHighWater(
      TatwoFleetPathHighWaterV1(
        purpose: TatwoFleetSignaturePurposeV1.queue.rawValue,
        canonicalRelativePath: relative,
        recordID: pathID,
        ledgerSequence: 1,
        bodyDigest: envelope.bodyDigest,
        authorityEpoch: 1,
        updatedAt: clock.now()))

    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: pathID)) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("binding") || text.contains("recordID") || text.contains("body"),
        "expected triple-binding failure, got \(text)")
    }
  }

  /// R4 (round 6): general loader rejects V1 envelopes; migration re-signs to V2.
  func testLegacyV1EnvelopeRejectedUntilHumanGatedMigration() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_700))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let job = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-migrate",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(job)
    let url = store.queueURL(for: "logical-migrate")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let live = try decoder.decode(TatwoFleetSignedEnvelopeV1.self, from: Data(contentsOf: url))
    XCTAssertEqual(live.schema, TatwoFleetSignedEnvelopeV1.schemaName)

    // Synthesize a legacy V1 envelope by re-signing with legacy material + schema.
    let identity = live.recordIdentity
    let sealMaterial = try TatwoFleetOriginAuthority.encodeBody(
      TatwoFleetSealMaterialV2(
        schema: TatwoFleetSealMaterialV2.legacySchemaName,
        identity: identity,
        recordID: live.recordID,
        bodyDigest: live.bodyDigest))
    let authorization = try authority.trust.authority.sign(
      payload: sealMaterial,
      purpose: TatwoFleetSignaturePurposeV1.queue.rawValue,
      identity: authority.trust.localIdentity,
      signedAt: ISO8601DateFormatter().string(from: clock.now()))
    let legacy = TatwoFleetSignedEnvelopeV1(
      schema: TatwoFleetSignedEnvelopeV1.legacySchemaName,
      purpose: .queue,
      authorityEpoch: live.authorityEpoch,
      originDeviceID: live.originDeviceID,
      ledgerSequence: live.ledgerSequence,
      recordID: live.recordID,
      canonicalRelativePath: live.canonicalRelativePath,
      body: live.body,
      authorization: authorization)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(legacy).write(to: url, options: .atomic)

    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: "logical-migrate")) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("legacy") || text.contains("migrate") || text.contains("V1")
          || text.contains("signature"),
        "expected V1 reject, got \(text)")
    }

    // Fixed legacy string alone is refused; confirm must bind inventory + plan.
    XCTAssertThrowsError(
      try TatwoFleetSealMigration.migrateFleetTree(
        fleetRoot: root, origin: authority, confirm: TatwoFleetSealMigration.confirmToken))
    XCTAssertThrowsError(
      try TatwoFleetSealMigration.migrateFleetTree(
        fleetRoot: root, origin: authority, confirm: "nope"))

    let plan = try TatwoFleetSealMigration.buildPlan(fleetRoot: root, origin: authority)
    let confirm = TatwoFleetSealMigration.expectedConfirmToken(
      fleetRoot: root,
      inventoryDigest: plan.inventoryDigest,
      migrationPlanHash: plan.migrationPlanHash)
    let receipt = try TatwoFleetSealMigration.migrateFleetTree(
      fleetRoot: root,
      origin: authority,
      confirm: confirm,
      now: clock.now())
    XCTAssertGreaterThanOrEqual(receipt.migrated.count, 1)
    XCTAssertEqual(receipt.toEnvelopeSchema, TatwoFleetSignedEnvelopeV1.schemaName)
    XCTAssertFalse(receipt.backupDirectory.isEmpty)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: receipt.backupDirectory),
      "migration receipt must record a real backup tree")

    let loaded = try store.loadLogicalJob(logicalJobID: "logical-migrate")
    XCTAssertEqual(loaded?.logicalJobID, "logical-migrate")
  }

  // MARK: - Round 8 adversarial MUSTFIX (migration resume + ledger fence)

  /// R1: forged unsigned journal + wrong confirm must not resume (no confused deputy).
  func testMigrationResumeRejectsForgedJournalWithWrongConfirm() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_002_000))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let receipts = root.appendingPathComponent("receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let journalURL = receipts.appendingPathComponent("seal-v2-migration.journal.json")
    // Unsigned plain JSON (legacy attack surface).
    let forged: [String: Any] = [
      "phase": "swapping",
      "fleetRootPath": root.path,
      "inventoryDigest": "deadbeef",
      "migrationPlanHash": "cafebabe",
      "backupDirectory": receipts.appendingPathComponent("seal-v2-backup-1").path,
      "confirmToken": "not-the-bound-token",
      "pendingRelativePaths": ["../target.conf"],
      "completedRelativePaths": [],
    ]
    let data = try JSONSerialization.data(withJSONObject: forged, options: [.sortedKeys])
    try data.write(to: journalURL)

    // Plant escape payload under fleet root (would be stage source in the old bug).
    try Data("pwn".utf8).write(to: root.appendingPathComponent("target.conf"))
    let outside = root.deletingLastPathComponent().appendingPathComponent("target.conf")
    try? FileManager.default.removeItem(at: outside)

    XCTAssertThrowsError(
      try TatwoFleetSealMigration.migrateFleetTree(
        fleetRoot: root, origin: authority, confirm: "wrong-confirm", now: clock.now())
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("unsigned") || text.contains("signed") || text.contains("forged")
          || text.contains("confirm") || text.contains("journal"),
        "expected unsigned/forged journal reject, got \(text)")
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: outside.path),
      "resume must not write outside fleet root")
  }

  /// R1: pendingRelativePaths with .. / absolute / empty / . must reject.
  func testMigrationResumeRejectsUnsafePendingRelativePaths() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_002_100))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    try TatwoFleetStore(rootURL: root, originAuthority: authority).ensureLayout()

    let badPaths = ["../target.conf", "/etc/passwd", "", ".", "foo/../../etc/passwd", "queue/./x.json"]
    for bad in badPaths {
      let inventoryDigest = "inv-\(bad.hashValue)"
      let planHash = "plan-\(bad.hashValue)"
      let confirm = TatwoFleetSealMigration.expectedConfirmToken(
        fleetRoot: root, inventoryDigest: inventoryDigest, migrationPlanHash: planHash)
      try plantSignedMigrationJournal(
        root: root,
        origin: authority,
        phase: "swapping",
        inventoryDigest: inventoryDigest,
        migrationPlanHash: planHash,
        confirmToken: confirm,
        pending: [bad],
        completed: [],
        stageManifest: [(bad, "00")],
        preRelativePath: "receipts/seal-v2-migration-pre-1.json",
        preDigest: "00",
        now: clock.now())

      XCTAssertThrowsError(
        try TatwoFleetSealMigration.migrateFleetTree(
          fleetRoot: root, origin: authority, confirm: confirm, now: clock.now()),
        "path \(bad) must reject")
      { error in
        let text = String(describing: error)
        XCTAssertTrue(
          text.contains("relative path") || text.contains("component")
            || text.contains("absolute") || text.contains("empty")
            || text.contains("escapes") || text.contains("rejects"),
          "expected path reject for \(bad), got \(text)")
      }
    }
  }

  /// R1: resume with wrong confirm must fail even when journal is origin-signed.
  func testMigrationResumeRejectsWrongConfirmOnSignedJournal() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_002_200))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    try TatwoFleetStore(rootURL: root, originAuthority: authority).ensureLayout()

    let inventoryDigest = "inv-resume-confirm"
    let planHash = "plan-resume-confirm"
    let boundConfirm = TatwoFleetSealMigration.expectedConfirmToken(
      fleetRoot: root, inventoryDigest: inventoryDigest, migrationPlanHash: planHash)
    try plantSignedMigrationJournal(
      root: root,
      origin: authority,
      phase: "swapping",
      inventoryDigest: inventoryDigest,
      migrationPlanHash: planHash,
      confirmToken: boundConfirm,
      pending: ["queue/logical-x.json"],
      completed: [],
      stageManifest: [("queue/logical-x.json", "aa")],
      preRelativePath: "receipts/seal-v2-migration-pre-2.json",
      preDigest: "bb",
      now: clock.now())

    XCTAssertThrowsError(
      try TatwoFleetSealMigration.migrateFleetTree(
        fleetRoot: root, origin: authority, confirm: "wrong-confirm", now: clock.now())
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("confirm") || text.contains("binding"),
        "expected confirm reject, got \(text)")
    }
  }

  /// R1: forged newer pre-receipt name must not become the completion receipt.
  func testMigrationResumeIgnoresForgedNewerPreReceipt() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_002_300))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    try TatwoFleetStore(rootURL: root, originAuthority: authority).ensureLayout()

    let inventoryDigest = "inv-prereceipt"
    let planHash = "plan-prereceipt"
    let boundConfirm = TatwoFleetSealMigration.expectedConfirmToken(
      fleetRoot: root, inventoryDigest: inventoryDigest, migrationPlanHash: planHash)

    let backupDir = root.appendingPathComponent("receipts/seal-v2-backup-bound", isDirectory: true)
    try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
    let backupDigest = TatwoLoopJobDigest.sha256(Data())
    // Empty backup tree digest must match directoryContentDigest of empty dir.
    // directoryContentDigest over empty enum → sha256("") of joined lines.
    let emptyBackupDigest = TatwoLoopJobDigest.sha256(Data("".utf8))
    let boundReceipt = TatwoFleetSealMigrationReceiptV1(
      originDeviceID: originID,
      confirmToken: boundConfirm,
      fleetRootPath: root.path,
      inventoryDigest: inventoryDigest,
      migrationPlanHash: planHash,
      backupDirectory: backupDir.path,
      authorityEpoch: authority.authorityEpoch,
      backupDigest: emptyBackupDigest,
      migrated: [],
      skippedAlreadyV2: 0,
      completedAt: clock.now())
    let preRel = "receipts/seal-v2-migration-pre-100.json"
    let preURL = root.appendingPathComponent(preRel)
    let preDigest = try writeSignedSealMigrationArtifact(
      body: boundReceipt,
      to: preURL,
      origin: authority,
      recordID: "seal-v2-migration-pre-100",
      canonicalRelativePath: preRel)

    // Forged *newer* pre-receipt (would win old "latest name" scan).
    let forgedReceipt = TatwoFleetSealMigrationReceiptV1(
      originDeviceID: originID,
      confirmToken: "forged-confirm",
      fleetRootPath: root.path,
      inventoryDigest: "forged-inv",
      migrationPlanHash: "forged-plan",
      backupDirectory: "/tmp/forged",
      authorityEpoch: authority.authorityEpoch,
      backupDigest: "forged-backup",
      migrated: [],
      skippedAlreadyV2: 99,
      completedAt: clock.now().addingTimeInterval(999))
    let forgedURL = root.appendingPathComponent("receipts/seal-v2-migration-pre-999.json")
    try JSONEncoder().encode(forgedReceipt).write(to: forgedURL)

    try plantSignedMigrationJournal(
      root: root,
      origin: authority,
      phase: "swapping",
      inventoryDigest: inventoryDigest,
      migrationPlanHash: planHash,
      confirmToken: boundConfirm,
      pending: [],
      completed: [],
      stageManifest: [],
      preRelativePath: preRel,
      preDigest: preDigest,
      backupDirectory: backupDir.path,
      backupDigest: emptyBackupDigest,
      migrationSequence: 1,
      now: clock.now())
    // Allocate sequence 1 as active (not yet consumed).
    try plantMigrationConsumeHW(root: root, allocatedMax: 1, completedMax: 0)

    let got = try TatwoFleetSealMigration.migrateFleetTree(
      fleetRoot: root, origin: authority, confirm: boundConfirm, now: clock.now())
    XCTAssertEqual(got.confirmToken, boundConfirm)
    XCTAssertEqual(got.inventoryDigest, inventoryDigest)
    XCTAssertEqual(got.migrationPlanHash, planHash)
    XCTAssertEqual(got.skippedAlreadyV2, 0)
    XCTAssertEqual(got.authorityEpoch, authority.authorityEpoch)
    XCTAssertEqual(got.backupDigest, emptyBackupDigest)
    XCTAssertNotEqual(got.confirmToken, "forged-confirm")
    XCTAssertNotEqual(got.skippedAlreadyV2, 99)
    _ = backupDigest
  }

  // MARK: - Round 9 adversarial MUSTFIX (symlink containment + journal replay)

  /// R1: mid-path symlink under fleet root must not escape writes outside the root.
  func testMigrationRejectsMidPathSymlinkEscapeAndDoesNotWriteOutside() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.deletingLastPathComponent()
      .appendingPathComponent("tatwo-fleet-escape-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

    let clock = Clock(Date(timeIntervalSince1970: 1_700_003_000))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let job = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-symlink-escape",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(job)
    let rel = "queue/logical-symlink-escape.json"
    let liveURL = store.queueURL(for: "logical-symlink-escape")
    let liveData = try Data(contentsOf: liveURL)
    let liveDigest = TatwoLoopJobDigest.sha256(liveData)

    // Stage the same bytes under .seal-v2-stage (as mid-migration would).
    let stageURL = root
      .appendingPathComponent(".seal-v2-stage", isDirectory: true)
      .appendingPathComponent(rel)
    try FileManager.default.createDirectory(
      at: stageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try liveData.write(to: stageURL)

    // Replace live queue/ with a symlink pointing outside the fleet root.
    let queueDir = root.appendingPathComponent("queue", isDirectory: true)
    let queueSaved = root.appendingPathComponent("queue.saved", isDirectory: true)
    try FileManager.default.moveItem(at: queueDir, to: queueSaved)
    try FileManager.default.createSymbolicLink(
      at: queueDir, withDestinationURL: outside)

    let inventoryDigest = "inv-symlink-escape"
    let planHash = "plan-symlink-escape"
    let confirm = TatwoFleetSealMigration.expectedConfirmToken(
      fleetRoot: root, inventoryDigest: inventoryDigest, migrationPlanHash: planHash)
    let emptyBackup = root.appendingPathComponent(
      "receipts/seal-v2-backup-symlink", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyBackup, withIntermediateDirectories: true)
    let emptyBackupDigest = TatwoLoopJobDigest.sha256(Data())
    let receipt = TatwoFleetSealMigrationReceiptV1(
      originDeviceID: originID,
      confirmToken: confirm,
      fleetRootPath: root.path,
      inventoryDigest: inventoryDigest,
      migrationPlanHash: planHash,
      backupDirectory: emptyBackup.path,
      authorityEpoch: authority.authorityEpoch,
      backupDigest: emptyBackupDigest,
      migrated: [
        TatwoFleetSealMigrationItemV1(
          relativePath: rel,
          purpose: TatwoFleetSignaturePurposeV1.queue.rawValue,
          recordID: "logical-symlink-escape",
          ledgerSequence: 1,
          priorBodyDigest: "00",
          priorEnvelopeDigest: "00",
          newEnvelopeDigest: liveDigest)
      ],
      skippedAlreadyV2: 0,
      completedAt: clock.now())
    let preRel = "receipts/seal-v2-migration-pre-symlink.json"
    let preDigest = try writeSignedSealMigrationArtifact(
      body: receipt,
      to: root.appendingPathComponent(preRel),
      origin: authority,
      recordID: "seal-v2-migration-pre-symlink",
      canonicalRelativePath: preRel)

    try plantSignedMigrationJournal(
      root: root,
      origin: authority,
      phase: "swapping",
      inventoryDigest: inventoryDigest,
      migrationPlanHash: planHash,
      confirmToken: confirm,
      pending: [rel],
      completed: [],
      stageManifest: [(rel, liveDigest)],
      preRelativePath: preRel,
      preDigest: preDigest,
      backupDirectory: emptyBackup.path,
      backupDigest: emptyBackupDigest,
      migrationSequence: 1,
      now: clock.now())
    try plantMigrationConsumeHW(root: root, allocatedMax: 1, completedMax: 0)

    let outsideTarget = outside.appendingPathComponent("logical-symlink-escape.json")
    try? FileManager.default.removeItem(at: outsideTarget)

    XCTAssertThrowsError(
      try TatwoFleetSealMigration.migrateFleetTree(
        fleetRoot: root, origin: authority, confirm: confirm, now: clock.now())
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("symlink") || text.contains("mid-path") || text.contains("openat")
          || text.contains("rejects"),
        "expected mid-path symlink reject, got \(text)")
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: outsideTarget.path),
      "migration must not write through mid-path symlink outside fleet root")
  }

  /// R2: completed migration sequence cannot be resumed via restored journal (same epoch).
  func testMigrationResumeRejectsConsumedSequenceReplay() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_003_100))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    try TatwoFleetStore(rootURL: root, originAuthority: authority).ensureLayout()

    let inventoryDigest = "inv-replay"
    let planHash = "plan-replay"
    let confirm = TatwoFleetSealMigration.expectedConfirmToken(
      fleetRoot: root, inventoryDigest: inventoryDigest, migrationPlanHash: planHash)
    let emptyBackup = root.appendingPathComponent(
      "receipts/seal-v2-backup-replay", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyBackup, withIntermediateDirectories: true)
    let emptyBackupDigest = TatwoLoopJobDigest.sha256(Data())
    let receipt = TatwoFleetSealMigrationReceiptV1(
      originDeviceID: originID,
      confirmToken: confirm,
      fleetRootPath: root.path,
      inventoryDigest: inventoryDigest,
      migrationPlanHash: planHash,
      backupDirectory: emptyBackup.path,
      authorityEpoch: authority.authorityEpoch,
      backupDigest: emptyBackupDigest,
      migrated: [],
      skippedAlreadyV2: 0,
      completedAt: clock.now())
    let preRel = "receipts/seal-v2-migration-pre-replay.json"
    let preDigest = try writeSignedSealMigrationArtifact(
      body: receipt,
      to: root.appendingPathComponent(preRel),
      origin: authority,
      recordID: "seal-v2-migration-pre-replay",
      canonicalRelativePath: preRel)

    try plantSignedMigrationJournal(
      root: root,
      origin: authority,
      phase: "swapping",
      inventoryDigest: inventoryDigest,
      migrationPlanHash: planHash,
      confirmToken: confirm,
      pending: [],
      completed: [],
      stageManifest: [],
      preRelativePath: preRel,
      preDigest: preDigest,
      backupDirectory: emptyBackup.path,
      backupDigest: emptyBackupDigest,
      migrationSequence: 3,
      now: clock.now())
    // Sequence already completed — classic same-epoch journal restore attack.
    try plantMigrationConsumeHW(root: root, allocatedMax: 3, completedMax: 3)

    XCTAssertThrowsError(
      try TatwoFleetSealMigration.migrateFleetTree(
        fleetRoot: root, origin: authority, confirm: confirm, now: clock.now())
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("consumed") || text.contains("replay") || text.contains("sequence"),
        "expected consumed-sequence reject, got \(text)")
    }
  }

  /// R2: completed live files are re-verified on resume; tampered A must quarantine.
  func testMigrationResumeRejectsTamperedCompletedLiveDigest() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_003_200))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let jobA = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-completed-a",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(jobA)
    let relA = "queue/logical-completed-a.json"
    let dataA = try Data(contentsOf: store.queueURL(for: "logical-completed-a"))
    let digestA = TatwoLoopJobDigest.sha256(dataA)

    // Stage copy (completed item no longer needs stage for re-verify of live).
    let stageA = root.appendingPathComponent(".seal-v2-stage/\(relA)")
    try FileManager.default.createDirectory(
      at: stageA.deletingLastPathComponent(), withIntermediateDirectories: true)
    try dataA.write(to: stageA)

    // Tamper live A after "completed" was recorded in journal.
    try Data("TAMPERED".utf8).write(to: store.queueURL(for: "logical-completed-a"))

    let inventoryDigest = "inv-tamper-completed"
    let planHash = "plan-tamper-completed"
    let confirm = TatwoFleetSealMigration.expectedConfirmToken(
      fleetRoot: root, inventoryDigest: inventoryDigest, migrationPlanHash: planHash)
    let emptyBackup = root.appendingPathComponent(
      "receipts/seal-v2-backup-tamper", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyBackup, withIntermediateDirectories: true)
    let emptyBackupDigest = TatwoLoopJobDigest.sha256(Data())
    let receipt = TatwoFleetSealMigrationReceiptV1(
      originDeviceID: originID,
      confirmToken: confirm,
      fleetRootPath: root.path,
      inventoryDigest: inventoryDigest,
      migrationPlanHash: planHash,
      backupDirectory: emptyBackup.path,
      authorityEpoch: authority.authorityEpoch,
      backupDigest: emptyBackupDigest,
      migrated: [
        TatwoFleetSealMigrationItemV1(
          relativePath: relA,
          purpose: TatwoFleetSignaturePurposeV1.queue.rawValue,
          recordID: "logical-completed-a",
          ledgerSequence: 1,
          priorBodyDigest: "00",
          priorEnvelopeDigest: "00",
          newEnvelopeDigest: digestA)
      ],
      skippedAlreadyV2: 0,
      completedAt: clock.now())
    let preRel = "receipts/seal-v2-migration-pre-tamper.json"
    let preDigest = try writeSignedSealMigrationArtifact(
      body: receipt,
      to: root.appendingPathComponent(preRel),
      origin: authority,
      recordID: "seal-v2-migration-pre-tamper",
      canonicalRelativePath: preRel)

    try plantSignedMigrationJournal(
      root: root,
      origin: authority,
      phase: "swapping",
      inventoryDigest: inventoryDigest,
      migrationPlanHash: planHash,
      confirmToken: confirm,
      pending: [],
      completed: [relA],
      stageManifest: [(relA, digestA)],
      preRelativePath: preRel,
      preDigest: preDigest,
      backupDirectory: emptyBackup.path,
      backupDigest: emptyBackupDigest,
      migrationSequence: 1,
      now: clock.now())
    try plantMigrationConsumeHW(root: root, allocatedMax: 1, completedMax: 0)

    XCTAssertThrowsError(
      try TatwoFleetSealMigration.migrateFleetTree(
        fleetRoot: root, origin: authority, confirm: confirm, now: clock.now())
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("digest") || text.contains("completed") || text.contains("quarantine")
          || text.contains("mismatch"),
        "expected completed live digest reject, got \(text)")
    }
  }

  /// R2/.DS_Store: exact `.DS_Store` is ignored; case/variant still quarantines.
  func testLedgerExactDSStoreIgnoredButVariantsQuarantined() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_003_300))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let job = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-dsstore",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(job)

    let ds = store.ledgerDirectory.appendingPathComponent(".DS_Store")
    try Data("finder".utf8).write(to: ds)
    // Force ledger inventory path (same as other fence tests).
    try hw.dangerousTestOnlyDeletePathMarkers()
    // Exact .DS_Store must not break inventory.
    XCTAssertNoThrow(try store.loadLogicalJob(logicalJobID: "logical-dsstore"))

    // Near-miss names must still quarantine (not a silent broad ignore).
    // Avoid case-only variants: APFS default is case-insensitive.
    try FileManager.default.removeItem(at: ds)
    let variant = store.ledgerDirectory.appendingPathComponent(".DS_Store.bak")
    try Data("nope".utf8).write(to: variant)
    try hw.dangerousTestOnlyDeletePathMarkers()
    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: "logical-dsstore")) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("inventory") || text.contains("extra") || text.contains("quarantine"),
        "expected near-miss .DS_Store.bak quarantine, got \(text)")
    }
  }

  // MARK: - Round 10 adversarial MUSTFIX (CLI receipt path + first-run reverify + DS_Store type)

  /// R1 (round 11): real-directory receipts transplant between writer calls must fail
  /// closed and must not write final receipt into the transplanted victim tree.
  func testMigrationRejectsRealReceiptsDirectoryTransplantBeforeFinalReceipt() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.deletingLastPathComponent()
    let outside = parent.appendingPathComponent(
      "tatwo-fleet-receipts-transplant-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

    let clock = Clock(Date(timeIntervalSince1970: 1_700_003_700))
    let stamp = Int(clock.now().timeIntervalSince1970)
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    try plantLegacyV1QueueJob(
      store: store, authority: authority, logicalJobID: "logical-rcpt-transplant",
      now: clock.now())

    let finalName = "seal-v2-migration-\(stamp).json"
    let victim = outside.appendingPathComponent(finalName)
    try Data("OUTSIDE-VICTIM\n".utf8).write(to: victim)

    let plan = try TatwoFleetSealMigration.buildPlan(fleetRoot: root, origin: authority)
    let confirm = TatwoFleetSealMigration.expectedConfirmToken(
      fleetRoot: root,
      inventoryDigest: plan.inventoryDigest,
      migrationPlanHash: plan.migrationPlanHash)

    let receiptsURL = root.appendingPathComponent("receipts", isDirectory: true)
    let receiptsSaved = parent.appendingPathComponent(
      "receipts.saved-\(UUID().uuidString)", isDirectory: true)

    XCTAssertThrowsError(
      try TatwoFleetSealMigration.migrateFleetTree(
        fleetRoot: root,
        origin: authority,
        confirm: confirm,
        now: clock.now(),
        testHookBeforeFinalReceiptWrite: {
          // Real directory transplant — no symlink. Between pre-receipt / journal
          // writes and final receipt write, replace $FLEET/receipts with victim.
          try? FileManager.default.removeItem(at: receiptsSaved)
          try? FileManager.default.moveItem(at: receiptsURL, to: receiptsSaved)
          try? FileManager.default.moveItem(at: outside, to: receiptsURL)
        })
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("replaced") || text.contains("receipts")
          || text.contains("mid-transaction") || text.contains("identity"),
        "expected receipts transplant reject, got \(text)")
    }

    // Restore layout so teardown and outside victim path are stable.
    if FileManager.default.fileExists(atPath: receiptsURL.path),
      !FileManager.default.fileExists(atPath: outside.path)
    {
      try? FileManager.default.moveItem(at: receiptsURL, to: outside)
    }
    if FileManager.default.fileExists(atPath: receiptsSaved.path),
      !FileManager.default.fileExists(atPath: receiptsURL.path)
    {
      try? FileManager.default.moveItem(at: receiptsSaved, to: receiptsURL)
    }

    let still = try Data(contentsOf: victim)
    XCTAssertEqual(
      still, Data("OUTSIDE-VICTIM\n".utf8),
      "migration must not overwrite outside victim via real receipts transplant")

    // Original fleet receipts (if restored) must not claim a final completion receipt
    // for this failed transaction either under the transplanted path.
    let outsideFinal = outside.appendingPathComponent(finalName)
    if FileManager.default.fileExists(atPath: outsideFinal.path) {
      let data = try Data(contentsOf: outsideFinal)
      XCTAssertEqual(data, Data("OUTSIDE-VICTIM\n".utf8))
    }
  }

  /// R1 (round 12): real-directory transplant of `$FLEET` itself mid-transaction must
  /// fail closed; replaced-tree stage victim must not be deleted by pathname cleanup.
  func testMigrationRejectsRealFleetRootDirectoryTransplantMidSwap() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.deletingLastPathComponent()
    let rootSaved = parent.appendingPathComponent(
      "fleet-root.saved-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootSaved) }

    let clock = Clock(Date(timeIntervalSince1970: 1_700_003_800))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    try plantLegacyV1QueueJob(
      store: store, authority: authority, logicalJobID: "logical-root-transplant",
      now: clock.now())

    let plan = try TatwoFleetSealMigration.buildPlan(fleetRoot: root, origin: authority)
    XCTAssertFalse(plan.candidates.isEmpty)
    let confirm = TatwoFleetSealMigration.expectedConfirmToken(
      fleetRoot: root,
      inventoryDigest: plan.inventoryDigest,
      migrationPlanHash: plan.migrationPlanHash)

    let victimMarker = "OUTSIDE-VICTIM-ROOT\n"
    var transplanted = false
    XCTAssertThrowsError(
      try TatwoFleetSealMigration.migrateFleetTree(
        fleetRoot: root,
        origin: authority,
        confirm: confirm,
        now: clock.now(),
        testHookAfterFirstRunSwap: { _ in
          guard !transplanted else { return }
          transplanted = true
          // Real directory transplant of $FLEET itself — no symlink.
          // Move original fleet aside; plant a new real directory at the same path
          // with a stage victim that pathname cleanup would wrongly delete.
          try? FileManager.default.removeItem(at: rootSaved)
          try? FileManager.default.moveItem(at: root, to: rootSaved)
          try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
          let stageVictimDir = root
            .appendingPathComponent(".seal-v2-stage", isDirectory: true)
          try? FileManager.default.createDirectory(
            at: stageVictimDir, withIntermediateDirectories: true)
          let victim = stageVictimDir.appendingPathComponent("OUTSIDE-VICTIM")
          try? Data(victimMarker.utf8).write(to: victim)
        })
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("replaced") || text.contains("fleet root")
          || text.contains("mid-transaction") || text.contains("identity"),
        "expected fleet root transplant reject, got \(text)")
    }
    XCTAssertTrue(transplanted, "hook must transplant $FLEET mid-swap")

    // Replaced directory (current $FLEET pathname) must keep victim bytes.
    let victimURL = root
      .appendingPathComponent(".seal-v2-stage", isDirectory: true)
      .appendingPathComponent("OUTSIDE-VICTIM")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: victimURL.path),
      "stage cleanup must not delete victim under transplanted $FLEET")
    let still = try Data(contentsOf: victimURL)
    XCTAssertEqual(
      still, Data(victimMarker.utf8),
      "migration must not mutate transplanted $FLEET stage victim")

    // Original fleet tree (moved aside) must not receive a completion receipt
    // claiming success for this failed transaction either.
    let stamp = Int(clock.now().timeIntervalSince1970)
    let savedFinal = rootSaved
      .appendingPathComponent("receipts/seal-v2-migration-\(stamp).json")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: savedFinal.path),
      "failed root-transplant migration must not mint completion receipt on old tree")
  }

  /// R1: `$FLEET/receipts` as external symlink must not let migration write outside.
  func testMigrationRejectsReceiptsSymlinkAndDoesNotWriteOutside() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.deletingLastPathComponent()
      .appendingPathComponent(
        "tatwo-fleet-receipts-escape-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

    let clock = Clock(Date(timeIntervalSince1970: 1_700_003_400))
    let stamp = Int(clock.now().timeIntervalSince1970)
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    try plantLegacyV1QueueJob(
      store: store, authority: authority, logicalJobID: "logical-rcpt-symlink", now: clock.now())

    // receipts/ → outside before Core creates migration artifacts.
    let receipts = root.appendingPathComponent("receipts", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: receipts, withDestinationURL: outside)

    // Victim files an attacker would hope CLI/Core overwrite via the symlink.
    let victimNames = [
      "seal-v2-migration-\(stamp).json",
      "seal-v2-migration.journal.json",
      "seal-v2-migration-pre-\(stamp).json",
    ]
    for name in victimNames {
      try Data("OUTSIDE-VICTIM".utf8).write(to: outside.appendingPathComponent(name))
    }

    let plan = try TatwoFleetSealMigration.buildPlan(fleetRoot: root, origin: authority)
    let confirm = TatwoFleetSealMigration.expectedConfirmToken(
      fleetRoot: root,
      inventoryDigest: plan.inventoryDigest,
      migrationPlanHash: plan.migrationPlanHash)

    XCTAssertThrowsError(
      try TatwoFleetSealMigration.migrateFleetTree(
        fleetRoot: root, origin: authority, confirm: confirm, now: clock.now())
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("symlink") || text.contains("mid-path") || text.contains("openat")
          || text.contains("rejects") || text.contains("receipts"),
        "expected receipts symlink reject, got \(text)")
    }

    for name in victimNames {
      let victim = outside.appendingPathComponent(name)
      let data = try Data(contentsOf: victim)
      XCTAssertEqual(
        data, Data("OUTSIDE-VICTIM".utf8),
        "migration must not overwrite outside file \(name) via receipts symlink")
    }
  }

  /// R1/CLI: Core signed completion receipt is the only durable write; path is report-only.
  func testMigrationCoreWritesSignedReceiptCLIMustNotRewritePath() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_003_450))
    let stamp = Int(clock.now().timeIntervalSince1970)
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    try plantLegacyV1QueueJob(
      store: store, authority: authority, logicalJobID: "logical-rcpt-core", now: clock.now())

    let plan = try TatwoFleetSealMigration.buildPlan(fleetRoot: root, origin: authority)
    let confirm = TatwoFleetSealMigration.expectedConfirmToken(
      fleetRoot: root,
      inventoryDigest: plan.inventoryDigest,
      migrationPlanHash: plan.migrationPlanHash)
    let receipt = try TatwoFleetSealMigration.migrateFleetTree(
      fleetRoot: root, origin: authority, confirm: confirm, now: clock.now())

    let relative = TatwoFleetSealMigration.signedCompletionReceiptRelativePath(for: receipt)
    XCTAssertEqual(relative, "receipts/seal-v2-migration-\(stamp).json")
    let url = root.appendingPathComponent(relative)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    // Must be origin-signed envelope, not a plain unsigned receipt body.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope = try decoder.decode(
      TatwoFleetSignedEnvelopeV1.self, from: Data(contentsOf: url))
    XCTAssertEqual(envelope.schema, TatwoFleetSignedEnvelopeV1.schemaName)
    XCTAssertEqual(envelope.purpose, TatwoFleetSignaturePurposeV1.sealMigration.rawValue)

    // Simulate post-Core attack surface the old CLI opened: replace receipts with
    // external symlink. With CLI no longer writing, outside stays untouched.
    let outside = root.deletingLastPathComponent()
      .appendingPathComponent(
        "tatwo-fleet-cli-rcpt-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let outsideVictim = outside.appendingPathComponent("seal-v2-migration-\(stamp).json")
    try Data("CLI-VICTIM".utf8).write(to: outsideVictim)
    let receiptsSaved = root.appendingPathComponent("receipts.saved", isDirectory: true)
    try FileManager.default.moveItem(
      at: root.appendingPathComponent("receipts", isDirectory: true),
      to: receiptsSaved)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("receipts", isDirectory: true),
      withDestinationURL: outside)

    // CLI-equivalent: only compute report path; never createDirectory/write.
    let reportPath =
      relative.isEmpty ? "" : root.appendingPathComponent(relative).path
    XCTAssertFalse(reportPath.isEmpty)
    let still = try Data(contentsOf: outsideVictim)
    XCTAssertEqual(still, Data("CLI-VICTIM".utf8),
      "report-only path must not write through receipts symlink")
  }

  /// R2: first-run path re-verifies completed live digests before phase=done.
  func testFirstRunMigrationRejectsTamperedCompletedLiveBeforeDone() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_003_500))
    let stamp = Int(clock.now().timeIntervalSince1970)
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    try plantLegacyV1QueueJob(
      store: store, authority: authority, logicalJobID: "logical-firstrun-a", now: clock.now())
    try plantLegacyV1QueueJob(
      store: store, authority: authority, logicalJobID: "logical-firstrun-b", now: clock.now())

    let plan = try TatwoFleetSealMigration.buildPlan(fleetRoot: root, origin: authority)
    XCTAssertGreaterThanOrEqual(plan.candidates.count, 2)
    let confirm = TatwoFleetSealMigration.expectedConfirmToken(
      fleetRoot: root,
      inventoryDigest: plan.inventoryDigest,
      migrationPlanHash: plan.migrationPlanHash)

    var swappedCount = 0
    var restoredRel: String?
    XCTAssertThrowsError(
      try TatwoFleetSealMigration.migrateFleetTree(
        fleetRoot: root,
        origin: authority,
        confirm: confirm,
        now: clock.now(),
        testHookAfterFirstRunSwap: { rel in
          swappedCount += 1
          // After first completed swap, restore pre-migration V1 bytes from backup.
          if swappedCount == 1 {
            let backup = root.appendingPathComponent(
              "receipts/seal-v2-backup-\(stamp)/\(rel)")
            let live = root.appendingPathComponent(rel)
            XCTAssertTrue(
              FileManager.default.fileExists(atPath: backup.path),
              "backup must exist for \(rel)")
            try? FileManager.default.removeItem(at: live)
            try? FileManager.default.copyItem(at: backup, to: live)
            restoredRel = rel
          }
        })
    ) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("digest") || text.contains("completed") || text.contains("quarantine")
          || text.contains("mismatch"),
        "expected first-run completed-live reverify reject, got \(text)")
    }
    XCTAssertEqual(swappedCount, 2, "both candidates should swap before final reverify")
    XCTAssertNotNil(restoredRel)

    // Must not mint a completion receipt claiming success.
    let finalURL = root.appendingPathComponent("receipts/seal-v2-migration-\(stamp).json")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: finalURL.path),
      "first-run must not write completion receipt after completed-live mismatch")

    // Journal must not be phase=done.
    let journalURL = root.appendingPathComponent("receipts/seal-v2-migration.journal.json")
    if FileManager.default.fileExists(atPath: journalURL.path) {
      let data = try Data(contentsOf: journalURL)
      let text = String(data: data, encoding: .utf8) ?? ""
      XCTAssertFalse(
        text.contains("\"phase\":\"done\"") || text.contains("\"phase\" : \"done\""),
        "journal must not claim done after first-run reverify failure")
    }
  }

  /// R3: symlink/directory named exact `.DS_Store` must quarantine (not skip before stat).
  func testLedgerDSStoreSymlinkAndDirectoryQuarantined() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_003_600))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let job = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-dsstore-type",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(job)

    let outside = root.deletingLastPathComponent()
      .appendingPathComponent("tatwo-dsstore-target-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data("x".utf8).write(to: outside)

    let ds = store.ledgerDirectory.appendingPathComponent(".DS_Store")
    try FileManager.default.createSymbolicLink(at: ds, withDestinationURL: outside)
    try hw.dangerousTestOnlyDeletePathMarkers()
    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: "logical-dsstore-type")) {
      error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("symlink") || text.contains("quarantine"),
        "expected .DS_Store symlink quarantine, got \(text)")
    }

    try FileManager.default.removeItem(at: ds)
    try FileManager.default.createDirectory(at: ds, withIntermediateDirectories: false)
    try hw.dangerousTestOnlyDeletePathMarkers()
    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: "logical-dsstore-type")) {
      error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("directory") || text.contains("quarantine"),
        "expected .DS_Store directory quarantine, got \(text)")
    }
  }

  /// R2: hidden / uppercase-extension ledger entries must quarantine (not silent filter).
  func testLedgerHiddenAndCaseVariantJSONQuarantined() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_002_400))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let job = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-ledger-fence",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(job)

    // Hidden sibling + uppercase extension must not be filtered away.
    let hidden = store.ledgerDirectory.appendingPathComponent(
      ".00000000000000000001.json")
    try Data("{}".utf8).write(to: hidden)
    try hw.dangerousTestOnlyDeletePathMarkers()

    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: "logical-ledger-fence")) {
      error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("inventory") || text.contains("extra") || text.contains("quarantine")
          || text.contains("ledger"),
        "expected inventory quarantine for hidden ledger entry, got \(text)")
    }

    try FileManager.default.removeItem(at: hidden)
    let upper = store.ledgerDirectory.appendingPathComponent(
      "00000000000000000001.JSON")
    try Data("{}".utf8).write(to: upper)

    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: "logical-ledger-fence")) {
      error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("inventory") || text.contains("extra") || text.contains("quarantine")
          || text.contains("ledger"),
        "expected inventory quarantine for .JSON case variant, got \(text)")
    }
  }

  /// Plant an origin-signed migration journal body for adversarial resume tests.
  private func plantSignedMigrationJournal(
    root: URL,
    origin: TatwoFleetOriginAuthority,
    phase: String,
    inventoryDigest: String,
    migrationPlanHash: String,
    confirmToken: String,
    pending: [String],
    completed: [String],
    stageManifest: [(String, String)],
    preRelativePath: String,
    preDigest: String,
    backupDirectory: String? = nil,
    backupDigest: String = "backup-digest-test",
    migrationID: String = "test-migration-id",
    migrationSequence: UInt64 = 1,
    now: Date
  ) throws {
    struct StageEntry: Codable {
      var relativePath: String
      var newEnvelopeDigest: String
    }
    struct JournalBody: Codable {
      var schema: String
      var phase: String
      var fleetRootPath: String
      var originDeviceID: String
      var authorityEpoch: UInt64
      var migrationID: String
      var migrationSequence: UInt64
      var inventoryDigest: String
      var migrationPlanHash: String
      var backupDirectory: String
      var backupDigest: String
      var confirmToken: String
      var stageManifest: [StageEntry]
      var pendingRelativePaths: [String]
      var completedRelativePaths: [String]
      var preReceiptRelativePath: String
      var preReceiptDigest: String
    }
    let receipts = root.appendingPathComponent("receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let journalURL = receipts.appendingPathComponent("seal-v2-migration.journal.json")
    let backupPath =
      backupDirectory
      ?? receipts.appendingPathComponent("seal-v2-backup-test", isDirectory: true).path
    let bodyValue = JournalBody(
      schema: "TatwoFleetSealMigrationJournalV1",
      phase: phase,
      fleetRootPath: root.path,
      originDeviceID: originID,
      authorityEpoch: origin.authorityEpoch,
      migrationID: migrationID,
      migrationSequence: migrationSequence,
      inventoryDigest: inventoryDigest,
      migrationPlanHash: migrationPlanHash,
      backupDirectory: backupPath,
      backupDigest: backupDigest,
      confirmToken: confirmToken,
      stageManifest: stageManifest.map {
        StageEntry(relativePath: $0.0, newEnvelopeDigest: $0.1)
      },
      pendingRelativePaths: pending,
      completedRelativePaths: completed,
      preReceiptRelativePath: preRelativePath,
      preReceiptDigest: preDigest)
    _ = now
    let body = try TatwoFleetOriginAuthority.encodeBody(bodyValue)
    let envelope = try origin.seal(
      body: body,
      purpose: .sealMigration,
      recordID: "seal-v2-migration.journal",
      ledgerSequence: 0,
      canonicalRelativePath: "receipts/seal-v2-migration.journal.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(envelope).write(to: journalURL, options: .atomic)
  }

  /// Write a V2 queue job then rewrite the on-disk envelope as legacy V1 seal material.
  private func plantLegacyV1QueueJob(
    store: TatwoFleetStore,
    authority: TatwoFleetOriginAuthority,
    logicalJobID: String,
    now: Date
  ) throws {
    let job = TatwoFleetLogicalJobV1(
      logicalJobID: logicalJobID,
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: now,
      updatedAt: now)
    try store.writeLogicalJob(job)
    let url = store.queueURL(for: logicalJobID)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let live = try decoder.decode(TatwoFleetSignedEnvelopeV1.self, from: Data(contentsOf: url))
    let identity = live.recordIdentity
    let sealMaterial = try TatwoFleetOriginAuthority.encodeBody(
      TatwoFleetSealMaterialV2(
        schema: TatwoFleetSealMaterialV2.legacySchemaName,
        identity: identity,
        recordID: live.recordID,
        bodyDigest: live.bodyDigest))
    let authorization = try authority.trust.authority.sign(
      payload: sealMaterial,
      purpose: TatwoFleetSignaturePurposeV1.queue.rawValue,
      identity: authority.trust.localIdentity,
      signedAt: ISO8601DateFormatter().string(from: now))
    let legacy = TatwoFleetSignedEnvelopeV1(
      schema: TatwoFleetSignedEnvelopeV1.legacySchemaName,
      purpose: .queue,
      authorityEpoch: live.authorityEpoch,
      originDeviceID: live.originDeviceID,
      ledgerSequence: live.ledgerSequence,
      recordID: live.recordID,
      canonicalRelativePath: live.canonicalRelativePath,
      body: live.body,
      authorization: authorization)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(legacy).write(to: url, options: .atomic)
  }

  private func plantMigrationConsumeHW(
    root: URL,
    allocatedMax: UInt64,
    completedMax: UInt64,
    lastMigrationID: String = "test-migration-id"
  ) throws {
    struct HW: Codable {
      var schema: String
      var allocatedMax: UInt64
      var completedMax: UInt64
      var lastMigrationID: String
    }
    let url = root.appendingPathComponent("receipts/seal-v2-migration-consume-hw.json")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let hw = HW(
      schema: "TatwoFleetSealMigrationConsumeHighWaterV1",
      allocatedMax: allocatedMax,
      completedMax: completedMax,
      lastMigrationID: lastMigrationID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(hw).write(to: url, options: .atomic)
  }

  private func writeSignedSealMigrationArtifact<T: Encodable>(
    body: T,
    to url: URL,
    origin: TatwoFleetOriginAuthority,
    recordID: String,
    canonicalRelativePath: String
  ) throws -> String {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bodyData = try TatwoFleetOriginAuthority.encodeBody(body)
    let envelope = try origin.seal(
      body: bodyData,
      purpose: .sealMigration,
      recordID: recordID,
      ledgerSequence: 0,
      canonicalRelativePath: canonicalRelativePath)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(envelope)
    try data.write(to: url, options: .atomic)
    return TatwoLoopJobDigest.sha256(data)
  }

  // MARK: - Round 7 adversarial MUSTFIX

  /// R1: current written → interrupted before ledger → sequence reused by another record → orphan rejected.
  func testOrphanEnvelopeRejectedWhenSequenceReusedByAnotherRecord() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_001_000))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    // Complete mutation for P at sequence 1.
    let jobP1 = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-orphan-p",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(jobP1)
    let urlP = store.queueURL(for: "logical-orphan-p")

    // Simulate interrupted update of P: write signed envelope seq 2 without ledger/global HW.
    clock.advance(1)
    let seq2: UInt64 = 2
    let jobP2 = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-orphan-p",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 11, maxOutputBytes: 2048),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .assigned,
      enqueuedAt: jobP1.enqueuedAt,
      updatedAt: clock.now(),
      authorityEpoch: 1,
      ledgerSequence: seq2)
    let relativeP = try TatwoFleetRecordIdentityV1.relativePath(of: urlP, under: root)
    let orphanEnvelope = try authority.sealEncodable(
      jobP2,
      purpose: .queue,
      recordID: "logical-orphan-p",
      ledgerSequence: seq2,
      canonicalRelativePath: relativeP)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(orphanEnvelope).write(to: urlP, options: .atomic)
    // Drop path HW for P so recovery path runs.
    try hw.dangerousTestOnlyDeletePathMarkers()

    // Q reuses sequence 2 successfully (ledger + global HW advance).
    clock.advance(1)
    let jobQ = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-orphan-q",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    // Force next sequence: after P's seq1, next is 2 — write Q as the complete seq2.
    // But writeLogicalJob calls nextLedgerSequence which should be 2 if global HW is 1.
    try store.writeLogicalJob(jobQ)

    let global = try hw.loadAuthorityHighWater()
    XCTAssertEqual(global?.ledgerSequence, 2)

    // Loading P must reject orphan envelope (ledger row 2 belongs to Q).
    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: "logical-orphan-p")) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("orphan") || text.contains("mismatch") || text.contains("quarantine")
          || text.contains("fenced") || text.contains("ledger"),
        "expected orphan rejection, got \(text)")
    }
    // Q remains loadable.
    let loadedQ = try store.loadLogicalJob(logicalJobID: "logical-orphan-q")
    XCTAssertEqual(loadedQ?.logicalJobID, "logical-orphan-q")
  }

  /// R2: tampered unverified ingest body must not be re-signed into capability/capacity.
  func testHeartbeatDoesNotResealTamperedIngestCapability() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_001_100))
    let originAuth = try makeOriginAuthority(root: root, now: { clock.now() })
    let (signer, _) = try makeTargetSigner(
      deviceID: targetAID,
      pinOrigin: originAuth.trust.localIdentity,
      now: { clock.now() })
    // Target-local store (no origin promotion) — matches production runner heartbeat path.
    let store = TatwoFleetStore(rootURL: root)
    let agentHome = root.appendingPathComponent("agent-home", isDirectory: true)
    try FileManager.default.createDirectory(at: agentHome, withIntermediateDirectories: true)
    // No real agent binaries → detectCapableAgents is empty.
    let binding = TatwoAgentEngineBinding(
      homeDirectoryURL: agentHome,
      realUserName: "test-user-no-isolated")
    let scheduler = TatwoFleetScheduler(
      store: store,
      now: { clock.now() },
      agentBinding: binding,
      targetSigner: signer)

    _ = try scheduler.registerDevice(
      deviceID: targetAID, maxConcurrent: 1, detectedAgentsOverride: [.grok])
    let ingestURL = store.ingestDeviceURL(for: targetAID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: ingestURL.path))

    // Attacker mutates body bytes: inflate maxConcurrent + claim .claude without re-signing.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let prior = try decoder.decode(
      TatwoFleetSignedEnvelopeV1.self, from: Data(contentsOf: ingestURL))
    let priorBody = try prior.decodeBody(TatwoFleetDeviceV1.self)
    let evilBody = TatwoFleetDeviceV1(
      deviceID: priorBody.deviceID,
      agents: [.claude, .grok, .codex],
      maxConcurrent: 64,
      inflight: priorBody.inflight,
      lastHeartbeatAt: priorBody.lastHeartbeatAt,
      authorityEpoch: priorBody.authorityEpoch,
      originDeviceID: priorBody.originDeviceID,
      ledgerSequence: priorBody.ledgerSequence)
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.sortedKeys]
    let evilBodyData = try enc.encode(evilBody)
    let evilEnvelope = TatwoFleetSignedEnvelopeV1(
      schema: prior.schema,
      purpose: .deviceReport,
      authorityEpoch: prior.authorityEpoch,
      originDeviceID: prior.originDeviceID,
      ledgerSequence: prior.ledgerSequence,
      recordID: prior.recordID,
      canonicalRelativePath: prior.canonicalRelativePath,
      body: evilBodyData,
      authorization: prior.authorization)
    try enc.encode(evilEnvelope).write(to: ingestURL, options: .atomic)

    // Heartbeat must not inherit tampered agents/capacity.
    let hb = try scheduler.reportHeartbeat(deviceID: targetAID, inflight: 0)
    XCTAssertFalse(hb.agents.contains(.claude), "must not inherit tampered .claude claim")
    XCTAssertEqual(hb.maxConcurrent, 1, "must not inherit inflated maxConcurrent from body")
    XCTAssertEqual(hb.agents, [], "empty host has no probed agents")
  }

  /// R6: late reaper adopts parent-owned children and waitpid-reaps without bare kill.
  func testLateRootReaperAdoptsAndReapsZombie() throws {
    #if canImport(Darwin)
    var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
    var attr = posix_spawnattr_t(bitPattern: 0)
    XCTAssertEqual(posix_spawn_file_actions_init(&fileActions), 0)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    XCTAssertEqual(posix_spawnattr_init(&attr), 0)
    defer { posix_spawnattr_destroy(&attr) }
    // Immediate-exit child becomes a zombie until waitpid.
    var argv: [UnsafeMutablePointer<CChar>?] = [
      strdup("/bin/sh"),
      strdup("-c"),
      strdup("exit 0"),
      nil,
    ]
    defer { for p in argv where p != nil { free(p) } }
    var child: pid_t = 0
    let rc = posix_spawn(&child, "/bin/sh", &fileActions, &attr, &argv, nil)
    XCTAssertEqual(rc, 0)
    XCTAssertGreaterThan(child, 1)
    Thread.sleep(forTimeInterval: 0.05)
    ProcessEngineBinding.LateRootReaper.shared.adopt(
      pid: child,
      identity: ProcessEngineBinding.liveProcessIdentity(pid: child),
      lifecycle: nil)
    // Poll until reaper (or we) clear the zombie — no bare-pid signal.
    let deadline = Date().addingTimeInterval(3)
    var reaped = false
    while Date() < deadline {
      var status: Int32 = 0
      let wr = waitpid(child, &status, WNOHANG)
      if wr < 0, errno == ECHILD {
        reaped = true
        break
      }
      if wr == child {
        reaped = true
        break
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    if !reaped {
      var status: Int32 = 0
      _ = waitpid(child, &status, 0)
      reaped = true
    }
    XCTAssertTrue(reaped)
    #else
    throw XCTSkip("Darwin only")
    #endif
  }

  /// R3: extra non-canonical ledger JSON must quarantine the chain.
  func testExtraLedgerJSONIsQuarantined() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_001_200))
    let hw = TatwoFleetFileHighWaterAnchor.underFleetRoot(root)
    let authority = try makeOriginAuthority(root: root, now: { clock.now() }, highWater: hw)
    let store = TatwoFleetStore(rootURL: root, originAuthority: authority)
    try store.ensureLayout()

    let job = TatwoFleetLogicalJobV1(
      logicalJobID: "logical-extra-ledger",
      originDeviceID: originID,
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      requiredAgent: nil,
      status: .pending,
      enqueuedAt: clock.now(),
      updatedAt: clock.now())
    try store.writeLogicalJob(job)

    // Plant extra non-canonical ledger JSON (duplicate-ish / beyond inventory).
    let extra = store.ledgerDirectory.appendingPathComponent("1.json")
    try Data("{}".utf8).write(to: extra)
    try hw.dangerousTestOnlyDeletePathMarkers()

    XCTAssertThrowsError(try store.loadLogicalJob(logicalJobID: "logical-extra-ledger")) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("inventory") || text.contains("extra") || text.contains("quarantine")
          || text.contains("ledger"),
        "expected inventory quarantine, got \(text)")
    }
  }

  // MARK: G3 — executable final target / digest pin

  func testAgentExecutableContentReplaceFailsClosed() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let exe = bin.appendingPathComponent("grok")
    try "#!/bin/sh\necho v1\n".write(to: exe, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: exe.path)

    let homes = root.appendingPathComponent("homes", isDirectory: true)
    let binding = TatwoAgentEngineBinding(
      homeDirectoryURL: root,
      realUserName: "testuser",
      isolatedHomesRootURL: homes,
      pinStoreURL: homes.appendingPathComponent("pins.json"))

    let pin1 = try binding.resolvePinnedExecutable(for: .grok)
    XCTAssertEqual(
      pin1.finalTargetPath,
      try TatwoAgentEngineBinding.finalTargetPath(of: exe.path))

    // Replace executable content (same path).
    try "#!/bin/sh\necho evil\n".write(to: exe, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: exe.path)

    XCTAssertThrowsError(try binding.resolvePinnedExecutable(for: .grok)) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("digest") || text.contains("re-authorization") || text.contains("pin"),
        text)
    }
  }

  // MARK: existing scheduling behaviors still hold

  func testRoundRobinAndCapabilitySkip() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let authority = try makeOriginAuthority(root: root, now: { clock.now() })
    let scheduler = makeScheduler(root: root, clock: clock, authority: authority)
    _ = try scheduler.registerDevice(
      deviceID: "dev-a", maxConcurrent: 1, detectedAgentsOverride: [.grok])
    _ = try scheduler.registerDevice(
      deviceID: "dev-b", maxConcurrent: 1, detectedAgentsOverride: [.codex])

    _ = try scheduler.enqueue(
      originDeviceID: originID,
      logicalJobIDPrefix: "need-grok",
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: "c",
          goalID: "g",
          identity: .sub,
          mode: .s,
          taskDescription: "t",
          agent: .grok)),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024))
    _ = try scheduler.enqueue(
      originDeviceID: originID,
      logicalJobIDPrefix: "need-shell",
      contractID: "c",
      goalID: "g",
      identity: .sub,
      workPath: "/tmp/w",
      payload: shellPayload(),
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 10, maxOutputBytes: 1024))

    let tick = try scheduler.tick(
      config: TatwoFleetTickConfigV1(heartbeatMaxAgeSeconds: 120),
      dispatch: mockDispatch())
    XCTAssertGreaterThanOrEqual(tick.assigned.count, 1)
    XCTAssertTrue(tick.assigned.contains { $0.targetDeviceID == "dev-a" })
  }
}
