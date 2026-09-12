import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class RemoteDispatchReadinessTests: XCTestCase {
  private let environment = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]

  func testHappyPathReservesAndEnqueues() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let job = fixture.job(jobID: "job-ready", nonce: "nonce-ready")
    let receipt = try fixture.receipt(for: job)

    let record = try fixture.projector(provider: FixedProvider(receipt)).enqueue(job)

    XCTAssertEqual(record.remoteJobID, job.jobID)
    XCTAssertNotNil(try fixture.registryRecord(job))
    XCTAssertTrue(fixture.channel.hasCommitMarker(forJobID: job.jobID))
  }

  func testMissingProviderRequirementsAndJobBindingFailClosed() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let job = fixture.job(jobID: "job-missing", nonce: "nonce-missing")
    let receipt = try fixture.receipt(for: job)

    try fixture.assertRejected(job: job, provider: nil)
    try fixture.assertRejected(
      job: fixture.job(jobID: "job-missing-req", nonce: "nonce-missing-req"),
      provider: FixedProvider(receipt),
      requirements: .some(
        TatwoRemoteDispatchReadinessRequirementsV1(challengeNonce: "wrong-challenge")))
    try fixture.assertRejected(
      job: fixture.job(
        jobID: "job-missing-binding",
        nonce: "nonce-missing-binding",
        readiness: .some(nil)),
      provider: FixedProvider(receipt))
  }

  func testStaleFutureLifetimeAndReadbackRejectBeforeMutation() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date()
    let cases: [(String, TatwoRemoteDispatchReadinessReceiptV1)] = [
      (
        "stale",
        try fixture.receipt(
          for: fixture.job(jobID: "job-stale", nonce: "nonce-stale"),
          issuedAt: now.addingTimeInterval(-600),
          expiresAt: now.addingTimeInterval(-300))),
      (
        "future",
        try fixture.receipt(
          for: fixture.job(jobID: "job-future", nonce: "nonce-future"),
          issuedAt: now.addingTimeInterval(90),
          expiresAt: now.addingTimeInterval(150))),
      (
        "lifetime",
        try fixture.receipt(
          for: fixture.job(jobID: "job-lifetime", nonce: "nonce-lifetime"),
          issuedAt: now,
          expiresAt: now.addingTimeInterval(301))),
      (
        "readback",
        try fixture.receipt(
          for: fixture.job(jobID: "job-readback", nonce: "nonce-readback"),
          readbackNonce: "wrong-readback")),
    ]
    for (label, receipt) in cases {
      let job = fixture.job(jobID: "job-\(label)", nonce: "nonce-\(label)")
      try fixture.assertRejected(job: job, provider: FixedProvider(receipt))
    }
  }

  func testReceiptFreshnessAndSignedAtFailuresRemainDistinguishable() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date()
    let staleJob = fixture.job(jobID: "job-distinct-stale", nonce: "nonce-distinct-stale")
    let stale = try fixture.receipt(
      for: staleJob,
      issuedAt: now.addingTimeInterval(-120),
      expiresAt: now.addingTimeInterval(-1))
    XCTAssertThrowsError(
      try stale.verify(
        job: staleJob,
        requirements: fixture.requirements,
        trust: fixture.originTrust,
        now: now,
        environment: fixture.environment)
    ) { error in
      XCTAssertEqual(error as? TatwoRemoteDispatchReadinessError, .stale)
    }

    let futureJob = fixture.job(jobID: "job-distinct-future", nonce: "nonce-distinct-future")
    let future = try fixture.receipt(
      for: futureJob,
      issuedAt: now.addingTimeInterval(60),
      expiresAt: now.addingTimeInterval(120))
    XCTAssertThrowsError(
      try future.verify(
        job: futureJob,
        requirements: fixture.requirements,
        trust: fixture.originTrust,
        now: now,
        environment: fixture.environment)
    ) { error in
      XCTAssertEqual(error as? TatwoRemoteDispatchReadinessError, .notYetValid)
    }

    let lifetimeJob = fixture.job(jobID: "job-distinct-lifetime", nonce: "nonce-distinct-lifetime")
    let lifetime = try fixture.receipt(
      for: lifetimeJob,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(301))
    XCTAssertThrowsError(
      try lifetime.verify(
        job: lifetimeJob,
        requirements: fixture.requirements,
        trust: fixture.originTrust,
        now: now,
        environment: fixture.environment)
    ) { error in
      XCTAssertEqual(error as? TatwoRemoteDispatchReadinessError, .lifetimeExceeded)
    }

    let signedAtJob = fixture.job(jobID: "job-distinct-signed-at", nonce: "nonce-distinct-signed-at")
    let signedAtBase = try fixture.receipt(for: signedAtJob, issuedAt: now)
    let wrongSignedAt = try fixture.targetTrust.sign(
      payload: signedAtBase.canonicalSigningPayload(),
      purpose: .loopTargetReadiness,
      signedAt: now.addingTimeInterval(1))
    let signedAtReceipt = fixture.copy(signedAtBase, signature: wrongSignedAt)
    XCTAssertThrowsError(
      try signedAtReceipt.verify(
        job: signedAtJob,
        requirements: fixture.requirements,
        trust: fixture.originTrust,
        now: now,
        environment: fixture.environment)
    ) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessError,
        .invalidReceipt("signedAt"))
    }
  }

  func testWrongJobNonceDigestWorkspaceCapabilityAndSkillRejectBeforeMutation() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let originalJob = fixture.job(jobID: "job-scope-id", nonce: "nonce-scope-id")
    let wrongJobReceipt = try fixture.receipt(
      for: fixture.job(jobID: "job-other", nonce: "nonce-scope-id"))
    try fixture.assertRejected(job: originalJob, provider: FixedProvider(wrongJobReceipt))

    let nonceJob = fixture.job(jobID: "job-scope-nonce", nonce: "nonce-scope-nonce")
    let wrongNonceReceipt = try fixture.receipt(
      for: fixture.job(jobID: nonceJob.jobID, nonce: "nonce-other"))
    try fixture.assertRejected(job: nonceJob, provider: FixedProvider(wrongNonceReceipt))

    let digestJob = fixture.job(jobID: "job-scope-digest", nonce: "nonce-scope-digest")
    let digestVariant = fixture.job(
      jobID: digestJob.jobID,
      nonce: digestJob.dispatchNonce,
      createdAt: digestJob.createdAt.addingTimeInterval(1))
    try fixture.assertRejected(
      job: digestJob,
      provider: FixedProvider(try fixture.receipt(for: digestVariant)))

    let workspaceJob = fixture.job(jobID: "job-scope-workspace", nonce: "nonce-scope-workspace")
    try fixture.assertRejected(
      job: workspaceJob,
      provider: FixedProvider(
        try fixture.receipt(
          for: workspaceJob,
          workspaceDigest: String(repeating: "d", count: 64))))

    let capabilityJob = fixture.job(jobID: "job-scope-cap", nonce: "nonce-scope-cap")
    try fixture.assertRejected(
      job: capabilityJob,
      provider: FixedProvider(
        try fixture.receipt(
          for: capabilityJob,
          capabilityDigest: String(repeating: "e", count: 64))))

    let skillJob = fixture.job(jobID: "job-scope-skill", nonce: "nonce-scope-skill")
    try fixture.assertRejected(
      job: skillJob,
      provider: FixedProvider(
        try fixture.receipt(
          for: skillJob,
          skillDigest: String(repeating: "f", count: 64))))
  }

  func testWrongTargetPurposeSignatureAndRevokedPinRejectBeforeMutation() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let targetJob = fixture.job(jobID: "job-target", nonce: "nonce-target")
    let wrongTarget = try fixture.resigned(
      try fixture.receipt(for: targetJob),
      targetDeviceID: "target-other")
    try fixture.assertRejected(job: targetJob, provider: FixedProvider(wrongTarget))

    let purposeJob = fixture.job(jobID: "job-purpose", nonce: "nonce-purpose")
    let validPurposeReceipt = try fixture.receipt(for: purposeJob)
    let wrongPurposeSignature = try fixture.targetTrust.sign(
      payload: validPurposeReceipt.canonicalSigningPayload(),
      purpose: .loopResult,
      signedAt: validPurposeReceipt.issuedAt)
    let wrongPurpose = fixture.copy(validPurposeReceipt, signature: wrongPurposeSignature)
    try fixture.assertRejected(job: purposeJob, provider: FixedProvider(wrongPurpose))

    let signatureJob = fixture.job(jobID: "job-signature", nonce: "nonce-signature")
    let validSignatureReceipt = try fixture.receipt(for: signatureJob)
    let badSignature = TatwoDeviceSignatureV1(
      purpose: validSignatureReceipt.targetSignature.purpose,
      deviceID: validSignatureReceipt.targetSignature.deviceID,
      keyID: validSignatureReceipt.targetSignature.keyID,
      keyGeneration: validSignatureReceipt.targetSignature.keyGeneration,
      payloadDigest: validSignatureReceipt.targetSignature.payloadDigest,
      signedAt: validSignatureReceipt.targetSignature.signedAt,
      signature: Data(repeating: 0, count: 64).base64EncodedString())
    try fixture.assertRejected(
      job: signatureJob,
      provider: FixedProvider(fixture.copy(validSignatureReceipt, signature: badSignature)))

    let revokedJob = fixture.job(jobID: "job-revoked", nonce: "nonce-revoked")
    let revokedReceipt = try fixture.receipt(for: revokedJob)
    let revokedIdentity = TatwoDevicePublicIdentityV1(
      deviceID: fixture.targetIdentity.deviceID,
      keyID: fixture.targetIdentity.keyID,
      publicKey: fixture.targetIdentity.publicKey,
      keyGeneration: fixture.targetIdentity.keyGeneration,
      keyStatus: .revoked,
      pinnedAt: fixture.targetIdentity.pinnedAt)
    let revokedTrust = try fixture.originTrust.withPin(revokedIdentity)
    try fixture.assertRejected(
      job: revokedJob,
      provider: FixedProvider(revokedReceipt),
      readinessTrust: revokedTrust)
  }

  func testRecoveryDispatchRequiresFreshChallengeAndReceipt() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = fixture.job(jobID: "job-original", nonce: "nonce-original")
    let originalReceipt = try fixture.receipt(for: original)
    let recovery = original.mintRecoveryDispatch(
      newJobID: "job-recovery",
      newDispatchNonce: "nonce-recovery",
      newReadinessChallengeNonce: "challenge-recovery",
      createdAt: Date(timeIntervalSince1970: 1_700_000_001))

    XCTAssertEqual(recovery.logicalJobID, original.logicalJobID)
    XCTAssertEqual(recovery.workspaceLocator, original.workspaceLocator)
    XCTAssertNotEqual(
      recovery.remoteDispatchReadiness?.challengeNonce,
      original.remoteDispatchReadiness?.challengeNonce)
    try fixture.assertRejected(job: recovery, provider: FixedProvider(originalReceipt))

    let freshRequirements = TatwoRemoteDispatchReadinessRequirementsV1(
      challengeNonce: "challenge-recovery")
    let freshReceipt = try fixture.receipt(for: recovery, requirements: freshRequirements)
    XCTAssertNoThrow(
      try fixture.projector(
        provider: FixedProvider(freshReceipt),
        requirements: freshRequirements).enqueue(recovery))
  }

  func testRetargetedRecoveryClearsTargetOwnedReadinessBinding() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = fixture.job(jobID: "job-retarget-old", nonce: "nonce-retarget-old")
    let recovery = original.mintRecoveryDispatch(
      newJobID: "job-retarget-new",
      newDispatchNonce: "nonce-retarget-new",
      newTargetDeviceID: "target-other")
    XCTAssertNil(recovery.remoteDispatchReadiness)
    XCTAssertNil(recovery.workspaceLocator)
  }

  func testAuthorizationPrecedesReadinessAndInvalidReadinessNeverReserves() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let job = fixture.job(jobID: "job-order", nonce: "nonce-order")
    _ = try fixture.authorizationStore.revokeSession(sessionID: fixture.sessionID)
    let provider = CountingProvider(try fixture.receipt(for: job))

    try fixture.assertRejected(job: job, provider: provider)
    XCTAssertEqual(provider.callCount, 0, "authorization preflight must reject before target transport")
  }

  func testGrantRevokedDuringProviderPreflightRejectsBeforeMutation() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let job = fixture.job(jobID: "job-revoke-race", nonce: "nonce-revoke-race")
    let provider = BlockingProvider(try fixture.receipt(for: job))
    let result = AsyncErrorBox()
    let projector = fixture.projector(provider: provider)
    let finished = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
      defer { finished.signal() }
      do {
        _ = try projector.enqueue(job)
        result.recordSuccess()
      } catch {
        result.record(error)
      }
    }
    XCTAssertEqual(provider.entered.wait(timeout: .now() + 5), .success)
    _ = try fixture.authorizationStore.revokeSession(sessionID: fixture.sessionID)
    provider.release.signal()
    XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    XCTAssertNotNil(result.error)
    XCTAssertNil(try fixture.registryRecord(job))
    XCTAssertFalse(fixture.channel.hasCommitMarker(forJobID: job.jobID))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.channel.jobURL(for: job).path))
  }

  func testLegacyDecodeWithoutReadinessRejectsOnGoalBoundPath() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let current = fixture.job(jobID: "job-legacy", nonce: "nonce-legacy")
    let encoded = try JSONEncoder().encode(current)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "remoteDispatchReadiness")
    let legacy = try JSONDecoder().decode(
      TatwoLoopJobV1.self,
      from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    XCTAssertNil(legacy.remoteDispatchReadiness)
    try fixture.assertRejected(
      job: legacy,
      provider: FixedProvider(try fixture.receipt(for: current)))
  }

  func testActiveSkillSetDigestIsCanonicalAndRejectsInvalidSets() throws {
    let a = TatwoActiveSkillRevisionV1(
      repository: "repo/a",
      revision: "rev-2",
      contentDigest: String(repeating: "a", count: 64))
    let b = TatwoActiveSkillRevisionV1(
      repository: "repo/b",
      revision: "rev-1",
      contentDigest: String(repeating: "b", count: 64))
    XCTAssertEqual(
      try TatwoActiveSkillSetDigestV1.canonicalDigest([a, b]),
      try TatwoActiveSkillSetDigestV1.canonicalDigest([b, a]))
    XCTAssertThrowsError(try TatwoActiveSkillSetDigestV1.canonicalDigest([]))
    XCTAssertThrowsError(try TatwoActiveSkillSetDigestV1.canonicalDigest([a, a]))
    XCTAssertThrowsError(
      try TatwoActiveSkillSetDigestV1.canonicalDigest([
        a,
        TatwoActiveSkillRevisionV1(
          repository: a.repository,
          revision: "rev-other",
          contentDigest: String(repeating: "c", count: 64)),
      ]))
    XCTAssertThrowsError(
      try TatwoActiveSkillSetDigestV1.canonicalDigest([
        TatwoActiveSkillRevisionV1(repository: "repo/c", revision: "rev", contentDigest: "bad")
      ]))
  }

  func testWorkspaceAndCapabilityCanonicalBuildersDetectInputChanges() throws {
    let workspace = TatwoTargetWorkspaceDigestInputV1(
      workspaceBindingID: "workspace-main",
      canonicalPathDigest: String(repeating: "1", count: 64),
      filesystemDeviceID: 42,
      filesystemInodeID: 100)
    let replacedInode = TatwoTargetWorkspaceDigestInputV1(
      workspaceBindingID: workspace.workspaceBindingID,
      canonicalPathDigest: workspace.canonicalPathDigest,
      filesystemDeviceID: workspace.filesystemDeviceID,
      filesystemInodeID: 101)
    XCTAssertNotEqual(try workspace.canonicalDigest(), try replacedInode.canonicalDigest())
    let replacedPath = TatwoTargetWorkspaceDigestInputV1(
      workspaceBindingID: workspace.workspaceBindingID,
      canonicalPathDigest: String(repeating: "4", count: 64),
      filesystemDeviceID: workspace.filesystemDeviceID,
      filesystemInodeID: workspace.filesystemInodeID)
    XCTAssertNotEqual(try workspace.canonicalDigest(), try replacedPath.canonicalDigest())

    let capability = TatwoAgentModelCapabilityDigestInputV1(
      requestedAgent: "codex",
      exactModelRouteID: "gpt-5.6-sol",
      executableContentDigest: String(repeating: "2", count: 64),
      transportCapabilities: ["file-receipt", "signed-readback"])
    let reordered = TatwoAgentModelCapabilityDigestInputV1(
      requestedAgent: capability.requestedAgent,
      exactModelRouteID: capability.exactModelRouteID,
      executableContentDigest: capability.executableContentDigest,
      transportCapabilities: Array(capability.transportCapabilities.reversed()))
    XCTAssertEqual(try capability.canonicalDigest(), try reordered.canonicalDigest())
    let differentModel = TatwoAgentModelCapabilityDigestInputV1(
      requestedAgent: capability.requestedAgent,
      exactModelRouteID: "gpt-5.6-luna",
      executableContentDigest: capability.executableContentDigest,
      transportCapabilities: capability.transportCapabilities)
    let differentExecutable = TatwoAgentModelCapabilityDigestInputV1(
      requestedAgent: capability.requestedAgent,
      exactModelRouteID: capability.exactModelRouteID,
      executableContentDigest: String(repeating: "3", count: 64),
      transportCapabilities: capability.transportCapabilities)
    XCTAssertNotEqual(try capability.canonicalDigest(), try differentModel.canonicalDigest())
    XCTAssertNotEqual(try capability.canonicalDigest(), try differentExecutable.canonicalDigest())
  }

  func testProviderRequestIsRedactedAndBindsTargetObservationToAttempt() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let job = fixture.job(jobID: "job-redacted-request", nonce: "nonce-redacted-request")
    let receipt = try fixture.receipt(for: job)
    let provider = CapturingProvider(receipt)

    _ = try fixture.projector(provider: provider).enqueue(job)

    let request = try XCTUnwrap(provider.request)
    XCTAssertEqual(request.originDeviceID, job.originDeviceID)
    XCTAssertEqual(request.targetDeviceID, job.targetDeviceID)
    XCTAssertEqual(request.jobID, job.jobID)
    XCTAssertEqual(request.logicalJobID, job.logicalJobID)
    XCTAssertEqual(request.dispatchNonce, job.dispatchNonce)
    XCTAssertEqual(request.jobCanonicalDigest, try job.canonicalDigest())
    XCTAssertEqual(request.expectedWorkspaceBindingID, fixture.binding.workspaceBindingID)
    XCTAssertEqual(
      request.expectedWorkspaceBindingDigest,
      fixture.binding.workspaceBindingDigest)
    XCTAssertEqual(
      request.expectedAgentModelCapabilityDigest,
      fixture.binding.agentModelCapabilityDigest)
    XCTAssertEqual(
      request.expectedActiveSkillSetDigest,
      fixture.binding.activeSkillSetDigest)
    XCTAssertEqual(request.challengeNonce, fixture.requirements.challengeNonce)
  }

  func testOriginPathCannotSubstituteTargetWorkspaceBinding() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let job = fixture.job(
      jobID: "job-origin-path-substitution",
      nonce: "nonce-origin-path-substitution",
      workPath: "/origin/display-name-that-is-not-a-target-binding")
    let forgedTargetObservation = TatwoRemoteDispatchReadinessObservationV1(
      targetWorkspaceBindingID: "origin/display-name-that-is-not-a-target-binding",
      targetWorkspaceBindingDigest: fixture.binding.workspaceBindingDigest,
      agentModelCapabilityDigest: fixture.binding.agentModelCapabilityDigest,
      activeSkillSetDigest: fixture.binding.activeSkillSetDigest,
      readbackNonce: fixture.requirements.challengeNonce)
    let forgedReceipt = try TatwoRemoteDispatchReadinessReceiptV1.issue(
      job: job,
      requirements: fixture.requirements,
      observation: forgedTargetObservation,
      targetTrust: fixture.targetTrust)

    try fixture.assertRejected(job: job, provider: FixedProvider(forgedReceipt))
  }

  func testRequirementsAreDerivedFromEachJobAttempt() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let job = fixture.job(jobID: "job-derived-requirements", nonce: "nonce-derived")
    let receipt = try fixture.receipt(for: job)

    XCTAssertNoThrow(
      try fixture.projector(
        provider: FixedProvider(receipt),
        requirements: nil).enqueue(job))

    let wrong = TatwoRemoteDispatchReadinessRequirementsV1(
      challengeNonce: "not-the-job-challenge")
    try fixture.assertRejected(
      job: fixture.job(jobID: "job-static-requirements", nonce: "nonce-static"),
      provider: FixedProvider(receipt),
      requirements: wrong)
  }

  func testSignedChannelReadinessTransportRoundTripUsesRedactedRequest() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let job = fixture.job(
      jobID: "job-channel-readiness",
      nonce: "nonce-channel-readiness",
      workPath: "/origin/secret/path")
    let requirements = try TatwoRemoteDispatchReadinessRequirementsV1(job: job)
    let request = try TatwoRemoteDispatchReadinessRequestV1(
      job: job,
      requirements: requirements)
    let targetTrust = try fixture.targetTrust.withPin(fixture.originTrust.localIdentity)
    let handler = TatwoRemoteDispatchReadinessTargetHandlerV1(
      rootURL: fixture.channel.rootURL,
      targetTrust: targetTrust
    ) { observed in
      XCTAssertFalse(
        String(describing: observed).contains("origin/secret/path"),
        "redacted request must not carry origin workPath")
      return TatwoRemoteDispatchReadinessObservationV1(
        targetWorkspaceBindingID: fixture.binding.workspaceBindingID,
        targetWorkspaceBindingDigest: fixture.binding.workspaceBindingDigest,
        agentModelCapabilityDigest: fixture.binding.agentModelCapabilityDigest,
        activeSkillSetDigest: fixture.binding.activeSkillSetDigest,
        readbackNonce: observed.challengeNonce)
    }
    let provider = TatwoRemoteDispatchReadinessChannelProviderV1(
      channel: fixture.channel,
      timeoutSec: 2,
      pollIntervalSec: 0.01)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { done.signal() }
      while Date() < Date().addingTimeInterval(1) {
        if (try? handler.servicePendingRequests()) == 1 { return }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
    let receipt = try provider.readinessReceipt(for: request)
    XCTAssertEqual(receipt.jobID, job.jobID)
    XCTAssertEqual(receipt.dispatchNonce, job.dispatchNonce)
    try receipt.verify(
      job: job,
      requirements: requirements,
      trust: fixture.originTrust,
      environment: fixture.environment)
    XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
  }

  func testProductionObserverMissingBindingsReturnsSignedExplicitBlocker() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let job = fixture.job(jobID: "job-observer-blocked", nonce: "nonce-observer-blocked")
    let requirements = try TatwoRemoteDispatchReadinessRequirementsV1(job: job)
    let request = try TatwoRemoteDispatchReadinessRequestV1(
      job: job,
      requirements: requirements)
    let targetTrust = try fixture.targetTrust.withPin(fixture.originTrust.localIdentity)
    let handler = TatwoRemoteDispatchReadinessTargetHandlerV1(
      rootURL: fixture.channel.rootURL,
      targetTrust: targetTrust,
      observe: TatwoRemoteDispatchReadinessTargetObservationProviderV1.production)
    let provider = TatwoRemoteDispatchReadinessChannelProviderV1(
      channel: fixture.channel,
      timeoutSec: 2,
      pollIntervalSec: 0.01)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { done.signal() }
      let deadline = Date().addingTimeInterval(1)
      while Date() < deadline {
        if (try? handler.servicePendingRequests()) == 1 { return }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
    XCTAssertThrowsError(try provider.readinessReceipt(for: request)) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessError,
        .targetObservationUnavailable(
          "workspace_binding,agent_model_capability,active_skill_set"))
    }
    XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
  }

  func testSignedManifestFableRouteCannotVerifyAsOpus() throws {
    let fixture = try Fixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date()
    let store = TatwoRemoteDispatchReadinessRegistryStoreV1(
      rootURL: fixture.root.appendingPathComponent("readiness-registry"),
      trust: fixture.targetTrust)
    let entry = TatwoRemoteDispatchReadinessRegistryEntryV1(
      workspaceBindingID: "workspace-fable",
      canonicalWorkspacePath: fixture.work.path,
      workspaceDigestInput: TatwoTargetWorkspaceDigestInputV1(
        workspaceBindingID: "workspace-fable",
        canonicalPathDigest: String(repeating: "a", count: 64),
        filesystemDeviceID: 1,
        filesystemInodeID: 1),
      requestedAgent: .claude,
      exactModelRouteID: "fable-5",
      executablePin: TatwoAgentExecutablePinV1(
        agent: "claude",
        whitelistPath: "/allowed/claude",
        finalTargetPath: "/allowed/claude",
        contentDigest: "sha256:" + String(repeating: "d", count: 64),
        recordedAt: now),
      transportCapabilities: ["signed-readiness-v1", "stdin-task-v1"],
      activeSkillRevisions: [
        TatwoActiveSkillRevisionV1(
          repository: "skills-main",
          revision: "rev-1",
          contentDigest: String(repeating: "e", count: 64))
      ],
      updatedAt: now)
    let manifest = try store.publish(
      entry,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(60))

    XCTAssertNoThrow(
      try manifest.verify(
        trust: fixture.originTrust,
        expectedTargetDeviceID: fixture.targetIdentity.deviceID,
        expectedAgent: .claude,
        expectedExactModelRouteID: "fable-5",
        now: now,
        environment: fixture.environment))
    XCTAssertThrowsError(
      try manifest.verify(
        trust: fixture.originTrust,
        expectedTargetDeviceID: fixture.targetIdentity.deviceID,
        expectedAgent: .claude,
        expectedExactModelRouteID: "opus-5",
        now: now,
        environment: fixture.environment)
    ) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessRegistryError,
        .invalidField("manifest.modelRouteScope"))
    }
  }

  func testTargetRegistryResolutionIgnoresOriginWorkPathSpoof() throws {
    let fixture = try ResolverFixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let job = fixture.job(workPath: fixture.originSpoof.path)

    try job.validate()
    let bound = try fixture.resolve(job)

    XCTAssertEqual(
      TatwoPathCanonical.filePath(try bound.currentPathString()),
      TatwoPathCanonical.filePath(fixture.work.path))
    XCTAssertNotEqual(
      TatwoPathCanonical.filePath(try bound.currentPathString()),
      TatwoPathCanonical.filePath(fixture.originSpoof.path))
  }

  func testFleetAdapterRejectsManifestReplacementAfterJobBinding() throws {
    let fixture = try ResolverFixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let queuedJob = fixture.job()

    XCTAssertNoThrow(
      try fixture.manifest.validateCurrentProductionAgentBinding(
        for: queuedJob,
        trust: fixture.targetTrust,
        environment: environment))

    // Publishing again advances the target-signed registry generation. The
    // queued job still carries the previous locator and must not be rewritten.
    let replacement = try fixture.registryStore.publish(fixture.entry)
    XCTAssertGreaterThan(
      replacement.registryGeneration,
      fixture.manifest.registryGeneration)
    XCTAssertThrowsError(
      try replacement.validateCurrentProductionAgentBinding(
        for: queuedJob,
        trust: fixture.targetTrust,
        environment: environment)
    ) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessRegistryError,
        .invalidField("job.workspaceLocator"))
    }
  }

  func testTargetRegistryResolutionRejectsMissingLocatorAndRegistry() throws {
    let fixture = try ResolverFixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertThrowsError(try fixture.resolve(fixture.job(includeLocator: false))) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessRegistryError,
        .bindingNotFound)
    }

    let missingStore = TatwoRemoteDispatchReadinessRegistryStoreV1(
      rootURL: fixture.root.appendingPathComponent("missing-registry"),
      trust: fixture.targetTrust)
    XCTAssertThrowsError(
      try missingStore.resolveAndBindWorkspace(
        for: fixture.job(),
        agentEngine: fixture.engine,
        skilletStore: fixture.skilletStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessRegistryError,
        .registryMissing)
    }
  }

  func testTargetRegistryResolutionRejectsStaleGenerationAndDigestDrift() throws {
    let fixture = try ResolverFixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = fixture.job()

    _ = try fixture.registryStore.publish(fixture.entry)
    XCTAssertThrowsError(try fixture.resolve(original)) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessRegistryError,
        .bindingDrift("registryGeneration"))
    }

    let currentManifest = try fixture.registryStore.publish(fixture.entry)
    let wrongBinding = TatwoRemoteDispatchReadinessBindingV1(
      workspaceBindingID: currentManifest.workspaceBindingID,
      workspaceBindingDigest: String(repeating: "0", count: 64),
      agentModelCapabilityDigest: currentManifest.agentModelCapabilityDigest,
      activeSkillSetDigest: currentManifest.activeSkillSetDigest,
      challengeNonce: "challenge-resolver")
    XCTAssertThrowsError(
      try fixture.resolve(
        fixture.job(
          registryGeneration: currentManifest.registryGeneration,
          readiness: wrongBinding))
    ) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessRegistryError,
        .bindingDrift("workspaceBindingDigest"))
    }
  }

  func testTargetRegistryResolutionRejectsActiveSkillDrift() throws {
    let fixture = try ResolverFixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = fixture.job()

    try fixture.advanceActiveSkill()

    XCTAssertThrowsError(try fixture.resolve(original)) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessRegistryError,
        .bindingDrift("activeSkillSetDigest"))
    }
  }

  func testTargetRegistryResolutionRejectsWorkspaceReplacementBeforeBind() throws {
    let fixture = try ResolverFixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = fixture.job()
    let moved = fixture.root.appendingPathComponent(
      "target-work-original",
      isDirectory: true)
    try FileManager.default.moveItem(at: fixture.work, to: moved)
    try FileManager.default.createDirectory(
      at: fixture.work,
      withIntermediateDirectories: true)

    XCTAssertThrowsError(try fixture.resolve(original)) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessRegistryError,
        .bindingDrift("workspaceBindingDigest"))
    }
  }

  func testTargetRegistryResolutionRejectsSymlinkedWorkspacePathStoredInRegistry() throws {
    let fixture = try ResolverFixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let symlink = fixture.root.appendingPathComponent(
      "workspace-link",
      isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: symlink,
      withDestinationURL: fixture.work)
    let symlinkEntry = TatwoRemoteDispatchReadinessRegistryEntryV1(
      workspaceBindingID: fixture.entry.workspaceBindingID,
      canonicalWorkspacePath: symlink.path,
      workspaceDigestInput: fixture.entry.workspaceDigestInput,
      requestedAgent: fixture.entry.requestedAgent,
      exactModelRouteID: fixture.entry.exactModelRouteID,
      executablePin: fixture.entry.executablePin,
      transportCapabilities: fixture.entry.transportCapabilities,
      activeSkillRevisions: fixture.entry.activeSkillRevisions)
    let manifest = try fixture.registryStore.publish(symlinkEntry)

    XCTAssertThrowsError(
      try fixture.resolve(
        fixture.job(
          registryGeneration: manifest.registryGeneration,
          readiness: manifest.binding(challengeNonce: "challenge-resolver")))
    ) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessRegistryError,
        .bindingDrift("canonicalWorkspacePath"))
    }
  }

  func testTargetRegistryResolutionRejectsSignedAmbiguousBinding() throws {
    let fixture = try ResolverFixture(environment: environment)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.writeSignedRegistry(entries: [fixture.entry, fixture.entry])

    XCTAssertThrowsError(try fixture.resolve(fixture.job())) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessRegistryError,
        .bindingAmbiguous)
    }
  }
}

private final class FixedProvider: TatwoRemoteDispatchReadinessProviding, @unchecked Sendable {
  let receipt: TatwoRemoteDispatchReadinessReceiptV1
  init(_ receipt: TatwoRemoteDispatchReadinessReceiptV1) { self.receipt = receipt }
  func readinessReceipt(
    for request: TatwoRemoteDispatchReadinessRequestV1
  ) throws -> TatwoRemoteDispatchReadinessReceiptV1 {
    _ = request
    return receipt
  }
}

private final class CountingProvider: TatwoRemoteDispatchReadinessProviding, @unchecked Sendable {
  private let lock = NSLock()
  private let receipt: TatwoRemoteDispatchReadinessReceiptV1
  private var calls = 0
  var callCount: Int { lock.withLock { calls } }
  init(_ receipt: TatwoRemoteDispatchReadinessReceiptV1) { self.receipt = receipt }
  func readinessReceipt(
    for request: TatwoRemoteDispatchReadinessRequestV1
  ) throws -> TatwoRemoteDispatchReadinessReceiptV1 {
    _ = request
    lock.withLock { calls += 1 }
    return receipt
  }
}

private final class BlockingProvider: TatwoRemoteDispatchReadinessProviding, @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private let receipt: TatwoRemoteDispatchReadinessReceiptV1
  init(_ receipt: TatwoRemoteDispatchReadinessReceiptV1) { self.receipt = receipt }
  func readinessReceipt(
    for request: TatwoRemoteDispatchReadinessRequestV1
  ) throws -> TatwoRemoteDispatchReadinessReceiptV1 {
    _ = request
    entered.signal()
    _ = release.wait(timeout: .now() + 5)
    return receipt
  }
}

private final class CapturingProvider: TatwoRemoteDispatchReadinessProviding, @unchecked Sendable {
  private let lock = NSLock()
  private let receipt: TatwoRemoteDispatchReadinessReceiptV1
  private var storedRequest: TatwoRemoteDispatchReadinessRequestV1?
  var request: TatwoRemoteDispatchReadinessRequestV1? { lock.withLock { storedRequest } }

  init(_ receipt: TatwoRemoteDispatchReadinessReceiptV1) { self.receipt = receipt }

  func readinessReceipt(
    for request: TatwoRemoteDispatchReadinessRequestV1
  ) throws -> TatwoRemoteDispatchReadinessReceiptV1 {
    lock.withLock { storedRequest = request }
    return receipt
  }
}

private final class AsyncErrorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Error?
  var error: Error? { lock.withLock { storedError } }
  func record(_ error: Error) { lock.withLock { storedError = error } }
  func recordSuccess() { lock.withLock { storedError = nil } }
}

private struct Fixture {
  let root: URL
  let work: URL
  let goalStore: TatwoGoalRunStore
  let registry: TatwoDispatchRegistry
  let authorizationStore: TatwoRemoteBorrowAuthorizationStore
  let contract: TatwoWorkOSContractV1
  let sessionID: String
  let grant: TatwoRemoteSessionGrantV1
  let originTrust: TatwoLoopJobChannelTrust
  let targetTrust: TatwoLoopJobChannelTrust
  let targetIdentity: TatwoDevicePublicIdentityV1
  let channel: TatwoLoopJobChannel
  let environment: [String: String]
  let requirements = TatwoRemoteDispatchReadinessRequirementsV1(challengeNonce: "challenge-ready")
  let binding = TatwoRemoteDispatchReadinessBindingV1(
    workspaceBindingID: "workspace-main",
    workspaceBindingDigest: String(repeating: "a", count: 64),
    agentModelCapabilityDigest: String(repeating: "b", count: 64),
    activeSkillSetDigest: String(repeating: "c", count: 64),
    challengeNonce: "challenge-ready")
  let locator = TatwoRemoteWorkspaceLocatorV1(
    workspaceBindingID: "workspace-main",
    registryGeneration: 1)

  init(environment: [String: String]) throws {
    self.environment = environment
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-readiness-\(UUID().uuidString)", isDirectory: true)
    work = root.appendingPathComponent("work", isDirectory: true)
    let state = root.appendingPathComponent("state", isDirectory: true)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)

    let originKeys = ReadinessMemoryKeyStore()
    let targetKeys = ReadinessMemoryKeyStore()
    let originSeed = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "origin-ready", privateKeyStore: originKeys, environment: environment)
    targetTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "target-ready", privateKeyStore: targetKeys, environment: environment)
    targetIdentity = targetTrust.localIdentity
    originTrust = try originSeed.withPin(targetIdentity)
    channel = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: originTrust,
      environment: environment)
    goalStore = TatwoGoalRunStore(directoryURL: state)
    registry = TatwoDispatchRegistry(directoryURL: state)
    contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "general-m-sol",
      objective: "remote readiness focused fixture",
      store: goalStore)
    let grokBinding = try XCTUnwrap(
      contract.identityBindings.first {
        $0.identity == .sub
          && TatwoGatewayDispatchCatalog.normalize($0.modelID ?? "") == "grok-build"
      },
      "readiness production fixture must issue the exact sub/grok-build binding")
    _ = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: grokBinding.id,
      sourceSlotID: grokBinding.sourceSlotID,
      identity: .sub,
      modelID: "grok-build",
      subtask: "issue readiness fixture route binding",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)
    authorizationStore = TatwoRemoteBorrowAuthorizationStore.production(stateRoot: state)
    sessionID = "thread-readiness"
    grant = try authorizationStore.issueSessionGrant(
      sessionID: sessionID,
      targetDeviceID: targetIdentity.deviceID,
      contractID: contract.contractID)
  }

  func job(
    jobID: String,
    nonce: String,
    readiness: TatwoRemoteDispatchReadinessBindingV1?? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    workPath: String? = nil
  ) -> TatwoLoopJobV1 {
    TatwoLoopJobV1(
      jobID: jobID,
      logicalJobID: "logical-\(jobID)",
      dispatchNonce: nonce,
      contractID: contract.contractID,
      goalID: contract.goalID,
      identity: .sub,
      originDeviceID: originTrust.localIdentity.deviceID,
      targetDeviceID: targetIdentity.deviceID,
      remoteBorrowInvocation: TatwoRemoteBorrowInvocationV1(
        sessionID: sessionID,
        targetDeviceID: targetIdentity.deviceID,
        contractID: contract.contractID,
        goalID: contract.goalID,
        mode: .manual,
        risk: .lowRisk,
        grantID: grant.id),
      remoteDispatchReadiness: readiness ?? binding,
      workspaceLocator: locator,
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contract.contractID,
          goalID: contract.goalID,
          identity: .sub,
          mode: .m,
          taskDescription: "readiness-gated remote agent task",
          agent: .grok,
          exactModelRouteID: "grok-build")),
      workPath: workPath ?? work.path,
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 2, maxOutputBytes: 256),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      createdAt: createdAt)
  }

  func receipt(
    for job: TatwoLoopJobV1,
    requirements: TatwoRemoteDispatchReadinessRequirementsV1? = nil,
    workspaceDigest: String? = nil,
    capabilityDigest: String? = nil,
    skillDigest: String? = nil,
    readbackNonce: String? = nil,
    issuedAt: Date = Date(),
    expiresAt: Date? = nil
  ) throws -> TatwoRemoteDispatchReadinessReceiptV1 {
    let req = requirements ?? self.requirements
    return try TatwoRemoteDispatchReadinessReceiptV1.issue(
      job: job,
      requirements: req,
      observation: TatwoRemoteDispatchReadinessObservationV1(
        targetWorkspaceBindingID: binding.workspaceBindingID,
        targetWorkspaceBindingDigest: workspaceDigest ?? binding.workspaceBindingDigest,
        agentModelCapabilityDigest: capabilityDigest ?? binding.agentModelCapabilityDigest,
        activeSkillSetDigest: skillDigest ?? binding.activeSkillSetDigest,
        readbackNonce: readbackNonce ?? req.challengeNonce),
      targetTrust: targetTrust,
      issuedAt: issuedAt,
      expiresAt: expiresAt)
  }

  func projector(
    provider: (any TatwoRemoteDispatchReadinessProviding)?,
    requirements: TatwoRemoteDispatchReadinessRequirementsV1? = nil,
    readinessTrust: TatwoLoopJobChannelTrust? = nil
  ) -> TatwoLoopOriginProjectorV1 {
    TatwoLoopOriginProjectorV1(
      channel: TatwoLoopJobChannel(
        rootURL: channel.rootURL,
        trust: readinessTrust ?? originTrust,
        environment: environment),
      registry: registry,
      originDeviceID: originTrust.localIdentity.deviceID,
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: registry.directoryURL),
      goalStore: goalStore,
      remoteBorrowAuthorizationStore: authorizationStore,
      verifiedTargetIdentity: targetIdentity,
      remoteReadinessProvider: provider,
      remoteReadinessRequirements: requirements ?? self.requirements,
      environment: environment)
  }

  func registryRecord(_ job: TatwoLoopJobV1) throws -> TatwoDispatchRecord? {
    try registry.run(forContractID: job.contractID)?
      .records.first { $0.remoteJobID == job.jobID }
  }

  func assertRejected(
    job: TatwoLoopJobV1,
    provider: (any TatwoRemoteDispatchReadinessProviding)?,
    requirements: TatwoRemoteDispatchReadinessRequirementsV1?? = nil,
    readinessTrust: TatwoLoopJobChannelTrust? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let resolvedRequirements = requirements ?? self.requirements
    XCTAssertThrowsError(
      try projector(
        provider: provider,
        requirements: resolvedRequirements,
        readinessTrust: readinessTrust).enqueue(job),
      file: file,
      line: line)
    XCTAssertNil(try registryRecord(job), file: file, line: line)
    XCTAssertFalse(channel.hasCommitMarker(forJobID: job.jobID), file: file, line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: channel.jobURL(for: job).path),
      file: file,
      line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: channel.jobSignatureURL(for: job).path),
      file: file,
      line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: channel.journalURL(forJobID: job.jobID).path),
      file: file,
      line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: channel.ackURL(forJobID: job.jobID).path),
      file: file,
      line: line)
  }

  func resigned(
    _ receipt: TatwoRemoteDispatchReadinessReceiptV1,
    targetDeviceID: String
  ) throws -> TatwoRemoteDispatchReadinessReceiptV1 {
    let candidate = TatwoRemoteDispatchReadinessReceiptV1(
      originDeviceID: receipt.originDeviceID,
      targetDeviceID: targetDeviceID,
      targetKeyID: receipt.targetKeyID,
      targetKeyGeneration: receipt.targetKeyGeneration,
      contractID: receipt.contractID,
      goalID: receipt.goalID,
      jobID: receipt.jobID,
      logicalJobID: receipt.logicalJobID,
      dispatchNonce: receipt.dispatchNonce,
      jobCanonicalDigest: receipt.jobCanonicalDigest,
      targetWorkspaceBindingID: receipt.targetWorkspaceBindingID,
      targetWorkspaceBindingDigest: receipt.targetWorkspaceBindingDigest,
      agentModelCapabilityDigest: receipt.agentModelCapabilityDigest,
      activeSkillSetDigest: receipt.activeSkillSetDigest,
      challengeNonce: receipt.challengeNonce,
      readbackNonce: receipt.readbackNonce,
      issuedAt: receipt.issuedAt,
      expiresAt: receipt.expiresAt,
      targetSignature: receipt.targetSignature)
    let signature = try targetTrust.sign(
      payload: candidate.canonicalSigningPayload(),
      purpose: .loopTargetReadiness,
      signedAt: candidate.issuedAt)
    return copy(candidate, signature: signature)
  }

  func copy(
    _ receipt: TatwoRemoteDispatchReadinessReceiptV1,
    signature: TatwoDeviceSignatureV1
  ) -> TatwoRemoteDispatchReadinessReceiptV1 {
    TatwoRemoteDispatchReadinessReceiptV1(
      originDeviceID: receipt.originDeviceID,
      targetDeviceID: receipt.targetDeviceID,
      targetKeyID: receipt.targetKeyID,
      targetKeyGeneration: receipt.targetKeyGeneration,
      contractID: receipt.contractID,
      goalID: receipt.goalID,
      jobID: receipt.jobID,
      logicalJobID: receipt.logicalJobID,
      dispatchNonce: receipt.dispatchNonce,
      jobCanonicalDigest: receipt.jobCanonicalDigest,
      targetWorkspaceBindingID: receipt.targetWorkspaceBindingID,
      targetWorkspaceBindingDigest: receipt.targetWorkspaceBindingDigest,
      agentModelCapabilityDigest: receipt.agentModelCapabilityDigest,
      activeSkillSetDigest: receipt.activeSkillSetDigest,
      challengeNonce: receipt.challengeNonce,
      readbackNonce: receipt.readbackNonce,
      issuedAt: receipt.issuedAt,
      expiresAt: receipt.expiresAt,
      targetSignature: signature)
  }
}

private struct ResolverFixture {
  let root: URL
  let work: URL
  let originSpoof: URL
  let skillSource: URL
  let targetTrust: TatwoLoopJobChannelTrust
  let engine: TatwoAgentEngineBinding
  let skilletStore: TatwoSkilletRepositoryStore
  let registryStore: TatwoRemoteDispatchReadinessRegistryStoreV1
  let entry: TatwoRemoteDispatchReadinessRegistryEntryV1
  let manifest: TatwoRemoteDispatchReadinessManifestV1

  init(environment: [String: String]) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-readiness-resolver-\(UUID().uuidString)",
      isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("target-work", isDirectory: true)
    let originSpoof = root.appendingPathComponent("origin-spoof", isDirectory: true)
    let skillSource = root.appendingPathComponent("skill-source", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: originSpoof,
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: skillSource,
      withIntermediateDirectories: true)

    let executableDirectory = home.appendingPathComponent(
      ".local/bin",
      isDirectory: true)
    try FileManager.default.createDirectory(
      at: executableDirectory,
      withIntermediateDirectories: true)
    let executable = executableDirectory.appendingPathComponent("grok")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path)

    let targetTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "target-resolver",
      privateKeyStore: ReadinessMemoryKeyStore(),
      environment: environment)
    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-system")
    let skilletStore = TatwoSkilletRepositoryStore(
      rootURL: root.appendingPathComponent("skillet", isDirectory: true))
    try Data("---\nname: resolver-skill\n---\nversion: 1\n".utf8)
      .write(to: skillSource.appendingPathComponent("SKILL.md"))
    let revision = try skilletStore.snapshotCanonicalSkillDirectory(
      repositoryID: "resolver-skill",
      displayName: "Resolver Skill",
      summary: "Target resolver fixture",
      sourceDirectory: skillSource,
      channel: .staging)
    try skilletStore.promoteRevision(
      repositoryID: "resolver-skill",
      revisionID: revision.id,
      to: .stable)
    try skilletStore.upsertDeviceHead(
      TatwoDeviceHeadV1(
        deviceID: targetTrust.localIdentity.deviceID,
        repositoryID: "resolver-skill",
        revisionID: revision.id,
        contentDigest: revision.contentDigest,
        requestID: "resolver-head-1",
        authorityEpoch: 1,
        ledgerSequence: 1,
        activationState: .active,
        lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_001)))

    let registryStore = TatwoRemoteDispatchReadinessRegistryStoreV1(
      rootURL: root.appendingPathComponent("readiness-registry", isDirectory: true),
      trust: targetTrust)
    let entry = try TatwoRemoteDispatchReadinessTargetSnapshotBuilderV1.build(
      workspaceBindingID: "workspace-resolver",
      workspaceURL: work,
      requestedAgent: .grok,
      exactModelRouteID: "grok-build",
      targetDeviceID: targetTrust.localIdentity.deviceID,
      agentEngine: engine,
      skilletStore: skilletStore)
    let manifest = try registryStore.publish(entry)

    self.root = root
    self.work = work
    self.originSpoof = originSpoof
    self.skillSource = skillSource
    self.targetTrust = targetTrust
    self.engine = engine
    self.skilletStore = skilletStore
    self.registryStore = registryStore
    self.entry = entry
    self.manifest = manifest
  }

  func job(
    workPath: String? = nil,
    includeLocator: Bool = true,
    registryGeneration: UInt64? = nil,
    readiness: TatwoRemoteDispatchReadinessBindingV1? = nil
  ) -> TatwoLoopJobV1 {
    TatwoLoopJobV1(
      jobID: "job-resolver",
      logicalJobID: "logical-resolver",
      dispatchNonce: "nonce-resolver",
      contractID: "contract-resolver",
      goalID: "goal-resolver",
      identity: .sub,
      originDeviceID: "origin-resolver",
      targetDeviceID: targetTrust.localIdentity.deviceID,
      remoteDispatchReadiness:
        readiness ?? manifest.binding(challengeNonce: "challenge-resolver"),
      workspaceLocator: includeLocator
        ? TatwoRemoteWorkspaceLocatorV1(
          workspaceBindingID: manifest.workspaceBindingID,
          registryGeneration: registryGeneration ?? manifest.registryGeneration)
        : nil,
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: "contract-resolver",
          goalID: "goal-resolver",
          identity: .sub,
          mode: .m,
          taskDescription: "resolve target workspace",
          agent: .grok,
          exactModelRouteID: "grok-build")),
      workPath: workPath ?? originSpoof.path,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: 2,
        maxOutputBytes: 256),
      stopConditions: TatwoLoopStopConditionsV1(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_002))
  }

  func resolve(_ job: TatwoLoopJobV1) throws -> TatwoBoundWorkPath {
    try registryStore.resolveAndBindWorkspace(
      for: job,
      agentEngine: engine,
      skilletStore: skilletStore)
  }

  func advanceActiveSkill() throws {
    try Data("---\nname: resolver-skill\n---\nversion: 2\n".utf8)
      .write(to: skillSource.appendingPathComponent("SKILL.md"))
    let revision = try skilletStore.snapshotCanonicalSkillDirectory(
      repositoryID: "resolver-skill",
      displayName: "Resolver Skill",
      summary: "Target resolver fixture",
      sourceDirectory: skillSource,
      channel: .staging)
    try skilletStore.promoteRevision(
      repositoryID: "resolver-skill",
      revisionID: revision.id,
      to: .stable)
    try skilletStore.upsertDeviceHead(
      TatwoDeviceHeadV1(
        deviceID: targetTrust.localIdentity.deviceID,
        repositoryID: "resolver-skill",
        revisionID: revision.id,
        contentDigest: revision.contentDigest,
        requestID: "resolver-head-2",
        authorityEpoch: 1,
        ledgerSequence: 2,
        activationState: .active,
        lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_003)))
  }

  func writeSignedRegistry(
    entries: [TatwoRemoteDispatchReadinessRegistryEntryV1]
  ) throws {
    let updatedAt = manifest.issuedAt
    let unsigned = TestReadinessRegistryUnsigned(
      targetDeviceID: targetTrust.localIdentity.deviceID,
      targetKeyID: targetTrust.localIdentity.keyID,
      targetKeyGeneration: targetTrust.localIdentity.keyGeneration,
      generation: manifest.registryGeneration,
      updatedAt: updatedAt,
      entries: entries)
    let signature = try targetTrust.sign(
      payload: try unsigned.canonicalData(),
      purpose: .loopTargetReadiness,
      signedAt: updatedAt)
    let registry = TestSignedReadinessRegistry(
      unsigned: unsigned,
      targetSignature: signature)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(registry).write(to: registryStore.registryURL)
  }
}

private struct TestSignedReadinessRegistry: Encodable {
  let schema = "TatwoRemoteDispatchReadinessRegistryV1"
  let unsigned: TestReadinessRegistryUnsigned
  let targetSignature: TatwoDeviceSignatureV1
}

private struct TestReadinessRegistryUnsigned: Encodable {
  let schema = "TatwoRemoteDispatchReadinessRegistryV1"
  let targetDeviceID: String
  let targetKeyID: String
  let targetKeyGeneration: UInt64
  let generation: UInt64
  let updatedAt: Date
  let entries: [TatwoRemoteDispatchReadinessRegistryEntryV1]

  func canonicalData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }
}

private final class ReadinessMemoryKeyStore: TatwoDevicePrivateKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String: Data] = [:]
  func loadPrivateKey(deviceID: String, generation: UInt64) throws -> Data? {
    lock.withLock { keys["\(deviceID)#\(generation)"] }
  }
  func storePrivateKey(_ key: Data, deviceID: String, generation: UInt64) throws {
    guard key.count == 32 else { throw TatwoDeviceTrustError.invalidPrivateKey }
    try lock.withLock {
      let account = "\(deviceID)#\(generation)"
      if let existing = keys[account], existing != key {
        throw TatwoDeviceTrustError.duplicatePrivateKeyMismatch
      }
      keys[account] = key
    }
  }
}
