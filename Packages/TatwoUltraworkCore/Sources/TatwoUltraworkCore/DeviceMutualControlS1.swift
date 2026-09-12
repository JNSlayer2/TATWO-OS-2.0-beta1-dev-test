import Foundation

// MARK: - Purpose / constants (D8 §1.3 / §7)

/// Cross-plane purpose for device mutual-control invoke. Never reuse fleet/handoff purposes.
public enum TatwoMutualControlPurposeV1: String, Codable, Sendable, CaseIterable, Equatable {
  case deviceMutualControlInvoke = "device_mutual_control_invoke"
  case deviceCapabilityManifest = "device_capability_manifest"
}

// MARK: - Risk

/// Descriptor-level risk. High-risk templates never receive standing authorization.
public enum TatwoMutualControlRiskLevelV1: String, Codable, Sendable, CaseIterable, Equatable {
  case normal
  case highRisk = "high_risk"
}

/// High-risk categories (D8 §6.1). Every member forces per-invocation human gate.
public enum TatwoMutualControlHighRiskCategoryV1: String, Codable, Sendable, CaseIterable, Equatable {
  case delete = "high.delete"
  case deploy = "high.deploy"
  case login = "high.login"
  case secret = "high.secret"
  case systemPermission = "high.system_permission"
  case money = "high.money"
  case trade = "high.trade"
  case sovereignty = "high.sovereignty"
  case interpreter = "high.interpreter"

  /// Always true — standing authorization is forbidden for all high-risk classes.
  public var requiresHumanGate: Bool { true }

  /// Always true — high-risk may not be pre-approved as standing policy.
  public var forbidsStandingAuthorization: Bool { true }
}

public enum TatwoMutualControlSideEffectClassV1: String, Codable, Sendable, CaseIterable, Equatable {
  case readOnly = "read_only"
  case localMutable = "local_mutable"
  case external
}

// MARK: - Fail-closed error codes (D8 §9)

public enum TatwoMutualControlErrorCodeV1: String, Codable, Sendable, CaseIterable, Equatable {
  case targetOffline = "E_TARGET_OFFLINE"
  case pinUntrusted = "E_PIN_UNTRUSTED"
  case signatureInvalid = "E_SIGNATURE_INVALID"
  case purposeMismatch = "E_PURPOSE_MISMATCH"
  case freshnessExpired = "E_FRESHNESS_EXPIRED"
  case replay = "E_REPLAY"
  case capabilityEmpty = "E_CAPABILITY_EMPTY"
  case capabilityVersionMismatch = "E_CAPABILITY_VERSION_MISMATCH"
  case templateNotFound = "E_TEMPLATE_NOT_FOUND"
  case templateDisabled = "E_TEMPLATE_DISABLED"
  case paramInvalid = "E_PARAM_INVALID"
  case resourceLimit = "E_RESOURCE_LIMIT"
  case highRiskNoApproval = "E_HIGH_RISK_NO_APPROVAL"
  case approvalInvalid = "E_APPROVAL_INVALID"
  case approvalReplay = "E_APPROVAL_REPLAY"
  case approvalExpired = "E_APPROVAL_EXPIRED"
  case spawnFailed = "E_SPAWN_FAILED"
  case outputTruncatedPolicy = "E_OUTPUT_TRUNCATED_POLICY"
  case useHandoffPlane = "E_USE_HANDOFF_PLANE"
  case useFleetPlane = "E_USE_FLEET_PLANE"
  case forbiddenShellShape = "E_FORBIDDEN_SHELL_SHAPE"
  case injectionRejected = "E_INJECTION_REJECTED"
  case schemaInvalid = "E_SCHEMA_INVALID"
}

// MARK: - Parameter whitelist (per slot / position)

/// Allowed pattern for one argv placeholder slot. Values expand as whole argv elements only.
public enum TatwoMutualControlParamConstraintV1: Codable, Sendable, Equatable {
  case enumValues([String])
  case regex(String)
  case pathPrefix([String])

  private enum CodingKeys: String, CodingKey {
    case kind
    case values
    case pattern
    case roots
  }

  private enum Kind: String, Codable {
    case `enum`
    case regex
    case pathPrefix = "path_prefix"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    switch kind {
    case .enum:
      self = .enumValues(try container.decode([String].self, forKey: .values))
    case .regex:
      self = .regex(try container.decode(String.self, forKey: .pattern))
    case .pathPrefix:
      self = .pathPrefix(try container.decode([String].self, forKey: .roots))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .enumValues(let values):
      try container.encode(Kind.enum, forKey: .kind)
      try container.encode(values, forKey: .values)
    case .regex(let pattern):
      try container.encode(Kind.regex, forKey: .kind)
      try container.encode(pattern, forKey: .pattern)
    case .pathPrefix(let roots):
      try container.encode(Kind.pathPrefix, forKey: .kind)
      try container.encode(roots, forKey: .roots)
    }
  }
}

/// One ordered parameter slot bound to a whole-element placeholder `{name}` in argvTemplate.
public struct TatwoMutualControlParamSlotV1: Codable, Sendable, Equatable {
  public let name: String
  public let constraint: TatwoMutualControlParamConstraintV1

  public init(name: String, constraint: TatwoMutualControlParamConstraintV1) {
    self.name = name
    self.constraint = constraint
  }
}

// MARK: - Resource limits

public struct TatwoMutualControlResourceLimitsV1: Codable, Sendable, Equatable {
  public let timeoutSec: TimeInterval
  public let maxOutputBytes: Int
  public let allowedCwdPrefixes: [String]

  public init(
    timeoutSec: TimeInterval,
    maxOutputBytes: Int,
    allowedCwdPrefixes: [String] = []
  ) {
    self.timeoutSec = timeoutSec
    self.maxOutputBytes = maxOutputBytes
    self.allowedCwdPrefixes = allowedCwdPrefixes
  }
}

// MARK: - Capability descriptor (D8 §4.2)

/// Single capability template: argv-only, param whitelist, limits, risk, optional descriptor digest.
/// Placeholders expand as **independent argv elements only** — never into a shell string.
public struct TatwoDeviceCapabilityDescriptorV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoDeviceCapabilityDescriptorV1"

  public let schema: String
  public let templateID: String
  public let displayName: String?
  public let description: String?
  /// Absolute path or allowlisted alias; never a free-form shell interpreter for `-c` scripts.
  public let executable: String
  /// Fixed argv template. Placeholder tokens must occupy an **entire** element (`{name}`).
  public let argvTemplate: [String]
  /// Ordered parameter slots; each `name` must appear as `{name}` in `argvTemplate`.
  public let paramSlots: [TatwoMutualControlParamSlotV1]
  public let resourceLimits: TatwoMutualControlResourceLimitsV1
  public let riskLevel: TatwoMutualControlRiskLevelV1
  /// Required when `riskLevel == .highRisk`.
  public let highRiskCategory: TatwoMutualControlHighRiskCategoryV1?
  public let sideEffectClass: TatwoMutualControlSideEffectClassV1
  public let enabled: Bool
  public let notes: String?
  /// Optional precomputed descriptor content digest (`sha256:…`).
  public let descriptorDigest: String?

  public init(
    schema: String = TatwoDeviceCapabilityDescriptorV1.schemaName,
    templateID: String,
    displayName: String? = nil,
    description: String? = nil,
    executable: String,
    argvTemplate: [String],
    paramSlots: [TatwoMutualControlParamSlotV1] = [],
    resourceLimits: TatwoMutualControlResourceLimitsV1,
    riskLevel: TatwoMutualControlRiskLevelV1 = .normal,
    highRiskCategory: TatwoMutualControlHighRiskCategoryV1? = nil,
    sideEffectClass: TatwoMutualControlSideEffectClassV1 = .readOnly,
    enabled: Bool = true,
    notes: String? = nil,
    descriptorDigest: String? = nil
  ) {
    self.schema = schema
    self.templateID = templateID
    self.displayName = displayName
    self.description = description
    self.executable = executable
    self.argvTemplate = argvTemplate
    self.paramSlots = paramSlots
    self.resourceLimits = resourceLimits
    self.riskLevel = riskLevel
    self.highRiskCategory = highRiskCategory
    self.sideEffectClass = sideEffectClass
    self.enabled = enabled
    self.notes = notes
    self.descriptorDigest = descriptorDigest
  }

  /// True when this template must force a per-invocation human gate (never standing).
  public var requiresHumanGate: Bool {
    if riskLevel == .highRisk { return true }
    if let highRiskCategory { return highRiskCategory.requiresHumanGate }
    return false
  }

  public func unsignedCanonicalPayload() throws -> Data {
    let body = UnsignedDescriptorBody(
      schema: schema,
      templateID: templateID,
      displayName: displayName,
      description: description,
      executable: executable,
      argvTemplate: argvTemplate,
      paramSlots: paramSlots,
      resourceLimits: resourceLimits,
      riskLevel: riskLevel,
      highRiskCategory: highRiskCategory,
      sideEffectClass: sideEffectClass,
      enabled: enabled,
      notes: notes)
    return try TatwoMutualControlCanonicalJSON.encode(body)
  }

  public func computeDescriptorDigest() throws -> String {
    TatwoLoopJobDigest.sha256(try unsignedCanonicalPayload())
  }

  private struct UnsignedDescriptorBody: Encodable {
    let schema: String
    let templateID: String
    let displayName: String?
    let description: String?
    let executable: String
    let argvTemplate: [String]
    let paramSlots: [TatwoMutualControlParamSlotV1]
    let resourceLimits: TatwoMutualControlResourceLimitsV1
    let riskLevel: TatwoMutualControlRiskLevelV1
    let highRiskCategory: TatwoMutualControlHighRiskCategoryV1?
    let sideEffectClass: TatwoMutualControlSideEffectClassV1
    let enabled: Bool
    let notes: String?
  }
}

// MARK: - Capability manifest (D8 §4.3)

/// Device-owned capability list. **Default empty `descriptors` = uncontrollable.**
public struct TatwoDeviceCapabilityManifestV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoDeviceCapabilityManifestV1"

  public let schema: String
  public let targetDeviceID: String
  public let capabilityVersion: UInt64
  public let descriptors: [TatwoDeviceCapabilityDescriptorV1]
  public let producedAt: String
  public let freshUntil: String?
  public let manifestDigest: String
  public let producerSignature: TatwoDeviceSignatureV1?
  public let signingKeyFingerprint: String?
  public let supersedesVersion: UInt64?

  public init(
    schema: String = TatwoDeviceCapabilityManifestV1.schemaName,
    targetDeviceID: String,
    capabilityVersion: UInt64,
    descriptors: [TatwoDeviceCapabilityDescriptorV1] = [],
    producedAt: String,
    freshUntil: String? = nil,
    manifestDigest: String,
    producerSignature: TatwoDeviceSignatureV1? = nil,
    signingKeyFingerprint: String? = nil,
    supersedesVersion: UInt64? = nil
  ) {
    self.schema = schema
    self.targetDeviceID = targetDeviceID
    self.capabilityVersion = capabilityVersion
    self.descriptors = descriptors
    self.producedAt = producedAt
    self.freshUntil = freshUntil
    self.manifestDigest = manifestDigest
    self.producerSignature = producerSignature
    self.signingKeyFingerprint = signingKeyFingerprint
    self.supersedesVersion = supersedesVersion
  }

  /// Empty list semantics: no remote mutual-control invoke may proceed.
  public var isEmpty: Bool { descriptors.isEmpty }

  public func descriptor(templateID: String) -> TatwoDeviceCapabilityDescriptorV1? {
    let normalized = templateID.precomposedStringWithCanonicalMapping
    return descriptors.first {
      $0.templateID.precomposedStringWithCanonicalMapping == normalized
    }
  }

  public func unsignedCanonicalPayload() throws -> Data {
    let structured = UnsignedManifestStructured(
      schema: schema,
      targetDeviceID: targetDeviceID,
      capabilityVersion: capabilityVersion,
      descriptors: try descriptors.map { try UnsignedDescriptorWire(from: $0) },
      producedAt: producedAt,
      freshUntil: freshUntil,
      supersedesVersion: supersedesVersion)
    return try TatwoMutualControlCanonicalJSON.encode(structured)
  }

  public func computeManifestDigest() throws -> String {
    TatwoLoopJobDigest.sha256(try unsignedCanonicalPayload())
  }

  /// Build a signed manifest owned by `targetDeviceID`. Empty `descriptors` is valid (= uncontrollable).
  public static func make(
    targetDeviceID: String,
    capabilityVersion: UInt64,
    descriptors: [TatwoDeviceCapabilityDescriptorV1] = [],
    producedAt: Date = Date(),
    freshUntil: Date? = nil,
    supersedesVersion: UInt64? = nil,
    trust: TatwoLoopJobChannelTrust? = nil
  ) throws -> TatwoDeviceCapabilityManifestV1 {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let producedAtString = iso.string(from: producedAt)
    let freshUntilString = freshUntil.map { iso.string(from: $0) }

    var digestedDescriptors: [TatwoDeviceCapabilityDescriptorV1] = []
    digestedDescriptors.reserveCapacity(descriptors.count)
    for descriptor in descriptors {
      let digest = try descriptor.computeDescriptorDigest()
      digestedDescriptors.append(
        TatwoDeviceCapabilityDescriptorV1(
          schema: descriptor.schema,
          templateID: descriptor.templateID,
          displayName: descriptor.displayName,
          description: descriptor.description,
          executable: descriptor.executable,
          argvTemplate: descriptor.argvTemplate,
          paramSlots: descriptor.paramSlots,
          resourceLimits: descriptor.resourceLimits,
          riskLevel: descriptor.riskLevel,
          highRiskCategory: descriptor.highRiskCategory,
          sideEffectClass: descriptor.sideEffectClass,
          enabled: descriptor.enabled,
          notes: descriptor.notes,
          descriptorDigest: digest))
    }

    let unsigned = TatwoDeviceCapabilityManifestV1(
      targetDeviceID: targetDeviceID,
      capabilityVersion: capabilityVersion,
      descriptors: digestedDescriptors,
      producedAt: producedAtString,
      freshUntil: freshUntilString,
      manifestDigest: "pending",
      producerSignature: nil,
      signingKeyFingerprint: nil,
      supersedesVersion: supersedesVersion)
    let digest = try unsigned.computeManifestDigest()

    var signature: TatwoDeviceSignatureV1?
    var fingerprint: String?
    if let trust {
      guard trust.localIdentity.deviceID == targetDeviceID else {
        throw TatwoMutualControlValidationError.signatureInvalid(
          "manifest targetDeviceID must match signing device")
      }
      // Sign the same unsigned payload that verifiers recompute (digest not in payload).
      signature = try trust.authority.sign(
        payload: try unsigned.unsignedCanonicalPayload(),
        purpose: TatwoMutualControlPurposeV1.deviceCapabilityManifest.rawValue,
        identity: trust.localIdentity,
        signedAt: producedAtString)
      fingerprint = trust.localIdentity.keyID
    }

    return TatwoDeviceCapabilityManifestV1(
      targetDeviceID: targetDeviceID,
      capabilityVersion: capabilityVersion,
      descriptors: digestedDescriptors,
      producedAt: producedAtString,
      freshUntil: freshUntilString,
      manifestDigest: digest,
      producerSignature: signature,
      signingKeyFingerprint: fingerprint,
      supersedesVersion: supersedesVersion)
  }

  private struct UnsignedManifestStructured: Encodable {
    let schema: String
    let targetDeviceID: String
    let capabilityVersion: UInt64
    let descriptors: [UnsignedDescriptorWire]
    let producedAt: String
    let freshUntil: String?
    let supersedesVersion: UInt64?
  }

  private struct UnsignedDescriptorWire: Encodable {
    let schema: String
    let templateID: String
    let displayName: String?
    let description: String?
    let executable: String
    let argvTemplate: [String]
    let paramSlots: [TatwoMutualControlParamSlotV1]
    let resourceLimits: TatwoMutualControlResourceLimitsV1
    let riskLevel: TatwoMutualControlRiskLevelV1
    let highRiskCategory: TatwoMutualControlHighRiskCategoryV1?
    let sideEffectClass: TatwoMutualControlSideEffectClassV1
    let enabled: Bool
    let notes: String?

    init(from descriptor: TatwoDeviceCapabilityDescriptorV1) throws {
      schema = descriptor.schema
      templateID = descriptor.templateID
      displayName = descriptor.displayName
      description = descriptor.description
      executable = descriptor.executable
      argvTemplate = descriptor.argvTemplate
      paramSlots = descriptor.paramSlots
      resourceLimits = descriptor.resourceLimits
      riskLevel = descriptor.riskLevel
      highRiskCategory = descriptor.highRiskCategory
      sideEffectClass = descriptor.sideEffectClass
      enabled = descriptor.enabled
      notes = descriptor.notes
    }
  }
}

// MARK: - Invocation (caller input; S1 does not transport)

/// Attempt-bound invoke request payload used by the pure Core validator.
public struct TatwoMutualControlInvocationV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoMutualControlInvocationV1"

  public let schema: String
  public let purpose: String
  public let logicalControlID: String
  public let jobID: String
  public let dispatchNonce: String
  public let sourceDeviceID: String
  public let operatorPrincipalID: String
  public let targetDeviceID: String
  public let templateID: String
  public let capabilityVersion: UInt64
  /// Parameter name → value. Each value becomes at most one argv element.
  public let params: [String: String]
  public let approvalID: String?
  public let requestedTimeoutSec: TimeInterval?
  public let requestedMaxOutputBytes: Int?
  public let invokeCanonicalDigest: String?
  /// Explicit lease/no-lease authority context; never inferred from nil.
  public let leaseDomainBinding: TatwoLeaseDomainBindingV1

  public init(
    schema: String = TatwoMutualControlInvocationV1.schemaName,
    purpose: String = TatwoMutualControlPurposeV1.deviceMutualControlInvoke.rawValue,
    logicalControlID: String,
    jobID: String,
    dispatchNonce: String,
    sourceDeviceID: String,
    operatorPrincipalID: String,
    targetDeviceID: String,
    templateID: String,
    capabilityVersion: UInt64,
    params: [String: String] = [:],
    approvalID: String? = nil,
    requestedTimeoutSec: TimeInterval? = nil,
    requestedMaxOutputBytes: Int? = nil,
    invokeCanonicalDigest: String? = nil,
    leaseDomainBinding: TatwoLeaseDomainBindingV1
  ) {
    self.schema = schema
    self.purpose = purpose
    self.logicalControlID = logicalControlID
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.sourceDeviceID = sourceDeviceID
    self.operatorPrincipalID = operatorPrincipalID
    self.targetDeviceID = targetDeviceID
    self.templateID = templateID
    self.capabilityVersion = capabilityVersion
    self.params = params
    self.approvalID = approvalID
    self.requestedTimeoutSec = requestedTimeoutSec
    self.requestedMaxOutputBytes = requestedMaxOutputBytes
    self.invokeCanonicalDigest = invokeCanonicalDigest
    self.leaseDomainBinding = leaseDomainBinding
  }

  public func unsignedCanonicalPayload() throws -> Data {
    let body = UnsignedInvocationBody(
      schema: schema,
      purpose: purpose,
      logicalControlID: logicalControlID,
      jobID: jobID,
      dispatchNonce: dispatchNonce,
      sourceDeviceID: sourceDeviceID,
      operatorPrincipalID: operatorPrincipalID,
      targetDeviceID: targetDeviceID,
      templateID: templateID,
      capabilityVersion: capabilityVersion,
      params: params,
      approvalID: approvalID,
      requestedTimeoutSec: requestedTimeoutSec,
      requestedMaxOutputBytes: requestedMaxOutputBytes,
      leaseDomainBinding: leaseDomainBinding)
    return try TatwoMutualControlCanonicalJSON.encode(body)
  }

  public func computeInvokeCanonicalDigest() throws -> String {
    TatwoLoopJobDigest.sha256(try unsignedCanonicalPayload())
  }

  private struct UnsignedInvocationBody: Encodable {
    let schema: String
    let purpose: String
    let logicalControlID: String
    let jobID: String
    let dispatchNonce: String
    let sourceDeviceID: String
    let operatorPrincipalID: String
    let targetDeviceID: String
    let templateID: String
    let capabilityVersion: UInt64
    let params: [String: String]
    let approvalID: String?
    let requestedTimeoutSec: TimeInterval?
    let requestedMaxOutputBytes: Int?
    let leaseDomainBinding: TatwoLeaseDomainBindingV1
  }
}

// MARK: - Validation result

public struct TatwoMutualControlValidationResultV1: Sendable, Equatable {
  private static let validatorMarker = UUID().uuidString

  public let accepted: Bool
  /// Forced `true` for any high-risk template even when listed and otherwise valid.
  public let requiresHumanGate: Bool
  public let resolvedExecutable: String?
  public let resolvedArgv: [String]?
  public let templateID: String?
  public let riskLevel: TatwoMutualControlRiskLevelV1?
  public let highRiskCategory: TatwoMutualControlHighRiskCategoryV1?
  public let errorCode: TatwoMutualControlErrorCodeV1?
  public let detail: String?
  public let invokeCanonicalDigest: String?
  public let capabilityVersion: UInt64?
  /// Bound to the descriptor that the signed-manifest validator actually
  /// checked.  Dispatch must not accept a caller-supplied digest.
  public let descriptorDigest: String?
  private let validationMarker: String

  internal init(
    accepted: Bool,
    requiresHumanGate: Bool,
    resolvedExecutable: String? = nil,
    resolvedArgv: [String]? = nil,
    templateID: String? = nil,
    riskLevel: TatwoMutualControlRiskLevelV1? = nil,
    highRiskCategory: TatwoMutualControlHighRiskCategoryV1? = nil,
    errorCode: TatwoMutualControlErrorCodeV1? = nil,
    detail: String? = nil,
    invokeCanonicalDigest: String? = nil,
    capabilityVersion: UInt64? = nil,
    descriptorDigest: String? = nil,
    validatorIssued: Bool = false
  ) {
    self.accepted = accepted
    self.requiresHumanGate = requiresHumanGate
    self.resolvedExecutable = resolvedExecutable
    self.resolvedArgv = resolvedArgv
    self.templateID = templateID
    self.riskLevel = riskLevel
    self.highRiskCategory = highRiskCategory
    self.errorCode = errorCode
    self.detail = detail
    self.invokeCanonicalDigest = invokeCanonicalDigest
    self.capabilityVersion = capabilityVersion
    self.descriptorDigest = descriptorDigest
    self.validationMarker = validatorIssued ? Self.validatorMarker : ""
  }

  internal var isValidatorIssued: Bool {
    validationMarker == Self.validatorMarker
  }

  public static func reject(
    _ code: TatwoMutualControlErrorCodeV1,
    detail: String,
    requiresHumanGate: Bool = false,
    templateID: String? = nil,
    riskLevel: TatwoMutualControlRiskLevelV1? = nil,
    highRiskCategory: TatwoMutualControlHighRiskCategoryV1? = nil,
    capabilityVersion: UInt64? = nil
  ) -> TatwoMutualControlValidationResultV1 {
    TatwoMutualControlValidationResultV1(
      accepted: false,
      requiresHumanGate: requiresHumanGate,
      templateID: templateID,
      riskLevel: riskLevel,
      highRiskCategory: highRiskCategory,
      errorCode: code,
      detail: detail,
      capabilityVersion: capabilityVersion,
      validatorIssued: false)
  }
}

public enum TatwoMutualControlValidationError: Error, Equatable, LocalizedError {
  case signatureInvalid(String)

  public var errorDescription: String? {
    switch self {
    case .signatureInvalid(let detail):
      "Mutual-control signature invalid: \(detail)"
    }
  }
}

// MARK: - Validator (S1 pure Core; never spawns)

/// Pure capability / invocation validator. **Does not execute processes or open transport.**
public enum TatwoMutualControlValidatorV1 {
  private static let maxArgvElements = 64
  private static let maxArgvElementBytes = 4 * 1024
  private static let maxRegexPatternLength = 512

  /// Validate an invocation against a single matched descriptor (ticket API shape).
  public static func validate(
    invocation: TatwoMutualControlInvocationV1,
    descriptor: TatwoDeviceCapabilityDescriptorV1
  ) -> TatwoMutualControlValidationResultV1 {
    // A raw descriptor has no issuer signature or pinned policy identity.  It
    // is intentionally not an authority path; callers must validate through a
    // signed manifest.
    return .reject(
      .signatureInvalid,
      detail: "unsigned direct descriptor validation is forbidden",
      templateID: descriptor.templateID)
  }

  /// Validate against a full device manifest (empty list fail-closed; version + signature).
  public static func validate(
    invocation: TatwoMutualControlInvocationV1,
    manifest: TatwoDeviceCapabilityManifestV1,
    expectedCapabilityVersion: UInt64? = nil,
    pinnedIdentity: TatwoDevicePublicIdentityV1? = nil,
    requireSignature: Bool = false
  ) -> TatwoMutualControlValidationResultV1 {
    if invocation.purpose != TatwoMutualControlPurposeV1.deviceMutualControlInvoke.rawValue {
      if invocation.purpose.contains("remote_execute") || invocation.purpose.contains("fleet") {
        return .reject(.useFleetPlane, detail: "purpose belongs to fleet plane")
      }
      if invocation.purpose.contains("origin_transfer") || invocation.purpose.contains("handoff") {
        return .reject(.useHandoffPlane, detail: "purpose belongs to handoff plane")
      }
      return .reject(.purposeMismatch, detail: "purpose must be device_mutual_control_invoke")
    }

    if normalizedNFC(invocation.targetDeviceID)
      != normalizedNFC(manifest.targetDeviceID)
    {
      return .reject(
        .paramInvalid,
        detail: "invocation targetDeviceID does not match manifest owner")
    }

    _ = requireSignature // retained for source compatibility; signatures are mandatory.
    if let sigIssue = verifyManifestSignature(
      manifest: manifest,
      pinnedIdentity: pinnedIdentity)
    {
      return sigIssue
    }

    if manifest.isEmpty {
      return .reject(
        .capabilityEmpty,
        detail: "empty capability list = uncontrollable")
    }

    let expectedVersion = expectedCapabilityVersion ?? invocation.capabilityVersion
    if manifest.capabilityVersion != expectedVersion
      || invocation.capabilityVersion != manifest.capabilityVersion
    {
      return .reject(
        .capabilityVersionMismatch,
        detail: "capabilityVersion mismatch",
        capabilityVersion: manifest.capabilityVersion)
    }

    guard let descriptor = manifest.descriptor(templateID: invocation.templateID) else {
      return .reject(
        .templateNotFound,
        detail: "templateID not in capability list",
        templateID: invocation.templateID,
        capabilityVersion: manifest.capabilityVersion)
    }

    if !descriptor.enabled {
      return .reject(
        .templateDisabled,
        detail: "template is disabled",
        templateID: descriptor.templateID,
        riskLevel: descriptor.riskLevel,
        highRiskCategory: descriptor.highRiskCategory,
        capabilityVersion: manifest.capabilityVersion)
    }

    if descriptor.highRiskCategory == .sovereignty {
      // Sovereignty may only open handoff plane — never complete lease transfer here.
      return .reject(
        .useHandoffPlane,
        detail: "sovereignty templates must use handoff plane",
        requiresHumanGate: true,
        templateID: descriptor.templateID,
        riskLevel: descriptor.riskLevel,
        highRiskCategory: descriptor.highRiskCategory,
        capabilityVersion: manifest.capabilityVersion)
    }

    if let shapeError = validateDescriptorShape(descriptor) {
      return shapeError.withCapabilityVersion(manifest.capabilityVersion)
    }
    return validateInvocationAgainstDescriptor(invocation: invocation, descriptor: descriptor)
      .withCapabilityVersion(manifest.capabilityVersion)
  }

  // MARK: Internals

  /// Returns a reject result when the descriptor shape is invalid; otherwise nil.
  private static func validateDescriptorShape(
    _ descriptor: TatwoDeviceCapabilityDescriptorV1
  ) -> TatwoMutualControlValidationResultV1? {
    let normalizedExecutable = normalizedNFC(descriptor.executable)
    if descriptor.schema != TatwoDeviceCapabilityDescriptorV1.schemaName {
      return .reject(
        .schemaInvalid,
        detail: "unsupported descriptor schema",
        templateID: descriptor.templateID)
    }
    if normalizedNFC(descriptor.templateID)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
    {
      return .reject(.schemaInvalid, detail: "templateID is empty")
    }
    if normalizedExecutable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .reject(
        .schemaInvalid,
        detail: "executable is empty",
        templateID: descriptor.templateID)
    }

    if descriptor.argvTemplate.count > maxArgvElements {
      return .reject(
        .resourceLimit,
        detail: "argvTemplate exceeds \(maxArgvElements) elements",
        templateID: descriptor.templateID,
        riskLevel: descriptor.riskLevel,
        highRiskCategory: descriptor.highRiskCategory)
    }
    if !withinArgvElementBounds(normalizedExecutable) {
      return .reject(
        .resourceLimit,
        detail: "executable exceeds the per-element UTF-8 bound",
        templateID: descriptor.templateID,
        riskLevel: descriptor.riskLevel,
        highRiskCategory: descriptor.highRiskCategory)
    }
    for token in descriptor.argvTemplate {
      if !withinArgvElementBounds(normalizedNFC(token)) {
        return .reject(
          .resourceLimit,
          detail: "argvTemplate element exceeds the per-element UTF-8 bound",
          templateID: descriptor.templateID,
          riskLevel: descriptor.riskLevel,
          highRiskCategory: descriptor.highRiskCategory)
      }
    }

    // Placeholders must be whole argv elements only.
    for token in descriptor.argvTemplate {
      if isEmbeddedPlaceholder(token) {
        return .reject(
          .forbiddenShellShape,
          detail: "placeholders must be whole argv elements, not shell-string fragments",
          templateID: descriptor.templateID)
      }
    }

    let placeholderNames = Set(
      descriptor.argvTemplate.compactMap { wholePlaceholderName($0) })
    let slotNames = descriptor.paramSlots.map { normalizedNFC($0.name) }
    if Set(slotNames).count != slotNames.count {
      return .reject(
        .schemaInvalid,
        detail: "duplicate param slot names",
        templateID: descriptor.templateID)
    }
    for name in slotNames where !placeholderNames.contains(name) {
      return .reject(
        .schemaInvalid,
        detail: "param slot \(name) has no whole-element placeholder in argvTemplate",
        templateID: descriptor.templateID)
    }
    for name in placeholderNames where !slotNames.contains(name) {
      return .reject(
        .schemaInvalid,
        detail: "placeholder {\(name)} has no param slot",
        templateID: descriptor.templateID)
    }

    if descriptor.riskLevel == .highRisk && descriptor.highRiskCategory == nil {
      return .reject(
        .schemaInvalid,
        detail: "high_risk descriptors require highRiskCategory",
        templateID: descriptor.templateID,
        riskLevel: .highRisk)
    }
    if let category = descriptor.highRiskCategory, descriptor.riskLevel != .highRisk {
      return .reject(
        .schemaInvalid,
        detail: "highRiskCategory requires riskLevel=high_risk",
        templateID: descriptor.templateID,
        highRiskCategory: category)
    }

    if descriptor.resourceLimits.timeoutSec <= 0
      || descriptor.resourceLimits.maxOutputBytes <= 0
    {
      return .reject(
        .schemaInvalid,
        detail: "resource limits must be positive",
        templateID: descriptor.templateID)
    }

    for slot in descriptor.paramSlots {
      if !withinArgvElementBounds(normalizedNFC(slot.name)) {
        return .reject(
          .resourceLimit,
          detail: "parameter name exceeds the per-element UTF-8 bound",
          templateID: descriptor.templateID)
      }
      switch slot.constraint {
      case let .enumValues(values):
        if values.contains(where: { !withinArgvElementBounds(normalizedNFC($0)) }) {
          return .reject(
            .resourceLimit,
            detail: "enum constraint contains an oversized value",
            templateID: descriptor.templateID)
        }
      case let .regex(pattern):
        let normalizedPattern = normalizedNFC(pattern)
        if !isBoundedRegex(normalizedPattern) {
          return .reject(
            .resourceLimit,
            detail: "regex constraint exceeds the bounded safe subset",
            templateID: descriptor.templateID)
        }
      case let .pathPrefix(roots):
        if roots.contains(where: { !withinArgvElementBounds(normalizedNFC($0)) }) {
          return .reject(
            .resourceLimit,
            detail: "path-prefix constraint contains an oversized root",
            templateID: descriptor.templateID)
        }
      }
    }

    return nil
  }

  private static func validateInvocationAgainstDescriptor(
    invocation: TatwoMutualControlInvocationV1,
    descriptor: TatwoDeviceCapabilityDescriptorV1
  ) -> TatwoMutualControlValidationResultV1 {
    if invocation.purpose != TatwoMutualControlPurposeV1.deviceMutualControlInvoke.rawValue {
      return .reject(.purposeMismatch, detail: "purpose must be device_mutual_control_invoke")
    }
    if normalizedNFC(invocation.templateID) != normalizedNFC(descriptor.templateID) {
      return .reject(
        .templateNotFound,
        detail: "invocation templateID does not match descriptor",
        templateID: invocation.templateID)
    }
    if !descriptor.enabled {
      return .reject(
        .templateDisabled,
        detail: "template is disabled",
        templateID: descriptor.templateID,
        riskLevel: descriptor.riskLevel,
        highRiskCategory: descriptor.highRiskCategory)
    }

    let declaredClassification = classify(
      executable: descriptor.executable,
      argv: descriptor.argvTemplate)
    let declaredRisk = effectiveRisk(
      descriptor: descriptor,
      classification: declaredClassification)
    let humanGate = declaredRisk.level == .highRisk

    // Resource pre-check (requested bounds must not exceed descriptor caps).
    if let requestedTimeout = invocation.requestedTimeoutSec,
      requestedTimeout > descriptor.resourceLimits.timeoutSec
    {
      return .reject(
        .resourceLimit,
        detail: "requested timeout exceeds descriptor limit",
        requiresHumanGate: humanGate,
        templateID: descriptor.templateID,
        riskLevel: declaredRisk.level,
        highRiskCategory: declaredRisk.category)
    }
    if let requestedOut = invocation.requestedMaxOutputBytes,
      requestedOut > descriptor.resourceLimits.maxOutputBytes
    {
      return .reject(
        .resourceLimit,
        detail: "requested maxOutputBytes exceeds descriptor limit",
        requiresHumanGate: humanGate,
        templateID: descriptor.templateID,
        riskLevel: declaredRisk.level,
        highRiskCategory: declaredRisk.category)
    }

    // Unknown params rejected (fail-closed). Normalize keys before comparing
    // so canonically equivalent Unicode spellings cannot bypass the slot map.
    var normalizedParams: [String: String] = [:]
    for (key, value) in invocation.params {
      let normalizedKey = normalizedNFC(key)
      guard normalizedParams[normalizedKey] == nil else {
        return .reject(
          .paramInvalid,
          detail: "duplicate parameter names after NFC normalization",
          requiresHumanGate: humanGate,
          templateID: descriptor.templateID,
          riskLevel: declaredRisk.level,
          highRiskCategory: declaredRisk.category)
      }
      normalizedParams[normalizedKey] = value
    }
    let allowedNames = Set(descriptor.paramSlots.map { normalizedNFC($0.name) })
    for key in normalizedParams.keys where !allowedNames.contains(key) {
        return .reject(
          .paramInvalid,
          detail: "unknown param \(key)",
          requiresHumanGate: humanGate,
          templateID: descriptor.templateID,
          riskLevel: declaredRisk.level,
          highRiskCategory: declaredRisk.category)
    }

    var resolvedValues: [String: String] = [:]
    for slot in descriptor.paramSlots {
      let slotName = normalizedNFC(slot.name)
      guard let raw = normalizedParams[slotName] else {
        return .reject(
          .paramInvalid,
          detail: "missing param \(slotName)",
          requiresHumanGate: humanGate,
          templateID: descriptor.templateID,
          riskLevel: declaredRisk.level,
          highRiskCategory: declaredRisk.category)
      }
      if let inject = rejectInjection(raw, param: slotName) {
        return .reject(
          inject,
          detail: "param \(slotName) failed injection defense",
          requiresHumanGate: humanGate,
          templateID: descriptor.templateID,
          riskLevel: declaredRisk.level,
          highRiskCategory: declaredRisk.category)
      }
      if !matchesConstraint(raw, constraint: slot.constraint) {
        return .reject(
          .paramInvalid,
          detail: "param \(slotName) failed whitelist constraint",
          requiresHumanGate: humanGate,
          templateID: descriptor.templateID,
          riskLevel: declaredRisk.level,
          highRiskCategory: declaredRisk.category)
      }
      let normalized = normalizedNFC(raw)
      guard withinArgvElementBounds(normalized) else {
        return .reject(
          .resourceLimit,
          detail: "param \(slotName) exceeds the per-element UTF-8 bound",
          requiresHumanGate: humanGate,
          templateID: descriptor.templateID,
          riskLevel: declaredRisk.level,
          highRiskCategory: declaredRisk.category)
      }
      resolvedValues[slotName] = normalized
    }

    // Expand placeholders into independent argv elements only.
    var resolvedArgv: [String] = []
    resolvedArgv.reserveCapacity(descriptor.argvTemplate.count)
    for token in descriptor.argvTemplate {
      if let name = wholePlaceholderName(token) {
        guard let value = resolvedValues[name] else {
          return .reject(
            .paramInvalid,
            detail: "unresolved placeholder {\(name)}",
            requiresHumanGate: humanGate,
            templateID: descriptor.templateID,
            riskLevel: declaredRisk.level,
            highRiskCategory: declaredRisk.category)
        }
        resolvedArgv.append(normalizedNFC(value))
      } else {
        resolvedArgv.append(normalizedNFC(token))
      }
    }

    guard resolvedArgv.count <= maxArgvElements,
      resolvedArgv.allSatisfy(withinArgvElementBounds)
    else {
      return .reject(
        .resourceLimit,
        detail: "resolved argv exceeds bounded shape",
        requiresHumanGate: humanGate,
        templateID: descriptor.templateID,
        riskLevel: declaredRisk.level,
        highRiskCategory: declaredRisk.category)
    }

    let resolvedClassification = classify(
      executable: descriptor.executable,
      argv: resolvedArgv)
    let risk = effectiveRisk(descriptor: descriptor, classification: resolvedClassification)
    let effectiveHumanGate = risk.level == .highRisk

    // High-risk: always requiresHumanGate; never standing; approval required to accept.
    if effectiveHumanGate {
      let approval = invocation.approvalID?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if approval.isEmpty {
        return TatwoMutualControlValidationResultV1(
          accepted: false,
          requiresHumanGate: true,
          resolvedExecutable: normalizedNFC(descriptor.executable),
          resolvedArgv: resolvedArgv,
          templateID: descriptor.templateID,
          riskLevel: risk.level,
          highRiskCategory: risk.category,
          errorCode: .highRiskNoApproval,
          detail: "high_risk template requires per-invocation human gate (no standing auth)")
      }
    }

    let digest: String?
    do {
      digest = try invocation.computeInvokeCanonicalDigest()
    } catch {
      return .reject(
        .schemaInvalid,
        detail: "failed to compute invoke digest",
        requiresHumanGate: effectiveHumanGate,
        templateID: descriptor.templateID)
    }
    if let claimed = invocation.invokeCanonicalDigest, claimed != digest {
      return .reject(
        .signatureInvalid,
        detail: "invokeCanonicalDigest mismatch",
        requiresHumanGate: effectiveHumanGate,
        templateID: descriptor.templateID)
    }

    return TatwoMutualControlValidationResultV1(
      accepted: true,
      requiresHumanGate: effectiveHumanGate,
      resolvedExecutable: normalizedNFC(descriptor.executable),
      resolvedArgv: resolvedArgv,
      templateID: descriptor.templateID,
      riskLevel: risk.level,
      highRiskCategory: risk.category,
      errorCode: nil,
      detail: nil,
      invokeCanonicalDigest: digest,
      capabilityVersion: invocation.capabilityVersion,
      descriptorDigest: descriptor.descriptorDigest,
      validatorIssued: true)
  }

  private static func verifyManifestSignature(
    manifest: TatwoDeviceCapabilityManifestV1,
    pinnedIdentity: TatwoDevicePublicIdentityV1?
  ) -> TatwoMutualControlValidationResultV1? {
    guard let signature = manifest.producerSignature else {
      return .reject(.signatureInvalid, detail: "manifest signature missing")
    }
    let identity: TatwoDevicePublicIdentityV1
    if let pinnedIdentity {
      identity = pinnedIdentity
    } else {
      return .reject(.signatureInvalid, detail: "pinned identity required to verify signature")
    }
    if identity.deviceID != manifest.targetDeviceID {
      return .reject(.signatureInvalid, detail: "pinned identity is not the manifest owner")
    }
    if let fingerprint = manifest.signingKeyFingerprint, fingerprint != identity.keyID {
      return .reject(.signatureInvalid, detail: "signingKeyFingerprint mismatch")
    }
    do {
      let expectedDigest = try manifest.computeManifestDigest()
      if expectedDigest != manifest.manifestDigest {
        return .reject(.signatureInvalid, detail: "manifestDigest mismatch (tamper)")
      }
      for descriptor in manifest.descriptors {
        guard let claimed = descriptor.descriptorDigest,
          let actual = try? descriptor.computeDescriptorDigest(),
          claimed == actual
        else {
          return .reject(
            .signatureInvalid,
            detail: "descriptorDigest missing or mismatched")
        }
      }
      try TatwoDeviceTrustAuthority.verify(
        payload: try manifest.unsignedCanonicalPayload(),
        purpose: TatwoMutualControlPurposeV1.deviceCapabilityManifest.rawValue,
        signature: signature,
        pinnedIdentity: identity)
    } catch {
      return .reject(.signatureInvalid, detail: "manifest signature verification failed")
    }
    return nil
  }

  // MARK: Injection / shell shape

  /// Reject NUL and newlines that can escape template/record semantics. Shell metacharacters
  /// (`;`, `$()`, quotes, spaces) remain literal argv bytes and are not shell-interpreted.
  private static func rejectInjection(
    _ value: String,
    param: String
  ) -> TatwoMutualControlErrorCodeV1? {
    if value.utf8.contains(0) {
      return .injectionRejected
    }
    if value.contains("\n") || value.contains("\r") || value.contains("\u{2028}")
      || value.contains("\u{2029}")
    {
      return .injectionRejected
    }
    // Embedded NUL via Swift string is already caught; also reject C0 control chars except tab.
    for scalar in value.unicodeScalars {
      if scalar.value < 0x20 && scalar != "\t" {
        return .injectionRejected
      }
    }
    _ = param
    return nil
  }

  private static func matchesConstraint(
    _ value: String,
    constraint: TatwoMutualControlParamConstraintV1
  ) -> Bool {
    let normalizedValue = normalizedNFC(value)
    switch constraint {
    case .enumValues(let allowed):
      return allowed.contains { normalizedNFC($0) == normalizedValue }
    case .regex(let pattern):
      let normalizedPattern = normalizedNFC(pattern)
      guard isBoundedRegex(normalizedPattern),
        let regex = try? NSRegularExpression(pattern: normalizedPattern, options: [])
      else {
        return false
      }
      let range = NSRange(
        normalizedValue.startIndex..<normalizedValue.endIndex,
        in: normalizedValue)
      guard let match = regex.firstMatch(
        in: normalizedValue,
        options: [],
        range: range)
      else {
        return false
      }
      return match.range.location == 0 && match.range.length == range.length
    case .pathPrefix(let roots):
      return isPath(value, insideAnyRoot: roots)
    }
  }

  /// Path containment with component boundaries (no bare `hasPrefix` root escape).
  private static func isPath(_ path: String, insideAnyRoot roots: [String]) -> Bool {
    let normalizedPath = normalizedNFC(path)
    guard normalizedPath.hasPrefix("/") else { return false }
    let child = standardizedPath(normalizedPath)
    for root in roots {
      let parent = standardizedPath(normalizedNFC(root))
      if pathIs(child, inside: parent) {
        return true
      }
    }
    return false
  }

  private static func pathIs(_ child: String, inside parent: String) -> Bool {
    if child == parent { return true }
    let parentParts = parent.split(separator: "/", omittingEmptySubsequences: true)
    let childParts = child.split(separator: "/", omittingEmptySubsequences: true)
    guard childParts.count >= parentParts.count else { return false }
    return childParts.starts(with: parentParts)
  }

  private static func standardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private struct RiskClassification {
    let level: TatwoMutualControlRiskLevelV1
    let category: TatwoMutualControlHighRiskCategoryV1?
  }

  private static func effectiveRisk(
    descriptor: TatwoDeviceCapabilityDescriptorV1,
    classification: RiskClassification?
  ) -> RiskClassification {
    if let classification {
      return classification
    }
    return RiskClassification(
      level: descriptor.riskLevel,
      category: descriptor.highRiskCategory)
  }

  /// Verifier-owned, non-degradable risk policy.  Descriptor issuer fields
  /// are only hints; a match here always upgrades to high risk.
  private static func classify(
    executable: String,
    argv: [String]
  ) -> RiskClassification? {
    let normalizedExecutable = normalizedNFC(executable)
    let executableBase = (normalizedExecutable as NSString)
      .lastPathComponent
      .lowercased()
    let args = argv.map { normalizedNFC($0) }
    let lowerArgs = args.map { $0.lowercased() }
    let shellNames: Set<String> = [
      "sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"
    ]

    if shellNames.contains(executableBase),
      lowerArgs.contains(where: { $0 == "-c" || $0 == "--command" || $0 == "-lc" })
    {
      return RiskClassification(level: .highRisk, category: .interpreter)
    }
    if executableBase == "env",
      let shellIndex = lowerArgs.firstIndex(where: { shellNames.contains($0) }),
      lowerArgs.dropFirst(shellIndex + 1)
        .contains(where: { $0 == "-c" || $0 == "--command" || $0 == "-lc" })
    {
      return RiskClassification(level: .highRisk, category: .interpreter)
    }
    let evalExecutables: Set<String> = [
      "python", "python3", "node", "osascript", "ruby", "perl"
    ]
    let evalFlags: Set<String> = ["-c", "-e", "--eval"]
    if evalExecutables.contains(executableBase),
      lowerArgs.contains(where: { evalFlags.contains($0) })
    {
      return RiskClassification(level: .highRisk, category: .interpreter)
    }

    let systemRoots = [
      "/system", "/library", "/applications", "/usr", "/bin", "/sbin",
      "/private", "/var/root", "/etc"
    ]
    let commandVerb = executableBase
    if commandVerb == "rm" || commandVerb == "mv" {
      let operands = args.filter {
        let lower = $0.lowercased()
        return !lower.hasPrefix("-") && !lower.isEmpty
      }
      if operands.contains(where: { operand in
        let lower = operand.lowercased()
        return lower.hasPrefix("{")
          || systemRoots.contains(where: { lower == $0 || lower.hasPrefix("\($0)/") })
      }) {
        let category: TatwoMutualControlHighRiskCategoryV1 =
          commandVerb == "rm" ? .delete : .deploy
        return RiskClassification(level: .highRisk, category: category)
      }
    }

    let systemVerbs: Set<String> = [
      "launchctl", "security", "codesign", "networksetup", "installer",
      "diskutil", "chmod", "chown", "killall", "shutdown", "reboot",
      "pkill"
    ]
    if systemVerbs.contains(commandVerb) {
      let category: TatwoMutualControlHighRiskCategoryV1 =
        commandVerb == "installer" ? .deploy : .systemPermission
      return RiskClassification(level: .highRisk, category: category)
    }
    return nil
  }

  private static func normalizedNFC(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
  }

  private static func withinArgvElementBounds(_ value: String) -> Bool {
    value.utf8.count <= maxArgvElementBytes
  }

  /// Conservative regex admission policy: bounded length and no nested
  /// quantifiers / adjacent quantifier chains that are common ReDoS shapes.
  private static func isBoundedRegex(_ pattern: String) -> Bool {
    guard pattern.utf8.count <= maxRegexPatternLength else { return false }
    var groups: [Bool] = []
    var escaped = false
    var previousQuantifier = false
    var closedGroupHadQuantifier = false
    for scalar in pattern.unicodeScalars {
      if escaped {
        escaped = false
        previousQuantifier = false
        closedGroupHadQuantifier = false
        continue
      }
      if scalar == "\\" {
        escaped = true
        continue
      }
      if scalar == "(" {
        groups.append(false)
        previousQuantifier = false
        closedGroupHadQuantifier = false
        continue
      }
      if scalar == ")" {
        guard let groupHadQuantifier = groups.popLast() else { return false }
        if groupHadQuantifier, !groups.isEmpty {
          groups[groups.count - 1] = true
        }
        closedGroupHadQuantifier = groupHadQuantifier
        previousQuantifier = false
        continue
      }
      let isQuantifier = scalar == "*" || scalar == "+" || scalar == "?"
        || scalar == "{"
      if isQuantifier {
        if previousQuantifier || closedGroupHadQuantifier {
          return false
        }
        if !groups.isEmpty {
          groups[groups.count - 1] = true
        }
        previousQuantifier = true
        closedGroupHadQuantifier = false
      } else {
        previousQuantifier = false
        closedGroupHadQuantifier = false
      }
    }
    return !escaped && groups.isEmpty
  }

  private static func wholePlaceholderName(_ token: String) -> String? {
    let normalizedToken = normalizedNFC(token)
    guard normalizedToken.count >= 3,
      normalizedToken.first == "{",
      normalizedToken.last == "}"
    else { return nil }
    let name = String(normalizedToken.dropFirst().dropLast())
    guard !name.isEmpty, !name.contains("{"), !name.contains("}") else { return nil }
    // Placeholder names are simple identifiers.
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_."))
    guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return name
  }

  private static func isEmbeddedPlaceholder(_ token: String) -> Bool {
    let normalizedToken = normalizedNFC(token)
    if wholePlaceholderName(normalizedToken) != nil { return false }
    // Any `{name}` substring inside a larger token is an injection surface.
    guard let open = normalizedToken.firstIndex(of: "{"),
      let close = normalizedToken[open...].firstIndex(of: "}"),
      close > open
    else {
      return false
    }
    let inner = normalizedToken[normalizedToken.index(after: open)..<close]
    return !inner.isEmpty
  }
}

private extension TatwoMutualControlValidationResultV1 {
  func withCapabilityVersion(_ version: UInt64) -> TatwoMutualControlValidationResultV1 {
    TatwoMutualControlValidationResultV1(
      accepted: accepted,
      requiresHumanGate: requiresHumanGate,
      resolvedExecutable: resolvedExecutable,
      resolvedArgv: resolvedArgv,
      templateID: templateID,
      riskLevel: riskLevel,
      highRiskCategory: highRiskCategory,
      errorCode: errorCode,
      detail: detail,
      invokeCanonicalDigest: invokeCanonicalDigest,
      capabilityVersion: version,
      descriptorDigest: descriptorDigest,
      validatorIssued: isValidatorIssued)
  }
}

// MARK: - Result receipt (D8 §8; fleet attempt-binding shape)

public struct TatwoMutualControlOutputArtifactRefV1: Codable, Sendable, Equatable {
  public let relativePath: String
  public let contentHash: String
  public let byteCount: Int?

  public init(relativePath: String, contentHash: String, byteCount: Int? = nil) {
    self.relativePath = relativePath
    self.contentHash = contentHash
    self.byteCount = byteCount
  }
}

public enum TatwoMutualControlReceiptStatusV1: String, Codable, Sendable, CaseIterable, Equatable {
  case completed
  case rejected
}

/// Mutual-control result / reject receipt. Attempt binding reuses fleet shape
/// (`jobID` + `dispatchNonce` + `invokeCanonicalDigest`). S1 only defines the structure;
/// S2 writes it after transport/execution.
public struct TatwoMutualControlReceiptV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoMutualControlReceiptV1"

  public let schema: String
  public let receiptID: String
  public let status: TatwoMutualControlReceiptStatusV1
  public let logicalControlID: String
  public let jobID: String
  public let dispatchNonce: String
  public let invokeCanonicalDigest: String
  public let sourceDeviceID: String
  public let operatorPrincipalID: String
  public let targetDeviceID: String
  public let templateID: String
  public let capabilityVersion: UInt64
  public let actualArgv: [String]
  public let executableResolved: String
  public let startedAt: String
  public let endedAt: String
  public let exitCode: Int32?
  public let terminatedBySignal: Int32?
  public let outputSummary: String?
  public let stdoutArtifact: TatwoMutualControlOutputArtifactRefV1?
  public let stderrArtifact: TatwoMutualControlOutputArtifactRefV1?
  public let approvalID: String?
  public let requiresHumanGate: Bool
  public let riskLevel: TatwoMutualControlRiskLevelV1
  public let highRiskCategory: TatwoMutualControlHighRiskCategoryV1?
  public let rejectCode: TatwoMutualControlErrorCodeV1?
  public let rejectDetail: String?
  public let targetSignature: TatwoDeviceSignatureV1?
  public let signingKeyFingerprint: String?

  public init(
    schema: String = TatwoMutualControlReceiptV1.schemaName,
    receiptID: String,
    status: TatwoMutualControlReceiptStatusV1,
    logicalControlID: String,
    jobID: String,
    dispatchNonce: String,
    invokeCanonicalDigest: String,
    sourceDeviceID: String,
    operatorPrincipalID: String,
    targetDeviceID: String,
    templateID: String,
    capabilityVersion: UInt64,
    actualArgv: [String],
    executableResolved: String,
    startedAt: String,
    endedAt: String,
    exitCode: Int32? = nil,
    terminatedBySignal: Int32? = nil,
    outputSummary: String? = nil,
    stdoutArtifact: TatwoMutualControlOutputArtifactRefV1? = nil,
    stderrArtifact: TatwoMutualControlOutputArtifactRefV1? = nil,
    approvalID: String? = nil,
    requiresHumanGate: Bool,
    riskLevel: TatwoMutualControlRiskLevelV1,
    highRiskCategory: TatwoMutualControlHighRiskCategoryV1? = nil,
    rejectCode: TatwoMutualControlErrorCodeV1? = nil,
    rejectDetail: String? = nil,
    targetSignature: TatwoDeviceSignatureV1? = nil,
    signingKeyFingerprint: String? = nil
  ) {
    self.schema = schema
    self.receiptID = receiptID
    self.status = status
    self.logicalControlID = logicalControlID
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.invokeCanonicalDigest = invokeCanonicalDigest
    self.sourceDeviceID = sourceDeviceID
    self.operatorPrincipalID = operatorPrincipalID
    self.targetDeviceID = targetDeviceID
    self.templateID = templateID
    self.capabilityVersion = capabilityVersion
    self.actualArgv = actualArgv
    self.executableResolved = executableResolved
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.exitCode = exitCode
    self.terminatedBySignal = terminatedBySignal
    self.outputSummary = outputSummary.map { String($0.prefix(512)) }
    self.stdoutArtifact = stdoutArtifact
    self.stderrArtifact = stderrArtifact
    self.approvalID = approvalID
    self.requiresHumanGate = requiresHumanGate
    self.riskLevel = riskLevel
    self.highRiskCategory = highRiskCategory
    self.rejectCode = rejectCode
    self.rejectDetail = rejectDetail
    self.targetSignature = targetSignature
    self.signingKeyFingerprint = signingKeyFingerprint
  }

  /// Build a reject receipt from a failed validation (no process was run).
  public static func makeRejected(
    receiptID: String = UUID().uuidString,
    invocation: TatwoMutualControlInvocationV1,
    validation: TatwoMutualControlValidationResultV1,
    startedAt: Date = Date(),
    endedAt: Date = Date()
  ) throws -> TatwoMutualControlReceiptV1 {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let digest: String
    if let existing = validation.invokeCanonicalDigest ?? invocation.invokeCanonicalDigest {
      digest = existing
    } else {
      digest = try invocation.computeInvokeCanonicalDigest()
    }
    return TatwoMutualControlReceiptV1(
      receiptID: receiptID,
      status: .rejected,
      logicalControlID: invocation.logicalControlID,
      jobID: invocation.jobID,
      dispatchNonce: invocation.dispatchNonce,
      invokeCanonicalDigest: digest,
      sourceDeviceID: invocation.sourceDeviceID,
      operatorPrincipalID: invocation.operatorPrincipalID,
      targetDeviceID: invocation.targetDeviceID,
      templateID: invocation.templateID,
      capabilityVersion: validation.capabilityVersion ?? invocation.capabilityVersion,
      actualArgv: validation.resolvedArgv ?? [],
      executableResolved: validation.resolvedExecutable ?? "",
      startedAt: iso.string(from: startedAt),
      endedAt: iso.string(from: endedAt),
      exitCode: nil,
      outputSummary: nil,
      approvalID: invocation.approvalID,
      requiresHumanGate: validation.requiresHumanGate,
      riskLevel: validation.riskLevel ?? .normal,
      highRiskCategory: validation.highRiskCategory,
      rejectCode: validation.errorCode,
      rejectDetail: validation.detail)
  }
}

/// Design-doc alias (D8 §3.2 / §8.1).
public typealias TatwoMutualControlResultReceiptV1 = TatwoMutualControlReceiptV1

// MARK: - S2 transport seam (interface only; no implementation)

/// S2 will implement sealed-channel mutual-control transport. S1 only freezes the contract.
public protocol TatwoMutualControlTransportSeamV1: Sendable {
  /// Deliver a validated invoke request to the target device channel.
  func deliverInvoke(
    invocation: TatwoMutualControlInvocationV1,
    validation: TatwoMutualControlValidationResultV1
  ) async throws -> String

  /// Await result/reject receipt for an attempt binding.
  func awaitReceipt(
    jobID: String,
    dispatchNonce: String,
    invokeCanonicalDigest: String
  ) async throws -> TatwoMutualControlReceiptV1
}

// MARK: - Canonical JSON helper

enum TatwoMutualControlCanonicalJSON {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  /// Opaque JSON value for nested re-encoding if needed.
  enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if container.decodeNil() {
        self = .null
      } else if let b = try? container.decode(Bool.self) {
        self = .bool(b)
      } else if let n = try? container.decode(Double.self) {
        self = .number(n)
      } else if let s = try? container.decode(String.self) {
        self = .string(s)
      } else if let a = try? container.decode([JSONValue].self) {
        self = .array(a)
      } else if let o = try? container.decode([String: JSONValue].self) {
        self = .object(o)
      } else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "unsupported JSON value")
      }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .null: try container.encodeNil()
      case .bool(let b): try container.encode(b)
      case .number(let n): try container.encode(n)
      case .string(let s): try container.encode(s)
      case .array(let a): try container.encode(a)
      case .object(let o): try container.encode(o)
      }
    }
  }
}
