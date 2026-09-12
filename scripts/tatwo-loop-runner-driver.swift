import Foundation
import TatwoUltraworkCore

private let contractID = "contract-xl-coding-f51cfabe38f8"
private let goalID = "goal-xl-coding-f51cfabe38f8"
private let originDeviceID = "origin-sandbox"
private let targetDeviceID = "runner-sandbox"

private struct SandboxManifest: Codable {
  let schema: String
  let contractID: String
  let goalID: String
  let jobIDs: [String]
  let cancelJobID: String
  let tatwoLoopJobID: String
  let originDeviceID: String
  let targetDeviceID: String
  let originPublicKey: String
  let targetPublicKey: String
}

@main
struct TatwoLoopRunnerDriver {
  static func main() {
    do {
      try run(Array(CommandLine.arguments.dropFirst()))
    } catch {
      fputs("tatwo-loop-runner error: \(error.localizedDescription)\n", stderr)
      Foundation.exit(1)
    }
  }

  private static func run(_ args: [String]) throws {
    guard let command = args.first else {
      throw UsageError.message(
        "expected origin-enqueue, runner, converge, verify, or negative-trust")
    }
    switch command {
    case "origin-enqueue":
      try originEnqueue(args)
    case "runner":
      try runner(args)
    case "converge":
      try converge(args)
    case "verify":
      try verify(args)
    case "negative-trust":
      try negativeTrust(args)
    case "negative-loop":
      try negativeLoop(args)
    case "negative-security":
      try negativeSecurity(args)
    default:
      throw UsageError.message(
        "expected origin-enqueue, runner, converge, verify, negative-trust, negative-loop, or negative-security")
    }
  }

  private static func originEnqueue(_ args: [String]) throws {
    let manifestURL = try requiredFileURL("--manifest", in: args)
    let workURL = try requiredDirectoryURL("--work-path", in: args)
    try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
    let pair = try loadOrCreateTrustPair()
    let channel = try TatwoLoopJobChannel.default(trust: pair.origin)
    let origin = TatwoLoopOriginProjectorV1(
      channel: channel,
      registry: TatwoDispatchRegistry.default(),
      originDeviceID: originDeviceID,
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: TatwoDispatchRegistry.default().directoryURL))
    let jobs = [
      makeJob(
        jobID: "job-success",
        payload: .shellSafe(
          TatwoShellSafePayloadV1(command: .echo, arguments: ["ws1-success"])),
        workURL: workURL,
        maxDurationSec: 2),
      makeJob(
        jobID: "job-timeout",
        payload: .shellSafe(
          TatwoShellSafePayloadV1(command: .sleep, arguments: ["1"])),
        workURL: workURL,
        maxDurationSec: 0.1),
      makeJob(
        jobID: "job-cancel",
        payload: .shellSafe(
          TatwoShellSafePayloadV1(command: .sleep, arguments: ["5"])),
        workURL: workURL,
        maxDurationSec: 2),
      makeJob(
        jobID: "job-tatwo-loop",
        payload: .tatwoLoop(
          TatwoLoopPayloadV1(
            contractID: contractID,
            goalID: goalID,
            identity: .sub,
            mode: .xl,
            taskDescription: "sandbox process-engine probe")),
        workURL: workURL,
        maxDurationSec: 5,
        maxOutputBytes: 4_096),
    ]
    for job in jobs {
      _ = try origin.enqueue(job)
      guard FileManager.default.fileExists(atPath: channel.jobSignatureURL(for: job).path) else {
        throw UsageError.message("missing job signature sidecar for \(job.jobID)")
      }
      guard FileManager.default.fileExists(
        atPath: channel.ackSignatureURL(forJobID: job.jobID).path)
      else {
        throw UsageError.message("missing ack signature sidecar for \(job.jobID)")
      }
    }
    _ = try origin.cancel(jobID: "job-cancel")
    let manifest = SandboxManifest(
      schema: "TatwoRemoteLoopsSandboxManifestV1",
      contractID: contractID,
      goalID: goalID,
      jobIDs: jobs.map(\.jobID),
      cancelJobID: "job-cancel",
      tatwoLoopJobID: "job-tatwo-loop",
      originDeviceID: originDeviceID,
      targetDeviceID: targetDeviceID,
      originPublicKey: pair.origin.localIdentity.publicKey,
      targetPublicKey: pair.runner.localIdentity.publicKey)
    try writeJSON(manifest, to: manifestURL)
    print(
      "origin_enqueued=4 cancel_signaled=job-cancel tatwo_loop=job-tatwo-loop signed=true origin=\(originDeviceID) runner=\(targetDeviceID)"
    )
  }

  private static func runner(_ args: [String]) throws {
    let deviceID = try requiredOption("--device-id", in: args)
    let pair = try loadOrCreateTrustPair()
    let channel = try TatwoLoopJobChannel.default(trust: pair.runner)
    let env = ProcessInfo.processInfo.environment
    let localRegistry = TatwoDispatchRegistry.default(environment: env)
    let receipts = try TatwoLoopRunnerV1(
      channel: channel,
      deviceID: deviceID,
      pollIntervalSec: 0.01,
      environment: env,
      sandboxRootURL: try TatwoLoopSandboxUnlock.sandboxRootURL(environment: env),
      engine: ProcessEngineBinding.sandboxProbe,
      localRegistry: localRegistry,
      memoryGate: MemoryPressureGate(
        minFreePercent: MemoryPressureGate.threshold(environment: env),
        freePercentProvider: { MemoryPressureGate.readSystemFreePercent() ?? 100 },
        journalDirectoryURL: localRegistry.directoryURL)).runUntilIdle()
    for receipt in receipts {
      guard FileManager.default.fileExists(
        atPath: channel.resultSignatureURL(forJobID: receipt.jobID).path)
      else {
        throw UsageError.message("missing result signature for \(receipt.jobID)")
      }
    }
    let summary = receipts
      .sorted { $0.jobID < $1.jobID }
      .map { "\($0.jobID):\($0.status.rawValue):\($0.failureCode ?? "ok")" }
      .joined(separator: ",")
    print("runner_jobs=\(receipts.count) \(summary) signed=true")
  }

  private static func converge(_ args: [String]) throws {
    let manifest = try readJSON(
      SandboxManifest.self,
      from: try requiredFileURL("--manifest", in: args))
    let pair = try loadOrCreateTrustPair()
    let channel = try TatwoLoopJobChannel.default(trust: pair.origin)
    let origin = TatwoLoopOriginProjectorV1(
      channel: channel,
      registry: TatwoDispatchRegistry.default(),
      originDeviceID: originDeviceID,
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: TatwoDispatchRegistry.default().directoryURL))
    for jobID in manifest.jobIDs where jobID != manifest.cancelJobID {
      _ = try origin.converge(jobID: jobID)
    }
    print("origin_converged=3 origin_cancelled=1 verified=true signed=true")
  }

  private static func verify(_ args: [String]) throws {
    let manifest = try readJSON(
      SandboxManifest.self,
      from: try requiredFileURL("--manifest", in: args))
    let pair = try loadOrCreateTrustPair()
    let channel = try TatwoLoopJobChannel.default(trust: pair.origin)
    let expectedJournals: [String: [TatwoLoopJobStatusV1]] = [
      "job-success": [.queued, .delivered, .accepted, .running, .completed, .verified],
      "job-timeout": [.queued, .delivered, .accepted, .running, .failed],
      "job-cancel": [.queued, .cancelled],
      "job-tatwo-loop": [.queued, .delivered, .accepted, .running, .completed, .verified],
    ]
    for jobID in manifest.jobIDs {
      let expectedStatus: TatwoLoopJobStatusV1
      switch jobID {
      case manifest.cancelJobID:
        expectedStatus = .cancelled
      case "job-timeout":
        expectedStatus = .failed
      default:
        expectedStatus = .verified
      }
      guard try channel.currentStatus(for: jobID) == expectedStatus else {
        throw UsageError.message(
          "job \(jobID) did not converge to \(expectedStatus.rawValue)")
      }
      let actual = try channel.journal(for: jobID).map(\.to)
      guard actual == expectedJournals[jobID] else {
        throw UsageError.message(
          "journal mismatch for \(jobID): \(actual.map(\.rawValue).joined(separator: ","))")
      }
      if jobID == manifest.cancelJobID {
        guard try channel.ack(for: jobID)?.status == .cancelled else {
          throw UsageError.message("cancelled job is missing the origin-signed ACK")
        }
        guard try channel.result(for: jobID) == nil else {
          throw UsageError.message("origin-cancelled job fabricated a target result")
        }
        guard FileManager.default.fileExists(
          atPath: channel.cancelSignatureURL(forJobID: jobID).path)
        else {
          throw UsageError.message("cancelled job is missing the origin cancel signature")
        }
        continue
      }
      guard let result = try channel.ack(for: jobID)?.result else {
        throw UsageError.message("missing result receipt for \(jobID)")
      }
      // Standalone signed result artifact must also verify.
      guard let signedResult = try channel.result(for: jobID) else {
        throw UsageError.message("missing signed result artifact for \(jobID)")
      }
      guard signedResult.jobID == result.jobID, signedResult.status == result.status else {
        throw UsageError.message("ack/result artifact mismatch for \(jobID)")
      }
      if jobID == "job-success" {
        guard result.status == .completed, result.failureCode == nil else {
          throw UsageError.message("success receipt mismatch")
        }
      } else if jobID == "job-timeout" {
        guard result.status == .failed, result.failureCode == "timeout" else {
          throw UsageError.message("timeout receipt mismatch")
        }
      } else if jobID == manifest.tatwoLoopJobID {
        guard result.status == .completed, result.failureCode == nil else {
          throw UsageError.message("tatwo-loop receipt mismatch")
        }
        guard (result.outputBytes) > 0 else {
          throw UsageError.message("tatwo-loop produced empty output")
        }
      }
    }
    let registry = TatwoDispatchRegistry.default()
    let records = try registry.run(forContractID: manifest.contractID)?.records ?? []
    guard records.count == 4 else {
      throw UsageError.message("expected 4 registry records, got \(records.count)")
    }
    for record in records {
      let expectedRemoteStatus: TatwoLoopJobStatusV1
      switch record.remoteJobID {
      case manifest.cancelJobID:
        expectedRemoteStatus = .cancelled
      case "job-timeout":
        expectedRemoteStatus = .failed
      default:
        expectedRemoteStatus = .verified
      }
      guard record.originDeviceID == originDeviceID,
        record.targetDeviceID == targetDeviceID,
        record.remoteStatus == expectedRemoteStatus
      else {
        throw UsageError.message("registry device/status projection mismatch")
      }
    }
    guard records.first(where: { $0.remoteJobID == "job-success" })?.status == .verified,
      records.first(where: { $0.remoteJobID == "job-timeout" })?.status == .failed,
      records.first(where: { $0.remoteJobID == "job-cancel" })?.status == .failed,
      records.first(where: { $0.remoteJobID == "job-tatwo-loop" })?.status == .verified,
      records.first(where: { $0.remoteJobID == "job-cancel" })?
        .failureReceipt?.errorCode == "cancelled"
    else {
      throw UsageError.message("registry UI status projection mismatch")
    }

    // Runner-side local registry projection for the live tatwo-loop job.
    if let runnerState = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_RUNNER_STATE_DIR"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !runnerState.isEmpty
    {
      let runnerRegistry = TatwoDispatchRegistry(
        directoryURL: URL(fileURLWithPath: runnerState, isDirectory: true))
      guard
        let local = try runnerRegistry.run(forContractID: manifest.contractID)?.records.first(
          where: { $0.remoteJobID == manifest.tatwoLoopJobID })
      else {
        throw UsageError.message("runner local GoalRun/dispatch record missing for tatwo-loop")
      }
      guard local.status == .completed else {
        throw UsageError.message(
          "runner local registry status expected completed, got \(local.status.rawValue)")
      }
    }

    print(
      "REMOTE_LOOPS_E2E_OK jobs=4 state_machines=4 journal=4 registry_projection=4 signed_results=3 signed_cancel=1 tatwo_loop=executed"
    )
  }

  /// Negative cases for R3-A: tampered job bytes and unknown identity both fail closed.
  private static func negativeTrust(_ args: [String]) throws {
    let workURL = try requiredDirectoryURL("--work-path", in: args)
    try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
    let pair = try loadOrCreateTrustPair()
    let channelRoot = try channelRootURL()
    let runnerChannel = TatwoLoopJobChannel(rootURL: channelRoot, trust: pair.runner)

    // 1) Tamper signed job bytes after a valid origin enqueue.
    let tamperJob = makeJob(
      jobID: "job-tamper",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["before-tamper"])),
      workURL: workURL,
      maxDurationSec: 1)
    let originChannel = TatwoLoopJobChannel(rootURL: channelRoot, trust: pair.origin)
    _ = try originChannel.enqueue(tamperJob)
    let jobURL = originChannel.jobURL(for: tamperJob)
    var bytes = try Data(contentsOf: jobURL)
    guard let range = String(decoding: bytes, as: UTF8.self).range(of: "before-tamper") else {
      throw UsageError.message("tamper fixture missing expected payload text")
    }
    let utf8 = String(decoding: bytes, as: UTF8.self)
      .replacingOccurrences(of: "before-tamper", with: "after-tamper!!!!")
    bytes = Data(utf8.utf8)
    _ = range
    try bytes.write(to: jobURL, options: .atomic)
    let listedAfterTamper = try runnerChannel.jobs(forTargetDeviceID: targetDeviceID)
    guard !listedAfterTamper.contains(where: { $0.jobID == "job-tamper" }) else {
      throw UsageError.message("tampered job was accepted")
    }
    let tamperRejects = try runnerChannel.rejections(for: "job-tamper")
    guard tamperRejects.contains(where: {
      $0.reason == .digestMismatch || $0.reason == .invalidSignature
    }) else {
      throw UsageError.message(
        "expected digest_mismatch/invalid_signature reject for tampered job, got \(tamperRejects.map(\.reason.rawValue))"
      )
    }

    // 2) Unknown identity: sign with a third device that runner has not pinned.
    let strangerStoreRoot = try testKeyStoreRootURL()
      .appendingPathComponent("stranger-keys", isDirectory: true)
    try FileManager.default.createDirectory(
      at: strangerStoreRoot, withIntermediateDirectories: true)
    // Test-only file keystore; never used for production Keychain paths.
    let strangerStore = try TatwoDeviceTestFilePrivateKeyStore(
      rootURL: strangerStoreRoot,
      testModeAuthorized: true,
      environment: ProcessInfo.processInfo.environment)
    let strangerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "stranger-device",
      privateKeyStore: strangerStore)
    let strangerChannel = TatwoLoopJobChannel(rootURL: channelRoot, trust: strangerTrust)
    let unknownJob = makeJob(
      jobID: "job-unknown-identity",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["forged"])),
      workURL: workURL,
      maxDurationSec: 1)
    // Force originDeviceID on job while signing as stranger by using a job that claims stranger as origin.
    let forged = TatwoLoopJobV1(
      jobID: unknownJob.jobID,
      logicalJobID: unknownJob.logicalJobID,
      dispatchNonce: unknownJob.dispatchNonce,
      contractID: unknownJob.contractID,
      goalID: unknownJob.goalID,
      identity: unknownJob.identity,
      originDeviceID: "stranger-device",
      targetDeviceID: targetDeviceID,
      payload: unknownJob.payload,
      workPath: unknownJob.workPath,
      resourceCaps: unknownJob.resourceCaps,
      stopConditions: unknownJob.stopConditions,
      createdAt: unknownJob.createdAt)
    _ = try strangerChannel.enqueue(forged)
    let listedUnknown = try runnerChannel.jobs(forTargetDeviceID: targetDeviceID)
    guard !listedUnknown.contains(where: { $0.jobID == "job-unknown-identity" }) else {
      throw UsageError.message("unknown-identity job was accepted")
    }
    let unknownRejects = try runnerChannel.rejections(for: "job-unknown-identity")
    guard unknownRejects.contains(where: { $0.reason == .unknownIdentity }) else {
      throw UsageError.message(
        "expected unknown_identity reject, got \(unknownRejects.map(\.reason.rawValue))")
    }

    print(
      "REMOTE_LOOPS_NEGATIVE_TRUST_OK tamper=reject unknown_identity=reject"
    )
  }

  /// R3-C negative: env unset (or not sandbox) → tatwo-loop remains disabled.
  private static func negativeLoop(_ args: [String]) throws {
    let workURL = try requiredDirectoryURL("--work-path", in: args)
    try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
    let pair = try loadOrCreateTrustPair()
    let channelRoot = try channelRootURL()
    let originChannel = TatwoLoopJobChannel(rootURL: channelRoot, trust: pair.origin)
    let runnerChannel = TatwoLoopJobChannel(rootURL: channelRoot, trust: pair.runner)
    let job = makeJob(
      jobID: "job-tatwo-loop-disabled",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .xl,
          taskDescription: "must stay disabled without enable env")),
      workURL: workURL,
      maxDurationSec: 2)
    _ = try originChannel.enqueue(job)
    // Explicitly strip enable flag even if the parent shell exported it.
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: TatwoLoopSandboxUnlock.enableEnvKey)
    let receipts = try TatwoLoopRunnerV1(
      channel: runnerChannel,
      deviceID: targetDeviceID,
      pollIntervalSec: 0.01,
      environment: env,
      sandboxRootURL: try TatwoLoopSandboxUnlock.sandboxRootURL(
        environment: ProcessInfo.processInfo.environment),
      engine: ProcessEngineBinding.sandboxProbe,
      localRegistry: nil,
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 })).runUntilIdle()
    guard let receipt = receipts.first(where: { $0.jobID == job.jobID }) else {
      throw UsageError.message("missing receipt for disabled tatwo-loop job")
    }
    guard receipt.status == .failed, receipt.failureCode == "tatwo_loop_disabled" else {
      throw UsageError.message(
        "expected tatwo_loop_disabled, got \(receipt.status.rawValue):\(receipt.failureCode ?? "nil")"
      )
    }
    print("REMOTE_LOOPS_NEGATIVE_LOOP_OK env_unset=tatwo_loop_disabled")
  }

  /// R3 security negatives: journal tamper fail-closed, origin-signed result rejected on converge.
  /// Cross-device pin distribution remains unfinished (M6) — these cases prove local fail-closed wiring only.
  private static func negativeSecurity(_ args: [String]) throws {
    let workURL = try requiredDirectoryURL("--work-path", in: args)
    try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
    let pair = try loadOrCreateTrustPair()
    let channelRoot = try channelRootURL()
    let originChannel = TatwoLoopJobChannel(rootURL: channelRoot, trust: pair.origin)
    let runnerChannel = TatwoLoopJobChannel(rootURL: channelRoot, trust: pair.runner)

    // 1) Journal tamper after enqueue → status/journal reads fail closed; runner will not execute.
    let journalJob = makeJob(
      jobID: "job-journal-tamper",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["ledger"])),
      workURL: workURL,
      maxDurationSec: 2)
    _ = try originChannel.enqueue(journalJob)
    let journalURL = originChannel.journalURL(forJobID: journalJob.jobID)
    var journalBytes = try Data(contentsOf: journalURL)
    if let range = journalBytes.range(of: Data("queued".utf8)) {
      journalBytes.replaceSubrange(range, with: Data("runxxx".utf8))
    }
    try journalBytes.write(to: journalURL, options: .atomic)
    do {
      _ = try runnerChannel.currentStatus(for: journalJob.jobID)
      throw UsageError.message("tampered journal was accepted")
    } catch let error as TatwoLoopJobStateError {
      guard case .signatureRejected = error else {
        throw UsageError.message("expected signatureRejected for journal tamper, got \(error)")
      }
    }
    let receipts = try TatwoLoopRunnerV1(
      channel: runnerChannel,
      deviceID: targetDeviceID,
      pollIntervalSec: 0.01,
      environment: ProcessInfo.processInfo.environment,
      engine: ProcessEngineBinding.sandboxProbe,
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 })).runUntilIdle()
    guard !receipts.contains(where: { $0.jobID == journalJob.jobID }) else {
      throw UsageError.message("runner executed job with tampered journal")
    }

    // 2) Origin self-signed result must not pass converge (M5).
    let launderJob = makeJob(
      jobID: "job-origin-launder",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .true)),
      workURL: workURL,
      maxDurationSec: 1)
    let registry = TatwoDispatchRegistry.default()
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: registry,
      originDeviceID: originDeviceID,
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: registry.directoryURL))
    _ = try origin.enqueue(launderJob)
    _ = try originChannel.transition(jobID: launderJob.jobID, to: .delivered, reason: "forged")
    _ = try originChannel.transition(jobID: launderJob.jobID, to: .accepted, reason: "forged")
    _ = try originChannel.transition(jobID: launderJob.jobID, to: .running, reason: "forged")
    let fake = try TatwoLoopJobResultReceiptV1(
      job: launderJob,
      projectionSequence: 5,
      status: .completed,
      outputDigest: nil,
      outputBytes: 0,
      exitCode: 0,
      failureCode: nil,
      message: "origin-self-signed",
      startedAt: Date(),
      finishedAt: Date())
    _ = try originChannel.transition(
      jobID: launderJob.jobID,
      to: .completed,
      reason: "origin-self-result",
      result: fake)
    do {
      _ = try origin.converge(jobID: launderJob.jobID)
      throw UsageError.message("converge accepted origin-signed result")
    } catch let error as TatwoLoopJobStateError {
      guard case .signatureRejected = error else {
        throw UsageError.message(
          "expected signatureRejected for origin-signed result, got \(error)")
      }
    }

    // 3) Symlink escape must not unlock sandbox.
    let sandboxRoot = try requiredDirectoryURL("--work-path", in: args)
      .deletingLastPathComponent()
    let escape = workURL.appendingPathComponent("escape-root")
    try? FileManager.default.removeItem(at: escape)
    try FileManager.default.createSymbolicLink(
      atPath: escape.path,
      withDestinationPath: "/")
    guard !TatwoLoopSandboxUnlock.isWorkPathInsideSandbox(
      workPath: escape,
      sandboxRoot: sandboxRoot)
    else {
      throw UsageError.message("symlink escape incorrectly passed sandbox check")
    }

    // 4) C1: cross-job result move (copy job-b signed result onto job-a paths) → reject.
    let jobA = makeJob(
      jobID: "job-xmove-a",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["a"])),
      workURL: workURL,
      maxDurationSec: 2)
    let jobB = makeJob(
      jobID: "job-xmove-b",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["b"])),
      workURL: workURL,
      maxDurationSec: 2)
    _ = try origin.enqueue(jobA)
    _ = try origin.enqueue(jobB)
    let xmoveReceipts = try TatwoLoopRunnerV1(
      channel: runnerChannel,
      deviceID: targetDeviceID,
      pollIntervalSec: 0.01,
      environment: ProcessInfo.processInfo.environment,
      engine: ProcessEngineBinding.sandboxProbe,
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 })).runUntilIdle()
    guard xmoveReceipts.contains(where: { $0.jobID == jobB.jobID && $0.status == .completed })
    else {
      throw UsageError.message("setup for cross-job move failed to complete job-b")
    }
    let fm = FileManager.default
    try? fm.removeItem(at: originChannel.resultURL(forJobID: jobA.jobID))
    try? fm.removeItem(at: originChannel.resultSignatureURL(forJobID: jobA.jobID))
    try fm.copyItem(
      at: originChannel.resultURL(forJobID: jobB.jobID),
      to: originChannel.resultURL(forJobID: jobA.jobID))
    try fm.copyItem(
      at: originChannel.resultSignatureURL(forJobID: jobB.jobID),
      to: originChannel.resultSignatureURL(forJobID: jobA.jobID))
    do {
      _ = try originChannel.result(for: jobA.jobID)
      throw UsageError.message("cross-job result move was accepted")
    } catch let error as TatwoLoopJobStateError {
      guard case let .signatureRejected(_, reason) = error,
        reason == TatwoLoopChannelRejectReasonV1.jobIdMismatch.rawValue
      else {
        throw UsageError.message(
          "expected job_id_mismatch for cross-job result move, got \(error)")
      }
    }

    // 5) C2: path-component escape tokens must fail validate / sanitize.
    guard !TatwoLoopPathComponent.isValid(".."),
      !TatwoLoopPathComponent.isValid("."),
      !TatwoLoopPathComponent.isValid("a/b"),
      !TatwoLoopPathComponent.isValid("x\0y"),
      TatwoLoopPathComponent.sanitize("..") != ".."
    else {
      throw UsageError.message("path component whitelist accepted escape token")
    }
    do {
      try makeJob(
        jobID: "..",
        payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
        workURL: workURL,
        maxDurationSec: 1).validate()
      throw UsageError.message("jobID=.. was accepted by validate")
    } catch let error as TatwoLoopJobStateError {
      guard case .invalidJob = error else {
        throw UsageError.message("expected invalidJob for .., got \(error)")
      }
    }

    // 6) C3: memory sensor failure is fail-closed; MIN_FREE=0 remains explicit allow.
    let sensorGate = MemoryPressureGate(
      minFreePercent: 20,
      freePercentProvider: { nil })
    guard case .blocked = sensorGate.evaluate(),
      sensorGate.evaluate().failureCode == "sensor_unavailable"
    else {
      throw UsageError.message("sensor failure must fail-closed as sensor_unavailable")
    }
    let disabledGate = MemoryPressureGate(
      minFreePercent: 0,
      freePercentProvider: { nil })
    guard disabledGate.evaluate() == .allow else {
      throw UsageError.message("MIN_FREE=0 must explicitly allow even when sensor is nil")
    }

    print(
      "REMOTE_LOOPS_NEGATIVE_SECURITY_OK journal_tamper=reject origin_result=reject symlink_escape=reject cross_job_move=reject path_escape=reject sensor_fail_closed=reject min_free_0=allow"
    )
  }

  private static func makeJob(
    jobID: String,
    payload: TatwoLoopJobPayloadV1,
    workURL: URL,
    maxDurationSec: TimeInterval,
    maxOutputBytes: Int = 256
  ) -> TatwoLoopJobV1 {
    TatwoLoopJobV1(
      jobID: jobID,
      logicalJobID: "logical-\(jobID)",
      dispatchNonce: "nonce-\(jobID)",
      contractID: contractID,
      goalID: goalID,
      identity: .sub,
      originDeviceID: originDeviceID,
      targetDeviceID: targetDeviceID,
      payload: payload,
      workPath: workURL.path,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: maxDurationSec,
        maxOutputBytes: maxOutputBytes),
      stopConditions: TatwoLoopStopConditionsV1(
        cancelFileSignal: true,
        rules: ["cancel-file"]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private struct TrustPair {
    let origin: TatwoLoopJobChannelTrust
    let runner: TatwoLoopJobChannelTrust
  }

  /// File-backed **test-only** keystores via TatwoDeviceTestFilePrivateKeyStore.
  /// Private keys never touch Keychain; store roots must sit under temporaryDirectory
  /// (enforced by TatwoDeviceTrust). Public pins are also mirrored under
  /// TATWO_ULTRAWORK_TRUST_ROOT when set (sandbox evidence only).
  /// Hard-requires TATWO_TEST_MODE=1 — never construct test keystores in production.
  private static func loadOrCreateTrustPair() throws -> TrustPair {
    let env = ProcessInfo.processInfo.environment
    guard env[TatwoLoopJobChannelTrust.testModeEnvKey] == "1" else {
      throw UsageError.message(
        "tatwo-loop-runner-driver test trust bootstrap requires TATWO_TEST_MODE=1")
    }
    let keyRoot = try testKeyStoreRootURL()
    let originKeys = keyRoot.appendingPathComponent("origin-keys", isDirectory: true)
    let runnerKeys = keyRoot.appendingPathComponent("runner-keys", isDirectory: true)
    try FileManager.default.createDirectory(at: originKeys, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runnerKeys, withIntermediateDirectories: true)

    let originStore = try TatwoDeviceTestFilePrivateKeyStore(
      rootURL: originKeys,
      testModeAuthorized: true,
      environment: env)
    let runnerStore = try TatwoDeviceTestFilePrivateKeyStore(
      rootURL: runnerKeys,
      testModeAuthorized: true,
      environment: env)

    // withPin is module-internal (test-only). Driver uses enroll additionalPins.
    let originSeed = try TatwoLoopJobChannelTrust.enroll(
      deviceID: originDeviceID,
      privateKeyStore: originStore,
      environment: env)
    let runnerSeed = try TatwoLoopJobChannelTrust.enroll(
      deviceID: targetDeviceID,
      privateKeyStore: runnerStore,
      environment: env)
    let origin = try TatwoLoopJobChannelTrust.enroll(
      deviceID: originDeviceID,
      privateKeyStore: originStore,
      additionalPins: [runnerSeed.localIdentity],
      environment: env)
    let runner = try TatwoLoopJobChannelTrust.enroll(
      deviceID: targetDeviceID,
      privateKeyStore: runnerStore,
      additionalPins: [originSeed.localIdentity],
      environment: env)

    if let pinRoot = optionalTrustEvidenceRootURL() {
      let pinDir = pinRoot.appendingPathComponent("pins", isDirectory: true)
      try FileManager.default.createDirectory(at: pinDir, withIntermediateDirectories: true)
      try writeJSON(
        origin.localIdentity,
        to: pinDir.appendingPathComponent("origin-sandbox.json"))
      try writeJSON(
        runner.localIdentity,
        to: pinDir.appendingPathComponent("runner-sandbox.json"))
    }
    return TrustPair(origin: origin, runner: runner)
  }

  /// Isolated under temporaryDirectory for TatwoDeviceTestFilePrivateKeyStore.
  private static func testKeyStoreRootURL() throws -> URL {
    let channel = try channelRootURL()
    let token = TatwoLoopJobChannelTrust.sha256Hex(Data(channel.path.utf8))
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-remote-loops-e2e-trust", isDirectory: true)
      .appendingPathComponent(String(token.prefix(16)), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func optionalTrustEvidenceRootURL() -> URL? {
    let env = ProcessInfo.processInfo.environment
    guard let raw = env["TATWO_ULTRAWORK_TRUST_ROOT"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else {
      return nil
    }
    return URL(fileURLWithPath: raw, isDirectory: true)
  }

  private static func channelRootURL() throws -> URL {
    guard let raw = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_JOB_CHANNEL_DIR"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else {
      throw TatwoLoopJobStateError.missingChannelRoot
    }
    return URL(fileURLWithPath: raw, isDirectory: true)
  }

  private static func requiredOption(_ name: String, in args: [String]) throws -> String {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
      throw UsageError.message("missing \(name)")
    }
    return args[index + 1]
  }

  private static func requiredFileURL(_ name: String, in args: [String]) throws -> URL {
    URL(fileURLWithPath: try requiredOption(name, in: args), isDirectory: false)
  }

  private static func requiredDirectoryURL(_ name: String, in args: [String]) throws -> URL {
    URL(fileURLWithPath: try requiredOption(name, in: args), isDirectory: true)
  }

  private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try encoder.encode(value).write(to: url)
  }

  private static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(contentsOf: url))
  }
}

private enum UsageError: Error, LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self {
    case let .message(value): return value
    }
  }
}
