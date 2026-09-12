import Foundation
import TatwoDomainContracts
#if canImport(Darwin)
import Darwin
#endif

/// Remote loop runner (target device).
///
/// Peer pins may load from the durable co-signed pin store
/// (`TatwoDeviceTrustPinStore`). Same-process e2e mutual pin remains test wiring;
/// live dual-host flag/run is a separate gate.
public struct TatwoLoopRunnerV1: Sendable {
  public let channel: TatwoLoopJobChannel
  public let deviceID: String
  public let pollIntervalSec: TimeInterval
  public let environment: [String: String]
  public let sandboxRootURL: URL?
  public let engine: any TatwoLoopEngineBinding
  public let localRegistry: TatwoDispatchRegistry?
  public let memoryGate: MemoryPressureGate
  /// Optional target-owned readiness request handler. Production target hosts
  /// inject an observer backed by their local workspace/runtime/Skill store.
  public let readinessHandler: TatwoRemoteDispatchReadinessTargetHandlerV1?
  /// Target-owned signed registry used to resolve production agent workspaces.
  public let workspaceRegistry: TatwoRemoteDispatchReadinessRegistryStoreV1?
  public let workspaceSkilletRootURL: URL?
  public let workspaceSkillRuntimeRootURL: URL?
  public let workspaceAgentEngine: TatwoAgentEngineBinding
  /// Target-App pressure admission gate.  When installed on a runner, every
  /// fresh queued job must consume a fresh App-signed permit before the channel
  /// can move past queued or spawn work. Production start always injects this.
  public let pressureAdmissionController: TatwoRunnerPressureAdmissionControllerV1?

  public init(
    channel: TatwoLoopJobChannel,
    deviceID: String,
    pollIntervalSec: TimeInterval = 0.05,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    sandboxRootURL: URL? = nil,
    engine: any TatwoLoopEngineBinding = ProcessEngineBinding.sandboxProbe,
    localRegistry: TatwoDispatchRegistry? = nil,
    memoryGate: MemoryPressureGate? = nil,
    readinessHandler: TatwoRemoteDispatchReadinessTargetHandlerV1? = nil,
    workspaceRegistry: TatwoRemoteDispatchReadinessRegistryStoreV1? = nil,
    workspaceSkilletRootURL: URL? = nil,
    workspaceSkillRuntimeRootURL: URL? = nil,
    workspaceAgentEngine: TatwoAgentEngineBinding = .production,
    pressureAdmissionController: TatwoRunnerPressureAdmissionControllerV1? = nil
  ) throws {
    self.channel = channel
    self.deviceID = deviceID
    self.pollIntervalSec = max(0.001, pollIntervalSec)
    self.environment = environment
    self.sandboxRootURL = try TatwoLoopSandboxUnlock.sandboxRootURL(
      environment: environment,
      injected: sandboxRootURL)
    self.engine = engine
    self.localRegistry = localRegistry
    self.memoryGate = memoryGate ?? MemoryPressureGate.default(environment: environment)
    self.readinessHandler = readinessHandler
    self.workspaceRegistry = workspaceRegistry
    let normalizedSkilletRoot = workspaceSkilletRootURL?.standardizedFileURL
    let normalizedSkillRuntimeRoot =
      workspaceSkillRuntimeRootURL?.standardizedFileURL
    if let normalizedSkilletRoot, let normalizedSkillRuntimeRoot {
      guard !Self.pathsOverlap(normalizedSkilletRoot, normalizedSkillRuntimeRoot) else {
        throw TatwoRemoteDispatchReadinessRegistryError.bindingDrift(
          "skillRuntimeRootMustNotBeSkilletStore")
      }
    }
    if workspaceRegistry != nil {
      guard normalizedSkilletRoot != nil, normalizedSkillRuntimeRoot != nil else {
        throw TatwoRemoteDispatchReadinessRegistryError.bindingNotFound
      }
    }
    self.workspaceSkilletRootURL = normalizedSkilletRoot
    self.workspaceSkillRuntimeRootURL = normalizedSkillRuntimeRoot
    self.workspaceAgentEngine = workspaceAgentEngine
    self.pressureAdmissionController = pressureAdmissionController
  }

  @discardableResult
  public func runOnce() throws -> [TatwoLoopJobResultReceiptV1] {
    // Live trust reload: pin-store generation drift (e.g. revocation ingest) must
    // take effect before the next dequeue/consume, not only on process restart.
    _ = try channel.refreshTrustFromDurableStoreIfNeeded()
    // Answer redacted, origin-signed readiness requests before dequeue. This
    // is target-owned observation; absence/failure never fabricates a receipt.
    _ = try readinessHandler?.servicePendingRequests()
    // Fleet capacity heartbeat (best-effort). Only refreshes if this device was
    // registered under channelRoot/fleet/devices; never blocks job execution.
    reportFleetHeartbeatBestEffort()
    let jobs = try channel.jobs(forTargetDeviceID: deviceID)
    var receipts: [TatwoLoopJobResultReceiptV1] = []
    for job in jobs {
      // Mid-batch revocation: re-check generation before each job consume.
      _ = try channel.refreshTrustFromDurableStoreIfNeeded()
      // A verified pre-existing origin cancellation is authoritative even
      // though readiness is false. Converge an already-existing target mirror
      // before skipping, without creating a target result or a new mirror.
      if channel.isCancelRequested(for: job) {
        let registry =
          localRegistry
          ?? TatwoDispatchRegistry.default(
            environment: environment,
            originAuthorityProvider: channel.originAuthorityProvider)
        projectExistingLocalCancelledWithoutReceipt(registry: registry, job: job)
        continue
      }
      // Fail-closed completeness: missing commit marker / queued ack means incomplete enqueue.
      // Partial job+journal orphans must never execute.
      guard (try? channel.isReadyForTargetExecution(job: job)) == true else { continue }
      // Replay fence: a target-signed result means the job was already consumed.
      if (try? channel.result(for: job.jobID)) != nil { continue }

      // Journal status is signature-verified; unsigned/tampered journals fail closed.
      let status = try? channel.currentStatus(for: job.jobID)
      let resumeMidFlight: Bool = {
        guard let status else { return false }
        switch status {
        case .delivered, .accepted, .running:
          return true
        case .queued, .completed, .failed, .cancelled, .verified:
          return false
        }
      }()

      if resumeMidFlight {
        // C5 crash gap recovery: durable mid-flight without result.
        // W1-G3b: a recovered runner must still prove the local App pressure
        // issuer is fresh/current before it resumes work.  This is a
        // non-consuming continuation check: fresh queued work consumes the
        // one-shot spawn permit, while mid-flight recovery validates the
        // existing consumption marker plus a fresh App lease/liveness signal.
        if let pressureAdmissionController {
          let admission = pressureAdmissionController.validatesContinuationAuthority(job: job)
          guard admission.authorized else {
            notePressureAdmissionRejection(
              job: job,
              reasonCode: admission.reasonCode,
              surface: "remote_loop_runner.midflight_resume")
            continue
          }
        }
        // Resume is already in the post-claim execution lineage. The global
        // target claim is create-only for spawn, not a one-winner recovery fence.
        // W1-G3b therefore also claims a continuation-resume marker below before
        // any projection/engine execution.
        // If no durable spawn claim exists (test-mode fixtures disable this anchor),
        // attempt to create it before resume; a binding mismatch still blocks.
        if (try? channel.hasTargetExecutionClaim(for: job)) != true {
          do {
            try channel.claimTargetExecution(for: job)
          } catch TatwoProductionLayoutError.targetExecutionAlreadyClaimed {
            // Matching prior claim: remain in the same execution lineage.
          } catch TatwoProductionLayoutError.globalAntiRollbackRegression {
            continue
          }
        }
        if let ack = try? channel.ack(for: job.jobID),
          [.completed, .failed, .cancelled, .verified].contains(ack.status)
        {
          continue
        }
        if let pressureAdmissionController {
          // Final pre-execute authority gate: this validates a fresh/current App
          // permit and atomically claims the one-winner resume fence in the same
          // controller call.  A loser writes no result/terminal/local projection.
          let admission = pressureAdmissionController.claimContinuationResumeAuthority(job: job)
          guard admission.authorized else {
            notePressureAdmissionRejection(
              job: job,
              reasonCode: admission.reasonCode,
              surface: "remote_loop_runner.midflight_resume.claim")
            continue
          }
        }
        let registry =
          localRegistry
          ?? TatwoDispatchRegistry.default(
            environment: environment,
            originAuthorityProvider: channel.originAuthorityProvider)
        if let receipt = try resumeRunningWithoutResult(
          job: job,
          from: status!,
          registry: registry)
        {
          receipts.append(receipt)
        }
        continue
      }

      guard status == .queued else { continue }
      // Ack fence: signed non-queued ack blocks journal-truncation replay (fresh path only).
      if let ack = try? channel.ack(for: job.jobID), ack.status != .queued {
        continue
      }
      // Gate 2: App pressure admission BEFORE any target claim, channel
      // transition, local running projection, or engine spawn. Missing/stale/
      // replayed permits leave the job queued for a fresh App lease; they do
      // not consume the global execution claim.
      if let pressureAdmissionController {
        let admission = pressureAdmissionController.authorize(job: job)
        guard admission.authorized else {
          notePressureAdmissionRejection(job: job, reasonCode: admission.reasonCode)
          continue
        }
      }
      // Gate 3: global target execution claim BEFORE any transition/engine work.
      // Restoring a queued channel+registry snapshot cannot re-enter execution once claimed.
      do {
        try channel.claimTargetExecution(for: job)
      } catch TatwoProductionLayoutError.targetExecutionAlreadyClaimed {
        continue
      } catch TatwoProductionLayoutError.globalAntiRollbackRegression {
        continue
      }
      // Local projection only after channel journal confirms lifecycle transitions
      // (C5: never project `.running` before durable `runner-started` journal/ack).
      let registry =
        localRegistry
        ?? TatwoDispatchRegistry.default(
          environment: environment,
          originAuthorityProvider: channel.originAuthorityProvider)
      let gate = memoryGate.evaluateAndJournal(surface: "remote_loop_runner")
      if case let .blocked(_, _, reason) = gate {
        do {
          guard try advanceChannelToRunning(job: job, from: .queued) else {
            projectLocalCancelledWithoutReceipt(registry: registry, job: job)
            continue
          }
        } catch {
          // Journal failed: never project local running; mark provisional gap.
          noteLocalProjectionFailure(
            registry: registry,
            job: job,
            surface: "remote_loop_runner.journal_failed_before_local",
            error: error,
            code: "local_projection_provisional_journal_failed")
          throw error
        }
        // Gate path still projects terminal via projectLocal; no pre-journal running.
        let startedAt = Date()
        let outcome = failureOutcome(
          job: job,
          code: gate.failureCode ?? "resource_gate_blocked",
          message: reason,
          startedAt: startedAt)
        if cancellationAlreadyCommitted(
          registry: registry,
          job: job)
        {
          continue
        }
        let terminalEntry = try channel.transition(
          jobID: job.jobID,
          to: outcome.receipt.status,
          reason: "runner-finished:\(outcome.receipt.failureCode ?? outcome.receipt.status.rawValue)",
          result: outcome.receipt,
          outputData: outcome.outputData,
          now: outcome.receipt.finishedAt)
        if terminalEntry.to == .cancelled {
          projectLocalCancelledWithoutReceipt(registry: registry, job: job)
          continue
        }
        let committedReceipt = try committedTerminalReceipt(
          job: job,
          entry: terminalEntry,
          proposed: outcome.receipt)
        projectLocal(registry: registry, job: job, receipt: committedReceipt)
        receipts.append(committedReceipt)
        continue
      }

      do {
        guard try advanceChannelToRunning(job: job, from: .queued) else {
          projectLocalCancelledWithoutReceipt(registry: registry, job: job)
          continue
        }
      } catch {
        // Journal failed mid-sequence: no local running projection (none yet). Mark provisional.
        noteLocalProjectionFailure(
          registry: registry,
          job: job,
          surface: "remote_loop_runner.journal_failed_before_local",
          error: error,
          code: "local_projection_provisional_journal_failed")
        throw error
      }
      // C5: journal/ack are durable for `.running` before local mirror projects running.
      projectLocalRunning(registry: registry, job: job)
      let outcome = execute(job)
      if cancellationAlreadyCommitted(
        registry: registry,
        job: job)
      {
        continue
      }
      let terminalEntry = try channel.transition(
        jobID: job.jobID,
        to: outcome.receipt.status,
        reason: "runner-finished:\(outcome.receipt.failureCode ?? outcome.receipt.status.rawValue)",
        result: outcome.receipt,
        outputData: outcome.outputData,
        now: outcome.receipt.finishedAt)
      if terminalEntry.to == .cancelled {
        projectLocalCancelledWithoutReceipt(registry: registry, job: job)
        continue
      }
      let committedReceipt = try committedTerminalReceipt(
        job: job,
        entry: terminalEntry,
        proposed: outcome.receipt)
      projectLocal(registry: registry, job: job, receipt: committedReceipt)
      receipts.append(committedReceipt)
    }
    return receipts
  }

  @discardableResult
  public func runUntilIdle(maxPasses: Int = 10_000) throws
    -> [TatwoLoopJobResultReceiptV1]
  {
    var receipts: [TatwoLoopJobResultReceiptV1] = []
    for _ in 0..<maxPasses {
      let pass = try runOnce()
      receipts.append(contentsOf: pass)
      let pending = try channel.jobs(forTargetDeviceID: deviceID).contains { job in
        if (try? channel.result(for: job.jobID)) != nil { return false }
        let status = try? channel.currentStatus(for: job.jobID)
        // C5 recovery pending: durable mid-flight without result.
        if let status, [.delivered, .accepted, .running].contains(status) {
          if let ack = try? channel.ack(for: job.jobID),
            [.completed, .failed, .cancelled, .verified].contains(ack.status)
          {
            return false
          }
          if let pressureAdmissionController,
            !pressureAdmissionController.validatesContinuationAuthority(job: job).authorized
          {
            return false
          }
          if let pressureAdmissionController,
            pressureAdmissionController.hasContinuationResumeClaimFence(job: job)
          {
            return false
          }
          return true
        }
        guard status == .queued else { return false }
        // Result/ack/claim fences mean the target will not execute this attempt again.
        if let ack = try? channel.ack(for: job.jobID), ack.status != .queued { return false }
        if (try? channel.hasTargetExecutionClaim(for: job)) == true { return false }
        if let pressureAdmissionController,
          !pressureAdmissionController.hasConsumablePermit(job: job)
        {
          return false
        }
        return true
      }
      if !pending {
        return receipts
      }
      Thread.sleep(forTimeInterval: pollIntervalSec)
    }
    throw TatwoLoopJobStateError.runnerLimitReached
  }

  private struct ExecutionOutcome: Sendable {
    let receipt: TatwoLoopJobResultReceiptV1
    /// Present whenever receipt.outputDigest is set (content written with the result).
    let outputData: Data?
  }

  /// Best-effort fleet heartbeat into **target→origin ingest** only.
  /// Failures are ignored so capacity reporting cannot block signed job execution.
  /// Requires prior registration (ingest or origin-accepted device). When channel
  /// trust is available, heartbeats are target-signed; unsigned path is skipped.
  private func reportFleetHeartbeatBestEffort() {
    let fleetRoot = TatwoFleetStore.underChannelRoot(channel.rootURL).rootURL
    let ingestURL = fleetRoot
      .appendingPathComponent("ingest", isDirectory: true)
      .appendingPathComponent("devices", isDirectory: true)
      .appendingPathComponent("\(TatwoLoopPathComponent.sanitize(deviceID)).json")
    let acceptedURL = fleetRoot
      .appendingPathComponent("devices", isDirectory: true)
      .appendingPathComponent("\(TatwoLoopPathComponent.sanitize(deviceID)).json")
    let registered =
      FileManager.default.fileExists(atPath: ingestURL.path)
      || FileManager.default.fileExists(atPath: acceptedURL.path)
    guard registered else { return }

    var inflight = 0
    if let registry = localRegistry {
      let runs = registry.allRuns()
      inflight = runs.reduce(0) { partial, run in
        partial + run.records.filter { $0.status == .running || $0.status == .queued }.count
      }
    }

    // Target-signed ingest only — never write origin control-plane state from the runner.
    let originID = channel.trust.pinnedIdentities.keys
      .first(where: { $0 != deviceID }) ?? ""
    guard !originID.isEmpty else { return }
    let signer = TatwoFleetTargetSigner(
      trust: channel.trust,
      originDeviceID: originID)
    let store = TatwoFleetStore(rootURL: fleetRoot)
    let scheduler = TatwoFleetScheduler(store: store, targetSigner: signer)
    _ = try? scheduler.reportHeartbeat(deviceID: deviceID, inflight: inflight)
  }

  private func execute(_ job: TatwoLoopJobV1) -> ExecutionOutcome {
    let startedAt = Date()
    // Production agent jobs resolve exclusively from target-signed registry
    // truth. Legacy tests and shell-safe jobs retain explicit workPath binding.
    let boundWork: TatwoBoundWorkPath
    do {
      switch job.payload {
      case .tatwoLoop:
        if let workspaceRegistry {
          guard engine is TatwoAgentEngineBinding else {
            throw TatwoRemoteDispatchReadinessRegistryError.bindingDrift(
              "agentEngine")
          }
          guard let workspaceSkilletRootURL else {
            throw TatwoRemoteDispatchReadinessRegistryError.bindingNotFound
          }
          boundWork = try workspaceRegistry.resolveAndBindWorkspace(
            for: job,
            agentEngine: workspaceAgentEngine,
            skilletStore: TatwoSkilletRepositoryStore(
              rootURL: workspaceSkilletRootURL))
        } else {
          guard job.workspaceLocator == nil else {
            throw TatwoRemoteDispatchReadinessRegistryError.bindingNotFound
          }
          boundWork = try TatwoBoundWorkPath.bind(
            URL(fileURLWithPath: job.workPath, isDirectory: true))
        }
      case .shellSafe:
        boundWork = try TatwoBoundWorkPath.bind(
          URL(fileURLWithPath: job.workPath, isDirectory: true))
      }
    } catch {
      return failureOutcome(
        job: job,
        code: "invalid_work_path",
        message: error.localizedDescription,
        startedAt: startedAt)
    }
    if job.stopConditions.cancelFileSignal, channel.isCancelRequested(for: job) {
      return cancelledOutcome(job: job, startedAt: startedAt)
    }

    switch job.payload {
    case let .tatwoLoop(payload):
      return runTatwoLoop(
        job: job,
        payload: payload,
        boundWork: boundWork,
        startedAt: startedAt)
    case let .shellSafe(payload):
      do {
        try job.resourceCaps.validate()
        try payload.validate()
      } catch {
        return failureOutcome(
          job: job,
          code: "invalid_payload",
          message: error.localizedDescription,
          startedAt: startedAt)
      }
      return runShellSafe(job: job, payload: payload, boundWork: boundWork, startedAt: startedAt)
    }
  }

  private func runTatwoLoop(
    job: TatwoLoopJobV1,
    payload: TatwoLoopPayloadV1,
    boundWork: TatwoBoundWorkPath,
    startedAt: Date
  ) -> ExecutionOutcome {
    let workURL = boundWork.path
    // Production remains disabled unless both unlock conditions hold.
    // Legacy MCP sandbox env alone fails closed with a clear invalid_payload error.
    let unlocked: Bool
    do {
      unlocked = try TatwoLoopSandboxUnlock.allowsExecution(
        workPath: workURL,
        environment: environment,
        sandboxRoot: sandboxRootURL)
    } catch {
      return failureOutcome(
        job: job,
        code: "invalid_sandbox_config",
        message: error.localizedDescription,
        startedAt: startedAt)
    }
    guard unlocked else {
      return failureOutcome(
        job: job,
        code: "tatwo_loop_disabled",
        message: "tatwo-loop requires TATWO_ULTRAWORK_TATWO_LOOP_ENABLE=sandbox and workPath inside \(TatwoLoopSandboxUnlock.sandboxRootEnvKey)",
        startedAt: startedAt)
    }

    do {
      try job.resourceCaps.validate()
      try payload.validate()
      try job.validate()
      // Re-assert identity after sandbox check, before engine resolve.
      try boundWork.assertUnchanged()
    } catch {
      return failureOutcome(
        job: job,
        code: "invalid_payload",
        message: error.localizedDescription,
        startedAt: startedAt)
    }

    let activeSkillBinding: TatwoActiveSkillLaunchBindingV1?
    do {
      if let readiness = job.remoteDispatchReadiness {
        guard let workspaceSkilletRootURL, let workspaceSkillRuntimeRootURL else {
          throw TatwoRemoteDispatchReadinessRegistryError.bindingNotFound
        }
        let revisions =
          try TatwoRemoteDispatchReadinessTargetSnapshotBuilderV1.activeSkillRevisions(
            targetDeviceID: deviceID,
            store: TatwoSkilletRepositoryStore(rootURL: workspaceSkilletRootURL))
        let binding = TatwoActiveSkillLaunchBindingV1(
          expectedActiveSkillSetDigest: readiness.activeSkillSetDigest,
          activeSkillRevisions: revisions,
          runtimeRootURL: workspaceSkillRuntimeRootURL)
        // The runner owns the exec gate as well as the engine.  Re-read the
        // exact runtime projection here so a custom/test engine cannot claim a
        // matching digest while bypassing the target-local Skill readback.
        _ = try binding.verifiedRuntimeDigest()
        activeSkillBinding = binding
      } else {
        activeSkillBinding = nil
      }
    } catch {
      return failureOutcome(
        job: job,
        code: "agent_skill_binding_invalid",
        message: error.localizedDescription,
        startedAt: startedAt)
    }

    // Local registry projection is owned by runOnce (inbound mirror + projectLocal).
    // Do not beginRemote here — that is origin prepare; target uses ensureInboundRemoteMirror.
    let task = TatwoLoopEngineTaskV1(
      payload: payload,
      activeSkillBinding: activeSkillBinding)
    let localCaps = job.resourceCaps.clampedForLocalExecution()
    let engineResult: TatwoLoopEngineResultV1
    do {
      // Pass the same bound credential used for sandbox gate — engine must not re-bind pathname.
      engineResult = try engine.run(
        task: task,
        boundWorkPath: boundWork,
        caps: localCaps,
        shouldCancel: {
          job.stopConditions.cancelFileSignal && channel.isCancelRequested(for: job)
        })
    } catch {
      return failureOutcome(
        job: job,
        code: "engine_failed",
        message: error.localizedDescription,
        startedAt: startedAt)
    }

    let finishedAt = Date()
    let outputData = engineResult.outputData
    let outputDigest = TatwoLoopJobDigest.sha256(outputData)
    let truncated = engineResult.outputTruncated
    let expectedActiveSkillSetDigest =
      job.remoteDispatchReadiness?.activeSkillSetDigest
    let actualLoadedSkillSetDigest =
      engineResult.actualLoadedSkillSetDigest
    let modelExecutionAttestation =
      engineResult.modelExecutionAttestation
    if engineResult.cancelled {
      return ExecutionOutcome(
        receipt: TatwoLoopJobResultReceiptV1(
          jobID: job.jobID,
          dispatchNonce: job.dispatchNonce,
          jobCanonicalDigest: jobCanonicalDigest(for: job),
          projectionSequence: nextProjectionSequence(for: job),
          status: .cancelled,
          outputDigest: outputDigest,
          outputBytes: outputData.count,
          exitCode: engineResult.exitCode,
          failureCode: engineResult.failureCode ?? "cancelled",
          message: engineResult.message,
          startedAt: startedAt,
          finishedAt: finishedAt,
          outputTruncated: truncated,
          expectedActiveSkillSetDigest: expectedActiveSkillSetDigest,
          actualLoadedSkillSetDigest: actualLoadedSkillSetDigest,
          modelExecutionAttestation: modelExecutionAttestation),
        outputData: outputData)
    }
    if let code = engineResult.failureCode {
      return ExecutionOutcome(
        receipt: TatwoLoopJobResultReceiptV1(
          jobID: job.jobID,
          dispatchNonce: job.dispatchNonce,
          jobCanonicalDigest: jobCanonicalDigest(for: job),
          projectionSequence: nextProjectionSequence(for: job),
          status: .failed,
          outputDigest: outputDigest,
          outputBytes: outputData.count,
          exitCode: engineResult.exitCode,
          failureCode: code,
          message: engineResult.message,
          startedAt: startedAt,
          finishedAt: finishedAt,
          outputTruncated: truncated,
          expectedActiveSkillSetDigest: expectedActiveSkillSetDigest,
          actualLoadedSkillSetDigest: actualLoadedSkillSetDigest,
          modelExecutionAttestation: modelExecutionAttestation),
        outputData: outputData)
    }
    if let expectedActiveSkillSetDigest,
      engineResult.expectedActiveSkillSetDigest != expectedActiveSkillSetDigest
        || actualLoadedSkillSetDigest != expectedActiveSkillSetDigest
    {
      return ExecutionOutcome(
        receipt: TatwoLoopJobResultReceiptV1(
          jobID: job.jobID,
          dispatchNonce: job.dispatchNonce,
          jobCanonicalDigest: jobCanonicalDigest(for: job),
          projectionSequence: nextProjectionSequence(for: job),
          status: .failed,
          outputDigest: outputDigest,
          outputBytes: outputData.count,
          exitCode: engineResult.exitCode,
          failureCode: actualLoadedSkillSetDigest == nil
            ? "agent_skill_readback_missing"
            : "agent_skill_readback_mismatch",
          message: "agent loaded Skill-set digest does not match readiness",
          startedAt: startedAt,
          finishedAt: finishedAt,
          outputTruncated: truncated,
          expectedActiveSkillSetDigest: expectedActiveSkillSetDigest,
          actualLoadedSkillSetDigest: actualLoadedSkillSetDigest,
          modelExecutionAttestation: modelExecutionAttestation),
        outputData: outputData)
    }
    let completedReceipt = TatwoLoopJobResultReceiptV1(
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: jobCanonicalDigest(for: job),
      projectionSequence: nextProjectionSequence(for: job),
      status: .completed,
      outputDigest: outputDigest,
      outputBytes: outputData.count,
      exitCode: engineResult.exitCode,
      failureCode: nil,
      message: nil,
      startedAt: startedAt,
      finishedAt: finishedAt,
      outputTruncated: truncated,
      expectedActiveSkillSetDigest: expectedActiveSkillSetDigest,
      actualLoadedSkillSetDigest: actualLoadedSkillSetDigest,
      modelExecutionAttestation: modelExecutionAttestation)
    do {
      try completedReceipt.validateModelExecutionAttestation(for: job)
    } catch {
      let missing =
        modelExecutionAttestation == nil
        || modelExecutionAttestation?.outcome == .attestationMissing
      return ExecutionOutcome(
        receipt: TatwoLoopJobResultReceiptV1(
          jobID: job.jobID,
          dispatchNonce: job.dispatchNonce,
          jobCanonicalDigest: jobCanonicalDigest(for: job),
          projectionSequence: nextProjectionSequence(for: job),
          status: .failed,
          outputDigest: outputDigest,
          outputBytes: outputData.count,
          exitCode: engineResult.exitCode,
          failureCode: missing
            ? "agent_model_attestation_missing"
            : "agent_model_route_mismatch",
          message: error.localizedDescription,
          startedAt: startedAt,
          finishedAt: finishedAt,
          outputTruncated: truncated,
          expectedActiveSkillSetDigest: expectedActiveSkillSetDigest,
          actualLoadedSkillSetDigest: actualLoadedSkillSetDigest,
          modelExecutionAttestation: modelExecutionAttestation),
        outputData: outputData)
    }
    return ExecutionOutcome(receipt: completedReceipt, outputData: outputData)
  }

  /// C5 recovery: durable journal is already mid-flight (delivered/accepted/running)
  /// without a result after crash. Finish remaining transitions, project local, execute.
  private func resumeRunningWithoutResult(
    job: TatwoLoopJobV1,
    from status: TatwoLoopJobStatusV1,
    registry: TatwoDispatchRegistry
  ) throws -> TatwoLoopJobResultReceiptV1? {
    switch status {
    case .delivered:
      do {
        guard try advanceChannelToRunning(job: job, from: .delivered) else {
          projectLocalCancelledWithoutReceipt(registry: registry, job: job)
          return nil
        }
      } catch {
        noteLocalProjectionFailure(
          registry: registry,
          job: job,
          surface: "remote_loop_runner.resume_journal_failed",
          error: error,
          code: "local_projection_provisional_journal_failed")
        throw error
      }
    case .accepted:
      do {
        guard try advanceChannelToRunning(job: job, from: .accepted) else {
          projectLocalCancelledWithoutReceipt(registry: registry, job: job)
          return nil
        }
      } catch {
        noteLocalProjectionFailure(
          registry: registry,
          job: job,
          surface: "remote_loop_runner.resume_journal_failed",
          error: error,
          code: "local_projection_provisional_journal_failed")
        throw error
      }
    case .running:
      // Durable running already recorded; resume execute only.
      break
    default:
      return nil
    }

    // Channel is durable `.running` before local projection (same C5 invariant).
    projectLocalRunning(registry: registry, job: job)
    let outcome = execute(job)
    if cancellationAlreadyCommitted(
      registry: registry,
      job: job)
    {
      return nil
    }
    let terminalEntry: TatwoLoopJobJournalEntryV1
    do {
      terminalEntry = try channel.transition(
        jobID: job.jobID,
        to: outcome.receipt.status,
        reason: "runner-finished:\(outcome.receipt.failureCode ?? outcome.receipt.status.rawValue)",
        result: outcome.receipt,
        outputData: outcome.outputData,
        now: outcome.receipt.finishedAt)
    } catch TatwoLoopJobStateError.invalidPayload(let message)
      where message.contains("result projectionSequence")
    {
      // Another recovered runner may have committed the terminal result after
      // this runner executed. Treat that as exactly-once logical commit: do not
      // overwrite, do not synthesize a second receipt. The origin consumes the
      // already-signed channel result.
      return nil
    }
    if terminalEntry.to == .cancelled {
      projectLocalCancelledWithoutReceipt(registry: registry, job: job)
      return nil
    }
    let committedReceipt = try committedTerminalReceipt(
      job: job,
      entry: terminalEntry,
      proposed: outcome.receipt)
    projectLocal(registry: registry, job: job, receipt: committedReceipt)
    return committedReceipt
  }

  private func advanceChannelToRunning(
    job: TatwoLoopJobV1,
    from status: TatwoLoopJobStatusV1
  ) throws -> Bool {
    if status == .queued {
      let delivered = try channel.transition(
        jobID: job.jobID,
        to: .delivered,
        reason: "runner-discovered")
      if delivered.to == .cancelled { return false }
    }
    if status == .queued || status == .delivered {
      let accepted = try channel.transition(
        jobID: job.jobID,
        to: .accepted,
        reason: "runner-accepted")
      if accepted.to == .cancelled { return false }
    }
    let running = try channel.transition(
      jobID: job.jobID,
      to: .running,
      reason: "runner-started")
    return running.to == .running
  }

  private func committedTerminalReceipt(
    job: TatwoLoopJobV1,
    entry: TatwoLoopJobJournalEntryV1,
    proposed: TatwoLoopJobResultReceiptV1
  ) throws -> TatwoLoopJobResultReceiptV1 {
    if entry.to == proposed.status {
      return proposed
    }
    guard let committed = try channel.resultForAudit(for: job.jobID),
      committed.status == entry.to,
      committed.dispatchNonce == job.dispatchNonce,
      committed.jobCanonicalDigest == (try job.canonicalDigest())
    else {
      throw TatwoLoopJobStateError.invalidPayload(
        "channel terminal state \(entry.to.rawValue) has no matching committed receipt")
    }
    return committed
  }

  /// Ensure inbound mirror exists and mark running **after** channel journal
  /// transition to `.running` (`runner-started`) has succeeded.
  /// On local projection failure, mark provisional (durable running already exists).
  private func projectLocalRunning(
    registry: TatwoDispatchRegistry,
    job: TatwoLoopJobV1
  ) {
    do {
      _ = try registry.ensureInboundRemoteMirror(job: job)
      _ = try registry.projectRemoteStatus(
        contractID: job.contractID,
        remoteJobID: job.jobID,
        remoteStatus: .running)
    } catch {
      // Durable channel is already `.running`; local lag is provisional until recover/retry.
      noteLocalProjectionFailure(
        registry: registry,
        job: job,
        surface: "remote_loop_runner.project_local_running",
        error: error,
        code: "local_projection_provisional")
    }
  }

  /// Project terminal/current receipt onto the target local registry mirror.
  /// Ensures the inbound record exists first so empty-target state still lists the loop.
  private func projectLocal(
    registry: TatwoDispatchRegistry,
    job: TatwoLoopJobV1,
    receipt: TatwoLoopJobResultReceiptV1
  ) {
    do {
      _ = try registry.ensureInboundRemoteMirror(job: job)
      let resultDigest = try receipt.canonicalDigest()
      let boundReceiptID = try receipt.boundReceiptID()
      _ = try registry.projectRemoteStatus(
        contractID: job.contractID,
        remoteJobID: job.jobID,
        remoteStatus: receipt.status,
        receiptID: boundReceiptID,
        outputRef: receipt.outputDigest,
        failureCode: receipt.failureCode,
        errorMessage: receipt.message,
        resultDigest: resultDigest,
        projectionSequence: receipt.projectionSequence)
    } catch {
      noteLocalProjectionFailure(
        registry: registry,
        job: job,
        surface: "remote_loop_runner.project_local",
        error: error)
    }
  }

  private func projectLocalCancelledWithoutReceipt(
    registry: TatwoDispatchRegistry,
    job: TatwoLoopJobV1
  ) {
    do {
      _ = try registry.ensureInboundRemoteMirror(job: job)
      _ = try registry.projectRemoteStatus(
        contractID: job.contractID,
        remoteJobID: job.jobID,
        remoteStatus: .cancelled,
        failureCode: "cancelled",
        errorMessage: "origin cancellation tombstone")
    } catch {
      noteLocalProjectionFailure(
        registry: registry,
        job: job,
        surface: "remote_loop_runner.project_local_cancelled",
        error: error)
    }
  }

  private func projectExistingLocalCancelledWithoutReceipt(
    registry: TatwoDispatchRegistry,
    job: TatwoLoopJobV1
  ) {
    do {
      guard
        try registry.run(forContractID: job.contractID)?
          .records.contains(where: { $0.remoteJobID == job.jobID }) == true
      else {
        return
      }
      _ = try registry.projectRemoteStatus(
        contractID: job.contractID,
        remoteJobID: job.jobID,
        remoteStatus: .cancelled,
        failureCode: "cancelled",
        errorMessage: "origin cancellation tombstone")
    } catch {
      noteLocalProjectionFailure(
        registry: registry,
        job: job,
        surface: "remote_loop_runner.project_existing_local_cancelled",
        error: error)
    }
  }

  /// Origin owns the durable cancellation decision. If it lands while target
  /// execution is in flight, the target must stop without attempting an
  /// invalid terminal rewrite or fabricating a target result receipt.
  private func cancellationAlreadyCommitted(
    registry: TatwoDispatchRegistry,
    job: TatwoLoopJobV1
  ) -> Bool {
    guard (try? channel.currentStatus(for: job.jobID)) == .cancelled else {
      return false
    }
    projectLocalCancelledWithoutReceipt(registry: registry, job: job)
    return true
  }

  /// Observable signal when App pressure admission rejects a queued job.
  /// This is intentionally stderr-only: rejection before target claim must not
  /// create channel/local lifecycle state or fabricate a failed target result.
  private func notePressureAdmissionRejection(
    job: TatwoLoopJobV1,
    reasonCode: String,
    surface: String = "remote_loop_runner"
  ) {
    fputs(
      "tatwo: pressure admission rejected surface=\(surface) jobID=\(job.jobID) "
        + "contractID=\(job.contractID) reason=\(reasonCode)\n",
      stderr)
  }

  /// Observable signal when local inbound projection fails (never silent).
  private func noteLocalProjectionFailure(
    registry: TatwoDispatchRegistry,
    job: TatwoLoopJobV1,
    surface: String,
    error: Error,
    code: String = "local_projection_failed"
  ) {
    let message = error.localizedDescription
    fputs(
      "tatwo: local inbound projection failed surface=\(surface) jobID=\(job.jobID) "
        + "contractID=\(job.contractID) code=\(code): \(message)\n",
      stderr)
    let entry = TatwoLocalProjectionJournalEntryV1(
      code: code,
      surface: surface,
      jobID: job.jobID,
      contractID: job.contractID,
      originDeviceID: job.originDeviceID,
      dispatchNonce: job.dispatchNonce,
      logicalJobID: job.logicalJobID,
      message: String(message.prefix(512)))
    TatwoLocalProjectionJournal.append(entry, directoryURL: registry.directoryURL)
  }

  private func runShellSafe(
    job: TatwoLoopJobV1,
    payload: TatwoShellSafePayloadV1,
    boundWork: TatwoBoundWorkPath,
    startedAt: Date
  ) -> ExecutionOutcome {
    let localCaps = job.resourceCaps.clampedForLocalExecution()
    let command: String
    switch payload.command {
    case .echo:
      let expectedBytes = payload.arguments.joined(separator: " ").utf8.count + 1
      guard expectedBytes <= localCaps.maxOutputBytes else {
        return failureOutcome(
          job: job,
          code: "output_cap",
          message: "echo output exceeds maxOutputBytes",
          startedAt: startedAt)
      }
      command = "/bin/echo"
    case .sleep:
      command = "/bin/sleep"
    case .true:
      command = "/usr/bin/true"
    case .false:
      command = "/usr/bin/false"
    }

    // Argv-only launch (no shell) with process-group kill + streaming output caps.
    // Work dir bound by open fd (posix_spawn fchdir) — no pathname re-resolve.
    let engineResult: TatwoLoopEngineResultV1
    do {
      engineResult = try ProcessEngineBinding.runProcess(
        executablePath: command,
        arguments: payload.arguments,
        boundWorkPath: boundWork,
        caps: localCaps,
        shouldCancel: {
          job.stopConditions.cancelFileSignal && channel.isCancelRequested(for: job)
        },
        environment: TatwoAgentLaunchEnvironment.explicitMinimal(executablePath: command))
    } catch {
      return failureOutcome(
        job: job,
        code: "launch_failed",
        message: error.localizedDescription,
        startedAt: startedAt)
    }

    let finishedAt = Date()
    let outputData = engineResult.outputData
    let outputDigest = TatwoLoopJobDigest.sha256(outputData)
    let truncated = engineResult.outputTruncated
    if engineResult.cancelled {
      return ExecutionOutcome(
        receipt: TatwoLoopJobResultReceiptV1(
          jobID: job.jobID,
          dispatchNonce: job.dispatchNonce,
          jobCanonicalDigest: jobCanonicalDigest(for: job),
          projectionSequence: nextProjectionSequence(for: job),
          status: .cancelled,
          outputDigest: outputDigest,
          outputBytes: outputData.count,
          exitCode: engineResult.exitCode,
          failureCode: "cancelled",
          message: engineResult.message ?? "cancel file signal observed",
          startedAt: startedAt,
          finishedAt: finishedAt,
          outputTruncated: truncated),
        outputData: outputData)
    }
    if engineResult.timedOut {
      return ExecutionOutcome(
        receipt: TatwoLoopJobResultReceiptV1(
          jobID: job.jobID,
          dispatchNonce: job.dispatchNonce,
          jobCanonicalDigest: jobCanonicalDigest(for: job),
          projectionSequence: nextProjectionSequence(for: job),
          status: .failed,
          outputDigest: outputDigest,
          outputBytes: outputData.count,
          exitCode: engineResult.exitCode,
          failureCode: "timeout",
          message: "maxDurationSec exceeded",
          startedAt: startedAt,
          finishedAt: finishedAt,
          outputTruncated: truncated),
        outputData: outputData)
    }
    if engineResult.outputTruncated || engineResult.failureCode == "output_cap" {
      return ExecutionOutcome(
        receipt: TatwoLoopJobResultReceiptV1(
          jobID: job.jobID,
          dispatchNonce: job.dispatchNonce,
          jobCanonicalDigest: jobCanonicalDigest(for: job),
          projectionSequence: nextProjectionSequence(for: job),
          status: .failed,
          outputDigest: outputDigest,
          outputBytes: outputData.count,
          exitCode: engineResult.exitCode,
          failureCode: "output_cap",
          message: "maxOutputBytes exceeded",
          startedAt: startedAt,
          finishedAt: finishedAt,
          outputTruncated: true),
        outputData: outputData)
    }
    if let code = engineResult.failureCode {
      return ExecutionOutcome(
        receipt: TatwoLoopJobResultReceiptV1(
          jobID: job.jobID,
          dispatchNonce: job.dispatchNonce,
          jobCanonicalDigest: jobCanonicalDigest(for: job),
          projectionSequence: nextProjectionSequence(for: job),
          status: .failed,
          outputDigest: outputDigest,
          outputBytes: outputData.count,
          exitCode: engineResult.exitCode,
          failureCode: code,
          message: engineResult.message ?? "shell-safe command failed",
          startedAt: startedAt,
          finishedAt: finishedAt,
          outputTruncated: truncated),
        outputData: outputData)
    }
    guard engineResult.exitCode == 0 else {
      return ExecutionOutcome(
        receipt: TatwoLoopJobResultReceiptV1(
          jobID: job.jobID,
          dispatchNonce: job.dispatchNonce,
          jobCanonicalDigest: jobCanonicalDigest(for: job),
          projectionSequence: nextProjectionSequence(for: job),
          status: .failed,
          outputDigest: outputDigest,
          outputBytes: outputData.count,
          exitCode: engineResult.exitCode,
          failureCode: "exit_nonzero",
          message: "shell-safe command exited non-zero",
          startedAt: startedAt,
          finishedAt: finishedAt,
          outputTruncated: truncated),
        outputData: outputData)
    }
    return ExecutionOutcome(
      receipt: TatwoLoopJobResultReceiptV1(
        jobID: job.jobID,
        dispatchNonce: job.dispatchNonce,
        jobCanonicalDigest: jobCanonicalDigest(for: job),
        projectionSequence: nextProjectionSequence(for: job),
        status: .completed,
        outputDigest: outputDigest,
        outputBytes: outputData.count,
        exitCode: engineResult.exitCode,
        failureCode: nil,
        message: nil,
        startedAt: startedAt,
        finishedAt: finishedAt,
        outputTruncated: truncated),
      outputData: outputData)
  }


  private func nextProjectionSequence(for job: TatwoLoopJobV1) -> UInt64 {
    let count = (try? channel.journal(for: job.jobID).count) ?? 0
    return UInt64(count) + 1
  }

  private func jobCanonicalDigest(for job: TatwoLoopJobV1) -> String {
    (try? job.canonicalDigest()) ?? ""
  }

  private func failureOutcome(
    job: TatwoLoopJobV1,
    code: String,
    message: String,
    startedAt: Date
  ) -> ExecutionOutcome {
    ExecutionOutcome(
      receipt: TatwoLoopJobResultReceiptV1(
        jobID: job.jobID,
        dispatchNonce: job.dispatchNonce,
        jobCanonicalDigest: jobCanonicalDigest(for: job),
        projectionSequence: nextProjectionSequence(for: job),
        status: .failed,
        outputDigest: nil,
        outputBytes: 0,
        exitCode: nil,
        failureCode: code,
        message: message,
        startedAt: startedAt,
        finishedAt: Date(),
        expectedActiveSkillSetDigest:
          job.remoteDispatchReadiness?.activeSkillSetDigest,
        actualLoadedSkillSetDigest: nil),
      outputData: nil)
  }

  private func cancelledOutcome(
    job: TatwoLoopJobV1,
    startedAt: Date
  ) -> ExecutionOutcome {
    ExecutionOutcome(
      receipt: TatwoLoopJobResultReceiptV1(
        jobID: job.jobID,
        dispatchNonce: job.dispatchNonce,
        jobCanonicalDigest: jobCanonicalDigest(for: job),
        projectionSequence: nextProjectionSequence(for: job),
        status: .cancelled,
        outputDigest: nil,
        outputBytes: 0,
        exitCode: nil,
        failureCode: "cancelled",
        message: "cancel file signal observed",
        startedAt: startedAt,
        finishedAt: Date(),
        expectedActiveSkillSetDigest:
          job.remoteDispatchReadiness?.activeSkillSetDigest,
        actualLoadedSkillSetDigest: nil),
      outputData: nil)
  }

  private static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
    let left = lhs.standardizedFileURL.resolvingSymlinksInPath().path
    let right = rhs.standardizedFileURL.resolvingSymlinksInPath().path
    func contains(_ path: String, _ root: String) -> Bool {
      path == root || path.hasPrefix(root.hasSuffix("/") ? root : "\(root)/")
    }
    return contains(left, right) || contains(right, left)
  }
}

public struct TatwoLoopOriginProjectorV1: Sendable {
  public let channel: TatwoLoopJobChannel
  public let registry: TatwoDispatchRegistry
  public let originDeviceID: String
  public let originAuthorityProvider: any TatwoOriginAuthorityProviding
  public let memoryGate: MemoryPressureGate
  /// When set, prepare uses the unified Work OS gate (authorize + GoalRun + reservation).
  public let goalStore: TatwoGoalRunStore?
  /// Durable borrow approvals. Required for `.tatwoLoop` production prepare.
  public let remoteBorrowAuthorizationStore: TatwoRemoteBorrowAuthorizationStore?
  /// Verified target pin loaded by the production bootstrap; never sourced from UI state.
  public let verifiedTargetIdentity: TatwoDevicePublicIdentityV1?
  /// Out-of-band target challenge/readback. Required for `.tatwoLoop` production prepare.
  public let remoteReadinessProvider: (any TatwoRemoteDispatchReadinessProviding)?
  public let remoteReadinessRequirements: TatwoRemoteDispatchReadinessRequirementsV1?
  public let environment: [String: String]

  public init(
    channel: TatwoLoopJobChannel,
    registry: TatwoDispatchRegistry,
    originDeviceID: String,
    memoryGate: MemoryPressureGate? = nil,
    goalStore: TatwoGoalRunStore? = nil,
    remoteBorrowAuthorizationStore: TatwoRemoteBorrowAuthorizationStore? = nil,
    verifiedTargetIdentity: TatwoDevicePublicIdentityV1? = nil,
    remoteReadinessProvider: (any TatwoRemoteDispatchReadinessProviding)? = nil,
    remoteReadinessRequirements: TatwoRemoteDispatchReadinessRequirementsV1? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil
  ) {
    self.channel = channel
    self.registry = registry
    self.originDeviceID = originDeviceID
    self.originAuthorityProvider =
      originAuthorityProvider
      ?? channel.originAuthorityProvider
    self.memoryGate = memoryGate
      ?? MemoryPressureGate.default(
        journalDirectoryURL: registry.directoryURL)
    self.goalStore = goalStore
    self.remoteBorrowAuthorizationStore = remoteBorrowAuthorizationStore
    self.verifiedTargetIdentity = verifiedTargetIdentity
    self.remoteReadinessProvider = remoteReadinessProvider
    self.remoteReadinessRequirements = remoteReadinessRequirements
    self.environment = environment
  }

  @discardableResult
  public func enqueue(_ job: TatwoLoopJobV1) throws -> TatwoDispatchRecord {
    try enqueue(job, afterReservation: nil)
  }

  /// Origin cancellation chokepoint. Production cancellation is persisted through
  /// the GoalRun outbox lifecycle; only explicit test-mode channels may use the
  /// fixture-compatible channel primitive without a GoalRun store.
  @discardableResult
  public func cancel(jobID: String) throws -> TatwoLoopJobStatusV1 {
    let job = try channel.job(forJobID: jobID)
    guard job.originDeviceID == originDeviceID else {
      throw TatwoLoopJobStateError.invalidJob(job.jobID)
    }
    if let goalStore {
      _ = try TatwoGoalRunDispatchLifecycle.cancelRemoteOutbox(
        contractID: job.contractID,
        jobID: job.jobID,
        goalStore: goalStore,
        dispatchRegistry: registry,
        channel: channel)
    } else if channel.testModeEnabled {
      let outcome = try channel.signalCancel(for: job)
      switch outcome {
      case .cancelled, .terminalWon(.cancelled):
        _ = try registry.projectRemoteStatus(
          contractID: job.contractID,
          remoteJobID: job.jobID,
          remoteStatus: .cancelled,
          failureCode: "cancelled",
          errorMessage: "origin cancellation tombstone",
          projectionSequence: UInt64(try channel.journal(for: job.jobID).count))
      case .terminalWon:
        break
      }
    } else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "goal_run_store_missing",
        message: "origin remote cancellation requires a durable GoalRun store")
    }
    return try channel.currentStatus(for: job.jobID)
  }

  /// Test seam for a deterministic reservation → cancellation → commit race.
  @discardableResult
  func enqueue(
    _ job: TatwoLoopJobV1,
    afterReservation: (() throws -> Void)?
  ) throws -> TatwoDispatchRecord {
    guard job.originDeviceID == originDeviceID else {
      throw TatwoLoopJobStateError.invalidJob(job.jobID)
    }
    // Preserve the existing resource-gate result before evaluating a lease
    // fence.  Authority is checked only for a lease-bound route after the
    // pre-existing gate has admitted the mutation.
    let gate = memoryGate.evaluateAndJournal(surface: "job_dispatch")
    if case let .blocked(_, _, reason) = gate {
      throw TatwoLoopJobStateError.resourceGateBlocked(reason: reason)
    }
    let authorityEpoch = originAuthorityProvider.authorityEpoch ?? 0
    try originAuthorityProvider.requireOriginAuthority(
      deviceID: originDeviceID,
      epoch: authorityEpoch,
      surface: "remote_loop_origin_projector",
      now: Date())
    // Prepare: every production job is GoalRun-gated. Agent jobs additionally
    // require Chat borrow authorization and target readiness; bounded shell-safe
    // jobs remain contract-gated without pretending to borrow an agent session.
    let record: TatwoDispatchRecord
    if let goalStore {
      switch job.payload {
      case .tatwoLoop:
        guard
          let remoteBorrowAuthorizationStore,
          let verifiedTargetIdentity
        else {
          throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
            code: "remote_borrow_context_missing",
            message:
              "agent remote dispatch requires durable authorization and verified target pin")
        }
        record = try TatwoGoalRunDispatchLifecycle.beginRemote(
          job: job,
          goalStore: goalStore,
          dispatchRegistry: registry,
          authorizationStore: remoteBorrowAuthorizationStore,
          verifiedTargetIdentity: verifiedTargetIdentity,
          readinessTrust: channel.trust,
          readinessProvider: remoteReadinessProvider,
          readinessRequirements: remoteReadinessRequirements,
          environment: environment)
      case .shellSafe:
        record = try TatwoGoalRunDispatchLifecycle.beginRemoteShellSafe(
          job: job,
          goalStore: goalStore,
          dispatchRegistry: registry,
          environment: environment)
      }
    } else if channel.testModeEnabled {
      // Explicit fixture-only compatibility for legacy channel/registry tests.
      // Production remains GoalRun-gated because non-test channels never enter
      // this unbound reservation seam.
      record = try registry.beginRemoteTestFixtureUnbound(job: job)
    } else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "goal_run_store_missing",
        message: "origin remote dispatch requires a durable GoalRun store")
    }
    try afterReservation?()
    do {
      if let goalStore {
        _ = try TatwoGoalRunDispatchLifecycle.commitRemoteChannel(
          job: job,
          goalStore: goalStore,
          environment: environment
        ) {
          try channel.enqueue(job)
        }
      } else if channel.testModeEnabled {
        try channel.enqueue(job)
      } else {
        throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
          code: "goal_run_store_missing",
          message: "origin remote dispatch requires a durable GoalRun store")
      }
      return record
    } catch {
      // Channel commit failed after reservation: quarantine. Never swallow with try?.
      if let goalStore {
        let intent = try TatwoGoalRunDispatchLifecycle.remoteOutboxIntent(
          contractID: job.contractID,
          jobID: job.jobID,
          goalStore: goalStore)
        if intent?.state != .cancelled {
          try TatwoGoalRunDispatchLifecycle.quarantineChannelEnqueueFailure(
            job: job,
            error: error,
            goalStore: goalStore,
            dispatchRegistry: registry)
        }
      } else if channel.testModeEnabled {
        _ = try registry.projectRemoteStatus(
          contractID: job.contractID,
          remoteJobID: job.jobID,
          remoteStatus: .failed,
          failureCode: "channel_enqueue_failed",
          errorMessage:
            "reconciliation_required:channel_enqueue:\(error.localizedDescription)")
      }
      throw error
    }
  }

  @discardableResult
  public func converge(jobID: String) throws -> TatwoLoopJobStatusV1 {
    // Origin-side state change: always reload trust before accepting target evidence.
    _ = try channel.refreshTrustFromDurableStoreIfNeeded()
    let status = try channel.currentStatus(for: jobID)
    let job = try channel.job(forJobID: jobID)
    // Replay guard: registry must still be bound to this signed job digest/nonce.
    _ = try registry.requireRemoteJobBinding(job: job)

    // M5: target-produced terminal truth comes only from target-signed result
    // artifacts. Origin-owned cancellation is the intentional exception: its
    // signed tombstone + journal + nil-result cancelled ACK are the authority,
    // and no target receipt may be fabricated merely to make converge consume.
    if [.completed, .failed, .cancelled].contains(status) {
      let auditedResult = try channel.resultForAudit(for: jobID)
      if status == .cancelled, auditedResult == nil {
        let journal = try channel.journal(for: jobID)
        let ack = try channel.ack(for: jobID)
        guard journal.last?.to == .cancelled,
          journal.last?.reason == "origin-cancel-tombstone",
          ack?.status == .cancelled,
          ack?.result == nil
        else {
          throw TatwoLoopJobStateError.signatureRejected(
            jobID: jobID,
            reason: TatwoLoopChannelRejectReasonV1.missingSignature.rawValue)
        }
      } else {
        guard
          let receipt = try channel.consumeResult(
            for: jobID,
            validating: { receipt, consumedJob in
              guard receipt.status == status else {
                throw TatwoLoopJobStateError.invalidPayload(
                  "target result status \(receipt.status.rawValue) does not match journal \(status.rawValue)")
              }
              try receipt.validateActiveSkillReadback(for: consumedJob)
              try receipt.validateModelExecutionAttestation(for: consumedJob)
            })
        else {
          throw TatwoLoopJobStateError.signatureRejected(
            jobID: jobID,
            reason: TatwoLoopChannelRejectReasonV1.missingSignature.rawValue)
        }
        let resultDigest = try receipt.canonicalDigest()
        let boundReceiptID = try receipt.boundReceiptID()
        // projectionSequence comes from the signed result (journal-derived), not a bare caller UInt64.
        _ = try registry.projectRemoteStatus(
          contractID: job.contractID,
          remoteJobID: job.jobID,
          remoteStatus: status,
          receiptID: boundReceiptID,
          outputRef: receipt.outputDigest,
          failureCode: receipt.failureCode,
          errorMessage: receipt.message,
          resultDigest: resultDigest,
          projectionSequence: receipt.projectionSequence)
        // Product `.verified` means the work itself passed acceptance. A
        // cryptographically valid failed/cancelled receipt is trusted evidence
        // of that terminal outcome, not a successful acceptance state.
        if status == .completed {
          _ = try channel.transition(
            jobID: jobID,
            to: .verified,
            reason: "origin-verified")
        }
      }
    }
    let finalStatus = try channel.currentStatus(for: jobID)
    // Verified / non-terminal re-project: audit read only; do not re-open consume.
    let finalResult = try channel.resultForAudit(for: jobID)
    let finalDigest = try finalResult?.canonicalDigest()
    let finalReceiptID = try finalResult?.boundReceiptID()
    // Sequence authority: signed result sequence, advanced only with identical evidence
    // by journal length after verified transition (same digests; no bare UInt64 replace).
    let journalCount = UInt64((try? channel.journal(for: jobID).count) ?? 0)
    let finalSequence = max(finalResult?.projectionSequence ?? 0, journalCount)
    _ = try registry.projectRemoteStatus(
      contractID: job.contractID,
      remoteJobID: job.jobID,
      remoteStatus: finalStatus,
      receiptID: finalReceiptID,
      outputRef: finalResult?.outputDigest,
      failureCode: finalResult?.failureCode,
      errorMessage: finalResult?.message,
      resultDigest: finalDigest,
      projectionSequence: finalSequence)
    return finalStatus
  }
}

private extension TatwoShellSafePayloadV1 {
  func validate() throws {
    switch command {
    case .echo:
      break
    case .sleep:
      guard arguments.count == 1,
        let duration = Double(arguments[0]),
        duration.isFinite,
        duration >= 0
      else {
        throw TatwoLoopJobStateError.invalidPayload(
          "sleep requires one non-negative duration")
      }
    case .true, .false:
      guard arguments.isEmpty else {
        throw TatwoLoopJobStateError.invalidPayload(
          "\(command.rawValue) does not accept arguments")
      }
    }
  }
}

/// Best-effort journal when target local inbound projection fails (display path only).
public struct TatwoLocalProjectionJournalEntryV1: Codable, Sendable, Equatable {
  public let schema: String
  public let code: String
  public let surface: String
  public let jobID: String
  public let contractID: String
  public let originDeviceID: String
  public let dispatchNonce: String
  public let logicalJobID: String
  public let message: String
  public let occurredAt: Date

  public init(
    schema: String = "TatwoLocalProjectionJournalV1",
    code: String,
    surface: String,
    jobID: String,
    contractID: String,
    originDeviceID: String,
    dispatchNonce: String,
    logicalJobID: String,
    message: String,
    occurredAt: Date = Date()
  ) {
    self.schema = schema
    self.code = code
    self.surface = surface
    self.jobID = jobID
    self.contractID = contractID
    self.originDeviceID = originDeviceID
    self.dispatchNonce = dispatchNonce
    self.logicalJobID = logicalJobID
    self.message = message
    self.occurredAt = occurredAt
  }
}

public enum TatwoLocalProjectionJournal {
  public static let fileName = "local-projection-journal.jsonl"

  public static func append(
    _ entry: TatwoLocalProjectionJournalEntryV1,
    directoryURL: URL
  ) {
    do {
      try FileManager.default.createDirectory(
        at: directoryURL, withIntermediateDirectories: true)
      let url = directoryURL.appendingPathComponent(fileName, isDirectory: false)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      var line = try encoder.encode(entry)
      line.append(contentsOf: "\n".utf8)
      if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
      } else {
        try line.write(to: url, options: .atomic)
      }
    } catch {
      // Journal is observability-only; never throw from projection fail path.
    }
  }

  public static func read(directoryURL: URL) throws -> [TatwoLocalProjectionJournalEntryV1] {
    let url = directoryURL.appendingPathComponent(fileName, isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try text
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map {
        try decoder.decode(TatwoLocalProjectionJournalEntryV1.self, from: Data($0.utf8))
      }
  }
}
