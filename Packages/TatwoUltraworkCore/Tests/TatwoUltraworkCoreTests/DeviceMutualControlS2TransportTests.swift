import Foundation
import TatwoDomainContracts
import XCTest

@testable import TatwoUltraworkCore

final class DeviceMutualControlS2TransportTests: XCTestCase {
  private let testEnvironment = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]
  private let producedAt = Date(timeIntervalSince1970: 1_800_000_000)

  // MARK: - Fixtures

  private func listDirDescriptor() -> TatwoDeviceCapabilityDescriptorV1 {
    TatwoDeviceCapabilityDescriptorV1(
      templateID: "fs.list_dir",
      displayName: "List directory",
      executable: "/bin/ls",
      argvTemplate: ["-la", "{path}"],
      paramSlots: [
        TatwoMutualControlParamSlotV1(
          name: "path",
          constraint: .pathPrefix(["/Users/example/inbox", "/tmp/mutual-control"]))
      ],
      resourceLimits: TatwoMutualControlResourceLimitsV1(
        timeoutSec: 30,
        maxOutputBytes: 64_000),
      riskLevel: .normal,
      sideEffectClass: .readOnly)
  }

  private func deleteDescriptor() -> TatwoDeviceCapabilityDescriptorV1 {
    TatwoDeviceCapabilityDescriptorV1(
      templateID: "fs.trash_path",
      executable: "/usr/bin/trash",
      argvTemplate: ["{path}"],
      paramSlots: [
        TatwoMutualControlParamSlotV1(
          name: "path",
          constraint: .pathPrefix(["/Users/example/inbox"]))
      ],
      resourceLimits: TatwoMutualControlResourceLimitsV1(
        timeoutSec: 60,
        maxOutputBytes: 8_192),
      riskLevel: .highRisk,
      highRiskCategory: .delete,
      sideEffectClass: .localMutable)
  }

  private func invocation(
    templateID: String,
    params: [String: String],
    approvalID: String? = nil,
    jobID: String = "job-mc-s2-1",
    dispatchNonce: String = "nonce-mc-s2-1",
    sourceDeviceID: String = "source-a",
    targetDeviceID: String = "target-b",
    leaseDomainBinding: TatwoLeaseDomainBindingV1 = .none(
      justification: "target is outside any lease domain")
  ) -> TatwoMutualControlInvocationV1 {
    TatwoMutualControlInvocationV1(
      logicalControlID: "logical-mc-s2-1",
      jobID: jobID,
      dispatchNonce: dispatchNonce,
      sourceDeviceID: sourceDeviceID,
      operatorPrincipalID: "operator-alice",
      targetDeviceID: targetDeviceID,
      templateID: templateID,
      capabilityVersion: 1,
      params: params,
      approvalID: approvalID,
      leaseDomainBinding: leaseDomainBinding)
  }

  private func makeTrust(deviceID: String) throws -> TatwoLoopJobChannelTrust {
    try TatwoLoopJobChannelTrust.enroll(
      deviceID: deviceID,
      privateKeyStore: S2TransportMemoryPrivateKeyStore(),
      pinnedAt: producedAt,
      environment: testEnvironment)
  }

  private func validate(
    invocation: TatwoMutualControlInvocationV1,
    descriptor: TatwoDeviceCapabilityDescriptorV1,
    targetDeviceID: String = "target-b"
  ) throws -> (
    validation: TatwoMutualControlValidationResultV1,
    limits: TatwoMutualControlResourceLimitsV1,
    digest: String?
  ) {
    let trust = try makeTrust(deviceID: targetDeviceID)
    let manifest = try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: targetDeviceID,
      capabilityVersion: 1,
      descriptors: [descriptor],
      producedAt: producedAt,
      trust: trust)
    let validation = TatwoMutualControlValidatorV1.validate(
      invocation: invocation,
      manifest: manifest,
      pinnedIdentity: trust.localIdentity)
    let digest = manifest.descriptor(templateID: descriptor.templateID)?.descriptorDigest
    return (validation, descriptor.resourceLimits, digest)
  }

  // MARK: - Force 1: validation must pass

  func testDispatchRejectedWhenValidationFails() throws {
    let inv = invocation(
      templateID: "fs.list_dir",
      params: ["path": "/etc/passwd"])  // path escape → param invalid
    let (validation, limits, _) = try validate(
      invocation: inv, descriptor: listDirDescriptor())
    XCTAssertFalse(validation.accepted)
    XCTAssertEqual(validation.errorCode, .paramInvalid)

    XCTAssertThrowsError(
      try TatwoMutualControlDispatchV1.make(
        invocation: inv,
        validation: validation,
        resourceLimits: limits,
        descriptorDigest: nil,
        leaseDomainBinding: .none(justification: "rejected validation fixture"),
        originAuthorityProvider: TatwoNoLeaseDomainAuthority(),
        now: producedAt)
    ) { error in
      guard let err = error as? TatwoMutualControlDispatchErrorV1,
        case let .validationNotAccepted(code, _) = err
      else {
        return XCTFail("expected validationNotAccepted, got \(error)")
      }
      XCTAssertEqual(code, .paramInvalid)
    }
  }

  // MARK: - Force 2: high_risk requires human gate token

  func testHighRiskWithoutHumanGateTokenRejected() throws {
    let inv = invocation(
      templateID: "fs.trash_path",
      params: ["path": "/Users/example/inbox/old"],
      approvalID: nil)
    let (validation, limits, _) = try validate(
      invocation: inv, descriptor: deleteDescriptor())
    // S1 validator already rejects; force dispatch path with a forged "accepted"
    // high-risk result to prove dispatch layer also gates.
    XCTAssertFalse(validation.accepted)
    XCTAssertEqual(validation.errorCode, .highRiskNoApproval)

    let forgedAccepted = TatwoMutualControlValidationResultV1(
      accepted: true,
      requiresHumanGate: true,
      resolvedExecutable: "/usr/bin/trash",
      resolvedArgv: ["/Users/example/inbox/old"],
      templateID: "fs.trash_path",
      riskLevel: .highRisk,
      highRiskCategory: .delete,
      invokeCanonicalDigest: "sha256:deadbeef",
      capabilityVersion: 1)

    XCTAssertThrowsError(
      try TatwoMutualControlDispatchV1.make(
        invocation: inv,
        validation: forgedAccepted,
        resourceLimits: limits,
        descriptorDigest: "sha256:forged",
        leaseDomainBinding: .none(justification: "forged validation fixture"),
        originAuthorityProvider: TatwoNoLeaseDomainAuthority(),
        now: producedAt)
    ) { error in
      XCTAssertEqual(
        error as? TatwoMutualControlDispatchErrorV1,
        .validationProofInvalid)
    }
  }

  // MARK: - Force 3: unsigned result rejected

  func testUnsignedResultRejected() throws {
    let inv = invocation(
      templateID: "fs.list_dir",
      params: ["path": "/tmp/mutual-control/ok"])
    let (validation, limits, digest) = try validate(
      invocation: inv, descriptor: listDirDescriptor())
    XCTAssertTrue(validation.accepted, validation.detail ?? "")

    let dispatch = try TatwoMutualControlDispatchV1.make(
      invocation: inv,
      validation: validation,
      resourceLimits: limits,
      descriptorDigest: digest,
      leaseDomainBinding: .none(justification: "target is outside any lease domain"),
      originAuthorityProvider: TatwoNoLeaseDomainAuthority(),
      now: producedAt)

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let binding = TatwoMutualControlResultBindingV1(
      jobID: dispatch.remoteLoopJob.jobID,
      dispatchNonce: dispatch.remoteLoopJob.dispatchNonce,
      invokeCanonicalDigest: dispatch.payload.invokeCanonicalDigest,
      exitCode: 0,
      actualArgv: dispatch.payload.resolvedArgv,
      executableResolved: dispatch.payload.resolvedExecutable,
      startedAt: iso.string(from: producedAt),
      endedAt: iso.string(from: producedAt.addingTimeInterval(1)))

    let targetTrust = try makeTrust(deviceID: "target-b")
    let originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "source-a",
      privateKeyStore: S2TransportMemoryPrivateKeyStore(),
      pinnedAt: producedAt,
      additionalPins: [targetTrust.localIdentity],
      environment: testEnvironment)

    XCTAssertThrowsError(
      try TatwoMutualControlResultRecoveryV1.acceptCompleted(
        dispatch: dispatch,
        binding: binding,
        targetSignature: nil,
        verifierTrust: originTrust)
    ) { error in
      XCTAssertEqual(
        error as? TatwoMutualControlDispatchErrorV1,
        .unsignedResultRejected)
    }
    _ = targetTrust
  }

  // MARK: - Force 4: origin authority required in lease domain

  func testOriginAuthorityBypassRejected() throws {
    let inv = invocation(
      templateID: "fs.list_dir",
      params: ["path": "/tmp/mutual-control/ok"],
      sourceDeviceID: "not-origin",
      leaseDomainBinding: .domain(id: "domain-lease-1"))
    let (validation, limits, _) = try validate(
      invocation: inv, descriptor: listDirDescriptor())
    XCTAssertTrue(validation.accepted, validation.detail ?? "")

    let fenced = S2FencedOriginAuthority(
      domainID: "domain-lease-1",
      epoch: 7,
      originDeviceID: "source-a")

    XCTAssertFalse(
      fenced.isOriginAuthority(deviceID: "not-origin", epoch: 7, now: producedAt))

    XCTAssertThrowsError(
      try TatwoMutualControlDispatchV1.make(
        invocation: inv,
        validation: validation,
        resourceLimits: limits,
        descriptorDigest: validation.descriptorDigest,
        leaseDomainBinding: .domain(id: "domain-lease-1"),
        originAuthorityProvider: fenced,
        now: producedAt)
    ) { error in
      XCTAssertEqual(
        error as? TatwoMutualControlDispatchErrorV1,
        .originAuthorityDenied(deviceID: "not-origin", epoch: 7))
    }
  }

  // MARK: - Happy path

  func testHappyPathDispatchAndSignedReceipt() throws {
    let inv = invocation(
      templateID: "fs.list_dir",
      params: ["path": "/tmp/mutual-control/ok"],
      leaseDomainBinding: .domain(id: "domain-lease-1"))
    let (validation, limits, digest) = try validate(
      invocation: inv, descriptor: listDirDescriptor())
    XCTAssertTrue(validation.accepted, validation.detail ?? "")

    let originProvider = S2FencedOriginAuthority(
      domainID: "domain-lease-1",
      epoch: 7,
      originDeviceID: "source-a")

    let dispatch = try TatwoMutualControlDispatchV1.make(
      invocation: inv,
      validation: validation,
      resourceLimits: limits,
      descriptorDigest: digest,
      leaseDomainBinding: .domain(id: "domain-lease-1"),
      originAuthorityProvider: originProvider,
      now: producedAt)

    // Fleet job type reuse (RemoteLoopJob = TatwoLoopJobV1).
    let fleetJob: RemoteLoopJob = dispatch.remoteLoopJob
    XCTAssertEqual(fleetJob.schema, "TatwoLoopJobV1")
    XCTAssertEqual(fleetJob.originDeviceID, "source-a")
    XCTAssertEqual(fleetJob.targetDeviceID, "target-b")
    XCTAssertEqual(dispatch.payload.templateID, "fs.list_dir")
    XCTAssertEqual(dispatch.payload.resolvedArgv, ["-la", "/tmp/mutual-control/ok"])
    XCTAssertNil(dispatch.payload.humanGateToken)
    XCTAssertFalse(dispatch.payload.requiresHumanGate)

    // Payload round-trips through fleet taskDescription.
    if case let .tatwoLoop(loop) = fleetJob.payload {
      let decoded = try TatwoMutualControlJobPayloadV1.decodeTaskDescription(
        loop.taskDescription)
      XCTAssertEqual(decoded, dispatch.payload)
    } else {
      XCTFail("expected tatwoLoop payload")
    }

    let targetTrust = try makeTrust(deviceID: "target-b")
    let originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "source-a",
      privateKeyStore: S2TransportMemoryPrivateKeyStore(),
      pinnedAt: producedAt,
      additionalPins: [targetTrust.localIdentity],
      environment: testEnvironment)

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let binding = TatwoMutualControlResultBindingV1(
      jobID: fleetJob.jobID,
      dispatchNonce: fleetJob.dispatchNonce,
      invokeCanonicalDigest: dispatch.payload.invokeCanonicalDigest,
      exitCode: 0,
      actualArgv: dispatch.payload.resolvedArgv,
      executableResolved: dispatch.payload.resolvedExecutable,
      startedAt: iso.string(from: producedAt),
      endedAt: iso.string(from: producedAt.addingTimeInterval(2)),
      stdoutArtifactPath: "mutual-control/outputs/\(fleetJob.jobID).stdout",
      stdoutArtifactHash: "sha256:1111111111111111111111111111111111111111111111111111111111111111")

    let signature = try TatwoMutualControlResultRecoveryV1.signResultBinding(
      binding: binding,
      targetTrust: targetTrust,
      signedAt: producedAt)

    let receipt = try TatwoMutualControlResultRecoveryV1.acceptCompleted(
      dispatch: dispatch,
      binding: binding,
      targetSignature: signature,
      verifierTrust: originTrust,
      receiptID: "receipt-s2-1",
      outputSummary: "ok")

    XCTAssertEqual(receipt.status, TatwoMutualControlReceiptStatusV1.completed)
    XCTAssertEqual(receipt.jobID, fleetJob.jobID)
    XCTAssertEqual(receipt.dispatchNonce, fleetJob.dispatchNonce)
    XCTAssertEqual(receipt.invokeCanonicalDigest, dispatch.payload.invokeCanonicalDigest)
    XCTAssertEqual(receipt.actualArgv, ["-la", "/tmp/mutual-control/ok"])
    XCTAssertEqual(receipt.exitCode, 0)
    XCTAssertNotNil(receipt.targetSignature)
    XCTAssertEqual(receipt.stdoutArtifact?.relativePath, binding.stdoutArtifactPath)
    XCTAssertEqual(receipt.templateID, "fs.list_dir")
  }

  func testHighRiskHappyPathWithHumanGateToken() throws {
    let inv = invocation(
      templateID: "fs.trash_path",
      params: ["path": "/Users/example/inbox/old"],
      approvalID: "human-gate-token-42")
    let (validation, limits, digest) = try validate(
      invocation: inv, descriptor: deleteDescriptor())
    XCTAssertTrue(validation.accepted, validation.detail ?? "")
    XCTAssertTrue(validation.requiresHumanGate)

    let dispatch = try TatwoMutualControlDispatchV1.make(
      invocation: inv,
      validation: validation,
      resourceLimits: limits,
      descriptorDigest: digest,
      leaseDomainBinding: .none(justification: "target is outside any lease domain"),
      originAuthorityProvider: TatwoNoLeaseDomainAuthority(),
      now: producedAt)
    XCTAssertEqual(dispatch.payload.humanGateToken, "human-gate-token-42")
    XCTAssertTrue(dispatch.payload.requiresHumanGate)
    XCTAssertEqual(dispatch.payload.riskLevel, TatwoMutualControlRiskLevelV1.highRisk)
  }

  func testLeaseBindingCannotBeImplicitOrMismatched() throws {
    let inv = invocation(
      templateID: "fs.list_dir",
      params: ["path": "/tmp/mutual-control/ok"],
      leaseDomainBinding: .domain(id: "domain-lease-1"))
    let (validation, limits, digest) = try validate(
      invocation: inv, descriptor: listDirDescriptor())
    XCTAssertTrue(validation.accepted)

    XCTAssertThrowsError(
      try TatwoMutualControlDispatchV1.make(
        invocation: inv,
        validation: validation,
        resourceLimits: limits,
        descriptorDigest: digest,
        leaseDomainBinding: .none(justification: ""),
        originAuthorityProvider: TatwoNoLeaseDomainAuthority(),
        now: producedAt)
    ) { error in
      guard case .leaseDomainBindingInvalid = error as? TatwoMutualControlDispatchErrorV1
      else {
        return XCTFail("expected explicit no-lease justification rejection, got \(error)")
      }
    }

    let wrongProvider = S2FencedOriginAuthority(
      domainID: "other-domain",
      epoch: 7,
      originDeviceID: "source-a")
    XCTAssertThrowsError(
      try TatwoMutualControlDispatchV1.make(
        invocation: inv,
        validation: validation,
        resourceLimits: limits,
        descriptorDigest: digest,
        leaseDomainBinding: .domain(id: "domain-lease-1"),
        originAuthorityProvider: wrongProvider,
        now: producedAt)
    ) { error in
      guard case .leaseDomainBindingInvalid = error as? TatwoMutualControlDispatchErrorV1
      else {
        return XCTFail("expected provider/binding mismatch rejection, got \(error)")
      }
    }
  }

  func testDescriptorDigestIsRequiredAndBoundToValidation() throws {
    let inv = invocation(
      templateID: "fs.list_dir",
      params: ["path": "/tmp/mutual-control/ok"],
      leaseDomainBinding: .none(justification: "explicit no lease"))
    let (validation, limits, digest) = try validate(
      invocation: inv, descriptor: listDirDescriptor())
    XCTAssertThrowsError(
      try TatwoMutualControlDispatchV1.make(
        invocation: inv,
        validation: validation,
        resourceLimits: limits,
        descriptorDigest: nil,
        leaseDomainBinding: .none(justification: "explicit no lease"),
        originAuthorityProvider: TatwoNoLeaseDomainAuthority(),
        now: producedAt)
    ) { error in
      XCTAssertEqual(
        error as? TatwoMutualControlDispatchErrorV1,
        .descriptorDigestRequired)
    }
    XCTAssertThrowsError(
      try TatwoMutualControlDispatchV1.make(
        invocation: inv,
        validation: validation,
        resourceLimits: limits,
        descriptorDigest: "sha256:wrong",
        leaseDomainBinding: .none(justification: "explicit no lease"),
        originAuthorityProvider: TatwoNoLeaseDomainAuthority(),
        now: producedAt)
    ) { error in
      XCTAssertEqual(
        error as? TatwoMutualControlDispatchErrorV1,
        .descriptorDigestRequired)
    }
    XCTAssertNotNil(digest)
  }
}

// MARK: - Test doubles

private struct S2FencedOriginAuthority: TatwoOriginAuthorityProviding {
  let domainID: String
  let epoch: UInt64
  let originDeviceID: String

  var authorityDomainID: String? { domainID }
  var authorityEpoch: UInt64? { epoch }

  func isOriginAuthority(deviceID: String, epoch: UInt64, now: Date) -> Bool {
    _ = now
    return deviceID == originDeviceID && epoch == self.epoch
  }
}

private final class S2TransportMemoryPrivateKeyStore: TatwoDevicePrivateKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String: Data] = [:]

  func loadPrivateKey(deviceID: String, generation: UInt64) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return keys["\(deviceID)#\(generation)"]
  }

  func storePrivateKey(_ key: Data, deviceID: String, generation: UInt64) throws {
    lock.lock()
    defer { lock.unlock() }
    keys["\(deviceID)#\(generation)"] = key
  }
}
