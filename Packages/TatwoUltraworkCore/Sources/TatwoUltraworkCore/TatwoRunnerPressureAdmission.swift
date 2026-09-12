import Foundation

private enum TatwoRunnerPressureAdmissionText {
  static func safeIdentifier(_ value: String, fallback: String) -> String {
    isSafeIdentifier(value) ? value : fallback
  }

  static func safeSHA256Digest(_ value: String, fallback: String) -> String {
    isSHA256Digest(value) ? value : fallback
  }

  static func isSHA256Digest(_ value: String) -> Bool {
    let allowedHex = Set("0123456789abcdef")
    return value.hasPrefix("sha256:")
      && value.count == 71
      && value.dropFirst("sha256:".count).allSatisfy { allowedHex.contains($0) }
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && !value.contains("\0")
      && value.count <= 128
      && value.range(of: #"^[A-Za-z0-9._:\-]+$"#, options: .regularExpression) != nil
  }
}

public enum TatwoRunnerPressureAdmissionErrorV1: Error, LocalizedError, Sendable, Equatable {
  case permitMissing(jobID: String)
  case invalidPermit(String)
  case signatureRejected(String)
  case bindingMismatch(String)
  case decisionRejected(String)
  case issuerRuntimeNotCurrent(String)
  case permitReplay(jobID: String, permitID: String)
  case consumptionMissing(jobID: String)
  case consumptionConflict(jobID: String, detail: String)
  case ledgerCorrupt(jobID: String, detail: String)
  case continuationResumeAlreadyClaimed(jobID: String, permitID: String)

  public var reasonCode: String {
    switch self {
    case .permitMissing:
      return "pressure_permit_missing"
    case .invalidPermit:
      return "pressure_permit_invalid"
    case .signatureRejected:
      return "pressure_permit_signature_rejected"
    case .bindingMismatch:
      return "pressure_permit_binding_mismatch"
    case .decisionRejected:
      return "pressure_permit_decision_rejected"
    case .issuerRuntimeNotCurrent:
      return "pressure_issuer_runtime_not_current"
    case .permitReplay:
      return "pressure_permit_replay"
    case .consumptionMissing:
      return "pressure_permit_consumption_missing"
    case .consumptionConflict:
      return "pressure_permit_consumption_conflict"
    case .ledgerCorrupt:
      return "pressure_permit_ledger_corrupt"
    case .continuationResumeAlreadyClaimed:
      return "pressure_resume_already_claimed"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .permitMissing(let jobID):
      return "pressure admission permit missing for \(jobID)"
    case .invalidPermit(let detail):
      return "pressure admission permit invalid: \(detail)"
    case .signatureRejected(let detail):
      return "pressure admission permit signature rejected: \(detail)"
    case .bindingMismatch(let detail):
      return "pressure admission permit binding mismatch: \(detail)"
    case .decisionRejected(let detail):
      return "pressure admission permit decision rejected: \(detail)"
    case .issuerRuntimeNotCurrent(let detail):
      return "pressure admission issuer runtime not current: \(detail)"
    case let .permitReplay(jobID, permitID):
      return "pressure admission permit replay for \(jobID): \(permitID)"
    case .consumptionMissing(let jobID):
      return "pressure admission consumption marker missing for \(jobID)"
    case let .consumptionConflict(jobID, detail):
      return "pressure admission consumption conflict for \(jobID): \(detail)"
    case let .ledgerCorrupt(jobID, detail):
      return "pressure admission consumption ledger corrupt for \(jobID): \(detail)"
    case let .continuationResumeAlreadyClaimed(jobID, permitID):
      return "pressure admission continuation resume already claimed for \(jobID): \(permitID)"
    }
  }
}

public struct TatwoAppPressureIssuerIdentityV1: Codable, Sendable, Equatable {
  public let schema: String
  public let issuerKind: String
  public let issuerID: String
  public let issuerDeviceID: String
  public let runtimeInstanceID: String
  public let runtimeGeneration: UInt64
  public let appLaunchID: String
  public let processID: Int32
  public let processStartToken: String
  public let executableSHA256: String
  public let buildVersion: String
  public let buildNumber: String
  public let identityDigest: String

  public init(
    schema: String = "TatwoAppPressureIssuerIdentityV1",
    issuerKind: String = "tatwo-app-pressure-runtime",
    issuerID: String,
    issuerDeviceID: String,
    runtimeInstanceID: String,
    runtimeGeneration: UInt64,
    appLaunchID: String,
    processID: Int32,
    processStartToken: String,
    executableSHA256: String,
    buildVersion: String,
    buildNumber: String,
    identityDigest: String? = nil
  ) throws {
    self.schema = schema
    self.issuerKind = issuerKind
    self.issuerID = issuerID
    self.issuerDeviceID = TatwoRunnerPressureAdmissionText.safeIdentifier(
      issuerDeviceID,
      fallback: "invalid-issuer-device-id")
    self.runtimeInstanceID = runtimeInstanceID
    self.runtimeGeneration = runtimeGeneration
    self.appLaunchID = appLaunchID
    self.processID = processID
    self.processStartToken = processStartToken
    self.executableSHA256 = executableSHA256
    self.buildVersion = buildVersion
    self.buildNumber = buildNumber
    if let identityDigest {
      self.identityDigest = identityDigest
    } else {
      self.identityDigest = try Self.computeDigest(
        schema: schema,
        issuerKind: issuerKind,
        issuerID: issuerID,
        issuerDeviceID: self.issuerDeviceID,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        appLaunchID: appLaunchID,
        processID: processID,
        processStartToken: processStartToken,
        executableSHA256: executableSHA256,
        buildVersion: buildVersion,
        buildNumber: buildNumber)
    }
  }

  public func validates(
    runtimeInstanceID expectedRuntimeInstanceID: String,
    runtimeGeneration expectedRuntimeGeneration: UInt64
  ) -> Bool {
    schema == "TatwoAppPressureIssuerIdentityV1"
      && issuerKind == "tatwo-app-pressure-runtime"
      && issuerID == "tatwo-app"
      && !issuerDeviceID.hasPrefix("invalid-")
      && runtimeInstanceID == expectedRuntimeInstanceID
      && runtimeGeneration == expectedRuntimeGeneration
      && processID > 0
      && ![appLaunchID, processStartToken, executableSHA256, buildVersion, buildNumber].contains {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      && executableSHA256.count == 64
      && executableSHA256.allSatisfy { $0.isHexDigit }
      && (try? Self.computeDigest(
        schema: schema,
        issuerKind: issuerKind,
        issuerID: issuerID,
        issuerDeviceID: issuerDeviceID,
        runtimeInstanceID: runtimeInstanceID,
        runtimeGeneration: runtimeGeneration,
        appLaunchID: appLaunchID,
        processID: processID,
        processStartToken: processStartToken,
        executableSHA256: executableSHA256,
        buildVersion: buildVersion,
        buildNumber: buildNumber)) == identityDigest
  }

  private static func computeDigest(
    schema: String,
    issuerKind: String,
    issuerID: String,
    issuerDeviceID: String,
    runtimeInstanceID: String,
    runtimeGeneration: UInt64,
    appLaunchID: String,
    processID: Int32,
    processStartToken: String,
    executableSHA256: String,
    buildVersion: String,
    buildNumber: String
  ) throws -> String {
    struct Body: Codable {
      let schema: String
      let issuerKind: String
      let issuerID: String
      let issuerDeviceID: String
      let runtimeInstanceID: String
      let runtimeGeneration: UInt64
      let appLaunchID: String
      let processID: Int32
      let processStartToken: String
      let executableSHA256: String
      let buildVersion: String
      let buildNumber: String
    }
    return try TatwoLoopJobDigest.canonicalJSONDigest(Body(
      schema: schema,
      issuerKind: issuerKind,
      issuerID: issuerID,
      issuerDeviceID: issuerDeviceID,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      appLaunchID: appLaunchID,
      processID: processID,
      processStartToken: processStartToken,
      executableSHA256: executableSHA256,
      buildVersion: buildVersion,
      buildNumber: buildNumber))
  }
}

public struct TatwoAppPressureIssuerLivenessV1: Sendable {
  public static let currentEnvKey = "TATWO_APP_PRESSURE_ISSUER_CURRENT"
  public static let runtimeInstanceIDEnvKey = "TATWO_APP_PRESSURE_RUNTIME_INSTANCE_ID"
  public static let runtimeGenerationEnvKey = "TATWO_APP_PRESSURE_RUNTIME_GENERATION"
  public static let appLaunchIDEnvKey = "TATWO_APP_PRESSURE_APP_LAUNCH_ID"

  private let isCurrentHandler: @Sendable (TatwoAppPressureIssuerIdentityV1, Date, [String: String]) -> Bool

  public init(
    isCurrent: @escaping @Sendable (TatwoAppPressureIssuerIdentityV1, Date, [String: String]) -> Bool
  ) {
    self.isCurrentHandler = isCurrent
  }

  public func isCurrent(
    issuerIdentity: TatwoAppPressureIssuerIdentityV1,
    now: Date,
    environment: [String: String]
  ) -> Bool {
    isCurrentHandler(issuerIdentity, now, environment)
  }

  public static let permissive = TatwoAppPressureIssuerLivenessV1 { _, _, _ in true }

  public static let production = TatwoAppPressureIssuerLivenessV1 { issuerIdentity, _, environment in
    guard environment[currentEnvKey] == "1" else { return false }
    guard environment[runtimeInstanceIDEnvKey] == issuerIdentity.runtimeInstanceID else { return false }
    guard environment[appLaunchIDEnvKey] == issuerIdentity.appLaunchID else { return false }
    guard let generation = environment[runtimeGenerationEnvKey].flatMap(UInt64.init),
      generation == issuerIdentity.runtimeGeneration
    else { return false }
    return true
  }
}

public struct TatwoAppPressureIssuerProcessIdentityV1: Codable, Sendable, Equatable {
  public let processID: Int32
  public let processStartToken: String
  public let executableSHA256: String
  public let buildVersion: String
  public let buildNumber: String

  public init(
    processID: Int32,
    processStartToken: String,
    executableSHA256: String,
    buildVersion: String,
    buildNumber: String
  ) {
    self.processID = processID
    self.processStartToken = TatwoRunnerPressureAdmissionText.safeIdentifier(
      processStartToken,
      fallback: "invalid-process-start-token")
    let normalizedExecutableSHA256 = executableSHA256
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    self.executableSHA256 =
      normalizedExecutableSHA256.count == 64
      && normalizedExecutableSHA256.allSatisfy { $0.isHexDigit }
      ? normalizedExecutableSHA256
      : String(repeating: "0", count: 64)
    self.buildVersion = TatwoRunnerPressureAdmissionText.safeIdentifier(
      buildVersion,
      fallback: "invalid-build-version")
    self.buildNumber = TatwoRunnerPressureAdmissionText.safeIdentifier(
      buildNumber,
      fallback: "invalid-build-number")
  }
}

public enum TatwoAppPressureIssuerLivenessAssertionModeV1: String, Codable, Sendable, Equatable {
  /// The App exports the exact fields consumed by `remote-runner start`.
  ///
  /// This is intentionally not named "live challenge": it is a runner-start
  /// environment binding for source/runtime handoff, not proof that a GUI App
  /// cannot hang after the environment was copied into a child process.
  case declaredRunnerStartupEnvironment = "declared_runner_startup_environment"
}

public struct TatwoAppRunnerPressurePermitIssueReceiptV1: Codable, Sendable, Equatable {
  public let schema: String
  public let permitID: String
  public let jobID: String
  public let logicalJobID: String
  public let dispatchNonce: String
  public let targetDeviceID: String
  public let issuerIdentityDigest: String
  public let runtimeInstanceID: String
  public let runtimeGeneration: UInt64
  public let permitPath: String
  public let permitPathSHA256: String
  public let runnerEnvironment: [String: String]
  public let livenessAssertionMode: TatwoAppPressureIssuerLivenessAssertionModeV1
  public let issuedAt: Date

  public init(
    schema: String = "TatwoAppRunnerPressurePermitIssueReceiptV1",
    permitID: String,
    jobID: String,
    logicalJobID: String,
    dispatchNonce: String,
    targetDeviceID: String,
    issuerIdentityDigest: String,
    runtimeInstanceID: String,
    runtimeGeneration: UInt64,
    permitPath: String,
    runnerEnvironment: [String: String],
    livenessAssertionMode: TatwoAppPressureIssuerLivenessAssertionModeV1 =
      .declaredRunnerStartupEnvironment,
    issuedAt: Date
  ) {
    self.schema = schema
    self.permitID = TatwoRunnerPressureAdmissionText.safeSHA256Digest(
      permitID,
      fallback: "invalid-permit-id")
    self.jobID = TatwoRunnerPressureAdmissionText.safeIdentifier(jobID, fallback: "invalid-job-id")
    self.logicalJobID = TatwoRunnerPressureAdmissionText.safeIdentifier(
      logicalJobID,
      fallback: "invalid-logical-job-id")
    self.dispatchNonce = TatwoRunnerPressureAdmissionText.safeIdentifier(
      dispatchNonce,
      fallback: "invalid-dispatch-nonce")
    self.targetDeviceID = TatwoRunnerPressureAdmissionText.safeIdentifier(
      targetDeviceID,
      fallback: "invalid-target-device-id")
    self.issuerIdentityDigest = TatwoRunnerPressureAdmissionText.safeSHA256Digest(
      issuerIdentityDigest,
      fallback: "invalid-issuer-identity-digest")
    self.runtimeInstanceID = TatwoRunnerPressureAdmissionText.safeIdentifier(
      runtimeInstanceID,
      fallback: "invalid-runtime-instance-id")
    self.runtimeGeneration = runtimeGeneration
    self.permitPath = String(TatwoPrivacyRedactor.redacted(permitPath).prefix(2_048))
    self.permitPathSHA256 = TatwoLoopJobDigest.sha256(Data(permitPath.utf8))
    self.runnerEnvironment = runnerEnvironment
    self.livenessAssertionMode = livenessAssertionMode
    self.issuedAt = issuedAt
  }
}

public enum TatwoRunnerPressureAdmissionLayoutV1 {
  public static func baseURL(stateRoot: URL, deviceID: String) -> URL {
    stateRoot.standardizedFileURL
      .appendingPathComponent("pressure-admission", isDirectory: true)
      .appendingPathComponent(TatwoLoopPathComponent.sanitize(deviceID), isDirectory: true)
  }

  public static func permitsDirectoryURL(stateRoot: URL, deviceID: String) -> URL {
    baseURL(stateRoot: stateRoot, deviceID: deviceID)
      .appendingPathComponent("permits", isDirectory: true)
  }

  public static func consumedDirectoryURL(stateRoot: URL, deviceID: String) -> URL {
    baseURL(stateRoot: stateRoot, deviceID: deviceID)
      .appendingPathComponent("consumed", isDirectory: true)
  }

  public static func runnerEnvironment(
    for issuerIdentity: TatwoAppPressureIssuerIdentityV1,
    base: [String: String] = ProcessInfo.processInfo.environment,
    current: Bool = true
  ) -> [String: String] {
    var environment = base
    environment[TatwoRunnerPressureAdmissionControllerV1.expectedIssuerIdentityDigestEnvKey] =
      issuerIdentity.identityDigest
    environment[TatwoAppPressureIssuerLivenessV1.currentEnvKey] = current ? "1" : "0"
    environment[TatwoAppPressureIssuerLivenessV1.runtimeInstanceIDEnvKey] =
      issuerIdentity.runtimeInstanceID
    environment[TatwoAppPressureIssuerLivenessV1.runtimeGenerationEnvKey] =
      "\(issuerIdentity.runtimeGeneration)"
    environment[TatwoAppPressureIssuerLivenessV1.appLaunchIDEnvKey] =
      issuerIdentity.appLaunchID
    return environment
  }
}

public struct TatwoRunnerPressureAdmissionPermitBodyV1: Codable, Sendable, Equatable {
  public let schema: String
  public let pressurePolicyVersion: String
  public let permitScope: String
  public let issuedAt: Date
  /// App-monotonic authority revision.  This is the source snapshot sequence
  /// used to issue the permit; readers must sort by this field, never wall time.
  public let permitRevision: UInt64
  public let issuer: String
  public let issuerIdentity: TatwoAppPressureIssuerIdentityV1
  public let targetDeviceID: String
  public let jobID: String
  public let logicalJobID: String
  public let dispatchNonce: String
  public let contractID: String
  public let goalID: String
  public let jobCanonicalDigest: String
  public let requestBinding: TatwoLoopAdmissionRequestBindingV1
  public let lease: TatwoPressureLeaseV1
  public let admissionDecision: TatwoLoopAdmissionDecisionV1

  public init(
    schema: String = "TatwoRunnerPressureAdmissionPermitBodyV1",
    pressurePolicyVersion: String = TatwoPressurePolicyVersionV1.current,
    permitScope: String = "target_runner_spawn",
    issuedAt: Date,
    permitRevision: UInt64? = nil,
    issuer: String = "tatwo-app",
    issuerIdentity: TatwoAppPressureIssuerIdentityV1,
    targetDeviceID: String,
    jobID: String,
    logicalJobID: String,
    dispatchNonce: String,
    contractID: String,
    goalID: String,
    jobCanonicalDigest: String,
    requestBinding: TatwoLoopAdmissionRequestBindingV1,
    lease: TatwoPressureLeaseV1,
    admissionDecision: TatwoLoopAdmissionDecisionV1
  ) {
    self.schema = schema
    self.pressurePolicyVersion = pressurePolicyVersion
    self.permitScope = permitScope
    self.issuedAt = issuedAt
    self.permitRevision = permitRevision ?? admissionDecision.sourceSnapshotSequence ?? 0
    self.issuer = issuer
    self.issuerIdentity = issuerIdentity
    self.targetDeviceID = targetDeviceID
    self.jobID = jobID
    self.logicalJobID = logicalJobID
    self.dispatchNonce = dispatchNonce
    self.contractID = contractID
    self.goalID = goalID
    self.jobCanonicalDigest = jobCanonicalDigest
    self.requestBinding = requestBinding
    self.lease = lease
    self.admissionDecision = admissionDecision
  }
}

public struct TatwoRunnerPressureAdmissionPermitV1: Codable, Sendable, Equatable {
  public let schema: String
  public let permitID: String
  public let body: TatwoRunnerPressureAdmissionPermitBodyV1
  public let issuerSignature: TatwoDeviceSignatureV1

  public init(
    schema: String = "TatwoRunnerPressureAdmissionPermitV1",
    permitID: String,
    body: TatwoRunnerPressureAdmissionPermitBodyV1,
    issuerSignature: TatwoDeviceSignatureV1
  ) {
    self.schema = schema
    self.permitID = permitID
    self.body = body
    self.issuerSignature = issuerSignature
  }

  public static func issue(
    job: TatwoLoopJobV1,
    request: TatwoLoopAdmissionRequestV1,
    snapshot: TatwoDevicePressureSnapshotV1,
    runtimeInstanceID: String,
    runtimeGeneration: UInt64,
    reservationID: String,
    issuerIdentity: TatwoAppPressureIssuerIdentityV1,
    trust: TatwoLoopJobChannelTrust,
    signedAt: Date = Date()
  ) throws -> TatwoRunnerPressureAdmissionPermitV1 {
    guard issuerIdentity.validates(
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration)
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit("issuer identity")
    }
    guard trust.localIdentity.deviceID == issuerIdentity.issuerDeviceID else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit("issuer signing trust")
    }
    guard issuerIdentity.issuerDeviceID != job.targetDeviceID else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit(
        "issuer signing key must be distinct from target runner device")
    }
    let requestBinding = try TatwoLoopAdmissionRequestBindingV1.make(for: request)
    let lease = try TatwoPressureLeaseV1.issue(
      for: snapshot,
      now: signedAt,
      ttlSeconds: TatwoPressureLeaseV1.defaultTTLSeconds,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: request.attemptID,
      admissionRequestBindingDigest: requestBinding.requestBindingDigest,
      dispatchNonce: request.dispatchNonce,
      reservationID: reservationID)
    let decision = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      lease: lease,
      now: signedAt,
      workers: snapshot.workers,
      requestBindingDigest: requestBinding.requestBindingDigest,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      admissionAttemptID: request.attemptID,
      dispatchNonce: request.dispatchNonce,
      reservationID: reservationID)
    guard decision.accepted, decision.authorizesSpawn else {
      throw TatwoRunnerPressureAdmissionErrorV1.decisionRejected(decision.reasonCode)
    }
    let body = TatwoRunnerPressureAdmissionPermitBodyV1(
      issuedAt: signedAt,
      permitRevision: decision.sourceSnapshotSequence,
      issuerIdentity: issuerIdentity,
      targetDeviceID: job.targetDeviceID,
      jobID: job.jobID,
      logicalJobID: job.logicalJobID,
      dispatchNonce: job.dispatchNonce,
      contractID: job.contractID,
      goalID: job.goalID,
      jobCanonicalDigest: try job.canonicalDigest(),
      requestBinding: requestBinding,
      lease: lease,
      admissionDecision: decision)
    let bodyData = try canonicalJSONData(body)
    let permitID = TatwoLoopJobDigest.sha256(bodyData)
    let signature = try trust.sign(
      payload: bodyData,
      purpose: .appPressurePermit,
      signedAt: signedAt)
    return TatwoRunnerPressureAdmissionPermitV1(
      permitID: permitID,
      body: body,
      issuerSignature: signature)
  }

  public func validate(
    for job: TatwoLoopJobV1,
    trust: TatwoLoopJobChannelTrust,
    now: Date = Date(),
    maxAgeSec: TimeInterval = TatwoPressureLeaseV1.defaultRunnerMaxAgeSeconds,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    guard schema == "TatwoRunnerPressureAdmissionPermitV1" else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit("schema")
    }
    guard body.schema == "TatwoRunnerPressureAdmissionPermitBodyV1",
      body.pressurePolicyVersion == TatwoPressurePolicyVersionV1.current,
      body.permitScope == "target_runner_spawn",
      body.issuer == "tatwo-app"
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit("body")
    }
    guard body.permitRevision > 0,
      body.permitRevision == body.lease.sourceSnapshotSequence,
      body.permitRevision == body.admissionDecision.sourceSnapshotSequence
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit("permit revision")
    }
    guard body.issuedAt.timeIntervalSince(now) <= 1 else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit("permit issued in future")
    }
    guard body.issuerIdentity.validates(
      runtimeInstanceID: body.lease.runtimeInstanceID ?? "missing-runtime-instance-id",
      runtimeGeneration: body.lease.runtimeGeneration ?? 0),
      body.issuerIdentity.runtimeInstanceID == body.admissionDecision.runtimeInstanceID,
      body.issuerIdentity.runtimeGeneration == body.admissionDecision.runtimeGeneration
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit("issuer identity")
    }
    let bodyData = try Self.canonicalJSONData(body)
    guard permitID == TatwoLoopJobDigest.sha256(bodyData) else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit("permit digest mismatch")
    }
    do {
      try trust.verify(
        payload: bodyData,
        purpose: .appPressurePermit,
        signature: issuerSignature,
        expectedDeviceID: body.issuerIdentity.issuerDeviceID,
        enforceFreshness: true,
        now: now,
        maxAgeSec: maxAgeSec,
        environment: environment)
    } catch {
      throw TatwoRunnerPressureAdmissionErrorV1.signatureRejected(error.localizedDescription)
    }
    guard issuerSignature.deviceID == body.issuerIdentity.issuerDeviceID,
      body.issuerIdentity.issuerDeviceID != job.targetDeviceID,
      body.targetDeviceID == job.targetDeviceID,
      body.jobID == job.jobID,
      body.logicalJobID == job.logicalJobID,
      body.dispatchNonce == job.dispatchNonce,
      body.contractID == job.contractID,
      body.goalID == job.goalID,
      body.jobCanonicalDigest == (try job.canonicalDigest())
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.bindingMismatch("job fields")
    }
    guard body.requestBinding.verifiesRequest() else {
      throw TatwoRunnerPressureAdmissionErrorV1.bindingMismatch("request binding")
    }
    let request = body.requestBinding.request
    guard request.hasExactAttemptBinding,
      request.jobID == job.jobID,
      request.dispatchNonce == job.dispatchNonce,
      request.deviceID == job.targetDeviceID,
      request.loopID == job.logicalJobID,
      request.contractID == job.contractID,
      request.workload == Self.defaultWorkload(for: job)
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.bindingMismatch("admission request")
    }
    guard body.lease.verifiesDigest(),
      body.lease.deviceID == job.targetDeviceID,
      body.lease.dispatchNonce == job.dispatchNonce,
      body.lease.admissionRequestBindingDigest == body.requestBinding.requestBindingDigest,
      body.lease.reservationID == body.admissionDecision.reservationID,
      body.lease.admissionAttemptID == request.attemptID,
      body.lease.runtimeInstanceID == body.issuerIdentity.runtimeInstanceID,
      body.lease.runtimeGeneration == body.issuerIdentity.runtimeGeneration,
      body.lease.leaseDigest != nil,
      body.lease.freshness(now: now, maxAgeSeconds: maxAgeSec) == .fresh
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit("lease")
    }
    guard body.admissionDecision.accepted,
      body.admissionDecision.authorizesSpawn,
      body.admissionDecision.deviceID == job.targetDeviceID,
      body.admissionDecision.loopID == job.logicalJobID,
      body.admissionDecision.dispatchNonce == job.dispatchNonce,
      body.admissionDecision.requestBindingDigest == body.requestBinding.requestBindingDigest,
      body.admissionDecision.leaseID == body.lease.leaseID,
      body.admissionDecision.leaseDigest == body.lease.leaseDigest,
      body.admissionDecision.admissionAttemptID == request.attemptID,
      body.admissionDecision.admissionAttemptID != nil,
      body.admissionDecision.runtimeInstanceID != nil,
      body.admissionDecision.runtimeGeneration != nil,
      body.admissionDecision.reservationID != nil,
      body.admissionDecision.sourceSnapshotSequence != nil,
      body.admissionDecision.sourceSampleAttemptID != nil
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.decisionRejected("decision scope")
    }
    let recomputed = TatwoLoopAdmissionDecisionV1.decide(
      deviceID: request.deviceID,
      loopID: request.loopID,
      workload: request.workload,
      lease: body.lease,
      now: body.admissionDecision.decidedAt,
      requestBindingDigest: body.requestBinding.requestBindingDigest,
      runtimeInstanceID: body.admissionDecision.runtimeInstanceID,
      runtimeGeneration: body.admissionDecision.runtimeGeneration,
      admissionAttemptID: request.attemptID,
      dispatchNonce: request.dispatchNonce,
      reservationID: body.admissionDecision.reservationID)
    guard recomputed.accepted,
      recomputed.authorizesSpawn,
      recomputed.reasonCode == body.admissionDecision.reasonCode,
      recomputed.leaseID == body.admissionDecision.leaseID,
      recomputed.leaseDigest == body.admissionDecision.leaseDigest
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.decisionRejected(
        body.admissionDecision.reasonCode)
    }
  }

  public static func defaultWorkload(for job: TatwoLoopJobV1) -> TatwoPressureWorkerClassV1 {
    switch job.payload {
    case .tatwoLoop:
      return .heavy
    case .shellSafe:
      return .light
    }
  }

  public static func canonicalJSONData<T: Encodable>(_ value: T) throws -> Data {
    try TatwoPressureCanonicalJSONV1.data(value)
  }
}

public struct TatwoRunnerPressureAdmissionConsumptionV1: Codable, Sendable, Equatable {
  public let schema: String
  public let jobID: String
  public let permitID: String
  public let permitBodyDigest: String
  public let targetDeviceID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  public let requestBindingDigest: String
  public let reservationID: String
  public let admissionAttemptID: String
  public let runtimeInstanceID: String
  public let runtimeGeneration: UInt64
  public let leaseID: String
  public let leaseDigest: String
  public let issuerIdentityDigest: String
  public let consumedAt: Date
  public let markerDigest: String?

  public init(
    schema: String = "TatwoRunnerPressureAdmissionConsumptionV1",
    jobID: String,
    permitID: String,
    permitBodyDigest: String,
    targetDeviceID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    requestBindingDigest: String,
    reservationID: String,
    admissionAttemptID: String,
    runtimeInstanceID: String,
    runtimeGeneration: UInt64,
    leaseID: String,
    leaseDigest: String,
    issuerIdentityDigest: String,
    consumedAt: Date,
    markerDigest: String? = nil
  ) {
    self.schema = schema
    self.jobID = jobID
    self.permitID = permitID
    self.permitBodyDigest = permitBodyDigest
    self.targetDeviceID = targetDeviceID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.requestBindingDigest = requestBindingDigest
    self.reservationID = reservationID
    self.admissionAttemptID = admissionAttemptID
    self.runtimeInstanceID = runtimeInstanceID
    self.runtimeGeneration = runtimeGeneration
    self.leaseID = leaseID
    self.leaseDigest = leaseDigest
    self.issuerIdentityDigest = issuerIdentityDigest
    self.consumedAt = consumedAt
    self.markerDigest = markerDigest
  }

  public func canonicalDigest() throws -> String {
    var copy = self
    copy = TatwoRunnerPressureAdmissionConsumptionV1(
      schema: copy.schema,
      jobID: copy.jobID,
      permitID: copy.permitID,
      permitBodyDigest: copy.permitBodyDigest,
      targetDeviceID: copy.targetDeviceID,
      dispatchNonce: copy.dispatchNonce,
      jobCanonicalDigest: copy.jobCanonicalDigest,
      requestBindingDigest: copy.requestBindingDigest,
      reservationID: copy.reservationID,
      admissionAttemptID: copy.admissionAttemptID,
      runtimeInstanceID: copy.runtimeInstanceID,
      runtimeGeneration: copy.runtimeGeneration,
      leaseID: copy.leaseID,
      leaseDigest: copy.leaseDigest,
      issuerIdentityDigest: copy.issuerIdentityDigest,
      consumedAt: copy.consumedAt,
      markerDigest: nil)
    return try TatwoPressureCanonicalJSONV1.digest(copy)
  }

  public func verifiesDigest() -> Bool {
    let isDigest: (String) -> Bool = { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      let raw = trimmed.hasPrefix("sha256:") ? String(trimmed.dropFirst("sha256:".count)) : trimmed
      return raw.count == 64 && raw.allSatisfy { $0.isHexDigit }
    }
    let isBoundID: (String) -> Bool = { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return !trimmed.isEmpty
        && !trimmed.hasPrefix("invalid-")
        && !trimmed.hasPrefix("missing-")
    }
    guard schema == "TatwoRunnerPressureAdmissionConsumptionV1",
      let markerDigest,
      isDigest(markerDigest),
      [jobID, permitID, targetDeviceID, dispatchNonce, reservationID, admissionAttemptID, runtimeInstanceID, leaseID]
        .allSatisfy(isBoundID),
      [permitBodyDigest, jobCanonicalDigest, requestBindingDigest, leaseDigest, issuerIdentityDigest].allSatisfy(isDigest)
    else { return false }
    return (try? canonicalDigest()) == markerDigest
  }
}

public enum TatwoRunnerPressureAdmissionConsumptionResultV1: Sendable, Equatable {
  case consumed(TatwoRunnerPressureAdmissionConsumptionV1)
  case alreadyConsumed(TatwoRunnerPressureAdmissionConsumptionV1)
}

public struct TatwoRunnerPressureContinuationResumeClaimV1: Codable, Sendable, Equatable {
  public let schema: String
  public let jobID: String
  public let logicalJobID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  public let originalConsumptionMarkerDigest: String
  public let originalPermitID: String
  public let continuationPermitID: String
  public let continuationPermitRevision: UInt64
  public let continuationIssuerIdentityDigest: String
  public let claimedAt: Date
  public let claimDigest: String?

  public init(
    schema: String = "TatwoRunnerPressureContinuationResumeClaimV1",
    jobID: String,
    logicalJobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    originalConsumptionMarkerDigest: String,
    originalPermitID: String,
    continuationPermitID: String,
    continuationPermitRevision: UInt64,
    continuationIssuerIdentityDigest: String,
    claimedAt: Date,
    claimDigest: String? = nil
  ) {
    self.schema = schema
    self.jobID = jobID
    self.logicalJobID = logicalJobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.originalConsumptionMarkerDigest = originalConsumptionMarkerDigest
    self.originalPermitID = originalPermitID
    self.continuationPermitID = continuationPermitID
    self.continuationPermitRevision = continuationPermitRevision
    self.continuationIssuerIdentityDigest = continuationIssuerIdentityDigest
    self.claimedAt = claimedAt
    self.claimDigest = claimDigest
  }

  public func canonicalDigest() throws -> String {
    let copy = TatwoRunnerPressureContinuationResumeClaimV1(
      schema: schema,
      jobID: jobID,
      logicalJobID: logicalJobID,
      dispatchNonce: dispatchNonce,
      jobCanonicalDigest: jobCanonicalDigest,
      originalConsumptionMarkerDigest: originalConsumptionMarkerDigest,
      originalPermitID: originalPermitID,
      continuationPermitID: continuationPermitID,
      continuationPermitRevision: continuationPermitRevision,
      continuationIssuerIdentityDigest: continuationIssuerIdentityDigest,
      claimedAt: claimedAt,
      claimDigest: nil)
    return try TatwoPressureCanonicalJSONV1.digest(copy)
  }

  public func verifiesDigest() -> Bool {
    guard schema == "TatwoRunnerPressureContinuationResumeClaimV1",
      let claimDigest,
      claimDigest.hasPrefix("sha256:"),
      claimDigest.count == 71,
      continuationPermitRevision > 0
    else { return false }
    return (try? canonicalDigest()) == claimDigest
  }
}

public struct TatwoRunnerPressureAdmissionConsumptionLedgerV1: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL) {
    self.directoryURL = directoryURL.standardizedFileURL
  }

  public func url(forJobID jobID: String) -> URL {
    directoryURL.appendingPathComponent(
      "\(TatwoLoopPathComponent.sanitize(jobID)).json",
      isDirectory: false)
  }

  public func continuationResumeClaimURL(forJobID jobID: String) -> URL {
    directoryURL
      .appendingPathComponent("continuation-resume-claims", isDirectory: true)
      .appendingPathComponent(
        "\(TatwoLoopPathComponent.sanitize(jobID)).json",
        isDirectory: false)
  }

  public func load(jobID: String) throws -> TatwoRunnerPressureAdmissionConsumptionV1? {
    let url = url(forJobID: jobID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw TatwoRunnerPressureAdmissionErrorV1.ledgerCorrupt(
        jobID: jobID,
        detail: "symlink refused")
    }
    let decoder = TatwoPressureCanonicalJSONV1.decoder()
    let marker = try decoder.decode(
      TatwoRunnerPressureAdmissionConsumptionV1.self,
      from: Data(contentsOf: url))
    guard marker.verifiesDigest() else {
      throw TatwoRunnerPressureAdmissionErrorV1.ledgerCorrupt(
        jobID: jobID,
        detail: "marker digest")
    }
    return marker
  }

  public func consume(
    permit: TatwoRunnerPressureAdmissionPermitV1,
    job: TatwoLoopJobV1,
    now: Date = Date()
  ) throws -> TatwoRunnerPressureAdmissionConsumptionResultV1 {
    let bodyDigest = TatwoLoopJobDigest.sha256(
      try TatwoRunnerPressureAdmissionPermitV1.canonicalJSONData(permit.body))
    var marker = TatwoRunnerPressureAdmissionConsumptionV1(
      jobID: job.jobID,
      permitID: permit.permitID,
      permitBodyDigest: bodyDigest,
      targetDeviceID: job.targetDeviceID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      requestBindingDigest: permit.body.requestBinding.requestBindingDigest,
      reservationID: permit.body.lease.reservationID ?? "missing-reservation-id",
      admissionAttemptID: permit.body.lease.admissionAttemptID ?? "missing-admission-attempt-id",
      runtimeInstanceID: permit.body.lease.runtimeInstanceID ?? "missing-runtime-instance-id",
      runtimeGeneration: permit.body.lease.runtimeGeneration ?? 0,
      leaseID: permit.body.lease.leaseID,
      leaseDigest: permit.body.lease.leaseDigest ?? "missing-lease-digest",
      issuerIdentityDigest: permit.body.issuerIdentity.identityDigest,
      consumedAt: now)
    marker = TatwoRunnerPressureAdmissionConsumptionV1(
      jobID: marker.jobID,
      permitID: marker.permitID,
      permitBodyDigest: marker.permitBodyDigest,
      targetDeviceID: marker.targetDeviceID,
      dispatchNonce: marker.dispatchNonce,
      jobCanonicalDigest: marker.jobCanonicalDigest,
      requestBindingDigest: marker.requestBindingDigest,
      reservationID: marker.reservationID,
      admissionAttemptID: marker.admissionAttemptID,
      runtimeInstanceID: marker.runtimeInstanceID,
      runtimeGeneration: marker.runtimeGeneration,
      leaseID: marker.leaseID,
      leaseDigest: marker.leaseDigest,
      issuerIdentityDigest: marker.issuerIdentityDigest,
      consumedAt: marker.consumedAt,
      markerDigest: try marker.canonicalDigest())
    guard marker.verifiesDigest() else {
      throw TatwoRunnerPressureAdmissionErrorV1.ledgerCorrupt(
        jobID: job.jobID,
        detail: "marker digest before publish")
    }
    let url = url(forJobID: job.jobID)
    let data = try TatwoPressureCanonicalJSONV1.data(marker)
    var duplicate: TatwoRunnerPressureAdmissionConsumptionV1?
    try TatwoCreateOnlyFile.write(data, to: url, onDuplicate: {
      guard let existing = try load(jobID: job.jobID),
        existing.permitID == marker.permitID,
        existing.permitBodyDigest == marker.permitBodyDigest,
        existing.dispatchNonce == marker.dispatchNonce,
        existing.jobCanonicalDigest == marker.jobCanonicalDigest,
        existing.requestBindingDigest == marker.requestBindingDigest,
        existing.reservationID == marker.reservationID,
        existing.admissionAttemptID == marker.admissionAttemptID,
        existing.runtimeInstanceID == marker.runtimeInstanceID,
        existing.runtimeGeneration == marker.runtimeGeneration,
        existing.leaseID == marker.leaseID,
        existing.leaseDigest == marker.leaseDigest,
        existing.issuerIdentityDigest == marker.issuerIdentityDigest
      else {
        throw TatwoRunnerPressureAdmissionErrorV1.consumptionConflict(
          jobID: job.jobID,
          detail: "existing marker mismatch")
      }
      duplicate = existing
    })
    if let duplicate {
      return .alreadyConsumed(duplicate)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return .consumed(marker)
  }

  public func loadContinuationResumeClaim(
    jobID: String
  ) throws -> TatwoRunnerPressureContinuationResumeClaimV1? {
    let url = continuationResumeClaimURL(forJobID: jobID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw TatwoRunnerPressureAdmissionErrorV1.ledgerCorrupt(
        jobID: jobID,
        detail: "resume claim symlink refused")
    }
    let claim = try TatwoPressureCanonicalJSONV1.decoder().decode(
      TatwoRunnerPressureContinuationResumeClaimV1.self,
      from: Data(contentsOf: url))
    guard claim.verifiesDigest() else {
      throw TatwoRunnerPressureAdmissionErrorV1.ledgerCorrupt(
        jobID: jobID,
        detail: "resume claim digest")
    }
    return claim
  }

  @discardableResult
  public func claimContinuationResume(
    permit: TatwoRunnerPressureAdmissionPermitV1,
    job: TatwoLoopJobV1,
    consumption: TatwoRunnerPressureAdmissionConsumptionV1,
    now: Date = Date()
  ) throws -> TatwoRunnerPressureContinuationResumeClaimV1 {
    guard let markerDigest = consumption.markerDigest,
      consumption.verifiesDigest()
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.ledgerCorrupt(
        jobID: job.jobID,
        detail: "resume claim requires consumed marker digest")
    }
    var claim = TatwoRunnerPressureContinuationResumeClaimV1(
      jobID: job.jobID,
      logicalJobID: job.logicalJobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      originalConsumptionMarkerDigest: markerDigest,
      originalPermitID: consumption.permitID,
      continuationPermitID: permit.permitID,
      continuationPermitRevision: permit.body.permitRevision,
      continuationIssuerIdentityDigest: permit.body.issuerIdentity.identityDigest,
      claimedAt: now)
    claim = TatwoRunnerPressureContinuationResumeClaimV1(
      jobID: claim.jobID,
      logicalJobID: claim.logicalJobID,
      dispatchNonce: claim.dispatchNonce,
      jobCanonicalDigest: claim.jobCanonicalDigest,
      originalConsumptionMarkerDigest: claim.originalConsumptionMarkerDigest,
      originalPermitID: claim.originalPermitID,
      continuationPermitID: claim.continuationPermitID,
      continuationPermitRevision: claim.continuationPermitRevision,
      continuationIssuerIdentityDigest: claim.continuationIssuerIdentityDigest,
      claimedAt: claim.claimedAt,
      claimDigest: try claim.canonicalDigest())
    guard claim.verifiesDigest() else {
      throw TatwoRunnerPressureAdmissionErrorV1.ledgerCorrupt(
        jobID: job.jobID,
        detail: "resume claim digest before publish")
    }
    let url = continuationResumeClaimURL(forJobID: job.jobID)
    let data = try TatwoPressureCanonicalJSONV1.data(claim)
    var duplicate: TatwoRunnerPressureContinuationResumeClaimV1?
    try TatwoCreateOnlyFile.write(data, to: url, onDuplicate: {
      if let existing = try loadContinuationResumeClaim(jobID: job.jobID),
        existing.jobID == claim.jobID,
        existing.dispatchNonce == claim.dispatchNonce,
        existing.jobCanonicalDigest == claim.jobCanonicalDigest,
        existing.originalConsumptionMarkerDigest == claim.originalConsumptionMarkerDigest,
        existing.originalPermitID == claim.originalPermitID,
        existing.continuationPermitID == claim.continuationPermitID,
        existing.continuationPermitRevision == claim.continuationPermitRevision,
        existing.continuationIssuerIdentityDigest == claim.continuationIssuerIdentityDigest
      {
        duplicate = existing
      } else {
        throw TatwoRunnerPressureAdmissionErrorV1.continuationResumeAlreadyClaimed(
          jobID: job.jobID,
          permitID: permit.permitID)
      }
    })
    if let duplicate {
      throw TatwoRunnerPressureAdmissionErrorV1.continuationResumeAlreadyClaimed(
        jobID: job.jobID,
        permitID: duplicate.continuationPermitID)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return claim
  }
}

public struct TatwoRunnerPressurePermitProviderV1: Sendable {
  private let loadHandler: @Sendable (TatwoLoopJobV1) throws -> TatwoRunnerPressureAdmissionPermitV1?

  public init(
    load: @escaping @Sendable (TatwoLoopJobV1) throws -> TatwoRunnerPressureAdmissionPermitV1?
  ) {
    self.loadHandler = load
  }

  public func permit(
    for job: TatwoLoopJobV1
  ) throws -> TatwoRunnerPressureAdmissionPermitV1? {
    try loadHandler(job)
  }
}

public struct TatwoRunnerPressurePermitFileProviderV1: Sendable {
  public let directoryURL: URL
  private let afterPreflightReadHook: (@Sendable (URL) throws -> Void)?

  public init(directoryURL: URL) {
    self.init(
      directoryURL: directoryURL,
      afterPreflightReadHook: nil)
  }

  init(
    directoryURL: URL,
    afterPreflightReadHook: (@Sendable (URL) throws -> Void)?
  ) {
    self.directoryURL = directoryURL.standardizedFileURL
    self.afterPreflightReadHook = afterPreflightReadHook
  }

  public func url(forJobID jobID: String) -> URL {
    directoryURL.appendingPathComponent(
      "\(TatwoLoopPathComponent.sanitize(jobID)).json",
      isDirectory: false)
  }

  public func revisionDirectoryURL(forJobID jobID: String) -> URL {
    directoryURL.appendingPathComponent(
      "\(TatwoLoopPathComponent.sanitize(jobID)).permit-revisions",
      isDirectory: true)
  }

  public func revisionURL(
    for permit: TatwoRunnerPressureAdmissionPermitV1
  ) -> URL {
    Self.revisionURL(
      directoryURL: directoryURL,
      jobID: permit.body.jobID,
      permitID: permit.permitID)
  }

  public var provider: TatwoRunnerPressurePermitProviderV1 {
    TatwoRunnerPressurePermitProviderV1 { job in
      try newestPermit(for: job)
    }
  }

  private func newestPermit(
    for job: TatwoLoopJobV1
  ) throws -> TatwoRunnerPressureAdmissionPermitV1? {
    var candidates: [TatwoRunnerPressureAdmissionPermitV1] = []
    let decoder = TatwoPressureCanonicalJSONV1.decoder()
    for url in try permitCandidateURLs(forJobID: job.jobID) {
      let permit = try decoder.decode(
        TatwoRunnerPressureAdmissionPermitV1.self,
        from: Self.loadStablePermitData(
          from: url,
          afterPreflightReadHook: afterPreflightReadHook))
      guard permit.body.jobID == job.jobID,
        permit.body.logicalJobID == job.logicalJobID,
        permit.body.dispatchNonce == job.dispatchNonce,
        permit.body.targetDeviceID == job.targetDeviceID,
        permit.body.jobCanonicalDigest == (try job.canonicalDigest())
      else {
        throw TatwoRunnerPressureAdmissionErrorV1.bindingMismatch(
          "permit file job binding")
      }
      candidates.append(permit)
    }
    var revisionsBySequence: [UInt64: TatwoRunnerPressureAdmissionPermitV1] = [:]
    for permit in candidates {
      if let existing = revisionsBySequence[permit.body.permitRevision],
        existing.permitID != permit.permitID
      {
        throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit(
          "permit revision conflict")
      }
      revisionsBySequence[permit.body.permitRevision] = permit
    }
    return candidates.max { lhs, rhs in
      if lhs.body.permitRevision != rhs.body.permitRevision {
        return lhs.body.permitRevision < rhs.body.permitRevision
      }
      return lhs.permitID < rhs.permitID
    }
  }

  private func permitCandidateURLs(forJobID jobID: String) throws -> [URL] {
    var urls: [URL] = []
    let revisions = revisionDirectoryURL(forJobID: jobID)
    var hasRevisionJSON = false
    if FileManager.default.fileExists(atPath: revisions.path) {
      let values = try revisions.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true,
        values.isDirectory == true
      else {
        throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit(
          "permit revision directory invalid")
      }
      let revisionFiles = try FileManager.default.contentsOfDirectory(
        at: revisions,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles])
      for file in revisionFiles where file.pathExtension == "json" {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true,
          values.isRegularFile == true
        else {
          throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit(
            "permit revision file invalid")
        }
        urls.append(file)
        hasRevisionJSON = true
      }
    }
    let legacy = url(forJobID: jobID)
    if FileManager.default.fileExists(atPath: legacy.path) {
      guard !hasRevisionJSON else {
        throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit(
          "legacy permit coexists with revisions")
      }
      urls.append(legacy)
    }
    return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  fileprivate static func revisionURL(
    directoryURL: URL,
    jobID: String,
    permitID: String
  ) -> URL {
    directoryURL.standardizedFileURL
      .appendingPathComponent(
        "\(TatwoLoopPathComponent.sanitize(jobID)).permit-revisions",
        isDirectory: true)
      .appendingPathComponent(
        "\(permitFileStem(permitID)).json",
        isDirectory: false)
  }

  fileprivate static func permitFileStem(_ permitID: String) -> String {
    let trimmed = permitID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.hasPrefix("sha256:") {
      let raw = String(trimmed.dropFirst("sha256:".count))
      if raw.count == 64,
        raw.allSatisfy({ $0.isHexDigit })
      {
        return "sha256-\(raw)"
      }
    }
    return TatwoLoopPathComponent.sanitize(permitID)
  }

  fileprivate static func loadStablePermitData(
    from url: URL,
    afterPreflightReadHook: (@Sendable (URL) throws -> Void)? = nil
  ) throws -> Data {
    let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .fileResourceIdentifierKey, .fileSizeKey]
    let before = try url.resourceValues(forKeys: keys)
    guard before.isSymbolicLink != true else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit("permit symlink refused")
    }
    try afterPreflightReadHook?(url)
    let data = try Data(contentsOf: url)
    let after = try url.resourceValues(forKeys: keys)
    guard after.isSymbolicLink != true else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit("permit symlink refused after read")
    }
    let beforeIdentifier = before.fileResourceIdentifier.map { String(describing: $0) }
    let afterIdentifier = after.fileResourceIdentifier.map { String(describing: $0) }
    guard beforeIdentifier == afterIdentifier,
      before.fileSize == after.fileSize,
      after.fileSize == data.count
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.invalidPermit("permit file changed during read")
    }
    return data
  }
}

public struct TatwoRunnerPressurePermitFileWriterV1: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL) {
    self.directoryURL = directoryURL.standardizedFileURL
  }

  public func url(forJobID jobID: String) -> URL {
    directoryURL.appendingPathComponent(
      "\(TatwoLoopPathComponent.sanitize(jobID)).json",
      isDirectory: false)
  }

  public func revisionDirectoryURL(forJobID jobID: String) -> URL {
    directoryURL.appendingPathComponent(
      "\(TatwoLoopPathComponent.sanitize(jobID)).permit-revisions",
      isDirectory: true)
  }

  public func revisionURL(
    for permit: TatwoRunnerPressureAdmissionPermitV1
  ) -> URL {
    TatwoRunnerPressurePermitFileProviderV1.revisionURL(
      directoryURL: directoryURL,
      jobID: permit.body.jobID,
      permitID: permit.permitID)
  }

  public func write(permit: TatwoRunnerPressureAdmissionPermitV1) throws -> URL {
    try write(permit: permit, publishFence: nil)
  }

  func write(
    permit: TatwoRunnerPressureAdmissionPermitV1,
    publishFence: ((_ publish: () throws -> TatwoCreateOnlyFile.PublishResult) throws -> TatwoCreateOnlyFile.PublishResult)?
  ) throws -> URL {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let data = try TatwoPressureCanonicalJSONV1.data(permit)
    let revisions = revisionDirectoryURL(forJobID: permit.body.jobID)
    try FileManager.default.createDirectory(
      at: revisions,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let revisionURL = revisionURL(for: permit)
    try TatwoCreateOnlyFile.write(
      data,
      to: revisionURL,
      onDuplicate: {
        let existing = try TatwoRunnerPressurePermitFileProviderV1.loadStablePermitData(
          from: revisionURL)
        guard existing == data else {
          throw TatwoRunnerPressureAdmissionErrorV1.consumptionConflict(
            jobID: permit.body.jobID,
            detail: "existing permit revision mismatch")
        }
      },
      publishFence: publishFence,
      faultBox: nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: revisionURL.path)
    return revisionURL
  }
}

public struct TatwoAppRunnerPressurePermitIssuerV1: Sendable {
  public let stateRoot: URL
  public let targetDeviceID: String
  public let trust: TatwoLoopJobChannelTrust
  public let issuerProcessIdentity: TatwoAppPressureIssuerProcessIdentityV1
  public let clock: TatwoPressureClockV1
  private let reservationIDProvider: @Sendable (TatwoLoopJobV1, TatwoLoopAdmissionRequestV1) throws -> String

  public init(
    stateRoot: URL,
    targetDeviceID: String,
    trust: TatwoLoopJobChannelTrust,
    issuerProcessIdentity: TatwoAppPressureIssuerProcessIdentityV1,
    clock: TatwoPressureClockV1 = TatwoPressureClockV1(),
    reservationIDProvider: @escaping @Sendable (TatwoLoopJobV1, TatwoLoopAdmissionRequestV1) throws -> String =
      Self.defaultReservationID
  ) {
    self.stateRoot = stateRoot.standardizedFileURL
    self.targetDeviceID = TatwoRunnerPressureAdmissionText.safeIdentifier(
      targetDeviceID,
      fallback: "invalid-target-device-id")
    self.trust = trust
    self.issuerProcessIdentity = issuerProcessIdentity
    self.clock = clock
    self.reservationIDProvider = reservationIDProvider
  }

  public func permitsDirectoryURL() -> URL {
    TatwoRunnerPressureAdmissionLayoutV1.permitsDirectoryURL(
      stateRoot: stateRoot,
      deviceID: targetDeviceID)
  }

  public func makeAdmissionRequest(
    for job: TatwoLoopJobV1,
    requestedAt: Date? = nil
  ) -> TatwoLoopAdmissionRequestV1 {
    TatwoLoopAdmissionRequestV1(
      jobID: job.jobID,
      attemptID: "attempt-\(job.jobID)",
      dispatchNonce: job.dispatchNonce,
      deviceID: job.targetDeviceID,
      loopID: job.logicalJobID,
      workload: TatwoRunnerPressureAdmissionPermitV1.defaultWorkload(for: job),
      contractID: job.contractID,
      goalHash: TatwoLoopJobDigest.sha256(Data(job.goalID.utf8)),
      planHash: TatwoLoopJobDigest.sha256(Data("plan-\(job.contractID)".utf8)),
      requestedAt: requestedAt ?? clock.now())
  }

  public func runnerEnvironment(
    for issuerIdentity: TatwoAppPressureIssuerIdentityV1,
    base: [String: String] = ProcessInfo.processInfo.environment,
    current: Bool = true
  ) -> [String: String] {
    TatwoRunnerPressureAdmissionLayoutV1.runnerEnvironment(
      for: issuerIdentity,
      base: base,
      current: current)
  }

  public func issuePermit(
    job: TatwoLoopJobV1,
    request: TatwoLoopAdmissionRequestV1,
    snapshot: TatwoDevicePressureSnapshotV1,
    runtime: TatwoAppPressureRuntimeV1,
    baseRunnerEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> TatwoAppRunnerPressurePermitIssueReceiptV1 {
    try await issuePermitWithPublishFence(
      job: job,
      request: request,
      snapshot: snapshot,
      runtime: runtime,
      baseRunnerEnvironment: baseRunnerEnvironment,
      beforePublish: {})
  }

  public func issuePermitWithPublishFence(
    job: TatwoLoopJobV1,
    request: TatwoLoopAdmissionRequestV1,
    snapshot: TatwoDevicePressureSnapshotV1,
    runtime: TatwoAppPressureRuntimeV1,
    baseRunnerEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> TatwoAppRunnerPressurePermitIssueReceiptV1 {
    try await issuePermitWithPublishFence(
      job: job,
      request: request,
      snapshot: snapshot,
      runtime: runtime,
      baseRunnerEnvironment: baseRunnerEnvironment,
      beforePublish: {})
  }

  func issuePermitWithPublishFence(
    job: TatwoLoopJobV1,
    request: TatwoLoopAdmissionRequestV1,
    snapshot: TatwoDevicePressureSnapshotV1,
    runtime: TatwoAppPressureRuntimeV1,
    baseRunnerEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    beforePublish: @Sendable () async throws -> Void
  ) async throws -> TatwoAppRunnerPressurePermitIssueReceiptV1 {
    let runtimeInstanceID = runtime.runtimeInstanceID
    let runtimeGeneration = await runtime.currentGeneration
    let issuedAt = clock.now()
    let issuerIdentity = try TatwoAppPressureIssuerIdentityV1(
      issuerID: "tatwo-app",
      issuerDeviceID: trust.localIdentity.deviceID,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      appLaunchID: appLaunchID(runtimeInstanceID: runtimeInstanceID),
      processID: issuerProcessIdentity.processID,
      processStartToken: issuerProcessIdentity.processStartToken,
      executableSHA256: issuerProcessIdentity.executableSHA256,
      buildVersion: issuerProcessIdentity.buildVersion,
      buildNumber: issuerProcessIdentity.buildNumber)
    let permit = try TatwoRunnerPressureAdmissionPermitV1.issue(
      job: job,
      request: request,
      snapshot: snapshot,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      reservationID: try reservationIDProvider(job, request),
      issuerIdentity: issuerIdentity,
      trust: trust,
      signedAt: issuedAt)
    try await beforePublish()
    let permitURL = try TatwoRunnerPressurePermitFileWriterV1(
      directoryURL: permitsDirectoryURL())
      .write(permit: permit, publishFence: { publish in
        let gated = runtime.validateSynchronousSpawnAuthorityResult(
          runtimeInstanceID: runtimeInstanceID,
          generation: runtimeGeneration
        ) {
          Result<TatwoCreateOnlyFile.PublishResult, Error> {
            try publish()
          }
        }
        switch gated {
        case .failure(let failure):
          throw TatwoRunnerPressureAdmissionErrorV1.issuerRuntimeNotCurrent(failure.rawValue)
        case .success(let result):
          return try result.get()
        }
      })
    return TatwoAppRunnerPressurePermitIssueReceiptV1(
      permitID: permit.permitID,
      jobID: job.jobID,
      logicalJobID: job.logicalJobID,
      dispatchNonce: job.dispatchNonce,
      targetDeviceID: job.targetDeviceID,
      issuerIdentityDigest: issuerIdentity.identityDigest,
      runtimeInstanceID: runtimeInstanceID,
      runtimeGeneration: runtimeGeneration,
      permitPath: permitURL.standardizedFileURL.path,
      runnerEnvironment: runnerEnvironment(
        for: issuerIdentity,
        base: baseRunnerEnvironment),
      issuedAt: issuedAt)
  }

  private func appLaunchID(runtimeInstanceID: String) -> String {
    TatwoLoopJobDigest.sha256(Data([
      "TatwoAppRunnerPressurePermitIssuerV1",
      "runtimeInstanceID=\(runtimeInstanceID)",
      "processID=\(issuerProcessIdentity.processID)",
      "processStartToken=\(issuerProcessIdentity.processStartToken)",
      "executableSHA256=\(issuerProcessIdentity.executableSHA256)",
      "buildVersion=\(issuerProcessIdentity.buildVersion)",
      "buildNumber=\(issuerProcessIdentity.buildNumber)"
    ].joined(separator: "\u{1f}").utf8))
  }

  public static func defaultReservationID(
    job: TatwoLoopJobV1,
    request: TatwoLoopAdmissionRequestV1
  ) throws -> String {
    TatwoLoopJobDigest.sha256(Data([
      "TatwoAppRunnerPressurePermitIssuerV1.reservation",
      "job=\(try job.canonicalDigest())",
      "request=\(try request.bindingDigest())"
    ].joined(separator: "\u{1f}").utf8))
  }
}

public struct TatwoRunnerPressureAdmissionOutcomeV1: Sendable, Equatable {
  public let authorized: Bool
  public let reasonCode: String
  public let permitID: String?
  public let consumption: TatwoRunnerPressureAdmissionConsumptionV1?

  public init(
    authorized: Bool,
    reasonCode: String,
    permitID: String? = nil,
    consumption: TatwoRunnerPressureAdmissionConsumptionV1? = nil
  ) {
    self.authorized = authorized
    self.reasonCode = reasonCode
    self.permitID = permitID
    self.consumption = consumption
  }
}

public struct TatwoRunnerPressureAdmissionControllerV1: Sendable {
  public let provider: TatwoRunnerPressurePermitProviderV1
  public let ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1
  public let trust: TatwoLoopJobChannelTrust
  public let clock: TatwoPressureClockV1
  public let maxAgeSec: TimeInterval
  public let environment: [String: String]
  public let expectedIssuerIdentityDigest: String?
  public let requiresIssuerIdentityBinding: Bool
  public let issuerLiveness: TatwoAppPressureIssuerLivenessV1

  public static let expectedIssuerIdentityDigestEnvKey =
    "TATWO_APP_PRESSURE_ISSUER_IDENTITY_DIGEST"

  public init(
    provider: TatwoRunnerPressurePermitProviderV1,
    ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1,
    trust: TatwoLoopJobChannelTrust,
    clock: TatwoPressureClockV1 = TatwoPressureClockV1(),
    maxAgeSec: TimeInterval = TatwoPressureLeaseV1.defaultRunnerMaxAgeSeconds,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    expectedIssuerIdentityDigest: String? = nil,
    requiresIssuerIdentityBinding: Bool = false,
    issuerLiveness: TatwoAppPressureIssuerLivenessV1? = nil
  ) {
    self.provider = provider
    self.ledger = ledger
    self.trust = trust
    self.clock = clock
    self.maxAgeSec = min(max(0, maxAgeSec), TatwoPressureLeaseV1.defaultRunnerMaxAgeSeconds)
    self.environment = environment
    self.expectedIssuerIdentityDigest = Self.normalizedDigest(expectedIssuerIdentityDigest)
    self.requiresIssuerIdentityBinding = requiresIssuerIdentityBinding
    self.issuerLiveness = issuerLiveness ?? (requiresIssuerIdentityBinding ? .production : .permissive)
  }

  private static func normalizedDigest(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let raw = trimmed.hasPrefix("sha256:") ? String(trimmed.dropFirst("sha256:".count)) : trimmed
    guard raw.count == 64,
      raw.allSatisfy({ $0.isHexDigit })
    else { return nil }
    return "sha256:\(raw.lowercased())"
  }

  public static func production(
    channel: TatwoLoopJobChannel,
    trust: TatwoLoopJobChannelTrust,
    deviceID: String,
    stateRoot: URL?,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoRunnerPressureAdmissionControllerV1 {
    let root = (stateRoot ?? channel.rootURL).standardizedFileURL
    let permits = TatwoRunnerPressureAdmissionLayoutV1.permitsDirectoryURL(
      stateRoot: root,
      deviceID: deviceID)
    let consumed = TatwoRunnerPressureAdmissionLayoutV1.consumedDirectoryURL(
      stateRoot: root,
      deviceID: deviceID)
    let expectedIssuerIdentityDigest = environment[Self.expectedIssuerIdentityDigestEnvKey]
    return TatwoRunnerPressureAdmissionControllerV1(
      provider: TatwoRunnerPressurePermitFileProviderV1(directoryURL: permits).provider,
      ledger: TatwoRunnerPressureAdmissionConsumptionLedgerV1(directoryURL: consumed),
      trust: trust,
      environment: environment,
      expectedIssuerIdentityDigest: expectedIssuerIdentityDigest,
      requiresIssuerIdentityBinding: true)
  }

  private func validateIssuerBinding(
    _ permit: TatwoRunnerPressureAdmissionPermitV1
  ) throws {
    if let expectedIssuerIdentityDigest {
      guard Self.normalizedDigest(permit.body.issuerIdentity.identityDigest) == expectedIssuerIdentityDigest else {
        throw TatwoRunnerPressureAdmissionErrorV1.bindingMismatch("issuer identity digest")
      }
    } else if requiresIssuerIdentityBinding {
      throw TatwoRunnerPressureAdmissionErrorV1.bindingMismatch("issuer identity digest missing")
    }
    guard issuerLiveness.isCurrent(
      issuerIdentity: permit.body.issuerIdentity,
      now: clock.now(),
      environment: environment)
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.bindingMismatch("issuer identity not current")
    }
  }

  public func hasConsumablePermit(
    job: TatwoLoopJobV1
  ) -> Bool {
    do {
      guard let permit = try provider.permit(for: job) else { return false }
      try permit.validate(
        for: job,
        trust: trust,
        now: clock.now(),
        maxAgeSec: maxAgeSec,
        environment: environment)
      try validateIssuerBinding(permit)
      return try ledger.load(jobID: job.jobID) == nil
    } catch {
      return false
    }
  }

  public func validatesContinuationAuthority(
    job: TatwoLoopJobV1
  ) -> TatwoRunnerPressureAdmissionOutcomeV1 {
    do {
      guard let permit = try provider.permit(for: job) else {
        throw TatwoRunnerPressureAdmissionErrorV1.permitMissing(jobID: job.jobID)
      }
      try permit.validate(
        for: job,
        trust: trust,
        now: clock.now(),
        maxAgeSec: maxAgeSec,
        environment: environment)
      try validateIssuerBinding(permit)
      let marker = try validatedExistingConsumption(permit: permit, job: job)
      return TatwoRunnerPressureAdmissionOutcomeV1(
        authorized: true,
        reasonCode: "pressure_permit_continuation_authorized",
        permitID: permit.permitID,
        consumption: marker)
    } catch let error as TatwoRunnerPressureAdmissionErrorV1 {
      return TatwoRunnerPressureAdmissionOutcomeV1(
        authorized: false,
        reasonCode: error.reasonCode,
        permitID: nil,
        consumption: nil)
    } catch {
      return TatwoRunnerPressureAdmissionOutcomeV1(
        authorized: false,
        reasonCode: "pressure_permit_invalid",
        permitID: nil,
        consumption: nil)
    }
  }

  /// Fail-closed resume fence probe for idle detection.
  ///
  /// `runUntilIdle` is not allowed to treat a mid-flight job as pending once
  /// any continuation-resume claim has been durably published for that job:
  /// `claimContinuationResume` is intentionally non-idempotent, so the winning
  /// runner may only continue inside the same in-memory pass that published the
  /// create-only fence.  Later runners/passes must treat the attempt as
  /// unresumable.  A corrupt or unreadable claim file is also a fence for
  /// scheduling purposes; it must not be interpreted as healthy/pending work.
  public func hasContinuationResumeClaimFence(
    job: TatwoLoopJobV1
  ) -> Bool {
    do {
      return try ledger.loadContinuationResumeClaim(jobID: job.jobID) != nil
    } catch {
      return true
    }
  }

  public func claimContinuationResumeAuthority(
    job: TatwoLoopJobV1
  ) -> TatwoRunnerPressureAdmissionOutcomeV1 {
    do {
      guard let permit = try provider.permit(for: job) else {
        throw TatwoRunnerPressureAdmissionErrorV1.permitMissing(jobID: job.jobID)
      }
      try permit.validate(
        for: job,
        trust: trust,
        now: clock.now(),
        maxAgeSec: maxAgeSec,
        environment: environment)
      try validateIssuerBinding(permit)
      let marker = try validatedExistingConsumption(permit: permit, job: job)
      _ = try ledger.claimContinuationResume(
        permit: permit,
        job: job,
        consumption: marker,
        now: clock.now())
      return TatwoRunnerPressureAdmissionOutcomeV1(
        authorized: true,
        reasonCode: "pressure_permit_continuation_resume_claimed",
        permitID: permit.permitID,
        consumption: marker)
    } catch let error as TatwoRunnerPressureAdmissionErrorV1 {
      return TatwoRunnerPressureAdmissionOutcomeV1(
        authorized: false,
        reasonCode: error.reasonCode,
        permitID: nil,
        consumption: nil)
    } catch {
      return TatwoRunnerPressureAdmissionOutcomeV1(
        authorized: false,
        reasonCode: "pressure_permit_invalid",
        permitID: nil,
        consumption: nil)
    }
  }

  public func authorize(
    job: TatwoLoopJobV1
  ) -> TatwoRunnerPressureAdmissionOutcomeV1 {
    do {
      guard let permit = try provider.permit(for: job) else {
        throw TatwoRunnerPressureAdmissionErrorV1.permitMissing(jobID: job.jobID)
      }
      try permit.validate(
        for: job,
        trust: trust,
        now: clock.now(),
        maxAgeSec: maxAgeSec,
        environment: environment)
      try validateIssuerBinding(permit)
      let consumption = try ledger.consume(permit: permit, job: job, now: clock.now())
      switch consumption {
      case .consumed(let marker):
        return TatwoRunnerPressureAdmissionOutcomeV1(
          authorized: true,
          reasonCode: "pressure_permit_consumed",
          permitID: permit.permitID,
          consumption: marker)
      case .alreadyConsumed(let marker):
        throw TatwoRunnerPressureAdmissionErrorV1.permitReplay(
          jobID: job.jobID,
          permitID: marker.permitID)
      }
    } catch let error as TatwoRunnerPressureAdmissionErrorV1 {
      return TatwoRunnerPressureAdmissionOutcomeV1(
        authorized: false,
        reasonCode: error.reasonCode,
        permitID: nil,
        consumption: nil)
    } catch {
      return TatwoRunnerPressureAdmissionOutcomeV1(
        authorized: false,
        reasonCode: "pressure_permit_invalid",
        permitID: nil,
        consumption: nil)
    }
  }

  private func validatedExistingConsumption(
    permit: TatwoRunnerPressureAdmissionPermitV1,
    job: TatwoLoopJobV1
  ) throws -> TatwoRunnerPressureAdmissionConsumptionV1 {
    guard let marker = try ledger.load(jobID: job.jobID) else {
      throw TatwoRunnerPressureAdmissionErrorV1.consumptionMissing(jobID: job.jobID)
    }
    guard marker.jobID == job.jobID,
      marker.targetDeviceID == job.targetDeviceID,
      marker.dispatchNonce == job.dispatchNonce,
      marker.jobCanonicalDigest == (try job.canonicalDigest())
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.consumptionConflict(
        jobID: job.jobID,
        detail: "existing marker does not match continuation job")
    }
    guard marker.admissionAttemptID == permit.body.requestBinding.request.attemptID,
      marker.admissionAttemptID == permit.body.lease.admissionAttemptID
    else {
      throw TatwoRunnerPressureAdmissionErrorV1.consumptionConflict(
        jobID: job.jobID,
        detail: "existing marker does not match continuation attempt")
    }
    return marker
  }
}
