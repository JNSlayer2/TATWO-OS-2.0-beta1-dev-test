import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class RemoteLoopJobTests: XCTestCase {
  private let contractID = "contract-xl-coding-f51cfabe38f8"
  private let goalID = "goal-xl-coding-f51cfabe38f8"
  private let originDeviceID = "origin-sandbox"
  private let targetDeviceID = "runner-sandbox"
  /// File high-water anchors; production path uses Keychain.
  private let testEnv = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]

  private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-remote-loop-tests-\(UUID().uuidString)",
      isDirectory: true)
  }

  private func makeChannel(
    rootURL: URL,
    trust: TatwoLoopJobChannelTrust,
    globalAntiRollbackAnchor: (any TatwoLoopGlobalAntiRollbackAnchor)? = nil
  ) -> TatwoLoopJobChannel {
    TatwoLoopJobChannel(
      rootURL: rootURL,
      trust: trust,
      environment: testEnv,
      globalAntiRollbackAnchor: globalAntiRollbackAnchor)
  }

  private func makeTrustPair(root: URL) throws -> (
    origin: TatwoLoopJobChannelTrust,
    runner: TatwoLoopJobChannelTrust,
    appIssuer: TatwoLoopJobChannelTrust
  ) {
    let originStore = MemoryDevicePrivateKeyStore()
    let runnerStore = MemoryDevicePrivateKeyStore()
    let appIssuerStore = MemoryDevicePrivateKeyStore()
    var origin = try TatwoLoopJobChannelTrust.enroll(
      deviceID: originDeviceID,
      privateKeyStore: originStore,
      environment: testEnv)
    var runner = try TatwoLoopJobChannelTrust.enroll(
      deviceID: targetDeviceID,
      privateKeyStore: runnerStore,
      environment: testEnv)
    var appIssuer = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "app-pressure-issuer",
      privateKeyStore: appIssuerStore,
      environment: testEnv)
    origin = try origin.withPin(runner.localIdentity)
    origin = try origin.withPin(appIssuer.localIdentity)
    runner = try runner.withPin(origin.localIdentity)
    runner = try runner.withPin(appIssuer.localIdentity)
    appIssuer = try appIssuer.withPin(origin.localIdentity)
    appIssuer = try appIssuer.withPin(runner.localIdentity)
    _ = root
    return (origin, runner, appIssuer)
  }

  private func makeJob(
    jobID: String = "job-success",
    logicalJobID: String? = nil,
    payload: TatwoLoopJobPayloadV1,
    workPath: URL,
    maxDurationSec: TimeInterval = 2,
    maxOutputBytes: Int = 256,
    originDeviceID: String? = nil,
    targetDeviceID: String? = nil,
    dispatchNonce: String? = nil
  ) -> TatwoLoopJobV1 {
    TatwoLoopJobV1(
      jobID: jobID,
      logicalJobID: logicalJobID ?? "logical-\(jobID)",
      dispatchNonce: dispatchNonce ?? "nonce-\(jobID)",
      contractID: contractID,
      goalID: goalID,
      identity: .sub,
      originDeviceID: originDeviceID ?? self.originDeviceID,
      targetDeviceID: targetDeviceID ?? self.targetDeviceID,
      payload: payload,
      workPath: workPath.path,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: maxDurationSec,
        maxOutputBytes: maxOutputBytes),
      stopConditions: TatwoLoopStopConditionsV1(
        cancelFileSignal: true,
        rules: ["cancel-file"]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  /// Deterministic gate for non-memory tests (disabled via threshold 0).
  private func allowGate(journal: URL? = nil) -> MemoryPressureGate {
    MemoryPressureGate(
      minFreePercent: 0,
      freePercentProvider: { 100 },
      journalDirectoryURL: journal)
  }

  private func pressurePermitRawBodyJSON(
    from permitData: Data,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> String {
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: permitData) as? [String: Any],
      file: file,
      line: line)
    let body = try XCTUnwrap(
      object["body"] as? [String: Any],
      file: file,
      line: line)
    let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return String(data: bodyData, encoding: .utf8) ?? ""
  }

  @discardableResult
  private func assertPressurePermitRawBodyUsesCanonicalDateStrings(
    _ permitData: Data,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> String {
    let bodyJSON = try pressurePermitRawBodyJSON(from: permitData, file: file, line: line)
    XCTAssertTrue(bodyJSON.contains("\"issuedAt\":\""), bodyJSON, file: file, line: line)
    XCTAssertNil(
      bodyJSON.range(of: #""\d{4}-\d{2}-\d{2}T"#, options: .regularExpression),
      bodyJSON,
      file: file,
      line: line)
    return bodyJSON
  }

  func testAtomicFileFailureBeforeFileSyncPreservesPriorRevisionAndCleansTemporaryFile() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("state.json")
    try Data("old".utf8).write(to: destination)
    let fault = TatwoAtomicFileFaultBox(failAt: .beforeFileSync)

    XCTAssertThrowsError(
      try TatwoAtomicFile.write(
        Data("new".utf8),
        to: destination,
        faultBox: fault))

    XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: root.path)
        .contains { $0.hasSuffix(".tmp") })
  }

  func testAtomicFileFailureAfterRenameReportsAmbiguousOutcomeButReopenReadsNewRevision() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("state.json")
    try Data("old".utf8).write(to: destination)
    let fault = TatwoAtomicFileFaultBox(failAt: .beforeDirectorySync)

    XCTAssertThrowsError(
      try TatwoAtomicFile.write(
        Data("new".utf8),
        to: destination,
        faultBox: fault))

    XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: root.path)
        .contains { $0.hasSuffix(".tmp") })
  }

  func testCreateOnlyDuplicateNeverObservesPartiallyPublishedBytes() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("claim.json")
    let committed = Data(repeating: 0x5a, count: 2 * 1_024 * 1_024)
    let fault = TatwoAtomicFileFaultBox(failAt: .beforeDirectorySync)

    XCTAssertThrowsError(
      try TatwoCreateOnlyFile.write(
        committed,
        to: destination,
        onDuplicate: {
          XCTFail("first publication cannot be a duplicate")
        },
        faultBox: fault))

    var duplicateBytes: Data?
    try TatwoCreateOnlyFile.write(
      Data("late-overwrite".utf8),
      to: destination,
      onDuplicate: {
        duplicateBytes = try Data(contentsOf: destination)
      })

    XCTAssertEqual(duplicateBytes, committed)
    XCTAssertEqual(try Data(contentsOf: destination), committed)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: root.path)
        .contains { $0.hasSuffix(".tmp") })
  }

  private func makeRunner(
    channel: TatwoLoopJobChannel,
    environment: [String: String] = [:],
    sandboxRootURL: URL? = nil,
    engine: any TatwoLoopEngineBinding = ProcessEngineBinding.sandboxProbe,
    localRegistry: TatwoDispatchRegistry? = nil,
    pressureAdmissionController: TatwoRunnerPressureAdmissionControllerV1? = nil
  ) throws -> TatwoLoopRunnerV1 {
    // Tests must never fall through to the production Application Support
    // registry. Callers that need to inspect projection state can still inject
    // their own registry; every other runner gets an isolated temporary root.
    let resolvedLocalRegistry = localRegistry ?? TatwoDispatchRegistry(
      directoryURL: makeRoot().appendingPathComponent("runner-state", isDirectory: true))
    return try TatwoLoopRunnerV1(
      channel: channel,
      deviceID: targetDeviceID,
      pollIntervalSec: 0.01,
      environment: environment,
      sandboxRootURL: sandboxRootURL,
      engine: engine,
      localRegistry: resolvedLocalRegistry,
      memoryGate: allowGate(),
      pressureAdmissionController: pressureAdmissionController)
  }

  private func makePressureAdmissionController(
    root: URL,
    job: TatwoLoopJobV1,
    issuerTrust: TatwoLoopJobChannelTrust,
    verifierTrust: TatwoLoopJobChannelTrust,
    issuedAt: Date = Date(timeIntervalSince1970: 1_700_000_100),
    now: Date = Date(timeIntervalSince1970: 1_700_000_105)
  ) throws -> TatwoRunnerPressureAdmissionControllerV1 {
    try makePressureAdmissionController(
      root: root,
      trust: verifierTrust,
      permit: makePressurePermit(job: job, trust: issuerTrust, issuedAt: issuedAt),
      now: now)
  }

  private func makePressureAdmissionController(
    root: URL,
    trust: TatwoLoopJobChannelTrust,
    permit: TatwoRunnerPressureAdmissionPermitV1,
    now: Date = Date(timeIntervalSince1970: 1_700_000_105)
  ) -> TatwoRunnerPressureAdmissionControllerV1 {
    TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { job in
        job.jobID == permit.body.jobID ? permit : nil
      },
      ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1(
        directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true)),
      trust: trust,
      clock: TatwoPressureClockV1(now: { now }),
      environment: testEnv)
  }

  private func makePressureIssuerIdentity(
    runtimeInstanceID: String,
    runtimeGeneration: UInt64,
    issuerDeviceID: String = "app-pressure-issuer",
    suffix: String = "test"
  ) throws -> TatwoAppPressureIssuerIdentityV1 {
    try TatwoAppPressureIssuerIdentityV1(
      issuerID: "tatwo-app",
      issuerDeviceID: issuerDeviceID,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      appLaunchID: "launch-\(suffix)",
      processID: 42,
      processStartToken: "pid-start-\(suffix)",
      executableSHA256: String(repeating: "a", count: 64),
      buildVersion: "0.1.test",
      buildNumber: "1")
  }

  private func makePressurePermit(
    job: TatwoLoopJobV1,
    trust: TatwoLoopJobChannelTrust,
    issuedAt: Date = Date(timeIntervalSince1970: 1_700_000_100),
    runtimeInstanceID: String? = nil,
    runtimeGeneration: UInt64 = 1,
    issuerIdentity: TatwoAppPressureIssuerIdentityV1? = nil,
    sourceSnapshotSequence: UInt64 = 1,
    sourceSampleAttemptID: String? = nil
  ) throws -> TatwoRunnerPressureAdmissionPermitV1 {
    let runtimeInstanceID = runtimeInstanceID ?? "runtime-\(job.targetDeviceID)"
    let issuerIdentity = try issuerIdentity ?? makePressureIssuerIdentity(
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      issuerDeviceID: trust.localIdentity.deviceID,
      suffix: job.jobID)
    let request = TatwoLoopAdmissionRequestV1(
      jobID: job.jobID,
      attemptID: "attempt-\(job.jobID)",
      dispatchNonce: job.dispatchNonce,
      deviceID: job.targetDeviceID,
      loopID: job.logicalJobID,
      workload: TatwoRunnerPressureAdmissionPermitV1.defaultWorkload(for: job),
      contractID: job.contractID,
      goalHash: TatwoLoopJobDigest.sha256(Data(job.goalID.utf8)),
      planHash: TatwoLoopJobDigest.sha256(Data("plan-\(job.contractID)".utf8)),
      requestedAt: issuedAt)
    return try TatwoRunnerPressureAdmissionPermitV1.issue(
      job: job,
      request: request,
      snapshot: TatwoDevicePressureSnapshotV1(
        deviceID: job.targetDeviceID,
        observedAt: issuedAt,
        sourceSnapshotSequence: sourceSnapshotSequence,
        sourceSampleAttemptID: sourceSampleAttemptID ?? "sample-\(job.jobID)-\(sourceSnapshotSequence)",
        memoryFreePercent: 60,
        swapFreeMiB: 2_048,
        dataVolumeFreeGiB: 100,
        load1PerCPU: 0.2,
        thermalWarning: false,
        uiLatencyMilliseconds: 20,
        swapGrowthMiBPerMinute: 0),
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      reservationID: TatwoLoopJobDigest.sha256(Data("reservation-\(job.jobID)".utf8)),
      issuerIdentity: issuerIdentity,
      trust: trust,
      signedAt: issuedAt)
  }

  private func productionIssuerEnvironment(
    for permit: TatwoRunnerPressureAdmissionPermitV1,
    current: String = "1"
  ) -> [String: String] {
    var environment = testEnv
    environment[TatwoRunnerPressureAdmissionControllerV1.expectedIssuerIdentityDigestEnvKey] =
      permit.body.issuerIdentity.identityDigest
    environment[TatwoAppPressureIssuerLivenessV1.currentEnvKey] = current
    environment[TatwoAppPressureIssuerLivenessV1.runtimeInstanceIDEnvKey] =
      permit.body.issuerIdentity.runtimeInstanceID
    environment[TatwoAppPressureIssuerLivenessV1.runtimeGenerationEnvKey] =
      "\(permit.body.issuerIdentity.runtimeGeneration)"
    environment[TatwoAppPressureIssuerLivenessV1.appLaunchIDEnvKey] =
      permit.body.issuerIdentity.appLaunchID
    return environment
  }

  private func makeGreenReadings() -> TatwoDevicePressureSensorReadingsV1 {
    TatwoDevicePressureSensorReadingsV1(
      memoryFreePercent: 60,
      swapFreeMiB: 2_048,
      dataVolumeFreeGiB: 100,
      load1PerCPU: 0.2,
      thermalWarning: false,
      uiLatencyMilliseconds: 20,
      swapGrowthMiBPerMinute: 0)
  }

  private func makePressureRuntime(
    deviceID: String,
    runtimeInstanceID: String,
    clock: TatwoPressureClockV1,
    readings: TatwoDevicePressureSensorReadingsV1? = nil
  ) -> TatwoAppPressureRuntimeV1 {
    let resolvedReadings = readings ?? makeGreenReadings()
    let sampler = TatwoAppPressureSamplerV1(
      deviceID: deviceID,
      provider: TatwoDevicePressureSensorProviderV1 { _ in
        resolvedReadings
      },
      clock: clock)
    let service = TatwoAppPressureServiceV1(
      sampler: sampler,
      clock: clock)
    return TatwoAppPressureRuntimeV1(
      sampler: sampler,
      service: service,
      clock: clock,
      runtimeInstanceID: runtimeInstanceID)
  }

  private func makePressureIssuerProcessIdentity(
    suffix: String
  ) -> TatwoAppPressureIssuerProcessIdentityV1 {
    TatwoAppPressureIssuerProcessIdentityV1(
      processID: 42,
      processStartToken: "process-start-\(suffix)",
      executableSHA256: String(repeating: "c", count: 64),
      buildVersion: "0.1.test",
      buildNumber: "1")
  }


  private func assertPressureRejectedWithoutSpawn(
    root: URL,
    runnerChannel: TatwoLoopJobChannel,
    job: TatwoLoopJobV1,
    controller: TatwoRunnerPressureAdmissionControllerV1,
    expectedExistingConsumption: TatwoRunnerPressureAdmissionConsumptionV1? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let probe = RemoteLoopPressureEngineProbeBox()
    let runner = try makeRunner(
      channel: runnerChannel,
      engine: RemoteLoopPressureCountingEngine(box: probe),
      pressureAdmissionController: controller)
    let receipts = try runner.runOnce()
    let idleReceipts = try runner.runUntilIdle(maxPasses: 2)
    XCTAssertTrue(receipts.isEmpty, file: file, line: line)
    XCTAssertTrue(idleReceipts.isEmpty, file: file, line: line)
    XCTAssertEqual(probe.runCount(), 0, file: file, line: line)
    XCTAssertEqual(try runnerChannel.currentStatus(for: job.jobID), .queued, file: file, line: line)
    XCTAssertFalse(try runnerChannel.hasTargetExecutionClaim(for: job), file: file, line: line)
    XCTAssertNil(try runnerChannel.resultForAudit(for: job.jobID), file: file, line: line)
    XCTAssertEqual(
      try controller.ledger.load(jobID: job.jobID),
      expectedExistingConsumption,
      file: file,
      line: line)
    _ = root
  }

  private struct PressureMidflightFixture {
    let trust: (
      origin: TatwoLoopJobChannelTrust,
      runner: TatwoLoopJobChannelTrust,
      appIssuer: TatwoLoopJobChannelTrust
    )
    let runnerChannel: TatwoLoopJobChannel
    let job: TatwoLoopJobV1
    let ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1
    let permit: TatwoRunnerPressureAdmissionPermitV1
    let consumption: TatwoRunnerPressureAdmissionConsumptionV1
  }

  private func makePressureMidflightFixture(
    root: URL,
    status: TatwoLoopJobStatusV1,
    issuedAt: Date = Date(timeIntervalSince1970: 1_700_000_100),
    payload: TatwoLoopJobPayloadV1? = nil,
    preclaim: Bool = true,
    jobID: String? = nil
  ) throws -> PressureMidflightFixture {
    guard [.delivered, .accepted, .running].contains(status) else {
      throw TatwoLoopJobStateError.invalidJob("pressure midflight status \(status.rawValue)")
    }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: jobID ?? "job-pressure-midflight-\(status.rawValue)",
      payload: payload ?? .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let permit = try makePressurePermit(
      job: job,
      trust: trust.appIssuer,
      issuedAt: issuedAt)
    let ledger = TatwoRunnerPressureAdmissionConsumptionLedgerV1(
      directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true))
    let consumptionResult = try ledger.consume(
      permit: permit,
      job: job,
      now: issuedAt.addingTimeInterval(1))
    let consumption: TatwoRunnerPressureAdmissionConsumptionV1
    switch consumptionResult {
    case .consumed(let marker), .alreadyConsumed(let marker):
      consumption = marker
    }
    if preclaim {
      try runnerChannel.claimTargetExecution(for: job)
    }
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .delivered,
      reason: "runner-discovered")
    if status == .accepted || status == .running {
      _ = try runnerChannel.transition(
        jobID: job.jobID,
        to: .accepted,
        reason: "runner-accepted")
    }
    if status == .running {
      _ = try runnerChannel.transition(
        jobID: job.jobID,
        to: .running,
        reason: "runner-started")
    }
    XCTAssertEqual(try runnerChannel.currentStatus(for: job.jobID), status)
    return PressureMidflightFixture(
      trust: trust,
      runnerChannel: runnerChannel,
      job: job,
      ledger: ledger,
      permit: permit,
      consumption: consumption)
  }



  func testRunnerPressureAdmissionRequiresFreshPermitBeforeSpawn() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-positive",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let controller = try makePressureAdmissionController(
      root: root,
      job: job,
      issuerTrust: trust.appIssuer,
      verifierTrust: trust.runner)

    let probe = RemoteLoopPressureEngineProbeBox()
    let receipts = try makeRunner(
      channel: runnerChannel,
      engine: RemoteLoopPressureCountingEngine(box: probe),
      pressureAdmissionController: controller).runUntilIdle()

    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts[0].status, .completed)
    XCTAssertEqual(try runnerChannel.currentStatus(for: job.jobID), .completed)
    let result = try XCTUnwrap(try runnerChannel.resultForAudit(for: job.jobID))
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.dispatchNonce, job.dispatchNonce)
    let consumption = try XCTUnwrap(controller.ledger.load(jobID: job.jobID))
    XCTAssertEqual(consumption.reservationID, try makePressurePermit(job: job, trust: trust.appIssuer).body.lease.reservationID)
    XCTAssertEqual(consumption.admissionAttemptID, "attempt-\(job.jobID)")
    XCTAssertEqual(consumption.runtimeInstanceID, "runtime-\(job.targetDeviceID)")
    XCTAssertEqual(consumption.runtimeGeneration, 1)
    XCTAssertEqual(consumption.leaseDigest, try makePressurePermit(job: job, trust: trust.appIssuer).body.lease.leaseDigest)
    XCTAssertFalse(consumption.issuerIdentityDigest.isEmpty)
  }

  func testRunnerPressureAdmissionMissingPermitDoesNotClaimOrSpawn() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-missing",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { _ in nil },
      ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1(
        directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true)),
      trust: trust.runner,
      environment: testEnv)

    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: job,
      controller: controller)
  }

  func testRunnerPressureAdmissionExpiredLeaseDoesNotClaimOrSpawn() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-expired",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let controller = try makePressureAdmissionController(
      root: root,
      job: job,
      issuerTrust: trust.appIssuer,
      verifierTrust: trust.runner,
      issuedAt: issuedAt,
      now: issuedAt.addingTimeInterval(16))

    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: job,
      controller: controller)
  }

  func testRunnerPressureAdmissionWrongJobBindingDoesNotClaimOrSpawn() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-wrong-binding",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let other = makeJob(
      jobID: "job-pressure-other-binding",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let permit = try makePressurePermit(job: other, trust: trust.appIssuer)
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { _ in permit },
      ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1(
        directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true)),
      trust: trust.runner,
      clock: TatwoPressureClockV1(now: { Date(timeIntervalSince1970: 1_700_000_105) }),
      environment: testEnv)

    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: job,
      controller: controller)
  }

  func testRunnerPressureAdmissionBadSignatureDoesNotClaimOrSpawn() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let attacker = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "attacker-device",
      privateKeyStore: MemoryDevicePrivateKeyStore(),
      environment: testEnv)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-bad-signature",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let permit = try makePressurePermit(job: job, trust: attacker)
    let controller = makePressureAdmissionController(
      root: root,
      trust: trust.runner,
      permit: permit)

    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: job,
      controller: controller)
  }

  func testRunnerPressureAdmissionReplayLedgerDoesNotClaimOrSpawn() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-replay",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let permit = try makePressurePermit(job: job, trust: trust.appIssuer)
    let ledger = TatwoRunnerPressureAdmissionConsumptionLedgerV1(
      directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true))
    _ = try ledger.consume(
      permit: permit,
      job: job,
      now: Date(timeIntervalSince1970: 1_700_000_101))
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { _ in permit },
      ledger: ledger,
      trust: trust.runner,
      clock: TatwoPressureClockV1(now: { Date(timeIntervalSince1970: 1_700_000_105) }),
      environment: testEnv)

    let existing = try XCTUnwrap(try ledger.load(jobID: job.jobID))
    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: job,
      controller: controller,
      expectedExistingConsumption: existing)
  }

  func testRunnerPressureAdmissionMidflightResumeExpiredLeaseDoesNotExecuteOrAdvance() throws {
    for status in [TatwoLoopJobStatusV1.delivered, .accepted, .running] {
      let root = makeRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
      let fixture = try makePressureMidflightFixture(
        root: root,
        status: status,
        issuedAt: issuedAt)
      let controller = TatwoRunnerPressureAdmissionControllerV1(
        provider: TatwoRunnerPressurePermitProviderV1 { job in
          job.jobID == fixture.permit.body.jobID ? fixture.permit : nil
        },
        ledger: fixture.ledger,
        trust: fixture.trust.runner,
        clock: TatwoPressureClockV1(now: { issuedAt.addingTimeInterval(16) }),
        environment: testEnv)
      XCTAssertFalse(
        controller.validatesContinuationAuthority(job: fixture.job).authorized)

      let probe = RemoteLoopPressureEngineProbeBox()
      let receipts = try makeRunner(
        channel: fixture.runnerChannel,
        engine: RemoteLoopPressureCountingEngine(box: probe),
        pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)

      XCTAssertTrue(receipts.isEmpty)
      XCTAssertEqual(probe.runCount(), 0)
      XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), status)
      XCTAssertNil(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
      XCTAssertEqual(try fixture.ledger.load(jobID: fixture.job.jobID), fixture.consumption)
    }
  }

  func testRunnerPressureAdmissionMidflightResumeIssuerNotCurrentDoesNotExecuteOrAdvance() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let fixture = try makePressureMidflightFixture(
      root: root,
      status: .running,
      issuedAt: issuedAt)
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { job in
        job.jobID == fixture.permit.body.jobID ? fixture.permit : nil
      },
      ledger: fixture.ledger,
      trust: fixture.trust.runner,
      clock: TatwoPressureClockV1(now: { issuedAt.addingTimeInterval(5) }),
      environment: productionIssuerEnvironment(for: fixture.permit, current: "0"),
      expectedIssuerIdentityDigest: fixture.permit.body.issuerIdentity.identityDigest,
      requiresIssuerIdentityBinding: true)
    XCTAssertFalse(
      controller.validatesContinuationAuthority(job: fixture.job).authorized)

    let probe = RemoteLoopPressureEngineProbeBox()
    let receipts = try makeRunner(
      channel: fixture.runnerChannel,
      engine: RemoteLoopPressureCountingEngine(box: probe),
      pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)

    XCTAssertTrue(receipts.isEmpty)
    XCTAssertEqual(probe.runCount(), 0)
    XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), .running)
    XCTAssertNil(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
    XCTAssertEqual(try fixture.ledger.load(jobID: fixture.job.jobID), fixture.consumption)
  }

  func testRunnerPressureAdmissionMidflightResumeRejectsAttemptLineageMismatch() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let fixture = try makePressureMidflightFixture(
      root: root,
      status: .running,
      issuedAt: issuedAt)
    let freshIssuedAt = Date(timeIntervalSince1970: 1_700_000_140)
    let mismatchedAttemptRequest = TatwoLoopAdmissionRequestV1(
      jobID: fixture.job.jobID,
      attemptID: "attempt-foreign-lineage",
      dispatchNonce: fixture.job.dispatchNonce,
      deviceID: fixture.job.targetDeviceID,
      loopID: fixture.job.logicalJobID,
      workload: TatwoRunnerPressureAdmissionPermitV1.defaultWorkload(for: fixture.job),
      contractID: fixture.job.contractID,
      goalHash: TatwoLoopJobDigest.sha256(Data(fixture.job.goalID.utf8)),
      planHash: TatwoLoopJobDigest.sha256(Data("plan-\(fixture.job.contractID)".utf8)),
      requestedAt: freshIssuedAt)
    let mismatchedPermit = try TatwoRunnerPressureAdmissionPermitV1.issue(
      job: fixture.job,
      request: mismatchedAttemptRequest,
      snapshot: TatwoDevicePressureSnapshotV1(
        deviceID: fixture.job.targetDeviceID,
        observedAt: freshIssuedAt,
        sourceSnapshotSequence: 2,
        sourceSampleAttemptID: "sample-fresh-mismatched-lineage",
        memoryFreePercent: 60,
        swapFreeMiB: 2_048,
        dataVolumeFreeGiB: 100,
        load1PerCPU: 0.2,
        thermalWarning: false,
        uiLatencyMilliseconds: 20,
        swapGrowthMiBPerMinute: 0),
      runtimeInstanceID: "runtime-\(fixture.job.targetDeviceID)",
      runtimeGeneration: 1,
      reservationID: TatwoLoopJobDigest.sha256(Data("reservation-fresh-mismatched-lineage".utf8)),
      issuerIdentity: fixture.permit.body.issuerIdentity,
      trust: fixture.trust.appIssuer,
      signedAt: freshIssuedAt)
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { job in
        job.jobID == mismatchedPermit.body.jobID ? mismatchedPermit : nil
      },
      ledger: fixture.ledger,
      trust: fixture.trust.runner,
      clock: TatwoPressureClockV1(now: { freshIssuedAt.addingTimeInterval(5) }),
      environment: testEnv)

    let continuation = controller.validatesContinuationAuthority(job: fixture.job)
    XCTAssertFalse(continuation.authorized)
    XCTAssertEqual(continuation.reasonCode, "pressure_permit_consumption_conflict")

    let receipts = try makeRunner(
      channel: fixture.runnerChannel,
      pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)
    XCTAssertTrue(receipts.isEmpty)
    XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), .running)
    XCTAssertNil(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
    XCTAssertEqual(try fixture.ledger.load(jobID: fixture.job.jobID), fixture.consumption)
  }

  func testRunnerPressureAdmissionMidflightResumeFinalRecheckStopsAuthorityDrift() throws {
    final class TwoPhaseLivenessBox: @unchecked Sendable {
      private let lock = NSLock()
      private var calls = 0
      func isCurrent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls == 1
      }
    }

    for status in [TatwoLoopJobStatusV1.delivered, .accepted, .running] {
      let root = makeRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
      let freshIssuedAt = Date(timeIntervalSince1970: 1_700_000_140)
      let fixture = try makePressureMidflightFixture(
        root: root,
        status: status,
        issuedAt: issuedAt)
      let freshPermit = try makePressurePermit(
        job: fixture.job,
        trust: fixture.trust.appIssuer,
        issuedAt: freshIssuedAt)
      let livenessBox = TwoPhaseLivenessBox()
      let controller = TatwoRunnerPressureAdmissionControllerV1(
        provider: TatwoRunnerPressurePermitProviderV1 { job in
          job.jobID == freshPermit.body.jobID ? freshPermit : nil
        },
        ledger: fixture.ledger,
        trust: fixture.trust.runner,
        clock: TatwoPressureClockV1(now: { freshIssuedAt.addingTimeInterval(5) }),
        environment: testEnv,
        issuerLiveness: TatwoAppPressureIssuerLivenessV1 { _, _, _ in
          livenessBox.isCurrent()
        })

      let receipts = try makeRunner(
        channel: fixture.runnerChannel,
        pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)

      XCTAssertTrue(receipts.isEmpty)
      XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), status)
      XCTAssertNil(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
      XCTAssertEqual(try fixture.ledger.load(jobID: fixture.job.jobID), fixture.consumption)
    }
  }

  func testRunnerPressureAdmissionMidflightResumeTerminalResultFencePreventsDuplicateResume() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let freshIssuedAt = Date(timeIntervalSince1970: 1_700_000_140)
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let globalClaimAnchor = TatwoLoopGlobalAntiRollbackFileAnchor(
      rootURL: root.appendingPathComponent("global-anti-rollback", isDirectory: true))
    let originChannel = makeChannel(
      rootURL: channelRoot,
      trust: trust.origin,
      globalAntiRollbackAnchor: globalClaimAnchor)
    let runnerChannel = makeChannel(
      rootURL: channelRoot,
      trust: trust.runner,
      globalAntiRollbackAnchor: globalClaimAnchor)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-midflight-claim-fence",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .sleep, arguments: ["0.2"])),
      workPath: work,
      maxDurationSec: 2)
    _ = try originChannel.enqueue(job)
    let originalPermit = try makePressurePermit(
      job: job,
      trust: trust.appIssuer,
      issuedAt: issuedAt)
    let ledger = TatwoRunnerPressureAdmissionConsumptionLedgerV1(
      directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true))
    let consumption: TatwoRunnerPressureAdmissionConsumptionV1
    switch try ledger.consume(permit: originalPermit, job: job, now: issuedAt.addingTimeInterval(1)) {
    case .consumed(let marker), .alreadyConsumed(let marker):
      consumption = marker
    }
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .delivered,
      reason: "runner-discovered")
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .accepted,
      reason: "runner-accepted")
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .running,
      reason: "runner-started")
    let freshPermit = try makePressurePermit(
      job: job,
      trust: trust.appIssuer,
      issuedAt: freshIssuedAt)
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { candidate in
        candidate.jobID == freshPermit.body.jobID ? freshPermit : nil
      },
      ledger: ledger,
      trust: trust.runner,
      clock: TatwoPressureClockV1(now: { freshIssuedAt.addingTimeInterval(5) }),
      environment: testEnv)
    let first = try makeRunner(
      channel: runnerChannel,
      pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)
    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(first.first?.status, .completed)
    XCTAssertEqual(try ledger.load(jobID: job.jobID), consumption)

    let replay = try makeRunner(
      channel: runnerChannel,
      pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)
    XCTAssertTrue(replay.isEmpty)
    XCTAssertEqual(try runnerChannel.currentStatus(for: job.jobID), .completed)
    XCTAssertTrue(try runnerChannel.hasTargetExecutionClaim(for: job))
  }

  func testRunnerPressureAdmissionMidflightResumeExpiredLeaseWithoutExistingClaimDoesNotCreateClaim() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let fixture = try makePressureMidflightFixture(
      root: root,
      status: .running,
      issuedAt: issuedAt,
      preclaim: false,
      jobID: "job-pressure-midflight-no-existing-claim")
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { job in
        job.jobID == fixture.permit.body.jobID ? fixture.permit : nil
      },
      ledger: fixture.ledger,
      trust: fixture.trust.runner,
      clock: TatwoPressureClockV1(now: { issuedAt.addingTimeInterval(16) }),
      environment: testEnv)

    let receipts = try makeRunner(
      channel: fixture.runnerChannel,
      pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)

    XCTAssertTrue(receipts.isEmpty)
    XCTAssertFalse(try fixture.runnerChannel.hasTargetExecutionClaim(for: fixture.job))
    XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), .running)
    XCTAssertNil(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
    XCTAssertEqual(try fixture.ledger.load(jobID: fixture.job.jobID), fixture.consumption)
  }

  func testRunnerPressureAdmissionMidflightResumeExpiredLeaseDoesNotInvokeTatwoLoopEngine() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let payload = TatwoLoopJobPayloadV1.tatwoLoop(
      TatwoLoopPayloadV1(
        contractID: contractID,
        goalID: goalID,
        identity: .sub,
        mode: .xxl,
        taskDescription: "pressure rejection must happen before engine invocation",
        agent: .codex,
        exactModelRouteID: "gpt-5.5"))
    let fixture = try makePressureMidflightFixture(
      root: root,
      status: .running,
      issuedAt: issuedAt,
      payload: payload,
      jobID: "job-pressure-midflight-tatwo-loop-no-engine")
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { job in
        job.jobID == fixture.permit.body.jobID ? fixture.permit : nil
      },
      ledger: fixture.ledger,
      trust: fixture.trust.runner,
      clock: TatwoPressureClockV1(now: { issuedAt.addingTimeInterval(16) }),
      environment: testEnv)
    var runnerEnv = testEnv
    runnerEnv[TatwoLoopSandboxUnlock.enableEnvKey] = TatwoLoopSandboxUnlock.enableSandboxValue
    runnerEnv[TatwoLoopSandboxUnlock.sandboxRootEnvKey] = root.path
    let probe = RemoteLoopPressureEngineProbeBox()
    XCTAssertFalse(controller.validatesContinuationAuthority(job: fixture.job).authorized)

    let receipts = try makeRunner(
      channel: fixture.runnerChannel,
      environment: runnerEnv,
      sandboxRootURL: root,
      engine: RemoteLoopPressureCountingEngine(box: probe),
      pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)

    XCTAssertTrue(receipts.isEmpty)
    XCTAssertEqual(probe.runCount(), 0)
    XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), .running)
    XCTAssertNil(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
  }

  func testRunnerPressureAdmissionMidflightResumeMissingPermitDoesNotExecuteOrAdvance() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let fixture = try makePressureMidflightFixture(
      root: root,
      status: .running,
      issuedAt: issuedAt)
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { _ in nil },
      ledger: fixture.ledger,
      trust: fixture.trust.runner,
      clock: TatwoPressureClockV1(now: { issuedAt.addingTimeInterval(5) }),
      environment: testEnv)
    XCTAssertEqual(
      controller.validatesContinuationAuthority(job: fixture.job).reasonCode,
      "pressure_permit_missing")

    let receipts = try makeRunner(
      channel: fixture.runnerChannel,
      pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)

    XCTAssertTrue(receipts.isEmpty)
    XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), .running)
    XCTAssertNil(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
    XCTAssertEqual(try fixture.ledger.load(jobID: fixture.job.jobID), fixture.consumption)
  }

  func testRunnerPressureAdmissionMidflightResumeMissingIssuerBindingDoesNotExecuteOrAdvance() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let fixture = try makePressureMidflightFixture(
      root: root,
      status: .running,
      issuedAt: issuedAt)
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { job in
        job.jobID == fixture.permit.body.jobID ? fixture.permit : nil
      },
      ledger: fixture.ledger,
      trust: fixture.trust.runner,
      clock: TatwoPressureClockV1(now: { issuedAt.addingTimeInterval(5) }),
      environment: testEnv,
      requiresIssuerIdentityBinding: true)
    XCTAssertEqual(
      controller.validatesContinuationAuthority(job: fixture.job).reasonCode,
      "pressure_permit_binding_mismatch")

    let receipts = try makeRunner(
      channel: fixture.runnerChannel,
      pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)

    XCTAssertTrue(receipts.isEmpty)
    XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), .running)
    XCTAssertNil(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
    XCTAssertEqual(try fixture.ledger.load(jobID: fixture.job.jobID), fixture.consumption)
  }

  func testRunnerPressureAdmissionMidflightResumeMissingConsumptionMarkerDoesNotExecute() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-midflight-missing-consumption",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let permit = try makePressurePermit(
      job: job,
      trust: trust.appIssuer,
      issuedAt: issuedAt)
    try runnerChannel.claimTargetExecution(for: job)
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .delivered,
      reason: "runner-discovered")
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .accepted,
      reason: "runner-accepted")
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .running,
      reason: "runner-started")
    let ledger = TatwoRunnerPressureAdmissionConsumptionLedgerV1(
      directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true))
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { candidate in
        candidate.jobID == permit.body.jobID ? permit : nil
      },
      ledger: ledger,
      trust: trust.runner,
      clock: TatwoPressureClockV1(now: { issuedAt.addingTimeInterval(5) }),
      environment: testEnv)
    XCTAssertEqual(
      controller.validatesContinuationAuthority(job: job).reasonCode,
      "pressure_permit_consumption_missing")

    let probe = RemoteLoopPressureEngineProbeBox()
    let receipts = try makeRunner(
      channel: runnerChannel,
      engine: RemoteLoopPressureCountingEngine(box: probe),
      pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)

    XCTAssertTrue(receipts.isEmpty)
    XCTAssertEqual(probe.runCount(), 0)
    XCTAssertEqual(try runnerChannel.currentStatus(for: job.jobID), .running)
    XCTAssertNil(try runnerChannel.resultForAudit(for: job.jobID))
    XCTAssertNil(try ledger.load(jobID: job.jobID))
  }

  func testRunnerPressureAdmissionMidflightResumeAcceptsFreshContinuationPermitWithoutReconsumingSpawnPermit()
    throws
  {
    for status in [TatwoLoopJobStatusV1.delivered, .accepted, .running] {
      let root = makeRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let originalIssuedAt = Date(timeIntervalSince1970: 1_700_000_100)
      let freshIssuedAt = Date(timeIntervalSince1970: 1_700_000_140)
      let fixture = try makePressureMidflightFixture(
        root: root,
        status: status,
        issuedAt: originalIssuedAt)
      let freshPermit = try makePressurePermit(
        job: fixture.job,
        trust: fixture.trust.appIssuer,
        issuedAt: freshIssuedAt)
      XCTAssertNotEqual(freshPermit.permitID, fixture.permit.permitID)
      let controller = TatwoRunnerPressureAdmissionControllerV1(
        provider: TatwoRunnerPressurePermitProviderV1 { job in
          job.jobID == freshPermit.body.jobID ? freshPermit : nil
        },
        ledger: fixture.ledger,
        trust: fixture.trust.runner,
        clock: TatwoPressureClockV1(now: { freshIssuedAt.addingTimeInterval(5) }),
        environment: testEnv)
      let continuation = controller.validatesContinuationAuthority(job: fixture.job)
      XCTAssertTrue(continuation.authorized, continuation.reasonCode)
      XCTAssertEqual(continuation.consumption, fixture.consumption)

      let probe = RemoteLoopPressureEngineProbeBox()
      let receipts = try makeRunner(
        channel: fixture.runnerChannel,
        engine: RemoteLoopPressureCountingEngine(box: probe),
        pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)

      XCTAssertEqual(receipts.count, 1)
      XCTAssertEqual(receipts.first?.status, .completed)
      XCTAssertEqual(probe.runCount(), 0)
      XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), .completed)
      let result = try XCTUnwrap(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
      XCTAssertEqual(result.status, .completed)
      XCTAssertEqual(result.dispatchNonce, fixture.job.dispatchNonce)
      XCTAssertEqual(result.exitCode, 0)
      XCTAssertEqual(result.outputBytes, 0)
      XCTAssertEqual(result.outputDigest, TatwoLoopJobDigest.sha256(Data()))
      XCTAssertNil(result.failureCode)
      XCTAssertEqual(try fixture.ledger.load(jobID: fixture.job.jobID), fixture.consumption)
    }
  }


  func testRunnerPressureAdmissionMidflightResumeConcurrentOneWinnerExecutesOnce() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let freshIssuedAt = Date(timeIntervalSince1970: 1_700_000_104)
    let payload = TatwoLoopJobPayloadV1.tatwoLoop(
      TatwoLoopPayloadV1(
        contractID: contractID,
        goalID: goalID,
        identity: .sub,
        mode: .xxl,
        taskDescription: "concurrent resume must have one engine winner",
        agent: .codex,
        exactModelRouteID: "gpt-5.5"))
    let fixture = try makePressureMidflightFixture(
      root: root,
      status: .running,
      issuedAt: issuedAt,
      payload: payload,
      jobID: "job-pressure-midflight-concurrent-one-winner")
    let freshPermit = try makePressurePermit(
      job: fixture.job,
      trust: fixture.trust.appIssuer,
      issuedAt: freshIssuedAt)
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { job in
        job.jobID == freshPermit.body.jobID ? freshPermit : nil
      },
      ledger: fixture.ledger,
      trust: fixture.trust.runner,
      clock: TatwoPressureClockV1(now: { freshIssuedAt.addingTimeInterval(1) }),
      environment: testEnv)
    var runnerEnv = testEnv
    runnerEnv[TatwoLoopSandboxUnlock.enableEnvKey] = TatwoLoopSandboxUnlock.enableSandboxValue
    runnerEnv[TatwoLoopSandboxUnlock.sandboxRootEnvKey] = root.path
    let probe = RemoteLoopPressureEngineProbeBox()
    let start = DispatchSemaphore(value: 0)
    let done = DispatchGroup()
    let lock = NSLock()
    var allReceipts: [TatwoLoopJobResultReceiptV1] = []
    var errors: [String] = []

    for _ in 0..<2 {
      done.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        start.wait()
        do {
          let receipts = try self.makeRunner(
            channel: fixture.runnerChannel,
            environment: runnerEnv,
            sandboxRootURL: root,
            engine: RemoteLoopPressureCountingEngine(box: probe),
            pressureAdmissionController: controller).runOnce()
          lock.lock()
          allReceipts.append(contentsOf: receipts)
          lock.unlock()
        } catch {
          lock.lock()
          errors.append(String(describing: error))
          lock.unlock()
        }
        done.leave()
      }
    }
    start.signal()
    start.signal()
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)

    XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
    XCTAssertEqual(probe.runCount(), 1)
    XCTAssertEqual(allReceipts.count, 1)
    XCTAssertEqual(allReceipts.first?.status, .completed)
    XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), .completed)
    XCTAssertNotNil(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
    XCTAssertNotNil(try fixture.ledger.loadContinuationResumeClaim(jobID: fixture.job.jobID))
  }

  func testRunnerPressureAdmissionMidflightResumeClaimLoserWritesNoTerminalOrResult() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let freshIssuedAt = Date(timeIntervalSince1970: 1_700_000_104)
    let payload = TatwoLoopJobPayloadV1.tatwoLoop(
      TatwoLoopPayloadV1(
        contractID: contractID,
        goalID: goalID,
        identity: .sub,
        mode: .xxl,
        taskDescription: "claimed resume loser must not execute",
        agent: .codex,
        exactModelRouteID: "gpt-5.5"))
    let fixture = try makePressureMidflightFixture(
      root: root,
      status: .running,
      issuedAt: issuedAt,
      payload: payload,
      jobID: "job-pressure-midflight-claim-loser")
    let freshPermit = try makePressurePermit(
      job: fixture.job,
      trust: fixture.trust.appIssuer,
      issuedAt: freshIssuedAt)
    _ = try fixture.ledger.claimContinuationResume(
      permit: freshPermit,
      job: fixture.job,
      consumption: fixture.consumption,
      now: freshIssuedAt.addingTimeInterval(1))
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { job in
        job.jobID == freshPermit.body.jobID ? freshPermit : nil
      },
      ledger: fixture.ledger,
      trust: fixture.trust.runner,
      clock: TatwoPressureClockV1(now: { freshIssuedAt.addingTimeInterval(2) }),
      environment: testEnv)
    let probe = RemoteLoopPressureEngineProbeBox()

    let receipts = try makeRunner(
      channel: fixture.runnerChannel,
      engine: RemoteLoopPressureCountingEngine(box: probe),
      pressureAdmissionController: controller).runOnce()

    XCTAssertTrue(receipts.isEmpty)
    XCTAssertEqual(probe.runCount(), 0)
    XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), .running)
    XCTAssertNil(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
  }

  func testRunnerPressureAdmissionMidflightResumeClaimLoserRunUntilIdleDoesNotSpin() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let freshIssuedAt = Date(timeIntervalSince1970: 1_700_000_104)
    let payload = TatwoLoopJobPayloadV1.tatwoLoop(
      TatwoLoopPayloadV1(
        contractID: contractID,
        goalID: goalID,
        identity: .sub,
        mode: .xxl,
        taskDescription: "claimed resume loser must not make runUntilIdle spin",
        agent: .codex,
        exactModelRouteID: "gpt-5.5"))
    let fixture = try makePressureMidflightFixture(
      root: root,
      status: .running,
      issuedAt: issuedAt,
      payload: payload,
      jobID: "job-pressure-midflight-claim-loser-idle")
    let freshPermit = try makePressurePermit(
      job: fixture.job,
      trust: fixture.trust.appIssuer,
      issuedAt: freshIssuedAt)
    _ = try fixture.ledger.claimContinuationResume(
      permit: freshPermit,
      job: fixture.job,
      consumption: fixture.consumption,
      now: freshIssuedAt.addingTimeInterval(1))
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { job in
        job.jobID == freshPermit.body.jobID ? freshPermit : nil
      },
      ledger: fixture.ledger,
      trust: fixture.trust.runner,
      clock: TatwoPressureClockV1(now: { freshIssuedAt.addingTimeInterval(2) }),
      environment: testEnv)
    let probe = RemoteLoopPressureEngineProbeBox()

    let receipts = try makeRunner(
      channel: fixture.runnerChannel,
      engine: RemoteLoopPressureCountingEngine(box: probe),
      pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)

    XCTAssertTrue(receipts.isEmpty)
    XCTAssertEqual(probe.runCount(), 0)
    XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), .running)
    XCTAssertNil(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
    XCTAssertNotNil(try fixture.ledger.loadContinuationResumeClaim(jobID: fixture.job.jobID))
  }

  func testRunnerPressureAdmissionMidflightFinalClaimAfterAuthorityDriftLeavesRetryableNoClaim() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let issuedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let fixture = try makePressureMidflightFixture(
      root: root,
      status: .running,
      issuedAt: issuedAt,
      jobID: "job-pressure-midflight-final-drift-retryable")
    let expiredContinuation = try makePressurePermit(
      job: fixture.job,
      trust: fixture.trust.appIssuer,
      issuedAt: issuedAt.addingTimeInterval(2))
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { job in
        job.jobID == expiredContinuation.body.jobID ? expiredContinuation : nil
      },
      ledger: fixture.ledger,
      trust: fixture.trust.runner,
      clock: TatwoPressureClockV1(now: { issuedAt.addingTimeInterval(40) }),
      environment: testEnv)
    let probe = RemoteLoopPressureEngineProbeBox()

    let receipts = try makeRunner(
      channel: fixture.runnerChannel,
      engine: RemoteLoopPressureCountingEngine(box: probe),
      pressureAdmissionController: controller).runOnce()

    XCTAssertTrue(receipts.isEmpty)
    XCTAssertEqual(probe.runCount(), 0)
    XCTAssertEqual(try fixture.runnerChannel.currentStatus(for: fixture.job.jobID), .running)
    XCTAssertNil(try fixture.runnerChannel.resultForAudit(for: fixture.job.jobID))
    XCTAssertNil(try fixture.ledger.loadContinuationResumeClaim(jobID: fixture.job.jobID))
  }

  func testRunnerPressureAdmissionIssuerDigestMismatchDoesNotClaimOrSpawn() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-issuer-mismatch",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let permit = try makePressurePermit(job: job, trust: trust.appIssuer)
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { _ in permit },
      ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1(
        directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true)),
      trust: trust.runner,
      clock: TatwoPressureClockV1(now: { Date(timeIntervalSince1970: 1_700_000_105) }),
      environment: testEnv,
      expectedIssuerIdentityDigest: String(repeating: "b", count: 64),
      requiresIssuerIdentityBinding: true)

    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: job,
      controller: controller)
  }

  func testRunnerPressureAdmissionIssuerNotCurrentDoesNotClaimOrSpawn() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-issuer-not-current",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let permit = try makePressurePermit(job: job, trust: trust.appIssuer)
    var staleIssuerEnvironment = testEnv
    staleIssuerEnvironment[TatwoAppPressureIssuerLivenessV1.currentEnvKey] = "0"
    staleIssuerEnvironment[TatwoAppPressureIssuerLivenessV1.runtimeInstanceIDEnvKey] =
      permit.body.issuerIdentity.runtimeInstanceID
    staleIssuerEnvironment[TatwoAppPressureIssuerLivenessV1.runtimeGenerationEnvKey] =
      "\(permit.body.issuerIdentity.runtimeGeneration)"
    staleIssuerEnvironment[TatwoAppPressureIssuerLivenessV1.appLaunchIDEnvKey] =
      permit.body.issuerIdentity.appLaunchID
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { job in
        job.jobID == permit.body.jobID ? permit : nil
      },
      ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1(
        directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true)),
      trust: trust.runner,
      clock: TatwoPressureClockV1(now: { Date(timeIntervalSince1970: 1_700_000_105) }),
      environment: staleIssuerEnvironment,
      expectedIssuerIdentityDigest: permit.body.issuerIdentity.identityDigest,
      requiresIssuerIdentityBinding: true)

    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: job,
      controller: controller)
  }

  func testRunnerPressureAdmissionCustomLivenessRejectsWithoutIssuerDigestDoesNotClaimOrSpawn() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-custom-liveness-no-digest",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let permit = try makePressurePermit(job: job, trust: trust.appIssuer)
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { job in
        job.jobID == permit.body.jobID ? permit : nil
      },
      ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1(
        directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true)),
      trust: trust.runner,
      clock: TatwoPressureClockV1(now: { Date(timeIntervalSince1970: 1_700_000_105) }),
      environment: testEnv,
      issuerLiveness: TatwoAppPressureIssuerLivenessV1 { _, _, _ in false })

    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: job,
      controller: controller)
  }

  func testRunnerPressureAdmissionProductionFactoryRequiresIssuerDigestDoesNotClaimOrSpawn() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-production-missing-digest",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let issuedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let permit = try makePressurePermit(job: job, trust: trust.appIssuer, issuedAt: issuedAt)
    let stateRoot = root.appendingPathComponent("state", isDirectory: true)
    let permitsURL = stateRoot
      .appendingPathComponent("pressure-admission", isDirectory: true)
      .appendingPathComponent(TatwoLoopPathComponent.sanitize(job.targetDeviceID), isDirectory: true)
      .appendingPathComponent("permits", isDirectory: true)
    let writer = TatwoRunnerPressurePermitFileWriterV1(directoryURL: permitsURL)
    _ = try writer.write(permit: permit)
    var environment = testEnv
    environment[TatwoAppPressureIssuerLivenessV1.currentEnvKey] = "1"
    environment[TatwoAppPressureIssuerLivenessV1.runtimeInstanceIDEnvKey] =
      permit.body.issuerIdentity.runtimeInstanceID
    environment[TatwoAppPressureIssuerLivenessV1.runtimeGenerationEnvKey] =
      "\(permit.body.issuerIdentity.runtimeGeneration)"
    environment[TatwoAppPressureIssuerLivenessV1.appLaunchIDEnvKey] =
      permit.body.issuerIdentity.appLaunchID
    let controller = TatwoRunnerPressureAdmissionControllerV1.production(
      channel: runnerChannel,
      trust: trust.runner,
      deviceID: job.targetDeviceID,
      stateRoot: stateRoot,
      environment: environment)

    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: job,
      controller: controller)
  }

  func testAppRunnerPressurePermitIssuerWritesProductionPermitAndRunnerEnvAuthorizesOneShellSafeJob() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let marker = "tatwo-pressure-permit-ok"
    let expectedOutput = Data("\(marker)\n".utf8)
    let job = makeJob(
      jobID: "job-pressure-app-issuer-env",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: [marker])),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let clock = TatwoPressureClockV1()
    let runtime = makePressureRuntime(
      deviceID: job.targetDeviceID,
      runtimeInstanceID: "runtime-app-issuer-env",
      clock: clock)
    await runtime.start(reason: .test, startTimers: false)
    defer { Task { await runtime.stop(reason: .test) } }
    let issuer = TatwoAppRunnerPressurePermitIssuerV1(
      stateRoot: root.appendingPathComponent("state", isDirectory: true),
      targetDeviceID: job.targetDeviceID,
      trust: trust.appIssuer,
      issuerProcessIdentity: makePressureIssuerProcessIdentity(suffix: job.jobID),
      clock: clock)
    let request = issuer.makeAdmissionRequest(for: job, requestedAt: clock.now())

    let snapshot = makeGreenReadings().snapshot(
      deviceID: job.targetDeviceID,
      observedAt: clock.now(),
      activeLoopID: nil,
      workers: [],
      sourceSnapshotSequence: 7,
      sourceSampleAttemptID: "sample-app-issuer-env")
    let receipt = try await issuer.issuePermit(
      job: job,
      request: request,
      snapshot: snapshot,
      runtime: runtime,
      baseRunnerEnvironment: testEnv)

    let permitRevisionsURL = TatwoRunnerPressurePermitFileWriterV1(
      directoryURL: issuer.permitsDirectoryURL())
      .revisionDirectoryURL(forJobID: job.jobID)
    let permitFiles = try FileManager.default.contentsOfDirectory(
      at: permitRevisionsURL,
      includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
    XCTAssertEqual(permitFiles.count, 1)
    let permitURL = try XCTUnwrap(permitFiles.first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: permitURL.path))
    XCTAssertEqual(receipt.permitPathSHA256, TatwoLoopJobDigest.sha256(Data(receipt.permitPath.utf8)))
    let data = try Data(contentsOf: permitURL)
    let permitJSON = String(data: data, encoding: .utf8) ?? ""
    XCTAssertTrue(permitJSON.contains("\"issuedAt\":"), permitJSON)
    _ = try assertPressurePermitRawBodyUsesCanonicalDateStrings(data)
    let decoder = TatwoPressureCanonicalJSONV1.decoder()
    let permit = try decoder.decode(TatwoRunnerPressureAdmissionPermitV1.self, from: data)
    let bodyData = try TatwoRunnerPressureAdmissionPermitV1.canonicalJSONData(permit.body)
    XCTAssertEqual(
      permit.issuerSignature.signedAt,
      TatwoLoopJobChannelTrust.iso8601(permit.body.issuedAt))
    XCTAssertEqual(
      permit.issuerSignature.payloadDigest,
      TatwoLoopJobChannelTrust.sha256Hex(bodyData))
    XCTAssertEqual(permit.permitID, receipt.permitID)
    XCTAssertEqual(receipt.runnerEnvironment[TatwoRunnerPressureAdmissionControllerV1.expectedIssuerIdentityDigestEnvKey], permit.body.issuerIdentity.identityDigest)
    XCTAssertEqual(receipt.runnerEnvironment[TatwoAppPressureIssuerLivenessV1.currentEnvKey], "1")
    XCTAssertEqual(receipt.runnerEnvironment[TatwoAppPressureIssuerLivenessV1.runtimeInstanceIDEnvKey], permit.body.issuerIdentity.runtimeInstanceID)
    XCTAssertEqual(receipt.runnerEnvironment[TatwoAppPressureIssuerLivenessV1.runtimeGenerationEnvKey], "\(permit.body.issuerIdentity.runtimeGeneration)")
    XCTAssertEqual(receipt.runnerEnvironment[TatwoAppPressureIssuerLivenessV1.appLaunchIDEnvKey], permit.body.issuerIdentity.appLaunchID)

    let controller = TatwoRunnerPressureAdmissionControllerV1.production(
      channel: runnerChannel,
      trust: trust.runner,
      deviceID: job.targetDeviceID,
      stateRoot: issuer.stateRoot,
      environment: receipt.runnerEnvironment)
    XCTAssertTrue(controller.hasConsumablePermit(job: job))
    let probe = RemoteLoopPressureEngineProbeBox()
    let receipts = try makeRunner(
      channel: runnerChannel,
      engine: RemoteLoopPressureCountingEngine(box: probe),
      pressureAdmissionController: controller).runUntilIdle()

    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts.first?.status, .completed)
    XCTAssertEqual(probe.runCount(), 0)
    XCTAssertEqual(try runnerChannel.currentStatus(for: job.jobID), .completed)
    let result = try XCTUnwrap(try runnerChannel.resultForAudit(for: job.jobID))
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.outputDigest, TatwoLoopJobDigest.sha256(expectedOutput))
    XCTAssertEqual(result.outputBytes, expectedOutput.count)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.failureCode, nil)
    let artifact = try originChannel.outputArtifact(for: job.jobID)
    XCTAssertEqual(artifact.data, expectedOutput)
    XCTAssertEqual(artifact.outputDigest, result.outputDigest)
    let consumption = try XCTUnwrap(controller.ledger.load(jobID: job.jobID))
    XCTAssertEqual(consumption.permitID, permit.permitID)
    XCTAssertEqual(consumption.issuerIdentityDigest, permit.body.issuerIdentity.identityDigest)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: controller.ledger.directoryURL,
        includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .count,
      1)

    let freshController = TatwoRunnerPressureAdmissionControllerV1.production(
      channel: runnerChannel,
      trust: trust.runner,
      deviceID: job.targetDeviceID,
      stateRoot: issuer.stateRoot,
      environment: receipt.runnerEnvironment)
    XCTAssertFalse(freshController.hasConsumablePermit(job: job))
    let replayProbe = RemoteLoopPressureEngineProbeBox()
    let replayReceipts = try makeRunner(
      channel: runnerChannel,
      engine: RemoteLoopPressureCountingEngine(box: replayProbe),
      pressureAdmissionController: freshController).runUntilIdle(maxPasses: 2)
    XCTAssertTrue(replayReceipts.isEmpty)
    XCTAssertEqual(replayProbe.runCount(), 0)
    XCTAssertEqual(try freshController.ledger.load(jobID: job.jobID), consumption)
  }

  func testAppRunnerPressurePermitIssuerMissingStaleWrongEnvLeavesJobQueuedBeforeClaim() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let clock = TatwoPressureClockV1()
    let stateRoot = root.appendingPathComponent("state", isDirectory: true)
    let runtime = makePressureRuntime(
      deviceID: targetDeviceID,
      runtimeInstanceID: "runtime-app-issuer-env-reject",
      clock: clock)
    await runtime.start(reason: .test, startTimers: false)
    defer { Task { await runtime.stop(reason: .test) } }
    let issuer = TatwoAppRunnerPressurePermitIssuerV1(
      stateRoot: stateRoot,
      targetDeviceID: targetDeviceID,
      trust: trust.appIssuer,
      issuerProcessIdentity: makePressureIssuerProcessIdentity(suffix: "env-reject"),
      clock: clock)
    let snapshot = makeGreenReadings().snapshot(
      deviceID: targetDeviceID,
      observedAt: clock.now(),
      activeLoopID: nil,
      workers: [],
      sourceSnapshotSequence: 8,
      sourceSampleAttemptID: "sample-env-reject")

    func enqueueJob(_ id: String) throws -> TatwoLoopJobV1 {
      let job = makeJob(
        jobID: id,
        payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
        workPath: work)
      _ = try originChannel.enqueue(job)
      return job
    }

    let missing = try enqueueJob("job-pressure-app-issuer-missing-env")
    let missingRequest = issuer.makeAdmissionRequest(for: missing, requestedAt: clock.now())
    _ = try await issuer.issuePermit(
      job: missing,
      request: missingRequest,
      snapshot: snapshot,
      runtime: runtime,
      baseRunnerEnvironment: testEnv)
    let missingEnvController = TatwoRunnerPressureAdmissionControllerV1.production(
      channel: runnerChannel,
      trust: trust.runner,
      deviceID: missing.targetDeviceID,
      stateRoot: stateRoot,
      environment: testEnv)
    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: missing,
      controller: missingEnvController)

    let stale = try enqueueJob("job-pressure-app-issuer-stale-env")
    let staleRequest = issuer.makeAdmissionRequest(for: stale, requestedAt: clock.now())
    let staleReceipt = try await issuer.issuePermit(
      job: stale,
      request: staleRequest,
      snapshot: snapshot,
      runtime: runtime,
      baseRunnerEnvironment: testEnv)
    var staleEnvironment = staleReceipt.runnerEnvironment
    staleEnvironment[TatwoAppPressureIssuerLivenessV1.currentEnvKey] = "0"
    let staleEnvController = TatwoRunnerPressureAdmissionControllerV1.production(
      channel: runnerChannel,
      trust: trust.runner,
      deviceID: stale.targetDeviceID,
      stateRoot: stateRoot,
      environment: staleEnvironment)
    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: stale,
      controller: staleEnvController)

    let wrongDigest = try enqueueJob("job-pressure-app-issuer-wrong-digest")
    let wrongDigestRequest = issuer.makeAdmissionRequest(for: wrongDigest, requestedAt: clock.now())
    let wrongDigestReceipt = try await issuer.issuePermit(
      job: wrongDigest,
      request: wrongDigestRequest,
      snapshot: snapshot,
      runtime: runtime,
      baseRunnerEnvironment: testEnv)
    var wrongDigestEnvironment = wrongDigestReceipt.runnerEnvironment
    wrongDigestEnvironment[TatwoRunnerPressureAdmissionControllerV1.expectedIssuerIdentityDigestEnvKey] =
      String(repeating: "d", count: 64)
    let wrongDigestController = TatwoRunnerPressureAdmissionControllerV1.production(
      channel: runnerChannel,
      trust: trust.runner,
      deviceID: wrongDigest.targetDeviceID,
      stateRoot: stateRoot,
      environment: wrongDigestEnvironment)
    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: wrongDigest,
      controller: wrongDigestController)
  }

  func testAppRunnerPressurePermitIssuerRenewsProductionPermitForMidflightContinuation() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let expectedOutput = Data()
    let job = makeJob(
      jobID: "job-pressure-app-issuer-renew-midflight",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let clock = TatwoPressureClockV1()
    let runtime = makePressureRuntime(
      deviceID: job.targetDeviceID,
      runtimeInstanceID: "runtime-app-issuer-renew-midflight",
      clock: clock)
    await runtime.start(reason: .test, startTimers: false)
    defer { Task { await runtime.stop(reason: .test) } }
    let stateRoot = root.appendingPathComponent("state", isDirectory: true)
    let issuer = TatwoAppRunnerPressurePermitIssuerV1(
      stateRoot: stateRoot,
      targetDeviceID: job.targetDeviceID,
      trust: trust.appIssuer,
      issuerProcessIdentity: makePressureIssuerProcessIdentity(suffix: job.jobID),
      clock: clock)
    let firstSnapshot = makeGreenReadings().snapshot(
      deviceID: job.targetDeviceID,
      observedAt: clock.now(),
      activeLoopID: nil,
      workers: [],
      sourceSnapshotSequence: 31,
      sourceSampleAttemptID: "sample-renew-midflight-1")
    let firstReceipt = try await issuer.issuePermit(
      job: job,
      request: issuer.makeAdmissionRequest(for: job, requestedAt: clock.now()),
      snapshot: firstSnapshot,
      runtime: runtime,
      baseRunnerEnvironment: testEnv)
    let firstController = TatwoRunnerPressureAdmissionControllerV1.production(
      channel: runnerChannel,
      trust: trust.runner,
      deviceID: job.targetDeviceID,
      stateRoot: stateRoot,
      environment: firstReceipt.runnerEnvironment)
    let spawnAdmission = firstController.authorize(job: job)
    XCTAssertTrue(spawnAdmission.authorized, spawnAdmission.reasonCode)
    let inMemoryConsumption = try XCTUnwrap(spawnAdmission.consumption)
    let originalConsumption = try XCTUnwrap(firstController.ledger.load(jobID: job.jobID))
    XCTAssertEqual(originalConsumption.permitID, inMemoryConsumption.permitID)
    XCTAssertEqual(originalConsumption.markerDigest, inMemoryConsumption.markerDigest)
    try runnerChannel.claimTargetExecution(for: job)
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .delivered,
      reason: "runner-discovered")
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .accepted,
      reason: "runner-accepted")
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .running,
      reason: "runner-started")

    let secondSnapshot = makeGreenReadings().snapshot(
      deviceID: job.targetDeviceID,
      observedAt: clock.now(),
      activeLoopID: job.logicalJobID,
      workers: [],
      sourceSnapshotSequence: 32,
      sourceSampleAttemptID: "sample-renew-midflight-2")
    let secondReceipt = try await issuer.issuePermit(
      job: job,
      request: issuer.makeAdmissionRequest(for: job, requestedAt: clock.now()),
      snapshot: secondSnapshot,
      runtime: runtime,
      baseRunnerEnvironment: testEnv)
    XCTAssertNotEqual(secondReceipt.permitID, firstReceipt.permitID)
    let revisionDir = TatwoRunnerPressurePermitFileWriterV1(
      directoryURL: issuer.permitsDirectoryURL())
      .revisionDirectoryURL(forJobID: job.jobID)
    let revisions = try FileManager.default.contentsOfDirectory(
      at: revisionDir,
      includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
    XCTAssertEqual(revisions.count, 2)

    let continuationController = TatwoRunnerPressureAdmissionControllerV1.production(
      channel: runnerChannel,
      trust: trust.runner,
      deviceID: job.targetDeviceID,
      stateRoot: stateRoot,
      environment: secondReceipt.runnerEnvironment)
    let continuation = continuationController.validatesContinuationAuthority(job: job)
    XCTAssertTrue(continuation.authorized, continuation.reasonCode)
    XCTAssertEqual(continuation.permitID, secondReceipt.permitID)
    XCTAssertEqual(continuation.consumption, originalConsumption)

    let receipts = try makeRunner(
      channel: runnerChannel,
      pressureAdmissionController: continuationController).runUntilIdle(maxPasses: 2)

    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts.first?.status, .completed)
    XCTAssertEqual(try runnerChannel.currentStatus(for: job.jobID), .completed)
    let result = try XCTUnwrap(try runnerChannel.resultForAudit(for: job.jobID))
    XCTAssertEqual(result.outputDigest, TatwoLoopJobDigest.sha256(expectedOutput))
    XCTAssertEqual(result.outputBytes, expectedOutput.count)
    XCTAssertEqual(try continuationController.ledger.load(jobID: job.jobID), originalConsumption)
  }

  func testAppRunnerPressurePermitIssuerConsumedPermitReplayIsRejectedByFreshController() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-app-issuer-consumed-replay",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let clock = TatwoPressureClockV1()
    let runtime = makePressureRuntime(
      deviceID: job.targetDeviceID,
      runtimeInstanceID: "runtime-app-issuer-consumed-replay",
      clock: clock)
    await runtime.start(reason: .test, startTimers: false)
    defer { Task { await runtime.stop(reason: .test) } }
    let issuer = TatwoAppRunnerPressurePermitIssuerV1(
      stateRoot: root.appendingPathComponent("state", isDirectory: true),
      targetDeviceID: job.targetDeviceID,
      trust: trust.appIssuer,
      issuerProcessIdentity: makePressureIssuerProcessIdentity(suffix: job.jobID),
      clock: clock)
    let snapshot = makeGreenReadings().snapshot(
      deviceID: job.targetDeviceID,
      observedAt: clock.now(),
      activeLoopID: nil,
      workers: [],
      sourceSnapshotSequence: 9,
      sourceSampleAttemptID: "sample-consumed-replay")
    let firstReceipt = try await issuer.issuePermit(
      job: job,
      request: issuer.makeAdmissionRequest(for: job, requestedAt: clock.now()),
      snapshot: snapshot,
      runtime: runtime,
      baseRunnerEnvironment: testEnv)
    let firstController = TatwoRunnerPressureAdmissionControllerV1.production(
      channel: runnerChannel,
      trust: trust.runner,
      deviceID: job.targetDeviceID,
      stateRoot: issuer.stateRoot,
      environment: firstReceipt.runnerEnvironment)

    let firstRun = try makeRunner(
      channel: runnerChannel,
      pressureAdmissionController: firstController).runUntilIdle()
    XCTAssertEqual(firstRun.count, 1)
    XCTAssertEqual(firstRun.first?.status, .completed)
    let consumed = try XCTUnwrap(firstController.ledger.load(jobID: job.jobID))

    let freshController = TatwoRunnerPressureAdmissionControllerV1.production(
      channel: runnerChannel,
      trust: trust.runner,
      deviceID: job.targetDeviceID,
      stateRoot: issuer.stateRoot,
      environment: firstReceipt.runnerEnvironment)
    XCTAssertFalse(freshController.hasConsumablePermit(job: job))
    XCTAssertEqual(try freshController.ledger.load(jobID: job.jobID), consumed)
    let probe = RemoteLoopPressureEngineProbeBox()
    let replay = try makeRunner(
      channel: runnerChannel,
      engine: RemoteLoopPressureCountingEngine(box: probe),
      pressureAdmissionController: freshController).runUntilIdle(maxPasses: 2)
    XCTAssertTrue(replay.isEmpty)
    XCTAssertEqual(probe.runCount(), 0)
    XCTAssertEqual(try runnerChannel.currentStatus(for: job.jobID), .completed)
  }

  func testAppRunnerPressurePermitIssuerRejectsTargetRunnerSigningAppPressurePermit() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-target-runner-signs-permit",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)

    XCTAssertThrowsError(
      try makePressurePermit(job: job, trust: trust.runner)
    ) { error in
      guard case TatwoRunnerPressureAdmissionErrorV1.invalidPermit(let detail) = error else {
        return XCTFail("expected target signing appPressurePermit to be invalid, got \(error)")
      }
      XCTAssertEqual(detail, "issuer signing key must be distinct from target runner device")
    }

    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { _ in nil },
      ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1(
        directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true)),
      trust: trust.runner,
      environment: testEnv)
    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: job,
      controller: controller)
  }

  func testAppRunnerPressurePermitIssuerRuntimeStoppedBeforePublishLeavesNoFinalPermitOrReceipt() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-app-issuer-stop-before-publish",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let clock = TatwoPressureClockV1()
    let runtime = makePressureRuntime(
      deviceID: job.targetDeviceID,
      runtimeInstanceID: "runtime-app-issuer-stop-before-publish",
      clock: clock)
    await runtime.start(reason: .test, startTimers: false)
    let issuer = TatwoAppRunnerPressurePermitIssuerV1(
      stateRoot: root.appendingPathComponent("state", isDirectory: true),
      targetDeviceID: job.targetDeviceID,
      trust: trust.appIssuer,
      issuerProcessIdentity: makePressureIssuerProcessIdentity(suffix: job.jobID),
      clock: clock)
    let snapshot = makeGreenReadings().snapshot(
      deviceID: job.targetDeviceID,
      observedAt: clock.now(),
      activeLoopID: nil,
      workers: [],
      sourceSnapshotSequence: 10,
      sourceSampleAttemptID: "sample-stop-before-publish")
    let revisionDir = TatwoRunnerPressurePermitFileWriterV1(
      directoryURL: issuer.permitsDirectoryURL())
      .revisionDirectoryURL(forJobID: job.jobID)
    var returnedReceipt: TatwoAppRunnerPressurePermitIssueReceiptV1?

    do {
      returnedReceipt = try await issuer.issuePermitWithPublishFence(
        job: job,
        request: issuer.makeAdmissionRequest(for: job, requestedAt: clock.now()),
        snapshot: snapshot,
        runtime: runtime,
        baseRunnerEnvironment: testEnv,
        beforePublish: {
          await runtime.stop(reason: .test)
        })
      XCTFail("runtime-stopped publish must fail closed")
    } catch TatwoRunnerPressureAdmissionErrorV1.issuerRuntimeNotCurrent(let reason) {
      XCTAssertEqual(reason, TatwoAppPressureRuntimeSpawnAuthorityValidationFailureV1.runtimeNotRunning.rawValue)
    } catch {
      XCTFail("expected issuerRuntimeNotCurrent, got \(error)")
    }

    XCTAssertNil(returnedReceipt)
    if FileManager.default.fileExists(atPath: revisionDir.path) {
      XCTAssertTrue(
        try FileManager.default.contentsOfDirectory(
          at: revisionDir,
          includingPropertiesForKeys: nil)
          .filter { $0.pathExtension == "json" }
          .isEmpty)
    }
  }

  func testAppRunnerPressurePermitIssuerRuntimeGenerationDriftBeforePublishLeavesNoFinalPermitOrReceipt() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-app-issuer-drift-before-publish",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let clock = TatwoPressureClockV1()
    let runtime = makePressureRuntime(
      deviceID: job.targetDeviceID,
      runtimeInstanceID: "runtime-app-issuer-drift-before-publish",
      clock: clock)
    await runtime.start(reason: .test, startTimers: false)
    defer { Task { await runtime.stop(reason: .test) } }
    let issuer = TatwoAppRunnerPressurePermitIssuerV1(
      stateRoot: root.appendingPathComponent("state", isDirectory: true),
      targetDeviceID: job.targetDeviceID,
      trust: trust.appIssuer,
      issuerProcessIdentity: makePressureIssuerProcessIdentity(suffix: job.jobID),
      clock: clock)
    let snapshot = makeGreenReadings().snapshot(
      deviceID: job.targetDeviceID,
      observedAt: clock.now(),
      activeLoopID: nil,
      workers: [],
      sourceSnapshotSequence: 11,
      sourceSampleAttemptID: "sample-drift-before-publish")
    let revisionDir = TatwoRunnerPressurePermitFileWriterV1(
      directoryURL: issuer.permitsDirectoryURL())
      .revisionDirectoryURL(forJobID: job.jobID)
    var returnedReceipt: TatwoAppRunnerPressurePermitIssueReceiptV1?

    do {
      returnedReceipt = try await issuer.issuePermitWithPublishFence(
        job: job,
        request: issuer.makeAdmissionRequest(for: job, requestedAt: clock.now()),
        snapshot: snapshot,
        runtime: runtime,
        baseRunnerEnvironment: testEnv,
        beforePublish: {
          await runtime.restart(reason: .test, startTimers: false)
        })
      XCTFail("runtime-generation drift must fail closed")
    } catch TatwoRunnerPressureAdmissionErrorV1.issuerRuntimeNotCurrent(let reason) {
      XCTAssertEqual(reason, TatwoAppPressureRuntimeSpawnAuthorityValidationFailureV1.runtimeGenerationMismatch.rawValue)
    } catch {
      XCTFail("expected issuerRuntimeNotCurrent, got \(error)")
    }

    XCTAssertNil(returnedReceipt)
    if FileManager.default.fileExists(atPath: revisionDir.path) {
      XCTAssertTrue(
        try FileManager.default.contentsOfDirectory(
          at: revisionDir,
          includingPropertiesForKeys: nil)
          .filter { $0.pathExtension == "json" }
          .isEmpty)
    }
  }

  func testRunnerPressureAdmissionProductionFactoryAcceptsCurrentIssuer() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-production-current",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let issuedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let permit = try makePressurePermit(job: job, trust: trust.appIssuer, issuedAt: issuedAt)
    let stateRoot = root.appendingPathComponent("state", isDirectory: true)
    let permitsURL = stateRoot
      .appendingPathComponent("pressure-admission", isDirectory: true)
      .appendingPathComponent(TatwoLoopPathComponent.sanitize(job.targetDeviceID), isDirectory: true)
      .appendingPathComponent("permits", isDirectory: true)
    let writer = TatwoRunnerPressurePermitFileWriterV1(directoryURL: permitsURL)
    _ = try writer.write(permit: permit)
    let controller = TatwoRunnerPressureAdmissionControllerV1.production(
      channel: runnerChannel,
      trust: trust.runner,
      deviceID: job.targetDeviceID,
      stateRoot: stateRoot,
      environment: productionIssuerEnvironment(for: permit))

    XCTAssertTrue(controller.hasConsumablePermit(job: job))
    let receipts = try makeRunner(
      channel: runnerChannel,
      pressureAdmissionController: controller).runUntilIdle()

    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts[0].status, .completed)
    XCTAssertEqual(try runnerChannel.currentStatus(for: job.jobID), .completed)
    XCTAssertNotNil(try runnerChannel.resultForAudit(for: job.jobID))
    let consumption = try XCTUnwrap(controller.ledger.load(jobID: job.jobID))
    XCTAssertEqual(consumption.permitID, permit.permitID)
    XCTAssertEqual(consumption.issuerIdentityDigest, permit.body.issuerIdentity.identityDigest)
  }

  func testRunnerPressureAdmissionDurableReplayAcrossFreshControllerDoesNotClaimOrSpawn() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-durable-replay",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let permit = try makePressurePermit(job: job, trust: trust.appIssuer)
    let ledgerURL = root.appendingPathComponent("pressure-consumed", isDirectory: true)
    let firstLedger = TatwoRunnerPressureAdmissionConsumptionLedgerV1(directoryURL: ledgerURL)
    _ = try firstLedger.consume(
      permit: permit,
      job: job,
      now: Date(timeIntervalSince1970: 1_700_000_101))
    let restartedController = TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitProviderV1 { _ in permit },
      ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1(directoryURL: ledgerURL),
      trust: trust.runner,
      clock: TatwoPressureClockV1(now: { Date(timeIntervalSince1970: 1_700_000_105) }),
      environment: testEnv)

    let existing = try XCTUnwrap(try firstLedger.load(jobID: job.jobID))
    try assertPressureRejectedWithoutSpawn(
      root: root,
      runnerChannel: runnerChannel,
      job: job,
      controller: restartedController,
      expectedExistingConsumption: existing)
  }

  func testRunnerPressureAdmissionInvalidConsumptionMarkerDoesNotPublishPoisonLedger() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-poison-ledger",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let permit = try makePressurePermit(job: job, trust: trust.appIssuer)
    let validLease = permit.body.lease
    let poisonedLease = TatwoPressureLeaseV1(
      schema: validLease.schema,
      pressurePolicyVersion: validLease.pressurePolicyVersion,
      leaseID: validLease.leaseID,
      deviceID: validLease.deviceID,
      issuer: validLease.issuer,
      issuedAt: validLease.issuedAt,
      expiresAt: validLease.expiresAt,
      snapshotObservedAt: validLease.snapshotObservedAt,
      snapshotDigest: validLease.snapshotDigest,
      sourceSnapshotSequence: validLease.sourceSnapshotSequence,
      sourceSampleAttemptID: validLease.sourceSampleAttemptID,
      classification: validLease.classification,
      reasonCodes: validLease.reasonCodes,
      runtimeInstanceID: validLease.runtimeInstanceID,
      runtimeGeneration: validLease.runtimeGeneration,
      admissionAttemptID: validLease.admissionAttemptID,
      admissionRequestBindingDigest: validLease.admissionRequestBindingDigest,
      dispatchNonce: validLease.dispatchNonce,
      reservationID: nil,
      leaseDigest: nil)
    let poisonedBody = TatwoRunnerPressureAdmissionPermitBodyV1(
      schema: permit.body.schema,
      pressurePolicyVersion: permit.body.pressurePolicyVersion,
      permitScope: permit.body.permitScope,
      issuedAt: permit.body.issuedAt,
      issuer: permit.body.issuer,
      issuerIdentity: permit.body.issuerIdentity,
      targetDeviceID: permit.body.targetDeviceID,
      jobID: permit.body.jobID,
      logicalJobID: permit.body.logicalJobID,
      dispatchNonce: permit.body.dispatchNonce,
      contractID: permit.body.contractID,
      goalID: permit.body.goalID,
      jobCanonicalDigest: permit.body.jobCanonicalDigest,
      requestBinding: permit.body.requestBinding,
      lease: poisonedLease,
      admissionDecision: permit.body.admissionDecision)
    let poisonedPermit = TatwoRunnerPressureAdmissionPermitV1(
      permitID: permit.permitID,
      body: poisonedBody,
      issuerSignature: permit.issuerSignature)
    let ledger = TatwoRunnerPressureAdmissionConsumptionLedgerV1(
      directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true))

    XCTAssertThrowsError(
      try ledger.consume(
        permit: poisonedPermit,
        job: job,
        now: Date(timeIntervalSince1970: 1_700_000_101))
    ) { error in
      guard case TatwoRunnerPressureAdmissionErrorV1.ledgerCorrupt(let jobID, let detail) = error else {
        return XCTFail("expected ledgerCorrupt before publish, got \(error)")
      }
      XCTAssertEqual(jobID, job.jobID)
      XCTAssertEqual(detail, "marker digest before publish")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.url(forJobID: job.jobID).path))
    XCTAssertNil(try ledger.load(jobID: job.jobID))
  }


  func testRunnerPressureAdmissionFileProviderUsesMonotonicPermitRevisionDespiteClockRollback() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-permit-clock-rollback",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let permitsURL = root.appendingPathComponent("pressure-permits", isDirectory: true)
    let writer = TatwoRunnerPressurePermitFileWriterV1(directoryURL: permitsURL)
    let first = try makePressurePermit(
      job: job,
      trust: trust.appIssuer,
      issuedAt: Date(timeIntervalSince1970: 1_700_000_200),
      sourceSnapshotSequence: 10,
      sourceSampleAttemptID: "sample-clock-rollback-10")
    let second = try makePressurePermit(
      job: job,
      trust: trust.appIssuer,
      issuedAt: Date(timeIntervalSince1970: 1_700_000_150),
      sourceSnapshotSequence: 11,
      sourceSampleAttemptID: "sample-clock-rollback-11")
    _ = try writer.write(permit: first)
    _ = try writer.write(permit: second)

    let loaded = try XCTUnwrap(
      try TatwoRunnerPressurePermitFileProviderV1(directoryURL: permitsURL).provider.permit(for: job))
    XCTAssertEqual(loaded.permitID, second.permitID)
    XCTAssertEqual(loaded.body.permitRevision, 11)
    XCTAssertLessThan(loaded.body.issuedAt, first.body.issuedAt)
  }

  func testRunnerPressureAdmissionFileProviderRejectsSameRevisionDifferentBytes() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-permit-same-revision-conflict",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let permitsURL = root.appendingPathComponent("pressure-permits", isDirectory: true)
    let writer = TatwoRunnerPressurePermitFileWriterV1(directoryURL: permitsURL)
    let first = try makePressurePermit(
      job: job,
      trust: trust.appIssuer,
      issuedAt: Date(timeIntervalSince1970: 1_700_000_100),
      sourceSnapshotSequence: 7,
      sourceSampleAttemptID: "sample-same-revision-a")
    let second = try makePressurePermit(
      job: job,
      trust: trust.appIssuer,
      issuedAt: Date(timeIntervalSince1970: 1_700_000_101),
      sourceSnapshotSequence: 7,
      sourceSampleAttemptID: "sample-same-revision-b")
    XCTAssertNotEqual(first.permitID, second.permitID)
    XCTAssertEqual(first.body.permitRevision, second.body.permitRevision)
    _ = try writer.write(permit: first)
    _ = try writer.write(permit: second)

    XCTAssertThrowsError(
      try TatwoRunnerPressurePermitFileProviderV1(directoryURL: permitsURL).provider.permit(for: job)
    ) { error in
      guard case TatwoRunnerPressureAdmissionErrorV1.invalidPermit(let detail) = error else {
        return XCTFail("expected invalidPermit conflict, got \(error)")
      }
      XCTAssertEqual(detail, "permit revision conflict")
    }
  }

  func testRunnerPressureAdmissionFileProviderRejectsLegacyAndRevisionCoexistence() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-permit-legacy-revision-conflict",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let permitsURL = root.appendingPathComponent("pressure-permits", isDirectory: true)
    let writer = TatwoRunnerPressurePermitFileWriterV1(directoryURL: permitsURL)
    let revision = try makePressurePermit(
      job: job,
      trust: trust.appIssuer,
      issuedAt: Date(timeIntervalSince1970: 1_700_000_100),
      sourceSnapshotSequence: 1)
    let legacy = try makePressurePermit(
      job: job,
      trust: trust.appIssuer,
      issuedAt: Date(timeIntervalSince1970: 1_700_000_101),
      sourceSnapshotSequence: 2)
    _ = try writer.write(permit: revision)
    try FileManager.default.createDirectory(at: permitsURL, withIntermediateDirectories: true)
    try TatwoPressureCanonicalJSONV1.data(legacy).write(to: writer.url(forJobID: job.jobID), options: .atomic)

    XCTAssertThrowsError(
      try TatwoRunnerPressurePermitFileProviderV1(directoryURL: permitsURL).provider.permit(for: job)
    ) { error in
      guard case TatwoRunnerPressureAdmissionErrorV1.invalidPermit(let detail) = error else {
        return XCTFail("expected invalidPermit legacy conflict, got \(error)")
      }
      XCTAssertEqual(detail, "legacy permit coexists with revisions")
    }
  }

  func testRunnerPressureAdmissionFuturePermitFailsClosedWithoutFallbackToOlderPermit() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-permit-future-no-fallback",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let permitsURL = root.appendingPathComponent("pressure-permits", isDirectory: true)
    let writer = TatwoRunnerPressurePermitFileWriterV1(directoryURL: permitsURL)
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let older = try makePressurePermit(
      job: job,
      trust: trust.appIssuer,
      issuedAt: now,
      sourceSnapshotSequence: 1)
    let future = try makePressurePermit(
      job: job,
      trust: trust.appIssuer,
      issuedAt: now.addingTimeInterval(120),
      sourceSnapshotSequence: 2)
    _ = try writer.write(permit: older)
    _ = try writer.write(permit: future)
    let provider = TatwoRunnerPressurePermitFileProviderV1(directoryURL: permitsURL).provider
    XCTAssertEqual(try provider.permit(for: job)?.permitID, future.permitID)
    let controller = TatwoRunnerPressureAdmissionControllerV1(
      provider: provider,
      ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1(
        directoryURL: root.appendingPathComponent("pressure-consumed", isDirectory: true)),
      trust: trust.runner,
      clock: TatwoPressureClockV1(now: { now }),
      environment: testEnv)

    XCTAssertFalse(controller.hasConsumablePermit(job: job))
    let receipts = try makeRunner(
      channel: runnerChannel,
      pressureAdmissionController: controller).runUntilIdle(maxPasses: 2)
    XCTAssertTrue(receipts.isEmpty)
    XCTAssertEqual(try runnerChannel.currentStatus(for: job.jobID), .queued)
    XCTAssertNil(try controller.ledger.load(jobID: job.jobID))
  }

  func testRunnerPressureAdmissionFileProviderRejectsPermitReplacementDuringRead() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-file-race",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let permitsURL = root.appendingPathComponent("pressure-permits", isDirectory: true)
    let writer = TatwoRunnerPressurePermitFileWriterV1(directoryURL: permitsURL)
    let first = try makePressurePermit(job: job, trust: trust.appIssuer)
    let duplicateURL = try writer.write(permit: first)
    let provider = TatwoRunnerPressurePermitFileProviderV1(
      directoryURL: permitsURL,
      afterPreflightReadHook: { url in
        XCTAssertEqual(
          url.resolvingSymlinksInPath().path,
          duplicateURL.resolvingSymlinksInPath().path)
        try Data("{}".utf8).write(to: url, options: .atomic)
      }).provider
    XCTAssertThrowsError(try provider.permit(for: job))
  }

  func testPressurePermitCanonicalJSONPreservesFractionalDatesAndRejectsOldISOArtifact() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-fractional-canonical",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let issuedAt = Date(timeIntervalSince1970: 1_786_438_000.25)
    let permit = try makePressurePermit(job: job, trust: trust.appIssuer, issuedAt: issuedAt)
    let permitsURL = root.appendingPathComponent("pressure-permits", isDirectory: true)
    let writer = TatwoRunnerPressurePermitFileWriterV1(directoryURL: permitsURL)
    let permitURL = try writer.write(permit: permit)
    let canonicalBytes = try Data(contentsOf: permitURL)
    let canonicalJSON = String(data: canonicalBytes, encoding: .utf8) ?? ""

    XCTAssertTrue(canonicalJSON.contains("\"issuedAt\":\"1786438000.25\""), canonicalJSON)
    XCTAssertTrue(canonicalJSON.contains("\"snapshotObservedAt\":\"1786438000.25\""), canonicalJSON)
    let bodyJSON = try assertPressurePermitRawBodyUsesCanonicalDateStrings(canonicalBytes)
    XCTAssertTrue(bodyJSON.contains("\"issuedAt\":\"1786438000.25\""), bodyJSON)
    XCTAssertTrue(bodyJSON.contains("\"snapshotObservedAt\":\"1786438000.25\""), bodyJSON)
    XCTAssertEqual(
      TatwoLoopJobDigest.sha256(try TatwoRunnerPressureAdmissionPermitV1.canonicalJSONData(permit.body)),
      permit.permitID)
    XCTAssertEqual(
      permit.issuerSignature.signedAt,
      TatwoLoopJobChannelTrust.iso8601(permit.body.issuedAt))
    XCTAssertEqual(
      permit.issuerSignature.payloadDigest,
      TatwoLoopJobChannelTrust.sha256Hex(
        try TatwoRunnerPressureAdmissionPermitV1.canonicalJSONData(permit.body)))

    let loaded = try XCTUnwrap(
      try TatwoRunnerPressurePermitFileProviderV1(directoryURL: permitsURL).provider.permit(for: job))
    XCTAssertEqual(loaded.permitID, permit.permitID)

    let oldCodecRoot = root.appendingPathComponent("old-codec", isDirectory: true)
    try FileManager.default.createDirectory(at: oldCodecRoot, withIntermediateDirectories: true)
    let oldCodecURL = oldCodecRoot.appendingPathComponent("\(TatwoLoopPathComponent.sanitize(job.jobID)).json")
    let oldEncoder = JSONEncoder()
    oldEncoder.dateEncodingStrategy = .iso8601
    oldEncoder.outputFormatting = [.sortedKeys]
    try oldEncoder.encode(permit).write(to: oldCodecURL, options: .atomic)
    let oldProvider = TatwoRunnerPressurePermitFileProviderV1(directoryURL: oldCodecRoot).provider
    XCTAssertThrowsError(try oldProvider.permit(for: job))
  }

  func testPressurePermitDateOnlyTamperFailsPermitLeaseDecisionAndLedgerRehydration() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-date-tamper",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let issuedAt = Date(timeIntervalSince1970: 1_786_438_000.25)
    let permit = try makePressurePermit(job: job, trust: trust.appIssuer, issuedAt: issuedAt)
    let bodyDigest = try TatwoLoopJobDigest.sha256(
      TatwoRunnerPressureAdmissionPermitV1.canonicalJSONData(permit.body))
    XCTAssertEqual(bodyDigest, permit.permitID)
    XCTAssertTrue(permit.body.requestBinding.verifiesRequest())
    XCTAssertTrue(permit.body.lease.verifiesDigest())

    var tamperedLease = permit.body.lease
    tamperedLease = TatwoPressureLeaseV1(
      schema: tamperedLease.schema,
      pressurePolicyVersion: tamperedLease.pressurePolicyVersion,
      leaseID: tamperedLease.leaseID,
      deviceID: tamperedLease.deviceID,
      issuer: tamperedLease.issuer,
      issuedAt: tamperedLease.issuedAt.addingTimeInterval(0.25),
      expiresAt: tamperedLease.expiresAt,
      snapshotObservedAt: tamperedLease.snapshotObservedAt,
      snapshotDigest: tamperedLease.snapshotDigest,
      sourceSnapshotSequence: tamperedLease.sourceSnapshotSequence,
      sourceSampleAttemptID: tamperedLease.sourceSampleAttemptID,
      classification: tamperedLease.classification,
      reasonCodes: tamperedLease.reasonCodes,
      runtimeInstanceID: tamperedLease.runtimeInstanceID,
      runtimeGeneration: tamperedLease.runtimeGeneration,
      admissionAttemptID: tamperedLease.admissionAttemptID,
      admissionRequestBindingDigest: tamperedLease.admissionRequestBindingDigest,
      dispatchNonce: tamperedLease.dispatchNonce,
      reservationID: tamperedLease.reservationID,
      leaseDigest: tamperedLease.leaseDigest)
    XCTAssertFalse(tamperedLease.verifiesDigest())

    let tamperedBody = TatwoRunnerPressureAdmissionPermitBodyV1(
      schema: permit.body.schema,
      pressurePolicyVersion: permit.body.pressurePolicyVersion,
      permitScope: permit.body.permitScope,
      issuedAt: permit.body.issuedAt,
      issuer: permit.body.issuer,
      issuerIdentity: permit.body.issuerIdentity,
      targetDeviceID: permit.body.targetDeviceID,
      jobID: permit.body.jobID,
      logicalJobID: permit.body.logicalJobID,
      dispatchNonce: permit.body.dispatchNonce,
      contractID: permit.body.contractID,
      goalID: permit.body.goalID,
      jobCanonicalDigest: permit.body.jobCanonicalDigest,
      requestBinding: permit.body.requestBinding,
      lease: tamperedLease,
      admissionDecision: permit.body.admissionDecision)
    let tamperedPermit = TatwoRunnerPressureAdmissionPermitV1(
      permitID: permit.permitID,
      body: tamperedBody,
      issuerSignature: permit.issuerSignature)
    XCTAssertThrowsError(
      try tamperedPermit.validate(
        for: job,
        trust: trust.runner,
        now: issuedAt.addingTimeInterval(1),
        environment: testEnv))

    let ledgerURL = root.appendingPathComponent("pressure-consumed", isDirectory: true)
    let ledger = TatwoRunnerPressureAdmissionConsumptionLedgerV1(directoryURL: ledgerURL)
    _ = try ledger.consume(permit: permit, job: job, now: issuedAt.addingTimeInterval(1))
    let markerURL = ledger.url(forJobID: job.jobID)
    let markerJSON = String(data: try Data(contentsOf: markerURL), encoding: .utf8)!
    XCTAssertTrue(markerJSON.contains("1786438001.25"), markerJSON)
    let tamperedMarkerJSON = markerJSON.replacingOccurrences(of: "1786438001.25", with: "1786438001.5")
    try Data(tamperedMarkerJSON.utf8).write(to: markerURL, options: .atomic)
    XCTAssertThrowsError(try ledger.load(jobID: job.jobID))
  }

  func testRunnerPressureAdmissionFileProviderAcceptsStablePermitBytes() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-pressure-file-stable",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let permitsURL = root.appendingPathComponent("pressure-permits", isDirectory: true)
    let writer = TatwoRunnerPressurePermitFileWriterV1(directoryURL: permitsURL)
    let first = try makePressurePermit(job: job, trust: trust.appIssuer)
    _ = try writer.write(permit: first)
    let provider = TatwoRunnerPressurePermitFileProviderV1(directoryURL: permitsURL).provider
    let loaded = try XCTUnwrap(try provider.permit(for: job))
    XCTAssertEqual(loaded.permitID, first.permitID)
  }

  func testSchemaRoundTripsAndTatwoLoopIsDisabled() throws {
    let root = makeRoot()
    let job = makeJob(
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .xl,
          taskDescription: "run the remote Work OS loop")),
      workPath: root)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(job)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["schema"] as? String, "TatwoLoopJobV1")
    XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    XCTAssertEqual(object["jobID"] as? String, "job-success")
    let payloadObject = try XCTUnwrap(object["payload"] as? [String: Any])
    XCTAssertEqual(payloadObject["kind"] as? String, "tatwo-loop")
    XCTAssertEqual(payloadObject["contractID"] as? String, contractID)
    XCTAssertEqual(payloadObject["goalID"] as? String, goalID)
    XCTAssertEqual(payloadObject["identity"] as? String, "sub")
    XCTAssertEqual(payloadObject["mode"] as? String, "XL")
    XCTAssertEqual(
      payloadObject["taskDescription"] as? String,
      "run the remote Work OS loop")
    XCTAssertNil(payloadObject["engineBinding"])
    XCTAssertNil(payloadObject["agent"])
    XCTAssertEqual(
      Set(payloadObject.keys),
      Set(["kind", "contractID", "goalID", "identity", "mode", "taskDescription"]))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(TatwoLoopJobV1.self, from: data)
    guard case let .tatwoLoop(payload) = decoded.payload else {
      return XCTFail("expected tatwo-loop payload")
    }
    XCTAssertEqual(payload.contractID, contractID)
    XCTAssertEqual(payload.goalID, goalID)
    XCTAssertEqual(payload.identity, .sub)
    XCTAssertEqual(payload.mode, .xl)
    XCTAssertEqual(payload.taskDescription, "run the remote Work OS loop")
    XCTAssertNil(payload.agent)
    XCTAssertTrue(payload.isDisabled)

    // Optional agent field round-trips when present (remote compute intent).
    let withAgent = makeJob(
      jobID: "job-agent",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .m,
          taskDescription: "run agent task",
          agent: .grok,
          exactModelRouteID: "grok-build")),
      workPath: root)
    let agentData = try encoder.encode(withAgent)
    let agentObject = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: agentData) as? [String: Any])
    let agentPayload = try XCTUnwrap(agentObject["payload"] as? [String: Any])
    XCTAssertEqual(agentPayload["agent"] as? String, "grok")
    XCTAssertEqual(agentPayload["exactModelRouteID"] as? String, "grok-build")
    XCTAssertEqual(
      Set(agentPayload.keys),
      Set([
        "kind", "contractID", "goalID", "identity", "mode", "taskDescription",
        "agent", "exactModelRouteID",
      ]))
    let decodedAgent = try decoder.decode(TatwoLoopJobV1.self, from: agentData)
    guard case let .tatwoLoop(agentLoop) = decodedAgent.payload else {
      return XCTFail("expected tatwo-loop with agent")
    }
    XCTAssertEqual(agentLoop.agent, .grok)
    XCTAssertEqual(agentLoop.exactModelRouteID, "grok-build")
  }

  func testExactModelRouteIsSignedAndCrossBrandRouteIsRejected() throws {
    let root = makeRoot()
    let fable = makeJob(
      jobID: "job-exact-model",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .m,
          taskDescription: "exact route",
          agent: .claude,
          exactModelRouteID: "fable-5")),
      workPath: root)
    let opus = makeJob(
      jobID: fable.jobID,
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .m,
          taskDescription: "exact route",
          agent: .claude,
          exactModelRouteID: "opus-5")),
      workPath: root)
    XCTAssertNotEqual(try fable.canonicalDigest(), try opus.canonicalDigest())

    let wrongBrand = TatwoLoopPayloadV1(
      contractID: contractID,
      goalID: goalID,
      identity: .sub,
      mode: .m,
      taskDescription: "wrong brand",
      agent: .claude,
      exactModelRouteID: "gpt-5.6-sol")
    XCTAssertThrowsError(try wrongBrand.validate())
  }

  func testXXLModeRoundTripsValidatesAndCannotDowngradeToXL() throws {
    let root = makeRoot()
    let xxl = makeJob(
      jobID: "job-xxl-mode",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .xxl,
          taskDescription: "orchestrated XXL loop")),
      workPath: root)
    let xl = makeJob(
      jobID: xxl.jobID,
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .xl,
          taskDescription: "orchestrated XXL loop")),
      workPath: root)

    try xxl.validate()
    XCTAssertNotEqual(try xxl.canonicalDigest(), try xl.canonicalDigest())
    let data = try JSONEncoder().encode(xxl)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let payload = try XCTUnwrap(object["payload"] as? [String: Any])
    XCTAssertEqual(payload["mode"] as? String, "XXL")
    let decoded = try JSONDecoder().decode(TatwoLoopJobV1.self, from: data)
    guard case let .tatwoLoop(loop) = decoded.payload else {
      return XCTFail("expected tatwo-loop payload")
    }
    XCTAssertEqual(loop.mode, .xxl)
    XCTAssertTrue(TatwoLoopModeV1.allCases.contains(.xxl))
  }

  func testLegacyEnginePayloadKindIsRejectedAsUnknown() throws {
    let legacyKind = ["codex", "exec"].joined(separator: "-")
    let legacyJSON = """
      {"kind":"\(legacyKind)","command":"engine","arguments":["unsafe"]}
      """

    XCTAssertThrowsError(
      try JSONDecoder().decode(
        TatwoLoopJobPayloadV1.self,
        from: Data(legacyJSON.utf8))
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopJobStateError,
        .invalidPayload("unknown kind \(legacyKind)"))
    }
  }

  func testStateMachineRejectsSkippingAndAllowsTerminalVerification() throws {
    XCTAssertThrowsError(
      try TatwoLoopJobStateMachine.validate(
        from: .queued,
        to: .running)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopJobStateError,
        .invalidTransition(from: .queued, to: .running))
    }

    XCTAssertNoThrow(
      try TatwoLoopJobStateMachine.validate(
        from: .failed,
        to: .verified))
    XCTAssertThrowsError(
      try TatwoLoopJobStateMachine.validate(
        from: .verified,
        to: .running))
  }

  func testChannelUsesAtomicJobAckAndAppendOnlyJournal() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work", isDirectory: true)
    let trust = try makeTrustPair(root: root)
    let channel = TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel"),
      trust: trust.origin,
      environment: testEnv)
    let job = makeJob(
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["hello"])),
      workPath: work)

    _ = try channel.enqueue(job)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: channel.jobURL(for: job).path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: channel.jobSignatureURL(for: job).path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: channel.ackSignatureURL(forJobID: job.jobID).path))
    XCTAssertEqual(try channel.currentStatus(for: job.jobID), .queued)

    _ = try channel.transition(jobID: job.jobID, to: .delivered, reason: "runner-discovered")
    _ = try channel.transition(jobID: job.jobID, to: .accepted, reason: "runner-accepted")
    let ack = try XCTUnwrap(channel.ack(for: job.jobID))
    XCTAssertEqual(ack.status, .accepted)

    let journal = try channel.journal(for: job.jobID)
    XCTAssertEqual(
      journal.map(\.to),
      [.queued, .delivered, .accepted])
    XCTAssertFalse(
      (try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("channel"),
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]))
      .contains { $0.pathExtension == "tmp" })
  }

  func testCancellationJournalRecoversAfterAuthoritativeBundleCrash() throws {
    try assertCancellationJournalRecovery(after: .afterAuthoritativeBundle)
  }

  func testCancellationJournalRecoversAfterCanonicalBodyBeforeSidecarCrash() throws {
    try assertCancellationJournalRecovery(after: .afterCanonicalBody)
  }

  func testTerminalResultJournalRecoversAfterAuthoritativeBundleCrash() throws {
    try assertTerminalResultJournalRecovery(after: .afterAuthoritativeBundle)
  }

  func testTerminalResultJournalRecoversAfterCanonicalBodyBeforeSidecarCrash() throws {
    try assertTerminalResultJournalRecovery(after: .afterCanonicalBody)
  }

  func testOriginOwnedCancelledWithoutTargetResultConvergesAndProjects() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-origin-cancel-no-target-result",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
    _ = try origin.enqueue(job)
    XCTAssertEqual(try originChannel.signalCancel(for: job), .cancelled)
    XCTAssertNil(try originChannel.resultForAudit(for: job.jobID))
    XCTAssertEqual(try originChannel.ack(for: job.jobID)?.status, .cancelled)
    XCTAssertNil(try originChannel.ack(for: job.jobID)?.result)

    XCTAssertEqual(try origin.converge(jobID: job.jobID), .cancelled)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: originChannel.resultConsumeMarkerURL(forJobID: job.jobID).path))
    let projected = try XCTUnwrap(
      try registry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertEqual(projected.remoteStatus, .cancelled)
    XCTAssertNil(projected.receiptID)
    XCTAssertNil(projected.consumedResultDigest)
  }

  private func assertCancellationJournalRecovery(
    after faultPoint: TatwoLoopJournalFaultPoint
  ) throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let fault = TatwoLoopJournalFaultBox()
    let crashingOrigin = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: trust.origin,
      environment: testEnv,
      journalFaultBox: fault)
    let recoveredOrigin = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-cancel-journal-\(faultPoint.rawValue)",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: crashingOrigin,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
    _ = try origin.enqueue(job)

    fault.setFailAt(faultPoint)
    XCTAssertThrowsError(try crashingOrigin.signalCancel(for: job))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: crashingOrigin.journalBundleURL(forJobID: job.jobID).path))

    XCTAssertEqual(
      try recoveredOrigin.signalCancel(for: job),
      .terminalWon(.cancelled))
    XCTAssertEqual(try recoveredOrigin.currentStatus(for: job.jobID), .cancelled)
    XCTAssertEqual(try recoveredOrigin.ack(for: job.jobID)?.status, .cancelled)
    XCTAssertNil(try recoveredOrigin.resultForAudit(for: job.jobID))
    XCTAssertEqual(try origin.converge(jobID: job.jobID), .cancelled)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: recoveredOrigin.resultConsumeMarkerURL(forJobID: job.jobID).path))
    let projected = try XCTUnwrap(
      try registry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertEqual(projected.remoteStatus, .cancelled)
    XCTAssertNil(projected.receiptID)
  }

  private func assertTerminalResultJournalRecovery(
    after faultPoint: TatwoLoopJournalFaultPoint
  ) throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let fault = TatwoLoopJournalFaultBox()
    let crashingRunner = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: trust.runner,
      environment: testEnv,
      journalFaultBox: fault)
    let recoveredRunner = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-terminal-journal-\(faultPoint.rawValue)",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
    _ = try origin.enqueue(job)
    _ = try crashingRunner.transition(
      jobID: job.jobID,
      to: .delivered,
      reason: "runner-discovered")
    _ = try crashingRunner.transition(
      jobID: job.jobID,
      to: .accepted,
      reason: "runner-accepted")
    _ = try crashingRunner.transition(
      jobID: job.jobID,
      to: .running,
      reason: "runner-started")
    let receipt = try TatwoLoopJobResultReceiptV1(
      job: job,
      projectionSequence: 5,
      status: .completed,
      outputDigest: nil,
      outputBytes: 0,
      exitCode: 0,
      failureCode: nil,
      message: "completed before injected journal projection crash",
      startedAt: Date(timeIntervalSince1970: 1_700_000_001),
      finishedAt: Date(timeIntervalSince1970: 1_700_000_002))

    fault.setFailAt(faultPoint)
    XCTAssertThrowsError(
      try crashingRunner.transition(
        jobID: job.jobID,
        to: .completed,
        reason: "runner-finished:completed",
        result: receipt,
        now: receipt.finishedAt))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: crashingRunner.journalBundleURL(forJobID: job.jobID).path))

    XCTAssertEqual(try recoveredRunner.currentStatus(for: job.jobID), .completed)
    XCTAssertEqual(
      try recoveredRunner.journal(for: job.jobID).map(\.to),
      [.queued, .delivered, .accepted, .running, .completed])
    _ = try recoveredRunner.transition(
      jobID: job.jobID,
      to: .completed,
      reason: "runner-finished:completed",
      result: receipt,
      now: receipt.finishedAt)
    XCTAssertEqual(
      try recoveredRunner.resultForAudit(for: job.jobID),
      receipt)
    XCTAssertEqual(try origin.converge(jobID: job.jobID), .verified)
  }

  func testRunnerFailsOnTimeoutAndOriginVerifiesProjection() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-timeout",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .sleep, arguments: ["1"])),
      workPath: work,
      maxDurationSec: 0.05)
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state"))
    let openGate = allowGate(
      journal: root.appendingPathComponent("origin-state"))
    let originOpen = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: job.originDeviceID,
      memoryGate: openGate)
    _ = try originOpen.enqueue(job)
    let receipts = try makeRunner(channel: runnerChannel).runUntilIdle()
    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts[0].status, .failed)
    XCTAssertEqual(receipts[0].failureCode, "timeout")

    XCTAssertNotNil(try runnerChannel.result(for: job.jobID))

    XCTAssertEqual(try originOpen.converge(jobID: job.jobID), .failed)
    XCTAssertEqual(
      try originChannel.journal(for: job.jobID).map(\.to),
      [.queued, .delivered, .accepted, .running, .failed])
    let record = try XCTUnwrap(
      try registry.run(forContractID: contractID)?.records.first)
    XCTAssertEqual(record.originDeviceID, "origin-sandbox")
    XCTAssertEqual(record.targetDeviceID, "runner-sandbox")
    XCTAssertEqual(record.remoteStatus, .failed)
    XCTAssertEqual(record.status, .failed)
  }

  func testRunnerHonorsCancelFileAndNeverExecutesTatwoLoopPayload() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let cancelJob = makeJob(
      jobID: "job-cancel",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .sleep, arguments: ["1"])),
      workPath: work)
    let tatwoLoopJob = makeJob(
      jobID: "job-tatwo-loop",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .xl,
          taskDescription: "disabled remote Work OS loop")),
      workPath: work)

    _ = try originChannel.enqueue(cancelJob)
    _ = try originChannel.enqueue(tatwoLoopJob)
    try originChannel.signalCancel(for: cancelJob.jobID)

    // Production path: env unset → tatwo-loop stays disabled (R3-C fail-closed).
    let receipts = try makeRunner(
      channel: runnerChannel,
      environment: [:]).runUntilIdle()
    let byID = Dictionary(uniqueKeysWithValues: receipts.map { ($0.jobID, $0) })
    XCTAssertNil(
      byID[cancelJob.jobID],
      "origin-owned cancellation must not fabricate a target-signed result receipt")
    XCTAssertEqual(
      try runnerChannel.ack(for: cancelJob.jobID)?.status,
      .cancelled)
    XCTAssertEqual(byID[tatwoLoopJob.jobID]?.status, .failed)
    XCTAssertEqual(byID[tatwoLoopJob.jobID]?.failureCode, "tatwo_loop_disabled")
    XCTAssertEqual(
      try runnerChannel.currentStatus(for: cancelJob.jobID),
      .cancelled)
    XCTAssertEqual(
      try runnerChannel.currentStatus(for: tatwoLoopJob.jobID),
      .failed)
  }

  func testCancelTombstoneBodyOnlyCrashRecoversAndPreventsCommitMarker() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let fault = TatwoLoopCancelFaultBox(failAt: .afterBody)
    let crashing = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: trust.origin,
      environment: testEnv,
      cancelFaultBox: fault)
    let recovered = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-cancel-body-crash",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)

    XCTAssertThrowsError(try crashing.signalCancel(for: job))
    XCTAssertTrue(FileManager.default.fileExists(atPath: crashing.cancelURL(forJobID: job.jobID).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: crashing.cancelSignatureURL(forJobID: job.jobID).path))

    XCTAssertEqual(try recovered.signalCancel(for: job), .cancelled)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: recovered.cancelSignatureURL(forJobID: job.jobID).path))
    XCTAssertThrowsError(try recovered.enqueue(job))
    XCTAssertFalse(recovered.hasCommitMarker(forJobID: job.jobID))
  }

  func testAttackerBodyOnlyDoesNotGetSignedOrSuppressGenericEnqueue() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let origin = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runner = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-attacker-body-enqueue",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let tombstone = TatwoLoopCancelTombstoneV1(
      jobID: job.jobID,
      logicalJobID: job.logicalJobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      reason: "origin-cancel-requested",
      requestedAt: job.createdAt)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let bodyURL = origin.cancelURL(forJobID: job.jobID)
    try FileManager.default.createDirectory(
      at: bodyURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try encoder.encode(tombstone).write(to: bodyURL, options: .atomic)

    _ = try origin.enqueue(job)

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: origin.cancelSignatureURL(forJobID: job.jobID).path))
    XCTAssertTrue(origin.hasCommitMarker(forJobID: job.jobID))
    XCTAssertTrue(try runner.isReadyForTargetExecution(job: job))
    XCTAssertFalse(runner.isCancelRequested(for: job))
    XCTAssertEqual(try makeRunner(channel: runner).runUntilIdle().first?.status, .completed)
  }

  func testSignatureWithoutBodyDoesNotHardFailGenericEnqueue() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let origin = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runner = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-orphan-cancel-signature",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let signature = try trust.origin.sign(
      payload: Data("orphan-cancel-signature".utf8),
      purpose: .loopAck)
    let signatureURL = origin.cancelSignatureURL(forJobID: job.jobID)
    try FileManager.default.createDirectory(
      at: signatureURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(signature).write(to: signatureURL, options: .atomic)

    _ = try origin.enqueue(job)

    XCTAssertTrue(origin.hasCommitMarker(forJobID: job.jobID))
    XCTAssertTrue(try runner.isReadyForTargetExecution(job: job))
    XCTAssertEqual(try makeRunner(channel: runner).runUntilIdle().first?.status, .completed)
    XCTAssertTrue(
      try runner.rejections(for: job.jobID).contains {
        $0.artifact == .cancel && $0.reason == .invalidSignature
      })
  }

  func testOldSignedCancelReplayAgainstNewAttemptIsNonAuthoritative() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let origin = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runner = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let logicalJobID = "logical-cancel-replay"
    let oldJob = makeJob(
      jobID: "job-cancel-replay-old",
      logicalJobID: logicalJobID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work,
      dispatchNonce: "nonce-cancel-replay-old")
    XCTAssertEqual(try origin.signalCancel(for: oldJob), .cancelled)

    let newJob = makeJob(
      jobID: "job-cancel-replay-new",
      logicalJobID: logicalJobID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work,
      dispatchNonce: "nonce-cancel-replay-new")
    let replayBodyURL = origin.cancelURL(forJobID: newJob.jobID)
    let replaySignatureURL = origin.cancelSignatureURL(forJobID: newJob.jobID)
    try FileManager.default.createDirectory(
      at: replayBodyURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: replaySignatureURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data(contentsOf: origin.cancelURL(forJobID: oldJob.jobID))
      .write(to: replayBodyURL, options: .atomic)
    try Data(contentsOf: origin.cancelSignatureURL(forJobID: oldJob.jobID))
      .write(to: replaySignatureURL, options: .atomic)

    _ = try origin.enqueue(newJob)

    XCTAssertTrue(origin.hasCommitMarker(forJobID: newJob.jobID))
    XCTAssertFalse(runner.isCancelRequested(for: newJob))
    XCTAssertTrue(try runner.isReadyForTargetExecution(job: newJob))
    XCTAssertEqual(try makeRunner(channel: runner).runUntilIdle().first?.status, .completed)
  }

  func testCancelRejectionsDeduplicateAcrossJournalAndStayBounded() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let origin = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runner = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-cancel-reject-bound",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try origin.enqueue(job)
    let tombstone = TatwoLoopCancelTombstoneV1(
      jobID: job.jobID,
      logicalJobID: job.logicalJobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      reason: "origin-cancel-requested",
      requestedAt: job.createdAt)
    let cancelEncoder = JSONEncoder()
    cancelEncoder.dateEncodingStrategy = .iso8601
    cancelEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let bodyURL = origin.cancelURL(forJobID: job.jobID)
    try FileManager.default.createDirectory(
      at: bodyURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try cancelEncoder.encode(tombstone).write(to: bodyURL, options: .atomic)
    let signatureURL = origin.cancelSignatureURL(forJobID: job.jobID)
    try FileManager.default.createDirectory(
      at: signatureURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)

    for _ in 0..<20 {
      try? FileManager.default.removeItem(at: signatureURL)
      XCTAssertFalse(runner.isCancelRequested(for: job))
      try Data("{malformed-sidecar".utf8).write(to: signatureURL, options: .atomic)
      XCTAssertFalse(runner.isCancelRequested(for: job))
    }
    XCTAssertEqual(try runner.rejections(for: job.jobID).count, 2)

    let rejectURL = runner.rejectJournalURL(forJobID: job.jobID)
    let rejectEncoder = JSONEncoder()
    rejectEncoder.dateEncodingStrategy = .iso8601
    rejectEncoder.outputFormatting = [.sortedKeys]
    var seeded = Data()
    for index in 0..<64 {
      var line = try rejectEncoder.encode(
        TatwoLoopJobRejectEntryV1(
          jobID: job.jobID,
          artifact: .cancel,
          reason: .invalidSignature,
          detail: "seed-\(index)",
          occurredAt: job.createdAt))
      line.append(Data("\n".utf8))
      seeded.append(line)
    }
    try seeded.write(to: rejectURL, options: .atomic)
    try Data("{another-malformed-sidecar".utf8).write(to: signatureURL, options: .atomic)
    XCTAssertFalse(runner.isCancelRequested(for: job))
    XCTAssertEqual(try runner.rejections(for: job.jobID).count, 64)
  }

  func testCancelBodyOnlyIsRejectedButDoesNotSuppressTargetReadiness() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let fault = TatwoLoopCancelFaultBox(failAt: .afterBody)
    let origin = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: trust.origin,
      environment: testEnv,
      cancelFaultBox: fault)
    let runner = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-cancel-body-readiness",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)

    _ = try origin.enqueue(job)
    XCTAssertThrowsError(try origin.signalCancel(for: job))
    XCTAssertTrue(try runner.isReadyForTargetExecution(job: job))
    XCTAssertFalse(runner.isCancelRequested(for: job))
    let rejects = try runner.rejections(for: job.jobID)
    XCTAssertTrue(
      rejects.contains { $0.artifact == .cancel && $0.reason == .missingSignature })

    let receipts = try makeRunner(channel: runner).runUntilIdle()
    XCTAssertEqual(receipts.first?.status, .completed)
    XCTAssertEqual(try runner.currentStatus(for: job.jobID), .completed)
  }

  func testForgedCancelSignatureIsRejectedButDoesNotSuppressExecution() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let fault = TatwoLoopCancelFaultBox(failAt: .afterBody)
    let origin = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: trust.origin,
      environment: testEnv,
      cancelFaultBox: fault)
    let runner = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-cancel-forged-signature",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)

    _ = try origin.enqueue(job)
    XCTAssertThrowsError(try origin.signalCancel(for: job))
    let body = try Data(contentsOf: origin.cancelURL(forJobID: job.jobID))
    let forged = try trust.runner.sign(payload: body, purpose: .loopAck)
    let signatureURL = origin.cancelSignatureURL(forJobID: job.jobID)
    try FileManager.default.createDirectory(
      at: signatureURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(forged).write(to: signatureURL, options: .atomic)

    XCTAssertTrue(try runner.isReadyForTargetExecution(job: job))
    XCTAssertFalse(runner.isCancelRequested(for: job))
    let rejects = try runner.rejections(for: job.jobID)
    XCTAssertTrue(
      rejects.contains { $0.artifact == .cancel && $0.reason == .producerMismatch })

    let receipts = try makeRunner(channel: runner).runUntilIdle()
    XCTAssertEqual(receipts.first?.status, .completed)
    XCTAssertEqual(try runner.currentStatus(for: job.jobID), .completed)
  }

  func testMalformedCancelSignatureIsRejectedButDoesNotSuppressExecution() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let fault = TatwoLoopCancelFaultBox(failAt: .afterBody)
    let origin = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: trust.origin,
      environment: testEnv,
      cancelFaultBox: fault)
    let runner = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-cancel-malformed-signature",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)

    _ = try origin.enqueue(job)
    XCTAssertThrowsError(try origin.signalCancel(for: job))
    let signatureURL = origin.cancelSignatureURL(forJobID: job.jobID)
    try FileManager.default.createDirectory(
      at: signatureURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data("{malformed-sidecar".utf8).write(to: signatureURL, options: .atomic)

    XCTAssertTrue(try runner.isReadyForTargetExecution(job: job))
    XCTAssertFalse(runner.isCancelRequested(for: job))
    let rejects = try runner.rejections(for: job.jobID)
    XCTAssertTrue(
      rejects.contains { $0.artifact == .cancel && $0.reason == .invalidSignature })

    let receipts = try makeRunner(channel: runner).runUntilIdle()
    XCTAssertEqual(receipts.first?.status, .completed)
    XCTAssertEqual(try runner.currentStatus(for: job.jobID), .completed)
  }

  func testValidSignedCancelSuppressesTargetReadiness() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let origin = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runner = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-cancel-valid-readiness",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)

    _ = try origin.enqueue(job)
    XCTAssertEqual(try origin.signalCancel(for: job), .cancelled)
    XCTAssertFalse(try runner.isReadyForTargetExecution(job: job))
    XCTAssertTrue(runner.isCancelRequested(for: job))
    XCTAssertTrue(try runner.rejections(for: job.jobID).isEmpty)
    XCTAssertTrue(try makeRunner(channel: runner).runUntilIdle().isEmpty)
    XCTAssertEqual(try runner.currentStatus(for: job.jobID), .cancelled)
  }

  func testPreexistingTargetMirrorProjectsCancelledBeforeRunnerSkips() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let origin = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("target-state", isDirectory: true))
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-preexisting-mirror-cancelled",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try origin.enqueue(job)
    _ = try registry.ensureInboundRemoteMirror(job: job)
    XCTAssertEqual(
      try registry.run(forContractID: job.contractID)?
        .records.first(where: { $0.remoteJobID == job.jobID })?.remoteStatus,
      .queued)
    XCTAssertEqual(try origin.signalCancel(for: job), .cancelled)

    let receipts = try makeRunner(
      channel: runnerChannel,
      localRegistry: registry).runOnce()

    XCTAssertTrue(receipts.isEmpty)
    let mirror = try XCTUnwrap(
      try registry.run(forContractID: job.contractID)?
        .records.first(where: { $0.remoteJobID == job.jobID }))
    XCTAssertEqual(mirror.remoteStatus, .cancelled)
    XCTAssertNil(mirror.receiptID)
    XCTAssertNil(mirror.outputRef)
    XCTAssertNil(try runnerChannel.resultForAudit(for: job.jobID))
  }

  func testBodyOnlyDoesNotCancelMidFlightUntilOriginCompletesSignature() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let fault = TatwoLoopCancelFaultBox(failAt: .afterBody)
    let crashingOrigin = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: trust.origin,
      environment: testEnv,
      cancelFaultBox: fault)
    let recoveredOrigin = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let sandbox = root.appendingPathComponent("sandbox", isDirectory: true)
    let work = sandbox.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-cancel-midflight-recovery",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .s,
          taskDescription: "sample signed cancellation")),
      workPath: work)
    _ = try crashingOrigin.enqueue(job)

    let probe = CancellationProbeBox()
    let environment = [
      TatwoLoopSandboxUnlock.enableEnvKey: TatwoLoopSandboxUnlock.enableSandboxValue,
      TatwoLoopSandboxUnlock.sandboxRootEnvKey: sandbox.path,
    ]
    let runner = try makeRunner(
      channel: runnerChannel,
      environment: environment,
      sandboxRootURL: sandbox,
      engine: CancellationProbeEngine(box: probe))
    DispatchQueue.global().async {
      do {
        probe.finish(receipts: try runner.runUntilIdle(), error: nil)
      } catch {
        probe.finish(receipts: [], error: error)
      }
    }

    XCTAssertEqual(probe.started.wait(timeout: .now() + 2), .success)
    XCTAssertThrowsError(try crashingOrigin.signalCancel(for: job))
    probe.requestSample()
    XCTAssertEqual(probe.sampled.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(probe.samples(), [false])

    XCTAssertEqual(try recoveredOrigin.signalCancel(for: job), .cancelled)
    probe.requestSample()
    XCTAssertEqual(probe.sampled.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(probe.samples(), [false, true])

    XCTAssertEqual(probe.finished.wait(timeout: .now() + 2), .success)
    XCTAssertNil(probe.runnerError())
    XCTAssertTrue(
      probe.receipts().isEmpty,
      "origin-owned cancellation must not fabricate a target result receipt")
    XCTAssertEqual(try runnerChannel.currentStatus(for: job.jobID), .cancelled)
    XCTAssertNil(try runnerChannel.resultForAudit(for: job.jobID))
    XCTAssertTrue(
      try runnerChannel.rejections(for: job.jobID).contains {
        $0.artifact == .cancel && $0.reason == .missingSignature
      })
  }

  func testTerminalStateWinsBeforeLaterCancellation() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let origin = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runner = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-terminal-before-cancel",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)

    _ = try origin.enqueue(job)
    _ = try makeRunner(channel: runner).runUntilIdle()
    XCTAssertEqual(try origin.signalCancel(for: job), .terminalWon(.completed))
    XCTAssertEqual(try origin.currentStatus(for: job.jobID), .completed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: origin.cancelURL(forJobID: job.jobID).path))
  }

  func testSignedTombstoneWinsBeforeLateCompletedTransition() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let cancelFault = TatwoLoopCancelFaultBox(failAt: .afterSignature)
    let origin = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: trust.origin,
      environment: testEnv,
      cancelFaultBox: cancelFault)
    let runner = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-cancel-before-late-success",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)

    _ = try origin.enqueue(job)
    _ = try runner.transition(jobID: job.jobID, to: .delivered, reason: "runner-discovered")
    _ = try runner.transition(jobID: job.jobID, to: .accepted, reason: "runner-accepted")
    _ = try runner.transition(jobID: job.jobID, to: .running, reason: "runner-started")
    XCTAssertThrowsError(try origin.signalCancel(for: job))

    let output = Data("late-success".utf8)
    let receipt = try TatwoLoopJobResultReceiptV1(
      job: job,
      projectionSequence: 5,
      status: .completed,
      outputDigest: TatwoLoopJobDigest.sha256(output),
      outputBytes: output.count,
      exitCode: 0,
      failureCode: nil,
      message: nil,
      startedAt: Date(),
      finishedAt: Date())
    let entry = try runner.transition(
      jobID: job.jobID,
      to: .completed,
      reason: "runner-finished:completed",
      result: receipt,
      outputData: output)

    XCTAssertEqual(entry.to, .cancelled)
    XCTAssertEqual(try runner.currentStatus(for: job.jobID), .cancelled)
    XCTAssertNil(try runner.resultForAudit(for: job.jobID))
    XCTAssertNil(try runner.ack(for: job.jobID)?.result)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: runner.outputURL(forJobID: job.jobID).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: runner.outputSignatureURL(forJobID: job.jobID).path))
  }

  func testTatwoLoopSandboxUnlockExecutesViaProcessEngineAndWritesLocalRegistry() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let sandboxRoot = root.appendingPathComponent("sandbox", isDirectory: true)
    let work = sandboxRoot.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try "marker".write(
      to: work.appendingPathComponent("probe.txt"),
      atomically: true,
      encoding: .utf8)

    let job = makeJob(
      jobID: "job-tatwo-loop-live",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .xl,
          taskDescription: "sandbox probe task")),
      workPath: work,
      maxOutputBytes: 4_096)
    let originRegistry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state"))
    let runnerRegistry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("runner-state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: originRegistry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
    _ = try origin.enqueue(job)

    let env = [
      TatwoLoopSandboxUnlock.enableEnvKey: TatwoLoopSandboxUnlock.enableSandboxValue,
      TatwoLoopSandboxUnlock.sandboxRootEnvKey: sandboxRoot.path,
    ]
    let receipts = try makeRunner(
      channel: runnerChannel,
      environment: env,
      sandboxRootURL: sandboxRoot,
      engine: ProcessEngineBinding.sandboxProbe,
      localRegistry: runnerRegistry).runUntilIdle()
    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts[0].status, .completed, receipts[0].message ?? "")
    XCTAssertNil(receipts[0].failureCode)
    XCTAssertGreaterThan(receipts[0].outputBytes, 0)
    XCTAssertNotNil(try runnerChannel.result(for: job.jobID))

    let local = try XCTUnwrap(
      try runnerRegistry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertEqual(local.status, .completed)
    XCTAssertEqual(local.remoteStatus, .completed)

    XCTAssertEqual(try origin.converge(jobID: job.jobID), .verified)
    let projected = try XCTUnwrap(
      try originRegistry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertEqual(projected.remoteStatus, .verified)
    // H3/C2: local status must not fold verified into completed.
    XCTAssertEqual(projected.status, .verified)
    XCTAssertNotEqual(projected.status, .completed)
  }

  func testTatwoLoopStillDisabledWhenWorkPathOutsideSandbox() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let sandboxRoot = root.appendingPathComponent("sandbox", isDirectory: true)
    let outside = root.appendingPathComponent("outside-work", isDirectory: true)
    try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-outside-sandbox",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .m,
          taskDescription: "must stay disabled")),
      workPath: outside)
    _ = try originChannel.enqueue(job)
    let receipts = try makeRunner(
      channel: runnerChannel,
      environment: [
        TatwoLoopSandboxUnlock.enableEnvKey: "sandbox",
        TatwoLoopSandboxUnlock.sandboxRootEnvKey: sandboxRoot.path,
      ],
      sandboxRootURL: sandboxRoot).runUntilIdle()
    XCTAssertEqual(receipts.first?.failureCode, "tatwo_loop_disabled")
  }

  func testRunnerMemoryGateBlocksQueuedJob() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-mem-block",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let journal = root.appendingPathComponent("runner-state", isDirectory: true)
    let runner = try TatwoLoopRunnerV1(
      channel: runnerChannel,
      deviceID: targetDeviceID,
      pollIntervalSec: 0.01,
      localRegistry: TatwoDispatchRegistry(
        directoryURL: root.appendingPathComponent("runner-registry", isDirectory: true)),
      memoryGate: MemoryPressureGate(
        minFreePercent: 40,
        freePercentProvider: { 5 },
        journalDirectoryURL: journal))
    let receipts = try runner.runUntilIdle()
    XCTAssertEqual(receipts.first?.failureCode, "resource_gate_blocked")
    let entries = try MemoryPressureGate.readJournal(directoryURL: journal)
    XCTAssertTrue(entries.contains { $0.surface == "remote_loop_runner" })
  }

  // MARK: - R3-A signature trust unit cases

  func testChannelSignAndVerifyHappyPath() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channel = TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel"),
      trust: trust.origin,
      environment: testEnv)
    let work = root.appendingPathComponent("work", isDirectory: true)
    let job = makeJob(
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["signed"])),
      workPath: work)
    _ = try channel.enqueue(job)

    let payload = try Data(contentsOf: channel.jobURL(for: job))
    let signature = try JSONDecoder().decode(
      TatwoDeviceSignatureV1.self,
      from: Data(contentsOf: channel.jobSignatureURL(for: job)))
    XCTAssertEqual(signature.purpose, "loop-job")
    XCTAssertEqual(signature.deviceID, originDeviceID)
    try trust.runner.verify(
      payload: payload,
      purpose: .loopJob,
      signature: signature,
      expectedDeviceID: originDeviceID)
  }

  func testChannelRejectsTamperedJobBytes() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    let job = makeJob(
      jobID: "job-tamper-unit",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["clean"])),
      workPath: work)
    _ = try originChannel.enqueue(job)

    let url = originChannel.jobURL(for: job)
    var text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    text = text.replacingOccurrences(of: "clean", with: "dirty")
    try Data(text.utf8).write(to: url)

    XCTAssertThrowsError(try runnerChannel.job(forJobID: job.jobID)) { error in
      guard case let TatwoLoopJobStateError.signatureRejected(_, reason) = error else {
        return XCTFail("expected signatureRejected, got \(error)")
      }
      XCTAssertTrue(
        reason == TatwoLoopChannelRejectReasonV1.digestMismatch.rawValue
          || reason == TatwoLoopChannelRejectReasonV1.invalidSignature.rawValue)
    }
    let rejects = try runnerChannel.rejections(for: job.jobID)
    XCTAssertFalse(rejects.isEmpty)
    XCTAssertTrue(
      rejects.contains {
        $0.reason == .digestMismatch || $0.reason == .invalidSignature
      })
  }

  func testChannelRejectsUnknownIdentity() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let stranger = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "stranger-device",
      privateKeyStore: MemoryDevicePrivateKeyStore())
    let strangerChannel = makeChannel(rootURL: channelRoot, trust: stranger)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    let job = makeJob(
      jobID: "job-unknown-unit",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["forged"])),
      workPath: work,
      originDeviceID: "stranger-device")
    _ = try strangerChannel.enqueue(job)

    XCTAssertThrowsError(try runnerChannel.job(forJobID: job.jobID)) { error in
      XCTAssertEqual(
        error as? TatwoLoopJobStateError,
        .signatureRejected(
          jobID: job.jobID,
          reason: TatwoLoopChannelRejectReasonV1.unknownIdentity.rawValue))
    }
    let rejects = try runnerChannel.rejections(for: job.jobID)
    XCTAssertTrue(rejects.contains { $0.reason == .unknownIdentity })
  }

  func testChannelRejectsDigestMismatchOnDetachedSignature() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channel = TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel"),
      trust: trust.origin,
      environment: testEnv)
    let work = root.appendingPathComponent("work", isDirectory: true)
    let job = makeJob(
      jobID: "job-digest-unit",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["digest"])),
      workPath: work)
    _ = try channel.enqueue(job)

    // Mutate only the sidecar digest field so verify fails closed as digest_mismatch.
    let signatureURL = channel.jobSignatureURL(for: job)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: signatureURL)) as? [String: Any])
    object["payloadDigest"] = String(repeating: "0", count: 64)
    let mutated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try mutated.write(to: signatureURL)

    let runnerChannel = TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel"),
      trust: trust.runner,
      environment: testEnv)
    XCTAssertThrowsError(try runnerChannel.job(forJobID: job.jobID)) { error in
      XCTAssertEqual(
        error as? TatwoLoopJobStateError,
        .signatureRejected(
          jobID: job.jobID,
          reason: TatwoLoopChannelRejectReasonV1.digestMismatch.rawValue))
    }
  }

  func testChannelRejectsMissingSignatureFailClosed() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    let job = makeJob(
      jobID: "job-unsigned-unit",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["unsigned"])),
      workPath: work)
    _ = try originChannel.enqueue(job)
    try FileManager.default.removeItem(at: originChannel.jobSignatureURL(for: job))

    XCTAssertThrowsError(try runnerChannel.job(forJobID: job.jobID)) { error in
      XCTAssertEqual(
        error as? TatwoLoopJobStateError,
        .signatureRejected(
          jobID: job.jobID,
          reason: TatwoLoopChannelRejectReasonV1.missingSignature.rawValue))
    }
    let rejects = try runnerChannel.rejections(for: job.jobID)
    XCTAssertTrue(rejects.contains { $0.reason == .missingSignature })
  }

  // MARK: - R3 security (H1–H3, M4–M5)

  func testSandboxRejectsSymlinkEscapeAndPrefixConfusion() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sandbox = root.appendingPathComponent("sandbox", isDirectory: true)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

    // H1: symlink inside sandbox pointing at /
    let escapeLink = sandbox.appendingPathComponent("escape-root")
    try FileManager.default.createSymbolicLink(
      atPath: escapeLink.path,
      withDestinationPath: "/")
    XCTAssertFalse(
      TatwoLoopSandboxUnlock.isWorkPathInsideSandbox(
        workPath: escapeLink,
        sandboxRoot: sandbox),
      "symlink resolving to / must not pass sandbox containment")

    // H1: prefix confusion /sandbox vs /sandbox-evil
    let evil = root.appendingPathComponent("sandbox-evil", isDirectory: true)
    try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
    XCTAssertFalse(
      TatwoLoopSandboxUnlock.isWorkPathInsideSandbox(
        workPath: evil,
        sandboxRoot: sandbox),
      "/sandbox-evil must not match parent /sandbox")

    let inside = sandbox.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    XCTAssertTrue(
      TatwoLoopSandboxUnlock.isWorkPathInsideSandbox(
        workPath: inside,
        sandboxRoot: sandbox))
  }

  func testProcessEngineDoesNotShellInjectViaWorkPathOrTaskDescription() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Directory name with shell metacharacters (classic sh -c escape).
    let evilName = "a\"; touch /tmp/PWNED-tatwo-r3; echo \""
    let work = root.appendingPathComponent(evilName, isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try "safe".write(
      to: work.appendingPathComponent("marker.txt"),
      atomically: true,
      encoding: .utf8)

    let pwned = URL(fileURLWithPath: "/tmp/PWNED-tatwo-r3")
    try? FileManager.default.removeItem(at: pwned)

    let task = TatwoLoopEngineTaskV1(
      contractID: contractID,
      goalID: goalID,
      identity: .sub,
      mode: .s,
      taskDescription: "desc\"; touch /tmp/PWNED-tatwo-r3; echo \"")

    // Argv-only probe: workPath is a discrete argument to /bin/ls.
    let result = try ProcessEngineBinding.sandboxProbe.run(
      task: task,
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 2, maxOutputBytes: 4_096),
      shouldCancel: { false })
    XCTAssertEqual(result.failureCode, nil, result.message ?? "")
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: pwned.path),
      "shell metacharacters in workPath/taskDescription must not execute")

    // Embedded placeholder inside a shell string must be rejected (no interpolation).
    let shellish = ProcessEngineBinding(
      executablePath: "/bin/sh",
      argumentTemplate: ["-c", "ls \"{workPath}\""])
    let rejected = try shellish.run(
      task: task,
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 1, maxOutputBytes: 256),
      shouldCancel: { false })
    XCTAssertEqual(rejected.failureCode, "invalid_argument_template")
    XCTAssertFalse(FileManager.default.fileExists(atPath: pwned.path))
  }

  func testJournalTamperRejectsAndBlocksReplayAndForgedVerified() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-journal-sec",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["ledger"])),
      workPath: work)
    _ = try originChannel.enqueue(job)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: originChannel.journalSignatureURL(forJobID: job.jobID).path))

    // Happy path execute once.
    let first = try makeRunner(channel: runnerChannel).runUntilIdle()
    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(first[0].status, .completed)

    // Canonical pair is now a projection: tampering its body must be repaired
    // from the already verified atomic bundle, never signed in place.
    let journalURL = originChannel.journalURL(forJobID: job.jobID)
    var journalText = String(decoding: try Data(contentsOf: journalURL), as: UTF8.self)
    journalText = journalText.replacingOccurrences(of: "completed", with: "verified")
    try Data(journalText.utf8).write(to: journalURL)
    XCTAssertEqual(
      try originChannel.journal(for: job.jobID).map(\.to),
      [.queued, .delivered, .accepted, .running, .completed])
    XCTAssertFalse(
      String(decoding: try Data(contentsOf: journalURL), as: UTF8.self)
        .contains("\"to\":\"verified\""))

    // H3: tamper authoritative bundle bytes without updating its embedded
    // detached signature → fail closed and block replay.
    let bundleURL = originChannel.journalBundleURL(forJobID: job.jobID)
    var bundleObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: bundleURL))
        as? [String: Any])
    bundleObject["journalBytes"] = Data(journalText.utf8).base64EncodedString()
    try JSONSerialization.data(
      withJSONObject: bundleObject,
      options: [.sortedKeys])
      .write(to: bundleURL, options: .atomic)
    XCTAssertThrowsError(try originChannel.journal(for: job.jobID)) { error in
      guard case TatwoLoopJobStateError.signatureRejected = error else {
        return XCTFail("expected signatureRejected, got \(error)")
      }
    }

    // Replay fence: second runUntilIdle must not re-execute the consumed job.
    XCTAssertThrowsError(try runnerChannel.currentStatus(for: job.jobID))
    let replay = try makeRunner(channel: runnerChannel).runUntilIdle()
    XCTAssertTrue(
      replay.isEmpty,
      "tampered authoritative journal bundle must not allow replay execution")

    // H3: a missing legacy sidecar is forward-repaired from the authoritative
    // bundle. Missing both bundle and sidecar retains fail-closed legacy behavior.
    let job2 = makeJob(
      jobID: "job-journal-unsigned",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(job2)
    try FileManager.default.removeItem(
      at: originChannel.journalSignatureURL(forJobID: job2.jobID))
    XCTAssertEqual(try runnerChannel.currentStatus(for: job2.jobID), .queued)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: originChannel.journalSignatureURL(forJobID: job2.jobID).path))
    try FileManager.default.removeItem(
      at: originChannel.journalBundleURL(forJobID: job2.jobID))
    try FileManager.default.removeItem(
      at: originChannel.journalSignatureURL(forJobID: job2.jobID))
    XCTAssertThrowsError(try runnerChannel.journal(for: job2.jobID)) { error in
      XCTAssertEqual(
        error as? TatwoLoopJobStateError,
        .signatureRejected(
          jobID: job2.jobID,
          reason: TatwoLoopChannelRejectReasonV1.missingSignature.rawValue))
    }
    let noRun = try makeRunner(channel: runnerChannel).runUntilIdle()
    XCTAssertFalse(noRun.contains { $0.jobID == job2.jobID })
  }

  func testResourceCapsKillProcessGroupAndStreamOutputCap() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let caps = TatwoLoopResourceCapsV1(maxDurationSec: 0.15, maxOutputBytes: 64)
    // Grandchild sleep held via process group: fixed shell script, no placeholders.
    let binding = ProcessEngineBinding(
      executablePath: "/bin/sh",
      argumentTemplate: [
        "-c",
        "sleep 30 & sleep 30; wait",
      ])
    let started = Date()
    let timed = try binding.run(
      task: TatwoLoopEngineTaskV1(
        contractID: contractID,
        goalID: goalID,
        identity: .sub,
        mode: .s,
        taskDescription: "timeout-group"),
      workPath: work,
      caps: caps,
      shouldCancel: { false })
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertEqual(timed.failureCode, "timeout")
    XCTAssertTrue(timed.timedOut)
    XCTAssertLessThan(elapsed, 5, "process group must die well before grandchild sleep 30s")

    // Oversized output: stream stop at maxOutputBytes (no multi-MB retention).
    let flood = ProcessEngineBinding(
      executablePath: "/bin/sh",
      argumentTemplate: [
        "-c",
        // Fixed script — no untrusted interpolation.
        "dd if=/dev/zero bs=1024 count=512 2>/dev/null",
      ])
    let flooded = try flood.run(
      task: TatwoLoopEngineTaskV1(
        contractID: contractID,
        goalID: goalID,
        identity: .sub,
        mode: .s,
        taskDescription: "flood"),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 5, maxOutputBytes: 256),
      shouldCancel: { false })
    XCTAssertEqual(flooded.failureCode, "output_cap")
    XCTAssertTrue(flooded.outputTruncated)
    XCTAssertLessThanOrEqual(flooded.outputData.count, 256)

    // Local clamp: absurd remote caps are reduced before execute.
    let remote = TatwoLoopResourceCapsV1(maxDurationSec: 9_999, maxOutputBytes: 50_000_000)
    let local = remote.clampedForLocalExecution()
    XCTAssertEqual(local.maxDurationSec, TatwoLoopResourceCapsV1.localHardMaxDurationSec)
    XCTAssertEqual(local.maxOutputBytes, TatwoLoopResourceCapsV1.localHardMaxOutputBytes)
  }

  // MARK: - R3 security batch 2 (C1–C3)

  func testCrossJobArtifactMoveRejectsResultAckAndJob() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let jobA = makeJob(
      jobID: "job-a",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["a"])),
      workPath: work)
    let jobB = makeJob(
      jobID: "job-b",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["b"])),
      workPath: work)
    _ = try originChannel.enqueue(jobA)
    _ = try originChannel.enqueue(jobB)

    // Complete job-b via runner so result/ack are target-signed for job-b.
    let runner = try makeRunner(channel: runnerChannel)
    let receipts = try runner.runUntilIdle()
    XCTAssertEqual(Set(receipts.map(\.jobID)), Set(["job-a", "job-b"]))
    let resultB = try XCTUnwrap(try runnerChannel.result(for: "job-b"))
    XCTAssertEqual(resultB.jobID, "job-b")
    XCTAssertEqual(resultB.status, .completed)

    // C1: copy job-b result + sidecar onto job-a paths (no key needed).
    let fm = FileManager.default
    try fm.removeItem(at: originChannel.resultURL(forJobID: "job-a"))
    try? fm.removeItem(at: originChannel.resultSignatureURL(forJobID: "job-a"))
    try fm.copyItem(
      at: originChannel.resultURL(forJobID: "job-b"),
      to: originChannel.resultURL(forJobID: "job-a"))
    try fm.copyItem(
      at: originChannel.resultSignatureURL(forJobID: "job-b"),
      to: originChannel.resultSignatureURL(forJobID: "job-a"))

    XCTAssertThrowsError(try originChannel.result(for: "job-a")) { error in
      XCTAssertEqual(
        error as? TatwoLoopJobStateError,
        .signatureRejected(
          jobID: "job-a",
          reason: TatwoLoopChannelRejectReasonV1.jobIdMismatch.rawValue))
    }

    // C1: same attack on ack (copy job-b completed ack over job-a).
    try fm.removeItem(at: originChannel.ackURL(forJobID: "job-a"))
    try? fm.removeItem(at: originChannel.ackSignatureURL(forJobID: "job-a"))
    try fm.copyItem(
      at: originChannel.ackURL(forJobID: "job-b"),
      to: originChannel.ackURL(forJobID: "job-a"))
    try fm.copyItem(
      at: originChannel.ackSignatureURL(forJobID: "job-b"),
      to: originChannel.ackSignatureURL(forJobID: "job-a"))

    XCTAssertThrowsError(try originChannel.ack(for: "job-a")) { error in
      XCTAssertEqual(
        error as? TatwoLoopJobStateError,
        .signatureRejected(
          jobID: "job-a",
          reason: TatwoLoopChannelRejectReasonV1.jobIdMismatch.rawValue))
    }

    // C1: rename/copy job-b job artifact onto job-a path under same target.
    let jobAURL = originChannel.jobURL(for: jobA)
    let jobBURL = originChannel.jobURL(for: jobB)
    let jobASig = originChannel.jobSignatureURL(for: jobA)
    let jobBSig = originChannel.jobSignatureURL(for: jobB)
    try fm.removeItem(at: jobAURL)
    try? fm.removeItem(at: jobASig)
    try fm.copyItem(at: jobBURL, to: jobAURL)
    try fm.copyItem(at: jobBSig, to: jobASig)

    XCTAssertThrowsError(try runnerChannel.job(forJobID: "job-a")) { error in
      XCTAssertEqual(
        error as? TatwoLoopJobStateError,
        .signatureRejected(
          jobID: "job-a",
          reason: TatwoLoopChannelRejectReasonV1.jobIdMismatch.rawValue))
    }
    let rejects = try runnerChannel.rejections(for: "job-a")
    XCTAssertTrue(rejects.contains { $0.reason == .jobIdMismatch })
  }

  func testPathComponentRejectsDotDotSlashAndNul() throws {
    XCTAssertTrue(TatwoLoopPathComponent.isValid("job-success"))
    XCTAssertTrue(TatwoLoopPathComponent.isValid("runner_sandbox"))
    XCTAssertFalse(TatwoLoopPathComponent.isValid(".."))
    XCTAssertFalse(TatwoLoopPathComponent.isValid("."))
    XCTAssertFalse(TatwoLoopPathComponent.isValid("a/b"))
    XCTAssertFalse(TatwoLoopPathComponent.isValid("a\\b"))
    XCTAssertFalse(TatwoLoopPathComponent.isValid("job\0id"))
    XCTAssertFalse(TatwoLoopPathComponent.isValid(""))
    XCTAssertFalse(TatwoLoopPathComponent.isValid("job.id"))
    // Sanitize must not preserve traversal tokens.
    XCTAssertNotEqual(TatwoLoopPathComponent.sanitize(".."), "..")
    XCTAssertNotEqual(TatwoLoopPathComponent.sanitize("."), ".")
    XCTAssertFalse(TatwoLoopPathComponent.sanitize("..").contains(".."))

    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let evilIDs = ["..", ".", "a/b", "x\0y", "has.dot"]
    for evil in evilIDs {
      let asJobID = makeJob(
        jobID: evil,
        payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
        workPath: work)
      XCTAssertThrowsError(try asJobID.validate(), "jobID \(evil) must reject") { error in
        XCTAssertEqual(error as? TatwoLoopJobStateError, .invalidJob(evil))
      }
      let asTarget = makeJob(
        jobID: "job-ok",
        payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
        workPath: work,
        targetDeviceID: evil)
      XCTAssertThrowsError(try asTarget.validate(), "targetDeviceID \(evil) must reject")
      let asOrigin = makeJob(
        jobID: "job-ok",
        payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
        workPath: work,
        originDeviceID: evil)
      XCTAssertThrowsError(try asOrigin.validate(), "originDeviceID \(evil) must reject")
    }

    // Channel path builder must not place `..` under outbox (escape to channel root).
    let trust = try makeTrustPair(root: root)
    let channel = TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel"),
      trust: trust.origin,
      environment: testEnv)
    let escaped = channel.jobURL(
      for: makeJob(
        jobID: "safe-job",
        payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
        workPath: work,
        targetDeviceID: ".."))
    XCTAssertFalse(
      escaped.path.contains("/outbox/../"),
      "safeComponent must not preserve .. as a path segment: \(escaped.path)")
    XCTAssertTrue(
      escaped.path.contains("/outbox/invalid-"),
      "invalid targetDeviceID must land under hashed invalid- segment")
  }

  func testConvergeRejectsOriginSignedResultAndAcceptsTargetSigned() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    // --- Origin self-signed result must not launder via ack ---
    let forgedJob = makeJob(
      jobID: "job-origin-result",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    _ = try originChannel.enqueue(forgedJob)
    // Advance journal to completed with origin channel (no real runner).
    _ = try originChannel.transition(
      jobID: forgedJob.jobID, to: .delivered, reason: "forged")
    _ = try originChannel.transition(
      jobID: forgedJob.jobID, to: .accepted, reason: "forged")
    _ = try originChannel.transition(
      jobID: forgedJob.jobID, to: .running, reason: "forged")
    let fakeReceipt = try TatwoLoopJobResultReceiptV1(
      job: forgedJob,
      projectionSequence: 5,
      status: .completed,
      outputDigest: nil,
      outputBytes: 0,
      exitCode: 0,
      failureCode: nil,
      message: "origin-laundered",
      startedAt: Date(),
      finishedAt: Date())
    _ = try originChannel.transition(
      jobID: forgedJob.jobID,
      to: .completed,
      reason: "origin-self-result",
      result: fakeReceipt)
    // Origin-signed result artifact must fail target-bound verify.
    XCTAssertThrowsError(try originChannel.result(for: forgedJob.jobID)) { error in
      guard case TatwoLoopJobStateError.signatureRejected = error else {
        return XCTFail("expected signatureRejected for origin-signed result, got \(error)")
      }
    }
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
    _ = try registry.beginRemoteTestFixtureUnbound(job: forgedJob)
    XCTAssertThrowsError(try origin.converge(jobID: forgedJob.jobID)) { error in
      guard case TatwoLoopJobStateError.signatureRejected = error else {
        return XCTFail("converge must reject origin-signed result, got \(error)")
      }
    }

    // --- Target-signed result is accepted ---
    let goodJob = makeJob(
      jobID: "job-target-result",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["ok"])),
      workPath: work)
    _ = try origin.enqueue(goodJob)
    let receipts = try makeRunner(channel: runnerChannel).runUntilIdle()
    XCTAssertEqual(receipts.first?.status, .completed)
    XCTAssertNotNil(try runnerChannel.result(for: goodJob.jobID))
    XCTAssertEqual(try origin.converge(jobID: goodJob.jobID), .verified)
  }

  func testOriginCommitFenceQuarantinesReservationCancelledBeforeChannelCommit() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channel = makeChannel(
      rootURL: root.appendingPathComponent("channel"),
      trust: trust.origin)
    let stateRoot = root.appendingPathComponent("origin-state", isDirectory: true)
    let goalStore = TatwoGoalRunStore(directoryURL: stateRoot)
    let registry = TatwoDispatchRegistry(directoryURL: stateRoot)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "cancel between remote reservation and channel commit",
      store: goalStore)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = TatwoLoopJobV1(
      jobID: "job-cancel-before-channel-commit",
      logicalJobID: "logical-cancel-before-channel-commit",
      dispatchNonce: "nonce-cancel-before-channel-commit",
      contractID: contract.contractID,
      goalID: contract.goalID,
      identity: .sub,
      originDeviceID: originDeviceID,
      targetDeviceID: targetDeviceID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work.path,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: 1,
        maxOutputBytes: 64),
      stopConditions: TatwoLoopStopConditionsV1(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let origin = TatwoLoopOriginProjectorV1(
      channel: channel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: stateRoot),
      goalStore: goalStore,
      environment: testEnv)

    XCTAssertThrowsError(
      try origin.enqueue(
        job,
        afterReservation: {
          _ = try goalStore.updateStatus(
            contractID: contract.contractID,
            status: .dispatching)
          _ = try goalStore.updateStatus(
            contractID: contract.contractID,
            status: .running,
            authority: .ledgerBeginAck,
            reason: "race-test-running",
            evidence: .ledger(dispatchID: "race-test"))
          _ = try goalStore.updateStatus(
            contractID: contract.contractID,
            status: .cancelled)
        })
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .goalRunCannotBegin(status: .cancelled))
    }

    XCTAssertFalse(channel.hasCommitMarker(forJobID: job.jobID))
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .cancelled)
    let reserved = try XCTUnwrap(
      try registry.run(forContractID: contract.contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertEqual(reserved.remoteStatus, .failed)
    XCTAssertEqual(reserved.failureReceipt?.errorCode, "channel_enqueue_failed")
    XCTAssertTrue(
      reserved.failureReceipt?.operatorMessage.contains(
        "reconciliation_required:channel_enqueue:") == true)
  }

  func testAgentResultReceiptRequiresActualLoadedSkillDigest() throws {
    let root = makeRoot()
    let readiness = TatwoRemoteDispatchReadinessBindingV1(
      workspaceBindingID: "workspace-agent-skills",
      workspaceBindingDigest: String(repeating: "a", count: 64),
      agentModelCapabilityDigest: String(repeating: "b", count: 64),
      activeSkillSetDigest: String(repeating: "c", count: 64),
      challengeNonce: "challenge-agent-skills")
    let job = TatwoLoopJobV1(
      jobID: "job-agent-skills",
      logicalJobID: "logical-job-agent-skills",
      dispatchNonce: "nonce-agent-skills",
      contractID: contractID,
      goalID: goalID,
      identity: .sub,
      originDeviceID: originDeviceID,
      targetDeviceID: targetDeviceID,
      remoteDispatchReadiness: readiness,
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .s,
          taskDescription: "load exact active skills",
          agent: .grok,
          exactModelRouteID: "grok-build")),
      workPath: root.path,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: 2,
        maxOutputBytes: 256),
      stopConditions: TatwoLoopStopConditionsV1(
        cancelFileSignal: true,
        rules: ["cancel-file"]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))

    XCTAssertThrowsError(
      try TatwoLoopJobResultReceiptV1(
        job: job,
        projectionSequence: 4,
        status: .completed,
        outputDigest: nil,
        outputBytes: 0,
        exitCode: 0,
        failureCode: nil,
        message: nil,
        startedAt: Date(),
        finishedAt: Date(),
        actualLoadedSkillSetDigest: String(repeating: "d", count: 64)))

    let receipt = try TatwoLoopJobResultReceiptV1(
      job: job,
      projectionSequence: 4,
      status: .completed,
      outputDigest: nil,
      outputBytes: 0,
      exitCode: 0,
      failureCode: nil,
      message: nil,
      startedAt: Date(),
      finishedAt: Date(),
      actualLoadedSkillSetDigest: readiness.activeSkillSetDigest)
    XCTAssertEqual(
      receipt.expectedActiveSkillSetDigest,
      readiness.activeSkillSetDigest)
    XCTAssertEqual(
      receipt.actualLoadedSkillSetDigest,
      readiness.activeSkillSetDigest)
    XCTAssertTrue(receipt.hasMatchingActiveSkillReadback)
    XCTAssertNoThrow(try receipt.validateActiveSkillReadback(for: job))

    let data = try JSONEncoder().encode(receipt)
    let decoded = try JSONDecoder().decode(
      TatwoLoopJobResultReceiptV1.self,
      from: data)
    XCTAssertEqual(decoded, receipt)
    XCTAssertTrue(decoded.hasMatchingActiveSkillReadback)

    for terminalStatus in [TatwoLoopJobStatusV1.failed, .cancelled] {
      let terminalReceipt = try TatwoLoopJobResultReceiptV1(
        job: job,
        projectionSequence: 5,
        status: terminalStatus,
        outputDigest: nil,
        outputBytes: 0,
        exitCode: terminalStatus == .failed ? 1 : nil,
        failureCode: terminalStatus == .failed ? "agent_skill_projection_failed" : "cancelled",
        message: nil,
        startedAt: Date(),
        finishedAt: Date())
      XCTAssertEqual(
        terminalReceipt.expectedActiveSkillSetDigest,
        readiness.activeSkillSetDigest)
      XCTAssertNil(terminalReceipt.actualLoadedSkillSetDigest)
      XCTAssertNoThrow(try terminalReceipt.validateActiveSkillReadback(for: job))
    }

    let wrongExpected = TatwoLoopJobResultReceiptV1(
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      projectionSequence: 6,
      status: .failed,
      outputDigest: nil,
      outputBytes: 0,
      exitCode: 1,
      failureCode: "agent_skill_projection_failed",
      message: nil,
      startedAt: Date(),
      finishedAt: Date(),
      expectedActiveSkillSetDigest: String(repeating: "d", count: 64),
      actualLoadedSkillSetDigest: nil)
    XCTAssertThrowsError(try wrongExpected.validateActiveSkillReadback(for: job))

    let malformedActual = TatwoLoopJobResultReceiptV1(
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      projectionSequence: 7,
      status: .cancelled,
      outputDigest: nil,
      outputBytes: 0,
      exitCode: nil,
      failureCode: "cancelled",
      message: nil,
      startedAt: Date(),
      finishedAt: Date(),
      expectedActiveSkillSetDigest: readiness.activeSkillSetDigest,
      actualLoadedSkillSetDigest: "not-a-digest")
    XCTAssertThrowsError(try malformedActual.validateActiveSkillReadback(for: job))
  }

  func testOriginConvergeRejectsMismatchedAgentSkillReadbackBeforeConsumeMarker() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(
      at: work,
      withIntermediateDirectories: true)
    let readiness = TatwoRemoteDispatchReadinessBindingV1(
      workspaceBindingID: "workspace-converge-skills",
      workspaceBindingDigest: String(repeating: "a", count: 64),
      agentModelCapabilityDigest: String(repeating: "b", count: 64),
      activeSkillSetDigest: String(repeating: "c", count: 64),
      challengeNonce: "challenge-converge-skills")
    let job = TatwoLoopJobV1(
      jobID: "job-converge-skills",
      logicalJobID: "logical-converge-skills",
      dispatchNonce: "nonce-converge-skills",
      contractID: contractID,
      goalID: goalID,
      identity: .sub,
      originDeviceID: originDeviceID,
      targetDeviceID: targetDeviceID,
      remoteDispatchReadiness: readiness,
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .s,
          taskDescription: "prove actual loaded skills",
          agent: .grok,
          exactModelRouteID: "grok-build")),
      workPath: work.path,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: 2,
        maxOutputBytes: 256),
      stopConditions: TatwoLoopStopConditionsV1(
        cancelFileSignal: true,
        rules: ["cancel-file"]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
    _ = try origin.enqueue(job)
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .delivered,
      reason: "runner-delivered")
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .accepted,
      reason: "runner-accepted")
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .running,
      reason: "runner-started")
    let receipt = TatwoLoopJobResultReceiptV1(
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      projectionSequence: 5,
      status: .completed,
      outputDigest: nil,
      outputBytes: 0,
      exitCode: 0,
      failureCode: nil,
      message: nil,
      startedAt: Date(),
      finishedAt: Date(),
      expectedActiveSkillSetDigest: readiness.activeSkillSetDigest,
      actualLoadedSkillSetDigest: String(repeating: "d", count: 64))
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .completed,
      reason: "runner-completed",
      result: receipt)

    XCTAssertThrowsError(try origin.converge(jobID: job.jobID)) { error in
      guard case TatwoLoopJobStateError.invalidPayload(let detail) = error else {
        return XCTFail("expected invalid Skill readback, got \(error)")
      }
      XCTAssertTrue(detail.contains("Skill readback"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: originChannel.resultConsumeMarkerURL(forJobID: job.jobID).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: originChannel.resultConsumeHighWaterURL(forJobID: job.jobID).path))
    XCTAssertEqual(try originChannel.currentStatus(for: job.jobID), .completed)
  }

  func testCompletedClaudeReceiptRequiresVerifiedExactModelAttestation() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true)
    let job = TatwoLoopJobV1(
      jobID: "job-claude-exact-model",
      logicalJobID: "logical-claude-exact-model",
      dispatchNonce: "nonce-claude-exact-model",
      contractID: contractID,
      goalID: goalID,
      identity: .sub,
      originDeviceID: originDeviceID,
      targetDeviceID: targetDeviceID,
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .s,
          taskDescription: "fable only",
          agent: .claude,
          exactModelRouteID: "fable-5")),
      workPath: root.path,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: 2,
        maxOutputBytes: 256),
      stopConditions: TatwoLoopStopConditionsV1(
        cancelFileSignal: true,
        rules: ["cancel-file"]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))

    XCTAssertThrowsError(
      try TatwoLoopJobResultReceiptV1(
        job: job,
        projectionSequence: 1,
        status: .completed,
        outputDigest: nil,
        outputBytes: 0,
        exitCode: 0,
        failureCode: nil,
        message: nil,
        startedAt: Date(),
        finishedAt: Date()))

    let mismatch = TatwoModelExecutionAttestationV1(
      requestedCanonicalModelID: "fable-5",
      requestedVendorModelID: "claude-fable-5",
      observedAssistantModelIDs: ["claude-fable-5", "claude-opus-5"],
      modelUsageKeys: ["claude-fable-5", "claude-opus-5"],
      fallbackEventCount: 0,
      outcome: .failClosedMismatch)
    XCTAssertThrowsError(
      try TatwoLoopJobResultReceiptV1(
        job: job,
        projectionSequence: 2,
        status: .completed,
        outputDigest: nil,
        outputBytes: 0,
        exitCode: 0,
        failureCode: nil,
        message: nil,
        startedAt: Date(),
        finishedAt: Date(),
        modelExecutionAttestation: mismatch))

    let forgedVerifiedWithOpusUsage = TatwoModelExecutionAttestationV1(
      requestedCanonicalModelID: "fable-5",
      requestedVendorModelID: "claude-fable-5",
      observedAssistantModelIDs: ["claude-fable-5"],
      modelUsageKeys: ["claude-fable-5", "claude-opus-5"],
      fallbackEventCount: 0,
      outcome: .verifiedExact)
    XCTAssertThrowsError(
      try TatwoLoopJobResultReceiptV1(
        job: job,
        projectionSequence: 3,
        status: .completed,
        outputDigest: nil,
        outputBytes: 0,
        exitCode: 0,
        failureCode: nil,
        message: nil,
        startedAt: Date(),
        finishedAt: Date(),
        modelExecutionAttestation: forgedVerifiedWithOpusUsage))

    let forgedVerifiedVendorMapping = TatwoModelExecutionAttestationV1(
      requestedCanonicalModelID: "fable-5",
      requestedVendorModelID: "claude-opus-5",
      observedAssistantModelIDs: ["claude-opus-5"],
      modelUsageKeys: ["claude-opus-5"],
      fallbackEventCount: 0,
      outcome: .verifiedExact)
    XCTAssertThrowsError(
      try TatwoLoopJobResultReceiptV1(
        job: job,
        projectionSequence: 3,
        status: .completed,
        outputDigest: nil,
        outputBytes: 0,
        exitCode: 0,
        failureCode: nil,
        message: nil,
        startedAt: Date(),
        finishedAt: Date(),
        modelExecutionAttestation: forgedVerifiedVendorMapping))

    let verified = TatwoModelExecutionAttestationV1(
      requestedCanonicalModelID: "fable-5",
      requestedVendorModelID: "claude-fable-5",
      observedAssistantModelIDs: ["claude-fable-5"],
      modelUsageKeys: ["claude-fable-5"],
      fallbackEventCount: 0,
      outcome: .verifiedExact)
    let receipt = try TatwoLoopJobResultReceiptV1(
      job: job,
      projectionSequence: 3,
      status: .completed,
      outputDigest: nil,
      outputBytes: 0,
      exitCode: 0,
      failureCode: nil,
      message: nil,
      startedAt: Date(),
      finishedAt: Date(),
      modelExecutionAttestation: verified)
    XCTAssertEqual(receipt.modelExecutionAttestation, verified)
    XCTAssertEqual(
      try JSONDecoder().decode(
        TatwoLoopJobResultReceiptV1.self,
        from: JSONEncoder().encode(receipt)),
      receipt)

    let failed = try TatwoLoopJobResultReceiptV1(
      job: job,
      projectionSequence: 4,
      status: .failed,
      outputDigest: nil,
      outputBytes: 0,
      exitCode: -1,
      failureCode: "agent_model_route_mismatch",
      message: "provider switched models",
      startedAt: Date(),
      finishedAt: Date(),
      modelExecutionAttestation: mismatch)
    XCTAssertEqual(failed.modelExecutionAttestation, mismatch)
  }

  func testAuditAndConvergeRejectSignedCompletedClaudeResultWithoutAttestation() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-legacy-claude-no-attestation",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .s,
          taskDescription: "legacy signed completion",
          agent: .claude,
          exactModelRouteID: "fable-5")),
      workPath: work)
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
    _ = try origin.enqueue(job)
    _ = try runnerChannel.transition(
      jobID: job.jobID, to: .delivered, reason: "runner-delivered")
    _ = try runnerChannel.transition(
      jobID: job.jobID, to: .accepted, reason: "runner-accepted")
    _ = try runnerChannel.transition(
      jobID: job.jobID, to: .running, reason: "runner-started")

    // Simulates a receipt produced by an older target binary: signed and
    // attempt-bound, but without provider model evidence.
    let legacyReceipt = TatwoLoopJobResultReceiptV1(
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      projectionSequence: 5,
      status: .completed,
      outputDigest: nil,
      outputBytes: 0,
      exitCode: 0,
      failureCode: nil,
      message: nil,
      startedAt: Date(),
      finishedAt: Date())
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .completed,
      reason: "legacy-runner-completed",
      result: legacyReceipt)

    XCTAssertThrowsError(try originChannel.resultForAudit(for: job.jobID)) { error in
      guard case TatwoLoopJobStateError.invalidPayload(let detail) = error else {
        return XCTFail("expected missing model attestation reject, got \(error)")
      }
      XCTAssertTrue(detail.contains("model attestation"), detail)
    }
    XCTAssertThrowsError(try origin.converge(jobID: job.jobID))
    XCTAssertEqual(try originChannel.currentStatus(for: job.jobID), .completed)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: originChannel.resultConsumeMarkerURL(forJobID: job.jobID).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: originChannel.resultConsumeHighWaterURL(forJobID: job.jobID).path))
    let projected = try XCTUnwrap(
      try registry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertNotEqual(projected.status, .verified)
    XCTAssertNotEqual(projected.remoteStatus, .verified)
  }

  func testRunnerFailsClosedWithoutClaudeAttestationAndPreservesVerifiedEvidence() throws {
    for scenario in [ExactModelEngineScenario.missing, .verified] {
      let root = makeRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let trust = try makeTrustPair(root: root)
      let channelRoot = root.appendingPathComponent("channel")
      let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
      let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
      let sandboxRoot = root.appendingPathComponent("sandbox", isDirectory: true)
      let work = sandboxRoot.appendingPathComponent("work", isDirectory: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let job = makeJob(
        jobID: "job-runner-claude-\(scenario.rawValue)",
        payload: .tatwoLoop(
          TatwoLoopPayloadV1(
            contractID: contractID,
            goalID: goalID,
            identity: .sub,
            mode: .s,
            taskDescription: "runner exact-model invariant",
            agent: .claude,
            exactModelRouteID: "fable-5")),
        workPath: work)
      let registry = TatwoDispatchRegistry(
        directoryURL: root.appendingPathComponent("origin-state"))
      let runnerRegistry = TatwoDispatchRegistry(
        directoryURL: root.appendingPathComponent("runner-state"))
      let origin = TatwoLoopOriginProjectorV1(
        channel: originChannel,
        registry: registry,
        originDeviceID: originDeviceID,
        memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
      _ = try origin.enqueue(job)
      let environment = [
        TatwoLoopSandboxUnlock.enableEnvKey: TatwoLoopSandboxUnlock.enableSandboxValue,
        TatwoLoopSandboxUnlock.sandboxRootEnvKey: sandboxRoot.path,
      ]
      let receipts = try makeRunner(
        channel: runnerChannel,
        environment: environment,
        sandboxRootURL: sandboxRoot,
        engine: ExactModelTestEngine(scenario: scenario),
        localRegistry: runnerRegistry).runUntilIdle()
      let receipt = try XCTUnwrap(receipts.first)
      let audited = try XCTUnwrap(try originChannel.resultForAudit(for: job.jobID))

      switch scenario {
      case .missing:
        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.failureCode, "agent_model_attestation_missing")
        XCTAssertNil(receipt.modelExecutionAttestation)
        XCTAssertEqual(audited.status, .failed)
        XCTAssertEqual(try origin.converge(jobID: job.jobID), .failed)
      case .verified:
        XCTAssertEqual(receipt.status, .completed, receipt.message ?? "")
        XCTAssertEqual(
          receipt.modelExecutionAttestation?.requestedCanonicalModelID,
          "fable-5")
        XCTAssertEqual(
          receipt.modelExecutionAttestation?.observedAssistantModelIDs,
          ["claude-fable-5"])
        XCTAssertEqual(
          receipt.modelExecutionAttestation?.modelUsageKeys,
          ["claude-fable-5"])
        XCTAssertEqual(receipt.modelExecutionAttestation?.fallbackEventCount, 0)
        XCTAssertEqual(receipt.modelExecutionAttestation?.outcome, .verifiedExact)
        XCTAssertEqual(audited.modelExecutionAttestation, receipt.modelExecutionAttestation)
        XCTAssertEqual(try origin.converge(jobID: job.jobID), .verified)
        let afterConverge = try XCTUnwrap(
          try originChannel.resultForAudit(for: job.jobID))
        XCTAssertEqual(
          afterConverge.modelExecutionAttestation,
          receipt.modelExecutionAttestation)
      }
    }
  }

  func testOriginConvergeConsumesReadinessBoundFailedAndCancelledResults() throws {
    for terminalStatus in [TatwoLoopJobStatusV1.failed, .cancelled] {
      let root = makeRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let trust = try makeTrustPair(root: root)
      let channelRoot = root.appendingPathComponent("channel")
      let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
      let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
      let work = root.appendingPathComponent("work", isDirectory: true)
      try FileManager.default.createDirectory(
        at: work,
        withIntermediateDirectories: true)
      let readiness = TatwoRemoteDispatchReadinessBindingV1(
        workspaceBindingID: "workspace-terminal-skills",
        workspaceBindingDigest: String(repeating: "a", count: 64),
        agentModelCapabilityDigest: String(repeating: "b", count: 64),
        activeSkillSetDigest: String(repeating: "c", count: 64),
        challengeNonce: "challenge-terminal-\(terminalStatus.rawValue)")
      let job = TatwoLoopJobV1(
        jobID: "job-terminal-\(terminalStatus.rawValue)",
        logicalJobID: "logical-terminal-\(terminalStatus.rawValue)",
        dispatchNonce: "nonce-terminal-\(terminalStatus.rawValue)",
        contractID: contractID,
        goalID: goalID,
        identity: .sub,
        originDeviceID: originDeviceID,
        targetDeviceID: targetDeviceID,
        remoteDispatchReadiness: readiness,
        payload: .tatwoLoop(
          TatwoLoopPayloadV1(
            contractID: contractID,
            goalID: goalID,
            identity: .sub,
            mode: .s,
            taskDescription: "terminal before Skill readback",
            agent: .grok,
            exactModelRouteID: "grok-build")),
        workPath: work.path,
        resourceCaps: TatwoLoopResourceCapsV1(
          maxDurationSec: 2,
          maxOutputBytes: 256),
        stopConditions: TatwoLoopStopConditionsV1(
          cancelFileSignal: true,
          rules: ["cancel-file"]),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000))
      let registry = TatwoDispatchRegistry(
        directoryURL: root.appendingPathComponent("origin-state"))
      let origin = TatwoLoopOriginProjectorV1(
        channel: originChannel,
        registry: registry,
        originDeviceID: originDeviceID,
        memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
      _ = try origin.enqueue(job)
      _ = try runnerChannel.transition(
        jobID: job.jobID,
        to: .delivered,
        reason: "runner-delivered")
      _ = try runnerChannel.transition(
        jobID: job.jobID,
        to: .accepted,
        reason: "runner-accepted")
      _ = try runnerChannel.transition(
        jobID: job.jobID,
        to: .running,
        reason: "runner-started")
      let receipt = try TatwoLoopJobResultReceiptV1(
        job: job,
        projectionSequence: 5,
        status: terminalStatus,
        outputDigest: nil,
        outputBytes: 0,
        exitCode: terminalStatus == .failed ? 1 : nil,
        failureCode: terminalStatus == .failed
          ? "agent_skill_projection_failed"
          : "cancelled",
        message: "terminal before agent Skill readback",
        startedAt: Date(),
        finishedAt: Date())
      _ = try runnerChannel.transition(
        jobID: job.jobID,
        to: terminalStatus,
        reason: "runner-\(terminalStatus.rawValue)",
        result: receipt)

      XCTAssertEqual(try origin.converge(jobID: job.jobID), terminalStatus)
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: originChannel.resultConsumeMarkerURL(forJobID: job.jobID).path))
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: originChannel.resultConsumeHighWaterURL(forJobID: job.jobID).path))
      XCTAssertEqual(
        try originChannel.currentStatus(for: job.jobID),
        terminalStatus)
      let projected = try XCTUnwrap(
        try registry.run(forContractID: contractID)?.records.first {
          $0.remoteJobID == job.jobID
        })
      XCTAssertEqual(projected.remoteStatus, terminalStatus)
      XCTAssertNotEqual(projected.remoteStatus, .verified)
    }
  }

  func testOriginRejectsFailedAgentReceiptWithMismatchedSkillReadback() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(
      at: work,
      withIntermediateDirectories: true)
    let readiness = TatwoRemoteDispatchReadinessBindingV1(
      workspaceBindingID: "workspace-failed-skill-mismatch",
      workspaceBindingDigest: String(repeating: "a", count: 64),
      agentModelCapabilityDigest: String(repeating: "b", count: 64),
      activeSkillSetDigest: String(repeating: "c", count: 64),
      challengeNonce: "challenge-failed-skill-mismatch")
    let job = TatwoLoopJobV1(
      jobID: "job-failed-skill-mismatch",
      logicalJobID: "logical-failed-skill-mismatch",
      dispatchNonce: "nonce-failed-skill-mismatch",
      contractID: contractID,
      goalID: goalID,
      identity: .sub,
      originDeviceID: originDeviceID,
      targetDeviceID: targetDeviceID,
      remoteDispatchReadiness: readiness,
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .s,
          taskDescription: "failed result with mismatched Skill readback",
          agent: .grok,
          exactModelRouteID: "grok-build")),
      workPath: work.path,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: 2,
        maxOutputBytes: 256),
      stopConditions: TatwoLoopStopConditionsV1(
        cancelFileSignal: true,
        rules: ["cancel-file"]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
    _ = try origin.enqueue(job)
    for (status, reason) in [
      (TatwoLoopJobStatusV1.delivered, "runner-delivered"),
      (.accepted, "runner-accepted"),
      (.running, "runner-started"),
    ] {
      _ = try runnerChannel.transition(
        jobID: job.jobID,
        to: status,
        reason: reason)
    }
    let receipt = TatwoLoopJobResultReceiptV1(
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      projectionSequence: 5,
      status: .failed,
      outputDigest: nil,
      outputBytes: 0,
      exitCode: 1,
      failureCode: "agent_skill_readback_mismatch",
      message: "agent loaded a different Skill set",
      startedAt: Date(),
      finishedAt: Date(),
      expectedActiveSkillSetDigest: readiness.activeSkillSetDigest,
      actualLoadedSkillSetDigest: String(repeating: "d", count: 64))
    _ = try runnerChannel.transition(
      jobID: job.jobID,
      to: .failed,
      reason: "runner-failed",
      result: receipt)

    XCTAssertThrowsError(try origin.converge(jobID: job.jobID)) { error in
      guard case TatwoLoopJobStateError.invalidPayload(let detail) = error else {
        return XCTFail("expected invalid Skill readback, got \(error)")
      }
      XCTAssertTrue(detail.contains("does not match readiness"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: originChannel.resultConsumeMarkerURL(forJobID: job.jobID).path))
    XCTAssertEqual(try originChannel.currentStatus(for: job.jobID), .failed)
  }

  // MARK: - Wave 0 residual cleanup

  func testRemoteRegistryAssignsMonotonicAttemptsAndKeepsPhysicalJobIdempotent() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("state"))
    let logicalJobID = "logical-registry-attempts"
    let work = root.appendingPathComponent("work")
    let firstJob = makeJob(
      jobID: "job-registry-attempt-1",
      logicalJobID: logicalJobID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)

    let first = try registry.beginRemoteTestFixtureUnbound(job: firstJob)
    let firstReplay = try registry.beginRemoteTestFixtureUnbound(job: firstJob)
    XCTAssertEqual(firstReplay, first)
    XCTAssertEqual(first.resolvedAttempt, 1)
    XCTAssertEqual(
      try registry.run(forContractID: contractID)?.records.count,
      1)

    _ = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: firstJob.jobID,
      remoteStatus: .failed,
      failureCode: "server_error",
      errorMessage: "retryable remote failure")
    let secondJob = makeJob(
      jobID: "job-registry-attempt-2",
      logicalJobID: logicalJobID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work,
      dispatchNonce: "nonce-registry-attempt-2")
    let second = try registry.beginRemoteTestFixtureUnbound(job: secondJob)
    XCTAssertEqual(second.resolvedAttempt, 2)

    let cancelledRecord = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: secondJob.jobID,
      remoteStatus: .cancelled,
      failureCode: "cancelled",
      errorMessage: "origin cancelled retry")
    XCTAssertEqual(cancelledRecord.failureReceipt?.errorCode, "cancelled")
    let thirdJob = makeJob(
      jobID: "job-registry-attempt-3",
      logicalJobID: logicalJobID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work,
      dispatchNonce: "nonce-registry-attempt-3")
    let third = try registry.beginRemoteTestFixtureUnbound(job: thirdJob)

    XCTAssertEqual(third.resolvedAttempt, 3)
    XCTAssertEqual(
      try registry.run(forContractID: contractID)?.records
        .map(\.resolvedAttempt)
        .sorted(),
      [1, 2, 3])
  }

  func testRemoteRegistryFailsClosedAfterSuccessfulLogicalHead() throws {
    for terminalStatus in [
      TatwoLoopJobStatusV1.completed,
      .verified,
    ] {
      let root = makeRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let registry = TatwoDispatchRegistry(
        directoryURL: root.appendingPathComponent("state"))
      let logicalJobID = "logical-success-head-\(terminalStatus.rawValue)"
      let firstJob = makeJob(
        jobID: "job-success-head-1-\(terminalStatus.rawValue)",
        logicalJobID: logicalJobID,
        payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
        workPath: root.appendingPathComponent("work"))
      _ = try registry.beginRemoteTestFixtureUnbound(job: firstJob)
      _ = try registry.projectRemoteStatus(
        contractID: contractID,
        remoteJobID: firstJob.jobID,
        remoteStatus: .completed)
      if terminalStatus == .verified {
        _ = try registry.projectRemoteStatus(
          contractID: contractID,
          remoteJobID: firstJob.jobID,
          remoteStatus: .verified)
      }
      let retryJob = makeJob(
        jobID: "job-success-head-2-\(terminalStatus.rawValue)",
        logicalJobID: logicalJobID,
        payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
        workPath: root.appendingPathComponent("work"),
        dispatchNonce: "nonce-success-head-2-\(terminalStatus.rawValue)")

      XCTAssertThrowsError(try registry.beginRemoteTestFixtureUnbound(job: retryJob)) { error in
        guard case TatwoDispatchRegistryError.terminalDispatchCannotRetry = error else {
          return XCTFail("expected terminalDispatchCannotRetry, got \(error)")
        }
      }
      XCTAssertEqual(
        try registry.run(forContractID: contractID)?.records.count,
        1)
    }
  }

  func testOlderCompletedAttemptDoesNotCloseHigherLogicalHead() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("state"))
    let logicalJobID = "logical-late-success"
    let firstJob = makeJob(
      jobID: "job-late-success-1",
      logicalJobID: logicalJobID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: root.appendingPathComponent("work"))
    let secondJob = makeJob(
      jobID: "job-late-success-2",
      logicalJobID: logicalJobID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: root.appendingPathComponent("work"),
      dispatchNonce: "nonce-late-success-2")

    XCTAssertEqual(try registry.beginRemoteTestFixtureUnbound(job: firstJob).resolvedAttempt, 1)
    XCTAssertEqual(try registry.beginRemoteTestFixtureUnbound(job: secondJob).resolvedAttempt, 2)
    _ = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: firstJob.jobID,
      remoteStatus: .completed)

    let thirdJob = makeJob(
      jobID: "job-late-success-3",
      logicalJobID: logicalJobID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: root.appendingPathComponent("work"),
      dispatchNonce: "nonce-late-success-3")
    XCTAssertEqual(try registry.beginRemoteTestFixtureUnbound(job: thirdJob).resolvedAttempt, 3)
  }

  func testInboundRemoteMirrorUsesLogicalAttemptsAndPhysicalIdempotency() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("state"))
    let logicalJobID = "logical-inbound-attempts"
    let firstJob = makeJob(
      jobID: "job-inbound-attempt-1",
      logicalJobID: logicalJobID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: root.appendingPathComponent("work"))
    let first = try registry.ensureInboundRemoteMirror(job: firstJob)
    XCTAssertEqual(
      try registry.ensureInboundRemoteMirror(job: firstJob),
      first)

    _ = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: firstJob.jobID,
      remoteStatus: .cancelled)
    let secondJob = makeJob(
      jobID: "job-inbound-attempt-2",
      logicalJobID: logicalJobID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: root.appendingPathComponent("work"),
      dispatchNonce: "nonce-inbound-attempt-2")
    let second = try registry.ensureInboundRemoteMirror(job: secondJob)

    XCTAssertEqual(first.resolvedAttempt, 1)
    XCTAssertEqual(second.resolvedAttempt, 2)
    XCTAssertEqual(
      try registry.run(forContractID: contractID)?.records.count,
      2)
  }

  func testProjectRemoteStatusRejectsRegressionAndNilSkips() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("state"))
    let job = makeJob(
      jobID: "job-project-regress",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: root.appendingPathComponent("work"))
    _ = try registry.beginRemoteTestFixtureUnbound(job: job)
    _ = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: job.jobID,
      remoteStatus: .running)
    _ = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: job.jobID,
      remoteStatus: .completed,
      receiptID: "receipt-terminal",
      outputRef: "sha256:abc",
      resultDigest: "sha256:result-1",
      projectionSequence: 1)

    // nil remoteStatus must not wipe terminal status, and must not rewrite evidence.
    let skipped = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: job.jobID,
      remoteStatus: nil)
    XCTAssertEqual(skipped.remoteStatus, .completed)
    XCTAssertEqual(skipped.receiptID, "receipt-terminal")
    XCTAssertThrowsError(
      try registry.projectRemoteStatus(
        contractID: contractID,
        remoteJobID: job.jobID,
        remoteStatus: nil,
        receiptID: "receipt-stale")
    ) { error in
      guard case TatwoDispatchRegistryError.terminalEvidenceRegression = error else {
        return XCTFail("expected terminalEvidenceRegression, got \(error)")
      }
    }

    // Terminal must not be covered by running/queued.
    XCTAssertThrowsError(
      try registry.projectRemoteStatus(
        contractID: contractID,
        remoteJobID: job.jobID,
        remoteStatus: .running)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDispatchRegistryError,
        .remoteStatusRegression(from: .completed, to: .running))
    }
    XCTAssertThrowsError(
      try registry.projectRemoteStatus(
        contractID: contractID,
        remoteJobID: job.jobID,
        remoteStatus: .queued)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDispatchRegistryError,
        .remoteStatusRegression(from: .completed, to: .queued))
    }
    let still = try XCTUnwrap(
      try registry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertEqual(still.remoteStatus, .completed)
    XCTAssertEqual(still.status, .completed)

    // Forward progress to verified still allowed (same evidence).
    let verified = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: job.jobID,
      remoteStatus: .verified,
      receiptID: "receipt-terminal",
      outputRef: "sha256:abc",
      resultDigest: "sha256:result-1",
      projectionSequence: 1)
    XCTAssertEqual(verified.remoteStatus, .verified)
    // H3/C2: projection layer keeps verified distinct from completed.
    XCTAssertEqual(verified.status, .verified)
    XCTAssertNotEqual(verified.status, .completed)
  }

  /// H3/C2: verified is an independent local presentation value (≠ completed).
  func testProjectRemoteStatusKeepsVerifiedDistinctFromCompleted() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("state"))
    let job = makeJob(
      jobID: "job-verified-distinct",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: root.appendingPathComponent("work"))
    _ = try registry.beginRemoteTestFixtureUnbound(job: job)

    let completed = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: job.jobID,
      remoteStatus: .completed,
      receiptID: "receipt-exec",
      outputRef: "sha256:out",
      resultDigest: "sha256:result-exec",
      projectionSequence: 1)
    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(completed.remoteStatus, .completed)
    XCTAssertNotEqual(completed.status, .verified)

    let verified = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: job.jobID,
      remoteStatus: .verified,
      receiptID: "receipt-exec",
      outputRef: "sha256:out",
      resultDigest: "sha256:result-exec",
      projectionSequence: 1)
    XCTAssertEqual(verified.remoteStatus, .verified)
    XCTAssertEqual(verified.status, .verified)
    XCTAssertNotEqual(verified.status, .completed)
    XCTAssertNotEqual(TatwoDispatchStatus.verified, TatwoDispatchStatus.completed)
  }

  /// H3/C1: channel journal durably records delivered before accepted (delivered-only observable).
  func testJournalObservesDeliveredOnlyBeforeAcceptedTransition() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work", isDirectory: true)
    let trust = try makeTrustPair(root: root)
    let channel = TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel"),
      trust: trust.origin,
      environment: testEnv)
    let job = makeJob(
      jobID: "job-delivered-only",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["c1"])),
      workPath: work)

    _ = try channel.enqueue(job)
    _ = try channel.transition(
      jobID: job.jobID,
      to: .delivered,
      reason: "runner-discovered")

    // After delivered transition returns, durable journal/ack show delivered-only
    // (no artificial delay; each transition prepare/commits independently).
    XCTAssertEqual(try channel.currentStatus(for: job.jobID), .delivered)
    let deliveredJournal = try channel.journal(for: job.jobID)
    XCTAssertEqual(deliveredJournal.map(\.to), [.queued, .delivered])
    XCTAssertFalse(deliveredJournal.map(\.to).contains(.accepted))
    XCTAssertFalse(deliveredJournal.map(\.to).contains(.running))
    let deliveredAck = try XCTUnwrap(channel.ack(for: job.jobID))
    XCTAssertEqual(deliveredAck.status, .delivered)

    // Fresh channel handle reloads disk truth — still delivered-only.
    let reopened = TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel"),
      trust: trust.origin,
      environment: testEnv)
    XCTAssertEqual(try reopened.currentStatus(for: job.jobID), .delivered)
    XCTAssertEqual(
      try reopened.journal(for: job.jobID).map(\.to),
      [.queued, .delivered])

    _ = try channel.transition(
      jobID: job.jobID,
      to: .accepted,
      reason: "runner-accepted")
    XCTAssertEqual(try channel.currentStatus(for: job.jobID), .accepted)
    XCTAssertEqual(
      try channel.journal(for: job.jobID).map(\.to),
      [.queued, .delivered, .accepted])
  }

  func testTerminalEvidenceRejectsStaleReceiptReplay() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("state"))
    let job = makeJob(
      jobID: "job-terminal-evidence",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: root.appendingPathComponent("work"))
    _ = try registry.beginRemoteTestFixtureUnbound(job: job)
    _ = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: job.jobID,
      remoteStatus: .completed,
      receiptID: "receipt-good",
      outputRef: "sha256:good",
      resultDigest: "sha256:digest-good",
      projectionSequence: 2)

    XCTAssertThrowsError(
      try registry.projectRemoteStatus(
        contractID: contractID,
        remoteJobID: job.jobID,
        remoteStatus: .completed,
        receiptID: "receipt-old",
        outputRef: "sha256:old",
        resultDigest: "sha256:digest-old",
        projectionSequence: 1)
    ) { error in
      guard case TatwoDispatchRegistryError.terminalEvidenceRegression = error else {
        return XCTFail("expected terminalEvidenceRegression, got \(error)")
      }
    }
    XCTAssertThrowsError(
      try registry.projectRemoteStatus(
        contractID: contractID,
        remoteJobID: job.jobID,
        remoteStatus: .completed,
        receiptID: "receipt-old",
        outputRef: "sha256:old",
        resultDigest: "sha256:digest-old",
        projectionSequence: 2)
    ) { error in
      switch error {
      case TatwoDispatchRegistryError.terminalEvidenceRegression,
        TatwoDispatchRegistryError.resultConsumeConflict:
        return
      default:
        XCTFail("expected evidence reject, got \(error)")
      }
    }
    let kept = try XCTUnwrap(
      try registry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertEqual(kept.receiptID, "receipt-good")
    XCTAssertEqual(kept.outputRef, "sha256:good")
    XCTAssertEqual(kept.consumedResultDigest, "sha256:digest-good")
  }

  func testStaleSignedBundleConvergeRejectedByJobBinding() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let job = makeJob(
      jobID: "job-replay-bundle",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["v1"])),
      workPath: work,
      dispatchNonce: "nonce-v1")
    let registry = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("origin-state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
    _ = try origin.enqueue(job)
    _ = try makeRunner(channel: runnerChannel).runUntilIdle()
    XCTAssertEqual(try origin.converge(jobID: job.jobID), .verified)

    // Snapshot the completed signed bundle (unique names — job + job sig share basename).
    let jobURL = originChannel.jobURL(for: job)
    let jobSigURL = originChannel.jobSignatureURL(for: job)
    let journalURL = originChannel.journalURL(forJobID: job.jobID)
    let journalSigURL = originChannel.journalSignatureURL(forJobID: job.jobID)
    let resultURL = originChannel.resultURL(forJobID: job.jobID)
    let resultSigURL = originChannel.resultSignatureURL(forJobID: job.jobID)
    let bundleDir = root.appendingPathComponent("old-bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
    let snapshots: [(URL, String)] = [
      (jobURL, "job.json"),
      (jobSigURL, "job.sig.json"),
      (journalURL, "journal.jsonl"),
      (journalSigURL, "journal.sig.json"),
      (resultURL, "result.json"),
      (resultSigURL, "result.sig.json"),
    ]
    for (url, name) in snapshots {
      try FileManager.default.copyItem(at: url, to: bundleDir.appendingPathComponent(name))
    }

    // New attempt: same jobID, different dispatch nonce / payload → new digest.
    let jobV2 = makeJob(
      jobID: "job-replay-bundle",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["v2"])),
      workPath: work,
      dispatchNonce: "nonce-v2")
    // Wipe channel artifacts and re-enqueue v2 into a fresh registry binding path:
    // beginRemote must reject same jobID with different digest against existing record.
    XCTAssertThrowsError(try registry.beginRemoteTestFixtureUnbound(job: jobV2)) { error in
      guard case TatwoDispatchRegistryError.remoteJobBindingMismatch = error else {
        return XCTFail("expected remoteJobBindingMismatch, got \(error)")
      }
    }

    // Simulate partial rollback: replace channel with old completed bundle while registry
    // still holds v1 binding that was already verified — re-converge is idempotent.
    // To exercise stale push after rebinding failure, create a clean registry that only
    // knows about v2, then plant the old v1 bundle and attempt converge.
    let registryV2 = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state-v2"))
    _ = try registryV2.beginRemoteTestFixtureUnbound(job: jobV2)
    // Plant old completed artifacts under the shared channel jobID path.
    try FileManager.default.removeItem(at: jobURL)
    try FileManager.default.removeItem(at: jobSigURL)
    try? FileManager.default.removeItem(at: journalURL)
    try? FileManager.default.removeItem(at: journalSigURL)
    try? FileManager.default.removeItem(at: resultURL)
    try? FileManager.default.removeItem(at: resultSigURL)
    let restores: [(String, URL)] = [
      ("job.json", jobURL),
      ("job.sig.json", jobSigURL),
      ("journal.jsonl", journalURL),
      ("journal.sig.json", journalSigURL),
      ("result.json", resultURL),
      ("result.sig.json", resultSigURL),
    ]
    for (name, dest) in restores {
      try FileManager.default.createDirectory(
        at: dest.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try FileManager.default.copyItem(
        at: bundleDir.appendingPathComponent(name),
        to: dest)
    }

    let originV2 = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registryV2,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("origin-state-v2")))
    XCTAssertThrowsError(try originV2.converge(jobID: job.jobID)) { error in
      if case TatwoDispatchRegistryError.remoteJobBindingMismatch = error { return }
      if case TatwoLoopJobStateError.jobBindingMismatch = error { return }
      return XCTFail("expected job binding reject on stale bundle converge, got \(error)")
    }
    let status = try XCTUnwrap(
      try registryV2.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertEqual(status.remoteStatus, .queued)
    XCTAssertNotEqual(status.status, .completed)
  }

  func testStaleSignedJobReplayRejectedOnConsume() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-stale-replay",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["stale"])),
      workPath: work)
    _ = try originChannel.enqueue(job)

    // Re-sign with an ancient signedAt (outside 900s + skew window).
    let payload = try Data(contentsOf: originChannel.jobURL(for: job))
    let oldSignedAt = Date(timeIntervalSinceNow: -10_000)
    let staleSig = try trust.origin.sign(
      payload: payload,
      purpose: .loopJob,
      signedAt: oldSignedAt)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(staleSig).write(
      to: originChannel.jobSignatureURL(for: job),
      options: .atomic)

    // Consume path (jobs listing) must reject as stale_signature.
    let accepted = try runnerChannel.jobs(forTargetDeviceID: targetDeviceID)
    XCTAssertFalse(accepted.contains { $0.jobID == job.jobID })
    let rejects = try runnerChannel.rejections(for: job.jobID)
    XCTAssertTrue(
      rejects.contains { $0.reason == .staleSignature },
      "expected stale_signature reject, got \(rejects.map(\.reason.rawValue))")

    // Audit path job(forJobID:) does not enforce freshness (historical read OK).
    let audited = try runnerChannel.job(forJobID: job.jobID)
    XCTAssertEqual(audited.jobID, job.jobID)
  }

  func testRevocationReceiptIngestionRejectsForgeryAndBlocksSignatures() throws {
    let originStore = MemoryDevicePrivateKeyStore()
    let runnerKeyStore = MemoryDevicePrivateKeyStore()
    var originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: originDeviceID,
      privateKeyStore: originStore)
    var runnerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: targetDeviceID,
      privateKeyStore: runnerKeyStore)
    originTrust = try originTrust.withPin(runnerTrust.localIdentity)
    runnerTrust = try runnerTrust.withPin(originTrust.localIdentity)

    let revocation = try runnerTrust.authority.revoke(
      targetIdentity: originTrust.localIdentity,
      authorizedBy: runnerTrust.localIdentity,
      authorityEpoch: 3,
      reason: "device replaced",
      revokedAt: TatwoLoopJobChannelTrust.iso8601(Date()))

    // Forged receipt (tampered reason after signing) must be rejected.
    let forged = TatwoDeviceKeyRevocationReceiptV1(
      targetDeviceID: revocation.receipt.targetDeviceID,
      targetKeyID: revocation.receipt.targetKeyID,
      targetKeyGeneration: revocation.receipt.targetKeyGeneration,
      authorizedByDeviceID: revocation.receipt.authorizedByDeviceID,
      authorizedByKeyID: revocation.receipt.authorizedByKeyID,
      authorizedByKeyGeneration: revocation.receipt.authorizedByKeyGeneration,
      authorityEpoch: revocation.receipt.authorityEpoch,
      reason: "forged reason",
      revokedAt: revocation.receipt.revokedAt,
      authorization: revocation.receipt.authorization)
    XCTAssertThrowsError(
      try runnerTrust.ingestRevocationReceipt(forged, expectedAuthorityEpoch: 3)
    ) { error in
      XCTAssertEqual(error as? TatwoDeviceTrustError, .invalidRevocation)
    }

    // Genuine receipt marks pin revoked.
    let after = try runnerTrust.ingestRevocationReceipt(
      revocation.receipt,
      expectedAuthorityEpoch: 3)
    XCTAssertEqual(after.pinnedIdentities[originDeviceID]?.keyStatus, .revoked)

    // Signatures from the revoked pin now fail closed.
    let freshPayload = Data("post-revoke-bytes".utf8)
    let postSig = try originTrust.sign(payload: freshPayload, purpose: .loopJob)
    XCTAssertThrowsError(
      try after.verify(
        payload: freshPayload,
        purpose: .loopJob,
        signature: postSig,
        expectedDeviceID: originDeviceID)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopJobStateError,
        .signatureRejected(
          jobID: originDeviceID,
          reason: TatwoLoopChannelRejectReasonV1.revoked.rawValue))
    }
  }

  func testLegacyLoopSandboxRootEnvAloneIsHardError() throws {
    let env = [
      TatwoLoopSandboxUnlock.legacyMCPSandboxRootEnvKey: "/tmp/mcp-only-root"
    ]
    XCTAssertThrowsError(
      try TatwoLoopSandboxUnlock.sandboxRootURL(environment: env)
    ) { error in
      guard case let TatwoLoopJobStateError.invalidPayload(message) = error else {
        return XCTFail("expected invalidPayload, got \(error)")
      }
      XCTAssertTrue(message.contains(TatwoLoopSandboxUnlock.sandboxRootEnvKey))
      XCTAssertTrue(message.contains(TatwoLoopSandboxUnlock.legacyMCPSandboxRootEnvKey))
    }
    // New key alone is fine.
    let ok = try TatwoLoopSandboxUnlock.sandboxRootURL(
      environment: [TatwoLoopSandboxUnlock.sandboxRootEnvKey: "/tmp/loop-root"])
    XCTAssertEqual(ok?.path, "/tmp/loop-root")
  }

  // MARK: - Wave 0 package C: authority epoch chain

  func testRevokedKeySelfSignedRotationRejected() throws {
    let originStore = MemoryDevicePrivateKeyStore()
    let runnerKeyStore = MemoryDevicePrivateKeyStore()
    var originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: originDeviceID,
      privateKeyStore: originStore)
    var runnerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: targetDeviceID,
      privateKeyStore: runnerKeyStore)
    originTrust = try originTrust.withPin(runnerTrust.localIdentity)
    runnerTrust = try runnerTrust.withPin(originTrust.localIdentity)

    let revocation = try originTrust.authority.revoke(
      targetIdentity: runnerTrust.localIdentity,
      authorizedBy: originTrust.localIdentity,
      authorityEpoch: 5,
      reason: "compromised",
      revokedAt: TatwoLoopJobChannelTrust.iso8601(Date()))
    originTrust = try originTrust.ingestRevocationReceipt(
      revocation.receipt,
      expectedAuthorityEpoch: 5)
    XCTAssertEqual(originTrust.pinnedIdentities[targetDeviceID]?.keyStatus, .revoked)

    // Compromised key rotates itself to generation+1 (classic self-sign path).
    let selfRotation = try runnerTrust.authority.rotate(
      identity: runnerTrust.localIdentity,
      rotatedAt: TatwoLoopJobChannelTrust.iso8601(Date()))
    XCTAssertThrowsError(
      try originTrust.withPin(
        selfRotation.identity,
        rotationReceipt: selfRotation.receipt)
    ) { error in
      switch error {
      case TatwoDeviceTrustPinMergeError.reEnrollmentRequiresAuthority,
        TatwoDeviceTrustError.reEnrollmentRequiresAuthority,
        TatwoDeviceTrustError.invalidRotation:
        return
      default:
        XCTFail("expected re-enrollment/authority reject, got \(error)")
      }
    }
  }

  func testAuthoritySignedReEnrollmentAccepted() throws {
    let originStore = MemoryDevicePrivateKeyStore()
    let runnerKeyStore = MemoryDevicePrivateKeyStore()
    var originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: originDeviceID,
      privateKeyStore: originStore)
    var runnerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: targetDeviceID,
      privateKeyStore: runnerKeyStore)
    originTrust = try originTrust.withPin(runnerTrust.localIdentity)
    runnerTrust = try runnerTrust.withPin(originTrust.localIdentity)

    let revokedRunner = runnerTrust.localIdentity
    let revocation = try originTrust.authority.revoke(
      targetIdentity: revokedRunner,
      authorizedBy: originTrust.localIdentity,
      authorityEpoch: 9,
      reason: "replaced",
      revokedAt: TatwoLoopJobChannelTrust.iso8601(Date()))
    originTrust = try originTrust.ingestRevocationReceipt(
      revocation.receipt,
      expectedAuthorityEpoch: 9)

    let rotatedAt = TatwoLoopJobChannelTrust.iso8601(Date())
    // New key material for re-enrollment (generation + 1).
    let newKey = try {
      // Use rotate against a temporary active clone only to mint key material,
      // then discard self-signed receipt and re-authorize via origin authority.
      return try runnerTrust.authority.rotate(
        identity: revokedRunner,
        rotatedAt: rotatedAt)
    }()
    // rotate() requires active; use ensure on generation 2 private key already stored.
    let newIdentity = newKey.identity
    let reEnroll = try originTrust.authority.authorizeReEnrollment(
      oldIdentity: TatwoDevicePublicIdentityV1(
        deviceID: revokedRunner.deviceID,
        keyID: revokedRunner.keyID,
        publicKey: revokedRunner.publicKey,
        keyGeneration: revokedRunner.keyGeneration,
        keyStatus: .revoked,
        pinnedAt: revokedRunner.pinnedAt),
      newIdentity: newIdentity,
      authorizedBy: originTrust.localIdentity,
      authorityEpoch: 10,
      supersedesRevocationEpoch: 9,
      rotatedAt: rotatedAt)
    let accepted = try originTrust.withPin(
      newIdentity,
      rotationReceipt: reEnroll,
      authorizingIdentity: originTrust.localIdentity,
      knownRevocationEpoch: 9)
    XCTAssertEqual(accepted.pinnedIdentities[targetDeviceID]?.keyStatus, .active)
    XCTAssertEqual(accepted.pinnedIdentities[targetDeviceID]?.keyGeneration, newIdentity.keyGeneration)
  }

  func testNewAttemptRejectsOldSignedResultAndJournal() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let jobA = makeJob(
      jobID: "job-attempt-bind",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["a"])),
      workPath: work,
      dispatchNonce: "nonce-a")
    let registry = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("state-a"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("state-a")))
    _ = try origin.enqueue(jobA)
    _ = try makeRunner(channel: runnerChannel).runUntilIdle()
    XCTAssertEqual(try origin.converge(jobID: jobA.jobID), .verified)

    // Snapshot old result/journal signatures.
    let resultURL = originChannel.resultURL(forJobID: jobA.jobID)
    let resultSigURL = originChannel.resultSignatureURL(forJobID: jobA.jobID)
    let journalURL = originChannel.journalURL(forJobID: jobA.jobID)
    let journalSigURL = originChannel.journalSignatureURL(forJobID: jobA.jobID)
    let oldResult = try Data(contentsOf: resultURL)
    let oldResultSig = try Data(contentsOf: resultSigURL)
    let oldJournal = try Data(contentsOf: journalURL)
    let oldJournalSig = try Data(contentsOf: journalSigURL)

    // Fresh registry + new attempt job (same jobID, different nonce) planted with old terminal artifacts.
    let jobB = makeJob(
      jobID: "job-attempt-bind",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["b"])),
      workPath: work,
      dispatchNonce: "nonce-b")
    let registryB = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("state-b"))
    _ = try registryB.beginRemoteTestFixtureUnbound(job: jobB)

    // Replace job with B (signed), but restore A result/journal.
    try? FileManager.default.removeItem(at: originChannel.jobURL(for: jobA))
    try? FileManager.default.removeItem(at: originChannel.jobSignatureURL(for: jobA))
    _ = try originChannel.enqueue(jobB)
    try oldResult.write(to: resultURL, options: .atomic)
    try oldResultSig.write(to: resultSigURL, options: .atomic)
    try oldJournal.write(to: journalURL, options: .atomic)
    try oldJournalSig.write(to: journalSigURL, options: .atomic)

    let originB = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registryB,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("state-b")))
    XCTAssertThrowsError(try originB.converge(jobID: jobB.jobID)) { error in
      switch error {
      case TatwoLoopJobStateError.attemptBindingMismatch,
        TatwoLoopJobStateError.malformedJournal,
        TatwoLoopJobStateError.signatureRejected,
        TatwoDispatchRegistryError.remoteJobBindingMismatch:
        return
      default:
        XCTFail("expected attempt/journal reject for cross-attempt splice, got \(error)")
      }
    }
  }

  func testDeleteConsumeMarkerCannotResurrectAttempt() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-consume-hw",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["once"])),
      workPath: work)
    let registry = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("state")))
    _ = try origin.enqueue(job)
    _ = try makeRunner(channel: runnerChannel).runUntilIdle()
    XCTAssertEqual(try origin.converge(jobID: job.jobID), .verified)

    let markerURL = originChannel.resultConsumeMarkerURL(forJobID: job.jobID)
    let highWaterURL = originChannel.resultConsumeHighWaterURL(forJobID: job.jobID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: highWaterURL.path))
    try? FileManager.default.removeItem(at: markerURL)
    // Dual-check fail-closed: marker missing + durable high-water present → reject.
    XCTAssertThrowsError(try originChannel.consumeResult(for: job.jobID)) { error in
      guard case TatwoLoopJobStateError.resultConsumeConflict = error else {
        return XCTFail("expected resultConsumeConflict after marker delete, got \(error)")
      }
    }

    // Different result digest after high-water must also fail (still no marker).
    let jobDigest = try job.canonicalDigest()
    let forged = TatwoLoopJobResultReceiptV1(
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: jobDigest,
      projectionSequence: 99,
      status: .completed,
      outputDigest: "sha256:forged",
      outputBytes: 1,
      exitCode: 0,
      failureCode: nil,
      message: "forged",
      startedAt: Date(),
      finishedAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let forgedData = try encoder.encode(forged)
    try forgedData.write(to: originChannel.resultURL(forJobID: job.jobID), options: .atomic)
    let forgedSig = try trust.runner.sign(payload: forgedData, purpose: .loopResult)
    try encoder.encode(forgedSig).write(
      to: originChannel.resultSignatureURL(forJobID: job.jobID),
      options: .atomic)
    XCTAssertThrowsError(try originChannel.consumeResult(for: job.jobID)) { error in
      guard case TatwoLoopJobStateError.resultConsumeConflict = error else {
        return XCTFail("expected resultConsumeConflict after high-water, got \(error)")
      }
    }
  }

  func testDeleteConsumeMarkerAndRollbackRegistryStillRejectsReplay() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-consume-hw-registry",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["once"])),
      workPath: work)
    let stateDir = root.appendingPathComponent("state")
    let registry = TatwoDispatchRegistry(directoryURL: stateDir)
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: stateDir))
    _ = try origin.enqueue(job)
    _ = try makeRunner(channel: runnerChannel).runUntilIdle()
    // First consume writes marker + durable high-water; leave journal at completed
    // so a later converge still takes the state-changing consume path.
    XCTAssertNotNil(try originChannel.consumeResult(for: job.jobID))
    XCTAssertEqual(try originChannel.currentStatus(for: job.jobID), .completed)

    // Wipe channel marker + roll registry back to a fresh directory.
    try? FileManager.default.removeItem(
      at: originChannel.resultConsumeMarkerURL(forJobID: job.jobID))
    let rolledRegistry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("state-rolled"))
    _ = try rolledRegistry.beginRemoteTestFixtureUnbound(job: job)
    let originRolled = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: rolledRegistry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("state-rolled")))

    // High-water still present (test-mode file anchor / production Keychain) → reject.
    XCTAssertThrowsError(try originRolled.converge(jobID: job.jobID)) { error in
      guard case TatwoLoopJobStateError.resultConsumeConflict = error else {
        return XCTFail(
          "expected resultConsumeConflict after marker+registry wipe, got \(error)")
      }
    }
    XCTAssertThrowsError(try originChannel.consumeResult(for: job.jobID)) { error in
      guard case TatwoLoopJobStateError.resultConsumeConflict = error else {
        return XCTFail("expected consume dual-check reject, got \(error)")
      }
    }
  }

  func testBareHigherProjectionSequenceCannotReplaceTerminalEvidence() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("state"))
    let job = makeJob(
      jobID: "job-seq-authority",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: root.appendingPathComponent("work"))
    _ = try registry.beginRemoteTestFixtureUnbound(job: job)
    _ = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: job.jobID,
      remoteStatus: .completed,
      receiptID: "receipt-a",
      outputRef: "sha256:a",
      resultDigest: "sha256:digest-a",
      projectionSequence: 5)
    XCTAssertThrowsError(
      try registry.projectRemoteStatus(
        contractID: contractID,
        remoteJobID: job.jobID,
        remoteStatus: .completed,
        receiptID: "receipt-b",
        outputRef: "sha256:b",
        resultDigest: "sha256:digest-b",
        projectionSequence: 99)
    ) { error in
      switch error {
      case TatwoDispatchRegistryError.terminalEvidenceRegression,
        TatwoDispatchRegistryError.resultConsumeConflict:
        return
      default:
        XCTFail("expected evidence reject for bare higher sequence, got \(error)")
      }
    }
    let kept = try XCTUnwrap(
      try registry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertEqual(kept.receiptID, "receipt-a")
    XCTAssertEqual(kept.consumedResultDigest, "sha256:digest-a")
  }

  func testFailureEvidenceHigherSequenceCannotRebuild() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("state"))
    let job = makeJob(
      jobID: "job-failure-writeonce",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: root.appendingPathComponent("work"))
    _ = try registry.beginRemoteTestFixtureUnbound(job: job)
    _ = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: job.jobID,
      remoteStatus: .failed,
      failureCode: "resource_gate_blocked",
      errorMessage: "original failure",
      projectionSequence: 3)
    let first = try XCTUnwrap(
      try registry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    let originalCode = try XCTUnwrap(first.failureReceipt?.errorCode)
    let originalMessage = try XCTUnwrap(first.failureReceipt?.operatorMessage)

    XCTAssertThrowsError(
      try registry.projectRemoteStatus(
        contractID: contractID,
        remoteJobID: job.jobID,
        remoteStatus: .failed,
        failureCode: "timeout",
        errorMessage: "forged failure via higher sequence",
        projectionSequence: 99)
    ) { error in
      guard case TatwoDispatchRegistryError.terminalEvidenceRegression = error else {
        return XCTFail(
          "expected terminalEvidenceRegression for failure rebuild, got \(error)")
      }
    }
    let kept = try XCTUnwrap(
      try registry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertEqual(kept.failureReceipt?.errorCode, originalCode)
    XCTAssertEqual(kept.failureReceipt?.operatorMessage, originalMessage)
    XCTAssertEqual(kept.remoteProjectionSequence, 3)
  }

  func testOriginConvergeRejectsAfterTargetRevocationWithoutReload() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let pinRoot = root.appendingPathComponent("pins", isDirectory: true)
    let env = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]
    let originStore = MemoryDevicePrivateKeyStore()
    let runnerStore = MemoryDevicePrivateKeyStore()
    var originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: originDeviceID,
      privateKeyStore: originStore,
      durablePinStoreRoot: pinRoot,
      loadDurablePins: true,
      environment: env)
    var runnerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: targetDeviceID,
      privateKeyStore: runnerStore,
      environment: env)
    let pinStore = originTrust.durablePinStore(rootURL: pinRoot, environment: env)
    try pinStore.pin(originTrust.localIdentity)
    try pinStore.pin(runnerTrust.localIdentity)
    originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: originDeviceID,
      privateKeyStore: originStore,
      durablePinStoreRoot: pinRoot,
      loadDurablePins: true,
      environment: env)
    runnerTrust = try runnerTrust.withPin(originTrust.localIdentity)

    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = TatwoLoopJobChannel(
      rootURL: channelRoot, trust: originTrust, environment: env)
    let runnerChannel = TatwoLoopJobChannel(
      rootURL: channelRoot, trust: runnerTrust, environment: env)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-rev-converge",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["x"])),
      workPath: work)
    let registry = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("state")))
    _ = try origin.enqueue(job)
    _ = try makeRunner(channel: runnerChannel).runUntilIdle()

    // Revoke target in durable store after result is signed.
    let revocation = try originTrust.authority.revoke(
      targetIdentity: runnerTrust.localIdentity,
      authorizedBy: originTrust.localIdentity,
      authorityEpoch: 4,
      reason: "compromised-mid-flight",
      revokedAt: TatwoLoopJobChannelTrust.iso8601(Date()))
    _ = try originTrust.ingestRevocationReceipt(
      revocation.receipt,
      expectedAuthorityEpoch: 4,
      durableStore: pinStore)

    // converge refreshes trust and must reject revoked target signatures.
    XCTAssertThrowsError(try origin.converge(jobID: job.jobID)) { error in
      guard case TatwoLoopJobStateError.signatureRejected(_, let reason) = error else {
        return XCTFail("expected signatureRejected, got \(error)")
      }
      XCTAssertEqual(reason, TatwoLoopChannelRejectReasonV1.revoked.rawValue)
    }
  }

  // MARK: - Target inbound local mirror (app left-rail)

  /// Target with empty registry executes inbound shellSafe job → local record running→completed.
  func testTargetInboundMirrorCreatesLocalRecordRunningToCompleted() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let job = makeJob(
      jobID: "job-inbound-mirror",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["hi"])),
      workPath: work)
    let originRegistry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state"))
    let runnerRegistry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("runner-state"))
    XCTAssertNil(try runnerRegistry.run(forContractID: contractID))

    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: originRegistry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
    _ = try origin.enqueue(job)

    let receipts = try makeRunner(
      channel: runnerChannel,
      localRegistry: runnerRegistry).runUntilIdle()
    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts[0].status, .completed)

    let localRecords =
      try XCTUnwrap(try runnerRegistry.run(forContractID: contractID)?.records)
    XCTAssertEqual(localRecords.count, 1)
    let local = try XCTUnwrap(localRecords.first { $0.remoteJobID == job.jobID })
    XCTAssertEqual(local.status, .completed)
    XCTAssertEqual(local.remoteStatus, .completed)
    XCTAssertEqual(local.originDeviceID, originDeviceID)
    XCTAssertEqual(local.targetDeviceID, targetDeviceID)
    XCTAssertEqual(local.remoteDispatchNonce, job.dispatchNonce)
    XCTAssertEqual(local.logicalDispatchID, job.logicalJobID)
    XCTAssertEqual(local.sourceSlotID, "inbound-remote:\(originDeviceID)")
    XCTAssertTrue(local.bindingID.hasPrefix("inbound-remote-loop-"))
    XCTAssertNotNil(local.receiptID)
    XCTAssertNotNil(local.outputRef)

    // Origin registry still has its own origin-style prepare record; converge still works.
    let originRecord = try XCTUnwrap(
      try originRegistry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertEqual(originRecord.sourceSlotID, "remote:\(targetDeviceID)")
    XCTAssertEqual(try origin.converge(jobID: job.jobID), .verified)
  }

  /// ensureInboundRemoteMirror + re-run runner is idempotent (one record, no duplicate).
  func testTargetInboundMirrorIsIdempotentOnReplay() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let job = makeJob(
      jobID: "job-inbound-idempotent",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let originRegistry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("origin-state"))
    let runnerRegistry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("runner-state"))
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: originRegistry,
      originDeviceID: originDeviceID,
      memoryGate: allowGate(journal: root.appendingPathComponent("origin-state")))
    _ = try origin.enqueue(job)

    _ = try makeRunner(channel: runnerChannel, localRegistry: runnerRegistry).runUntilIdle()
    let first = try XCTUnwrap(
      try runnerRegistry.run(forContractID: contractID)?.records)
    XCTAssertEqual(first.count, 1)
    let firstID = first[0].id

    // Direct re-ensure is a pure no-op identity return.
    let again = try runnerRegistry.ensureInboundRemoteMirror(job: job)
    XCTAssertEqual(again.id, firstID)
    XCTAssertEqual(
      try runnerRegistry.run(forContractID: contractID)?.records.count, 1)

    // Runner re-entry is claim-fenced; must not invent a second mirror.
    let replay = try makeRunner(channel: runnerChannel, localRegistry: runnerRegistry)
      .runUntilIdle()
    XCTAssertTrue(replay.isEmpty)
    XCTAssertEqual(
      try runnerRegistry.run(forContractID: contractID)?.records.count, 1)
    XCTAssertEqual(
      try runnerRegistry.run(forContractID: contractID)?.records.first?.id, firstID)
  }

  /// Same-machine origin beginRemote then target ensureInbound must not duplicate/overwrite.
  func testInboundMirrorDoesNotDuplicateOriginRecordOnSharedRegistry() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-shared-registry",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work)
    let registry = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("state"))

    let originRecord = try registry.beginRemoteTestFixtureUnbound(job: job)
    XCTAssertEqual(originRecord.sourceSlotID, "remote:\(targetDeviceID)")

    let inbound = try registry.ensureInboundRemoteMirror(job: job)
    XCTAssertEqual(inbound.id, originRecord.id)
    XCTAssertEqual(inbound.sourceSlotID, originRecord.sourceSlotID)
    XCTAssertEqual(try registry.run(forContractID: contractID)?.records.count, 1)

    // Second ensure still one record.
    _ = try registry.ensureInboundRemoteMirror(job: job)
    XCTAssertEqual(try registry.run(forContractID: contractID)?.records.count, 1)
  }

  // MARK: - Output artifact return path

  func testOutputArtifactWrittenAndDigestMatchesReceipt() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-output-happy",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["remote-output-body"])),
      workPath: work)
    _ = try originChannel.enqueue(job)
    let receipts = try makeRunner(channel: runnerChannel).runUntilIdle()
    XCTAssertEqual(receipts.count, 1)
    let receipt = try XCTUnwrap(receipts.first)
    XCTAssertEqual(receipt.status, .completed)
    XCTAssertEqual(receipt.failureCode, nil)

    let bodyURL = runnerChannel.outputURL(forJobID: job.jobID)
    let sigURL = runnerChannel.outputSignatureURL(forJobID: job.jobID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: bodyURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sigURL.path))
    let body = try Data(contentsOf: bodyURL)
    XCTAssertEqual(TatwoLoopJobDigest.sha256(body), receipt.outputDigest)
    XCTAssertEqual(body.count, receipt.outputBytes)

    let artifact = try originChannel.outputArtifact(for: job.jobID)
    XCTAssertEqual(artifact.outputDigest, receipt.outputDigest)
    XCTAssertEqual(artifact.data, body)
    XCTAssertEqual(String(data: artifact.data, encoding: .utf8), "remote-output-body\n")
    XCTAssertFalse(artifact.outputTruncated)
    XCTAssertEqual(artifact.dispatchNonce, job.dispatchNonce)
    XCTAssertEqual(artifact.jobCanonicalDigest, try job.canonicalDigest())
  }

  func testOutputArtifactTamperBodyFailsClosed() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-output-tamper-body",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["clean"])),
      workPath: work)
    _ = try originChannel.enqueue(job)
    _ = try makeRunner(channel: runnerChannel).runUntilIdle()
    let bodyURL = originChannel.outputURL(forJobID: job.jobID)
    try Data("evil\n".utf8).write(to: bodyURL, options: .atomic)
    XCTAssertThrowsError(try originChannel.outputArtifact(for: job.jobID)) { error in
      guard case TatwoLoopJobStateError.signatureRejected = error else {
        return XCTFail("expected signatureRejected after body tamper, got \(error)")
      }
    }
  }

  func testOutputArtifactMissingOrTamperedSignatureFailsClosed() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-output-tamper-sig",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["sig"])),
      workPath: work)
    _ = try originChannel.enqueue(job)
    _ = try makeRunner(channel: runnerChannel).runUntilIdle()
    let sigURL = originChannel.outputSignatureURL(forJobID: job.jobID)
    try FileManager.default.removeItem(at: sigURL)
    XCTAssertThrowsError(try originChannel.outputArtifact(for: job.jobID)) { error in
      guard case TatwoLoopJobStateError.signatureRejected = error else {
        return XCTFail("expected signatureRejected after signature remove, got \(error)")
      }
    }

    // Restore path with garbage signature bytes.
    try Data("{not-a-signature}".utf8).write(to: sigURL, options: .atomic)
    XCTAssertThrowsError(try originChannel.outputArtifact(for: job.jobID)) { error in
      guard case TatwoLoopJobStateError.signatureRejected = error else {
        return XCTFail("expected signatureRejected after signature tamper, got \(error)")
      }
    }
  }

  func testOutputArtifactTruncationMarksReceiptAndDigestMatchesBody() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    // Flood stdout via fixed engine template (no untrusted interpolation).
    let floodEngine = ProcessEngineBinding(
      executablePath: "/bin/sh",
      argumentTemplate: [
        "-c",
        "dd if=/dev/zero bs=1024 count=64 2>/dev/null",
      ])
    // shell-safe path rejects oversized echo before run; use tatwoLoop + sandbox unlock.
    let sandbox = root.appendingPathComponent("sandbox", isDirectory: true)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    let jobWork = sandbox.appendingPathComponent("job-work", isDirectory: true)
    try FileManager.default.createDirectory(at: jobWork, withIntermediateDirectories: true)
    let job = makeJob(
      jobID: "job-output-trunc",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .s,
          taskDescription: "flood")),
      workPath: jobWork,
      maxOutputBytes: 64)
    let env = [
      TatwoLoopJobChannelTrust.testModeEnvKey: "1",
      TatwoLoopSandboxUnlock.enableEnvKey: TatwoLoopSandboxUnlock.enableSandboxValue,
      TatwoLoopSandboxUnlock.sandboxRootEnvKey: sandbox.path,
    ]
    _ = try originChannel.enqueue(job)
    let receipts = try makeRunner(
      channel: runnerChannel,
      environment: env,
      sandboxRootURL: sandbox,
      engine: floodEngine
    ).runUntilIdle()
    let receipt = try XCTUnwrap(receipts.first)
    XCTAssertEqual(receipt.failureCode, "output_cap")
    XCTAssertTrue(receipt.outputTruncated)
    XCTAssertLessThanOrEqual(receipt.outputBytes, 64)

    let artifact = try originChannel.outputArtifact(for: job.jobID)
    XCTAssertTrue(artifact.outputTruncated)
    XCTAssertEqual(artifact.outputBytes, receipt.outputBytes)
    XCTAssertEqual(TatwoLoopJobDigest.sha256(artifact.data), receipt.outputDigest)
    XCTAssertLessThanOrEqual(artifact.data.count, 64)
  }

  func testOutputArtifactCrossAttemptBindingFailsClosed() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let jobA = makeJob(
      jobID: "job-output-a",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["alpha-output"])),
      workPath: work)
    let jobB = makeJob(
      jobID: "job-output-b",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["beta-output"])),
      workPath: work)
    _ = try originChannel.enqueue(jobA)
    _ = try originChannel.enqueue(jobB)
    _ = try makeRunner(channel: runnerChannel).runUntilIdle()

    // Copy attempt A's signed output body+sig over B's paths (wrong digest vs B receipt).
    try FileManager.default.removeItem(at: originChannel.outputURL(forJobID: jobB.jobID))
    try FileManager.default.copyItem(
      at: originChannel.outputURL(forJobID: jobA.jobID),
      to: originChannel.outputURL(forJobID: jobB.jobID))
    try FileManager.default.removeItem(at: originChannel.outputSignatureURL(forJobID: jobB.jobID))
    try FileManager.default.copyItem(
      at: originChannel.outputSignatureURL(forJobID: jobA.jobID),
      to: originChannel.outputSignatureURL(forJobID: jobB.jobID))

    let goodA = try originChannel.outputArtifact(for: jobA.jobID)
    XCTAssertEqual(String(data: goodA.data, encoding: .utf8), "alpha-output\n")
    XCTAssertThrowsError(try originChannel.outputArtifact(for: jobB.jobID)) { error in
      guard case TatwoLoopJobStateError.signatureRejected = error else {
        return XCTFail("expected digest reject for cross-attempt output splice, got \(error)")
      }
    }
  }

  // MARK: - I3 D7 residuals C4 / C5 / C6

  /// C4: design vocabulary maps wire cases without renaming enum raw values.
  func testDesignSemanticLabelMapsFiveStatesWithoutRenamingWireCases() {
    XCTAssertEqual(TatwoLoopJobStatusV1.delivered.rawValue, "delivered")
    XCTAssertEqual(TatwoLoopJobStatusV1.accepted.rawValue, "accepted")
    XCTAssertEqual(TatwoLoopJobStatusV1.running.rawValue, "running")
    XCTAssertEqual(TatwoLoopJobStatusV1.completed.rawValue, "completed")
    XCTAssertEqual(TatwoLoopJobStatusV1.verified.rawValue, "verified")

    XCTAssertEqual(TatwoLoopJobStatusV1.delivered.designSemanticLabel, "已送達")
    XCTAssertEqual(
      TatwoLoopJobStatusV1.accepted.designSemanticLabel,
      "已啟動(runner接受)")
    XCTAssertEqual(TatwoLoopJobStatusV1.running.designSemanticLabel, "執行中")
    XCTAssertEqual(TatwoLoopJobStatusV1.completed.designSemanticLabel, "已完成")
    XCTAssertEqual(TatwoLoopJobStatusV1.verified.designSemanticLabel, "已驗收")
    // Naming collision guard: wire `.accepted` is never「已驗收」.
    XCTAssertNotEqual(
      TatwoLoopJobStatusV1.accepted.designSemanticLabel,
      TatwoLoopJobStatusV1.verified.designSemanticLabel)
    XCTAssertFalse(
      TatwoLoopJobStatusV1.accepted.designSemanticLabel.contains("已驗收"))

    // Local dispatch presentation inventory also uses designSemanticLabel.
    XCTAssertEqual(TatwoDispatchStatus.queued.designSemanticLabel, "已排隊")
    XCTAssertEqual(TatwoDispatchStatus.running.designSemanticLabel, "執行中")
    XCTAssertEqual(TatwoDispatchStatus.completed.designSemanticLabel, "已完成")
    XCTAssertEqual(TatwoDispatchStatus.verified.designSemanticLabel, "已驗收")
    XCTAssertEqual(TatwoDispatchLedgerStatus.verified.designSemanticLabel, "已驗收")
    XCTAssertNotEqual(
      TatwoDispatchLedgerStatus.done.designSemanticLabel,
      TatwoDispatchLedgerStatus.verified.designSemanticLabel)
  }

  /// C5: production runner projects local `.running` only after journal `runner-started`.
  func testRunnerProjectsLocalRunningOnlyAfterChannelRunningJournal() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // TatwoUltraworkCoreTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // package root
    let runnerSource = try String(
      contentsOf: packageRoot
        .appendingPathComponent("Sources/TatwoUltraworkCore/RemoteLoopRunner.swift"),
      encoding: .utf8)
    // Happy path order: the helper gate must complete before local running
    // projection, and local projection must complete before execution.
    let runOnceStartKey =
      "public func runOnce() throws -> [TatwoLoopJobResultReceiptV1] {"
    let runOnceEndKey = "public func runUntilIdle(maxPasses:"
    let advanceKey = "guard try advanceChannelToRunning(job: job, from: .queued)"
    let projectKey = "projectLocalRunning(registry: registry, job: job)"
    let executeKey = "let outcome = execute(job)"
    guard
      let runOnceStart = runnerSource.range(of: runOnceStartKey),
      let runOnceEnd = runnerSource.range(
        of: runOnceEndKey,
        range: runOnceStart.upperBound..<runnerSource.endIndex)
    else {
      return XCTFail("missing runOnce anchors in RemoteLoopRunner.swift")
    }
    let runOnceSource = runnerSource[runOnceStart.lowerBound..<runOnceEnd.lowerBound]
    guard
      let projectRange = runOnceSource.range(of: projectKey),
      let advanceRange = runOnceSource.range(
        of: advanceKey,
        options: .backwards,
        range: runOnceSource.startIndex..<projectRange.lowerBound),
      let executeRange = runOnceSource.range(
        of: executeKey,
        range: projectRange.upperBound..<runOnceSource.endIndex)
    else {
      return XCTFail("missing C5 order anchors in runOnce")
    }
    XCTAssertLessThan(
      advanceRange.lowerBound,
      projectRange.lowerBound,
      "projectLocalRunning must follow the channel-to-running gate")
    XCTAssertLessThan(
      projectRange.lowerBound,
      executeRange.lowerBound,
      "projectLocalRunning must complete before execute")
    // Pre-transition early project must not precede the target-execution claim.
    if let claimRange = runOnceSource.range(of: "claimTargetExecution(for: job)") {
      XCTAssertLessThan(
        claimRange.lowerBound,
        advanceRange.lowerBound)
      XCTAssertLessThan(
        claimRange.lowerBound,
        projectRange.lowerBound)
    }

    // The extracted helper itself must durably request `.running` with the
    // runner-started reason before it can report success to runOnce.
    let helperStartKey = "private func advanceChannelToRunning("
    let helperEndKey = "private func committedTerminalReceipt("
    guard
      let helperStart = runnerSource.range(of: helperStartKey),
      let helperEnd = runnerSource.range(
        of: helperEndKey,
        range: helperStart.upperBound..<runnerSource.endIndex)
    else {
      return XCTFail("missing advanceChannelToRunning helper anchors")
    }
    let helperSource = runnerSource[helperStart.lowerBound..<helperEnd.lowerBound]
    guard
      let runningTransition = helperSource.range(
        of: "to: .running,\n      reason: \"runner-started\""),
      let successfulReturn = helperSource.range(
        of: "return running.to == .running")
    else {
      return XCTFail("advanceChannelToRunning no longer proves runner-started durability")
    }
    XCTAssertLessThan(runningTransition.lowerBound, successfulReturn.lowerBound)

    // Protocol: channel running is durable before local projection is applied.
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work", isDirectory: true)
    let trust = try makeTrustPair(root: root)
    let channel = makeChannel(
      rootURL: root.appendingPathComponent("channel"),
      trust: trust.origin)
    let registry = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("state"))
    let job = makeJob(
      jobID: "job-c5-order",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["c5"])),
      workPath: work)
    _ = try channel.enqueue(job)
    _ = try channel.transition(
      jobID: job.jobID, to: .delivered, reason: "runner-discovered")
    _ = try channel.transition(
      jobID: job.jobID, to: .accepted, reason: "runner-accepted")
    // Before running journal: local mirror may exist but must not claim channel running.
    _ = try registry.ensureInboundRemoteMirror(job: job)
    let pre = try XCTUnwrap(
      try registry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertNotEqual(pre.remoteStatus, .running)
    XCTAssertEqual(try channel.currentStatus(for: job.jobID), .accepted)

    _ = try channel.transition(
      jobID: job.jobID, to: .running, reason: "runner-started")
    XCTAssertEqual(try channel.currentStatus(for: job.jobID), .running)
    _ = try registry.projectRemoteStatus(
      contractID: contractID,
      remoteJobID: job.jobID,
      remoteStatus: .running)
    let post = try XCTUnwrap(
      try registry.run(forContractID: contractID)?.records.first {
        $0.remoteJobID == job.jobID
      })
    XCTAssertEqual(post.remoteStatus, .running)
    XCTAssertEqual(post.remoteStatus?.designSemanticLabel, "執行中")
  }

  /// C6:「已啟動」is a typed reader over journal runner-accepted (no second disk artifact).
  func testStartReceiptTypedReaderFromRunnerAcceptedJournal() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = root.appendingPathComponent("work", isDirectory: true)
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let job = makeJob(
      jobID: "job-c6-start",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["start"])),
      workPath: work)

    _ = try originChannel.enqueue(job)
    XCTAssertNil(try originChannel.startReceipt(for: job.jobID))

    _ = try runnerChannel.transition(
      jobID: job.jobID, to: .delivered, reason: "runner-discovered")
    XCTAssertNil(try runnerChannel.startReceipt(for: job.jobID))

    _ = try runnerChannel.transition(
      jobID: job.jobID, to: .accepted, reason: "runner-accepted")
    let start = try XCTUnwrap(try runnerChannel.startReceipt(for: job.jobID))
    XCTAssertEqual(start.schema, TatwoLoopStartReceiptV1.schemaName)
    XCTAssertEqual(start.jobID, job.jobID)
    XCTAssertEqual(start.attempt, job.dispatchNonce)
    XCTAssertEqual(start.jobCanonicalDigest, try job.canonicalDigest())
    XCTAssertEqual(start.reason, TatwoLoopStartReceiptV1.runnerAcceptedReason)
    XCTAssertEqual(start.targetDeviceID, targetDeviceID)
    XCTAssertEqual(start.journalSignature.deviceID, targetDeviceID)
    XCTAssertEqual(start.journalSignerDeviceID, targetDeviceID)
    // Design label for the wire status this receipt represents:
    XCTAssertEqual(TatwoLoopJobStatusV1.accepted.designSemanticLabel, "已啟動(runner接受)")
    XCTAssertGreaterThanOrEqual(start.journalSequence, 1)

    // Still no separate start file under channel root.
    let startFiles = try FileManager.default.contentsOfDirectory(
      at: channelRoot,
      includingPropertiesForKeys: nil)
    XCTAssertFalse(
      startFiles.contains { $0.lastPathComponent.localizedCaseInsensitiveContains("start") },
      "C6 must not introduce a separate start on-disk tree")

    // Advance past accepted; reader still returns the accepted journal entry.
    _ = try runnerChannel.transition(
      jobID: job.jobID, to: .running, reason: "runner-started")
    let afterRunning = try XCTUnwrap(try runnerChannel.startReceipt(for: job.jobID))
    XCTAssertEqual(afterRunning.jobID, job.jobID)
    XCTAssertEqual(afterRunning.reason, "runner-accepted")
    // Signer field is journal ledger at read time (may be target now); not a frozen target-only artifact name.
    XCTAssertEqual(afterRunning.journalSignerDeviceID, afterRunning.journalSignature.deviceID)
  }

  /// C5 recovery: durable `.running` without result resumes execute (crash gap).
  func testRunnerResumesAfterRunningJournalCrashGap() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runnerSource = try String(
      contentsOf: packageRoot
        .appendingPathComponent("Sources/TatwoUltraworkCore/RemoteLoopRunner.swift"),
      encoding: .utf8)
    XCTAssertTrue(
      runnerSource.contains("resumeRunningWithoutResult"),
      "C5 recovery helper must exist")
    XCTAssertTrue(
      runnerSource.contains("local_projection_provisional"),
      "C5 provisional local projection signal must exist")

    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trust = try makeTrustPair(root: root)
    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = makeChannel(rootURL: channelRoot, trust: trust.origin)
    let runnerChannel = makeChannel(rootURL: channelRoot, trust: trust.runner)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let registry = TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("state"))
    let job = makeJob(
      jobID: "job-c5-crash-gap",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["resume"])),
      workPath: work)
    _ = try originChannel.enqueue(job)
    // Simulate crash after durable running journal, before local project/execute.
    try runnerChannel.claimTargetExecution(for: job)
    _ = try runnerChannel.transition(
      jobID: job.jobID, to: .delivered, reason: "runner-discovered")
    _ = try runnerChannel.transition(
      jobID: job.jobID, to: .accepted, reason: "runner-accepted")
    _ = try runnerChannel.transition(
      jobID: job.jobID, to: .running, reason: "runner-started")
    XCTAssertEqual(try runnerChannel.currentStatus(for: job.jobID), .running)
    XCTAssertNil(try runnerChannel.result(for: job.jobID))

    let receipts = try makeRunner(
      channel: runnerChannel,
      localRegistry: registry).runOnce()
    XCTAssertEqual(receipts.count, 1, "crash-gap resume must execute once")
    XCTAssertEqual(receipts.first?.status, .completed, receipts.first?.message ?? "")
    XCTAssertNotNil(try runnerChannel.result(for: job.jobID))
  }
}

private final class RemoteLoopPressureEngineProbeBox: @unchecked Sendable {
  private let lock = NSLock()
  private var observedRuns: Int = 0

  func recordRun() {
    lock.lock()
    observedRuns += 1
    lock.unlock()
  }

  func runCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return observedRuns
  }
}

private struct RemoteLoopPressureCountingEngine: TatwoLoopEngineBinding {
  let box: RemoteLoopPressureEngineProbeBox

  func run(
    task: TatwoLoopEngineTaskV1,
    boundWorkPath: TatwoBoundWorkPath,
    caps: TatwoLoopResourceCapsV1,
    shouldCancel: @Sendable () -> Bool
  ) throws -> TatwoLoopEngineResultV1 {
    _ = task
    _ = boundWorkPath
    _ = caps
    _ = shouldCancel
    box.recordRun()
    return TatwoLoopEngineResultV1(
      exitCode: 0,
      outputData: Data("pressure engine invoked\n".utf8))
  }
}

private enum ExactModelEngineScenario: String {
  case missing
  case verified
}

private struct ExactModelTestEngine: TatwoLoopEngineBinding {
  let scenario: ExactModelEngineScenario

  func run(
    task: TatwoLoopEngineTaskV1,
    boundWorkPath: TatwoBoundWorkPath,
    caps: TatwoLoopResourceCapsV1,
    shouldCancel: @Sendable () -> Bool
  ) throws -> TatwoLoopEngineResultV1 {
    _ = task
    _ = boundWorkPath
    _ = caps
    _ = shouldCancel
    let attestation: TatwoModelExecutionAttestationV1?
    switch scenario {
    case .missing:
      attestation = nil
    case .verified:
      attestation = TatwoModelExecutionAttestationV1(
        requestedCanonicalModelID: "fable-5",
        requestedVendorModelID: "claude-fable-5",
        observedAssistantModelIDs: ["claude-fable-5"],
        modelUsageKeys: ["claude-fable-5"],
        fallbackEventCount: 0,
        outcome: .verifiedExact)
    }
    return TatwoLoopEngineResultV1(
      exitCode: 0,
      outputData: Data("model evidence\n".utf8),
      modelExecutionAttestation: attestation)
  }
}

private final class CancellationProbeBox: @unchecked Sendable {
  let started = DispatchSemaphore(value: 0)
  let sampled = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)
  private let sampleRequest = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var observedSamples: [Bool] = []
  private var observedReceipts: [TatwoLoopJobResultReceiptV1] = []
  private var observedError: Error?

  func requestSample() {
    sampleRequest.signal()
  }

  func waitForSampleRequest() {
    _ = sampleRequest.wait(timeout: .now() + 2)
  }

  func recordSample(_ value: Bool) {
    lock.lock()
    observedSamples.append(value)
    lock.unlock()
    sampled.signal()
  }

  func samples() -> [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return observedSamples
  }

  func finish(receipts: [TatwoLoopJobResultReceiptV1], error: Error?) {
    lock.lock()
    observedReceipts = receipts
    observedError = error
    lock.unlock()
    finished.signal()
  }

  func receipts() -> [TatwoLoopJobResultReceiptV1] {
    lock.lock()
    defer { lock.unlock() }
    return observedReceipts
  }

  func runnerError() -> Error? {
    lock.lock()
    defer { lock.unlock() }
    return observedError
  }
}

private struct CancellationProbeEngine: TatwoLoopEngineBinding {
  let box: CancellationProbeBox

  func run(
    task: TatwoLoopEngineTaskV1,
    boundWorkPath: TatwoBoundWorkPath,
    caps: TatwoLoopResourceCapsV1,
    shouldCancel: @Sendable () -> Bool
  ) throws -> TatwoLoopEngineResultV1 {
    _ = task
    _ = boundWorkPath
    _ = caps
    box.started.signal()
    box.waitForSampleRequest()
    box.recordSample(shouldCancel())
    box.waitForSampleRequest()
    let cancelled = shouldCancel()
    box.recordSample(cancelled)
    return TatwoLoopEngineResultV1(
      exitCode: cancelled ? -1 : 0,
      outputData: Data(),
      cancelled: cancelled,
      failureCode: cancelled ? "cancelled" : nil,
      message: cancelled ? "signed cancel observed" : nil)
  }
}

/// In-memory private key store for unit tests only (no Keychain, no disk).
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
