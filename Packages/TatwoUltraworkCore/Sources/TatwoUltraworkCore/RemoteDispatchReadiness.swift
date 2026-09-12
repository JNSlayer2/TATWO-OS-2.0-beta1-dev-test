import Foundation

public enum TatwoRemoteDispatchReadinessError: Error, LocalizedError, Sendable, Equatable {
  case missingProvider
  case missingRequirements
  case missingJobBinding
  case invalidReceipt(String)
  case scopeMismatch(String)
  case stale
  case notYetValid
  case lifetimeExceeded
  case signatureRejected
  case targetObservationUnavailable(String)

  public var errorDescription: String? {
    switch self {
    case .missingProvider:
      return "remote dispatch readiness provider is required"
    case .missingRequirements:
      return "remote dispatch readiness requirements are required"
    case .missingJobBinding:
      return "signed remote job is missing readiness bindings"
    case .invalidReceipt(let field):
      return "remote dispatch readiness receipt is invalid: \(field)"
    case .scopeMismatch(let field):
      return "remote dispatch readiness scope mismatch: \(field)"
    case .stale:
      return "remote dispatch readiness receipt is stale"
    case .notYetValid:
      return "remote dispatch readiness receipt is not yet valid"
    case .lifetimeExceeded:
      return "remote dispatch readiness receipt lifetime exceeds the allowed window"
    case .signatureRejected:
      return "remote dispatch readiness target signature was rejected"
    case .targetObservationUnavailable(let detail):
      return "target readiness observation is unavailable: \(detail)"
    }
  }
}

public struct TatwoRemoteDispatchReadinessRequirementsV1: Sendable, Equatable {
  public let challengeNonce: String

  public init(challengeNonce: String) {
    self.challengeNonce = challengeNonce
  }

  /// Derive the per-attempt challenge from the signed job binding.
  ///
  /// The origin must not keep a process-global/static challenge for remote
  /// dispatch. Recovery attempts receive a new job binding and therefore a new
  /// challenge before any target transport is contacted.
  public init(job: TatwoLoopJobV1) throws {
    guard
      let binding = job.remoteDispatchReadiness,
      !binding.challengeNonce.isEmpty,
      !binding.challengeNonce.contains("\0")
    else {
      throw TatwoRemoteDispatchReadinessError.missingJobBinding
    }
    self.challengeNonce = binding.challengeNonce
  }
}

/// Redacted origin request sent to a target readiness provider.
///
/// This deliberately carries the signed attempt scope and opaque target
/// binding digests, but never carries `TatwoLoopJobV1.workPath` (or any other
/// origin-local absolute path/display name). A transport implementation must
/// resolve and observe its own canonical workspace, runtime capability pin and
/// active Skill set on the target, then return a target-signed receipt.
public struct TatwoRemoteDispatchReadinessRequestV1: Codable, Sendable, Equatable {
  public let originDeviceID: String
  public let targetDeviceID: String
  public let contractID: String
  public let goalID: String
  public let jobID: String
  public let logicalJobID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  public let expectedWorkspaceBindingID: String
  public let expectedWorkspaceBindingDigest: String
  public let expectedAgentModelCapabilityDigest: String
  public let expectedActiveSkillSetDigest: String
  /// Present for production `.tatwoLoop` jobs. Legacy/shell-safe readiness
  /// probes may omit these additive fields.
  public let expectedAgent: String?
  public let expectedExactModelRouteID: String?
  public let challengeNonce: String

  public init(
    job: TatwoLoopJobV1,
    requirements: TatwoRemoteDispatchReadinessRequirementsV1
  ) throws {
    guard let binding = job.remoteDispatchReadiness else {
      throw TatwoRemoteDispatchReadinessError.missingJobBinding
    }
    self.originDeviceID = job.originDeviceID
    self.targetDeviceID = job.targetDeviceID
    self.contractID = job.contractID
    self.goalID = job.goalID
    self.jobID = job.jobID
    self.logicalJobID = job.logicalJobID
    self.dispatchNonce = job.dispatchNonce
    self.jobCanonicalDigest = try job.canonicalDigest()
    self.expectedWorkspaceBindingID = binding.workspaceBindingID
    self.expectedWorkspaceBindingDigest = binding.workspaceBindingDigest
    self.expectedAgentModelCapabilityDigest = binding.agentModelCapabilityDigest
    self.expectedActiveSkillSetDigest = binding.activeSkillSetDigest
    if case let .tatwoLoop(loop) = job.payload {
      self.expectedAgent = loop.agent?.rawValue
      self.expectedExactModelRouteID = loop.exactModelRouteID
    } else {
      self.expectedAgent = nil
      self.expectedExactModelRouteID = nil
    }
    self.challengeNonce = requirements.challengeNonce
  }
}

/// Target-observed readiness truth. A target provider obtains this from the
/// target filesystem/runtime; the origin does not derive it from `job.workPath`.
public struct TatwoRemoteDispatchReadinessObservationV1: Sendable, Equatable {
  public let targetWorkspaceBindingID: String
  public let targetWorkspaceBindingDigest: String
  public let agentModelCapabilityDigest: String
  public let activeSkillSetDigest: String
  public let readbackNonce: String

  public init(
    targetWorkspaceBindingID: String,
    targetWorkspaceBindingDigest: String,
    agentModelCapabilityDigest: String,
    activeSkillSetDigest: String,
    readbackNonce: String
  ) {
    self.targetWorkspaceBindingID = targetWorkspaceBindingID
    self.targetWorkspaceBindingDigest = targetWorkspaceBindingDigest
    self.agentModelCapabilityDigest = agentModelCapabilityDigest
    self.activeSkillSetDigest = activeSkillSetDigest
    self.readbackNonce = readbackNonce
  }
}

public struct TatwoTargetWorkspaceDigestInputV1: Codable, Sendable, Equatable {
  public let workspaceBindingID: String
  /// SHA-256 of the target-canonical path bytes. The path itself stays target-local.
  public let canonicalPathDigest: String
  public let filesystemDeviceID: UInt64
  public let filesystemInodeID: UInt64

  public init(
    workspaceBindingID: String,
    canonicalPathDigest: String,
    filesystemDeviceID: UInt64,
    filesystemInodeID: UInt64
  ) {
    self.workspaceBindingID = workspaceBindingID
    self.canonicalPathDigest = canonicalPathDigest
    self.filesystemDeviceID = filesystemDeviceID
    self.filesystemInodeID = filesystemInodeID
  }

  public func canonicalDigest() throws -> String {
    guard TatwoRemoteDispatchCanonicalDigest.isSafeIdentifier(workspaceBindingID),
      TatwoRemoteDispatchCanonicalDigest.isSHA256(canonicalPathDigest),
      filesystemDeviceID > 0,
      filesystemInodeID > 0
    else {
      throw TatwoRemoteDispatchReadinessError.invalidReceipt("workspaceDigestInput")
    }
    return try TatwoRemoteDispatchCanonicalDigest.digest(self)
  }
}

public struct TatwoAgentModelCapabilityDigestInputV1: Codable, Sendable, Equatable {
  public let requestedAgent: String
  public let exactModelRouteID: String
  public let executableContentDigest: String
  public let transportCapabilities: [String]

  public init(
    requestedAgent: String,
    exactModelRouteID: String,
    executableContentDigest: String,
    transportCapabilities: [String]
  ) {
    self.requestedAgent = requestedAgent
    self.exactModelRouteID = exactModelRouteID
    self.executableContentDigest = executableContentDigest
    self.transportCapabilities = transportCapabilities
  }

  public func canonicalDigest() throws -> String {
    guard TatwoRemoteDispatchCanonicalDigest.isSafeIdentifier(requestedAgent),
      TatwoRemoteDispatchCanonicalDigest.isSafeIdentifier(exactModelRouteID),
      TatwoRemoteDispatchCanonicalDigest.isSHA256(executableContentDigest),
      !transportCapabilities.isEmpty
    else {
      throw TatwoRemoteDispatchReadinessError.invalidReceipt("capabilityDigestInput")
    }
    let sortedCapabilities = transportCapabilities.sorted()
    guard Set(sortedCapabilities).count == sortedCapabilities.count,
      sortedCapabilities.allSatisfy(TatwoRemoteDispatchCanonicalDigest.isSafeIdentifier)
    else {
      throw TatwoRemoteDispatchReadinessError.invalidReceipt("capabilityDigestInput")
    }
    let canonical = TatwoAgentModelCapabilityDigestInputV1(
      requestedAgent: requestedAgent,
      exactModelRouteID: exactModelRouteID,
      executableContentDigest: executableContentDigest,
      transportCapabilities: sortedCapabilities)
    return try TatwoRemoteDispatchCanonicalDigest.digest(canonical)
  }
}

/// Canonical active Skill revision used to derive the readiness Skill-set digest.
public struct TatwoActiveSkillRevisionV1: Codable, Sendable, Equatable, Hashable {
  public let repository: String
  public let revision: String
  public let contentDigest: String

  public init(repository: String, revision: String, contentDigest: String) {
    self.repository = repository
    self.revision = revision
    self.contentDigest = contentDigest
  }
}

public enum TatwoActiveSkillSetDigestV1 {
  /// Stable digest over sorted repository/revision/content-digest tuples.
  /// Empty sets, duplicate tuples, unsafe identifiers, and malformed SHA-256
  /// content digests are rejected rather than normalized silently.
  public static func canonicalDigest(
    _ revisions: [TatwoActiveSkillRevisionV1]
  ) throws -> String {
    guard !revisions.isEmpty else {
      throw TatwoRemoteDispatchReadinessError.invalidReceipt("activeSkillSet.empty")
    }
    var seenRepositories = Set<String>()
    for entry in revisions {
      guard isSafeIdentifier(entry.repository), isSafeIdentifier(entry.revision) else {
        throw TatwoRemoteDispatchReadinessError.invalidReceipt("activeSkillSet.identifier")
      }
      guard entry.contentDigest.range(
        of: #"^[0-9a-f]{64}$"#,
        options: .regularExpression) != nil
      else {
        throw TatwoRemoteDispatchReadinessError.invalidReceipt("activeSkillSet.contentDigest")
      }
      guard seenRepositories.insert(entry.repository).inserted else {
        throw TatwoRemoteDispatchReadinessError.invalidReceipt("activeSkillSet.duplicate")
      }
    }
    let sorted = revisions.sorted {
      ($0.repository, $0.revision, $0.contentDigest)
        < ($1.repository, $1.revision, $1.contentDigest)
    }
    return try TatwoRemoteDispatchCanonicalDigest.digest(sorted)
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && !value.contains("\0")
      && value.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._/@:+-]*$"#,
        options: .regularExpression) != nil
  }
}

private enum TatwoRemoteDispatchCanonicalDigest {
  static func digest<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = TatwoLoopJobDigest.sha256(try encoder.encode(value))
    return digest.hasPrefix("sha256:")
      ? String(digest.dropFirst("sha256:".count))
      : digest
  }

  static func isSHA256(_ value: String) -> Bool {
    value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
  }

  static func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && !value.contains("\0")
      && value.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._/@:+-]*$"#,
        options: .regularExpression) != nil
  }
}

/// Transport boundary for target-owned readiness collection. Implementations
/// must perform the target preflight from the redacted request and return a
/// target-signed snapshot. This protocol does not itself provide a production
/// transport implementation.
public protocol TatwoRemoteDispatchReadinessProviding: Sendable {
  func readinessReceipt(
    for request: TatwoRemoteDispatchReadinessRequestV1
  ) throws -> TatwoRemoteDispatchReadinessReceiptV1
}

/// Bounded file-channel transport for a target-owned readiness preflight.
///
/// The request is redacted (notably it contains no `workPath`) and is signed
/// by the origin before being written. The target handler writes a separately
/// signed response. The transport is intentionally fail-closed when the target
/// does not answer within the bounded wait.
public struct TatwoRemoteDispatchReadinessChannelProviderV1:
  TatwoRemoteDispatchReadinessProviding, Sendable
{
  public let rootURL: URL
  public let originTrust: TatwoLoopJobChannelTrust
  public let timeoutSec: TimeInterval
  public let pollIntervalSec: TimeInterval

  public init(
    channel: TatwoLoopJobChannel,
    timeoutSec: TimeInterval = 5,
    pollIntervalSec: TimeInterval = 0.05
  ) {
    self.rootURL = channel.rootURL
    self.originTrust = channel.trust
    self.timeoutSec = max(0.05, timeoutSec)
    self.pollIntervalSec = max(0.001, pollIntervalSec)
  }

  public init(
    rootURL: URL,
    originTrust: TatwoLoopJobChannelTrust,
    timeoutSec: TimeInterval = 5,
    pollIntervalSec: TimeInterval = 0.05
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.originTrust = originTrust
    self.timeoutSec = max(0.05, timeoutSec)
    self.pollIntervalSec = max(0.001, pollIntervalSec)
  }

  public func readinessReceipt(
    for request: TatwoRemoteDispatchReadinessRequestV1
  ) throws -> TatwoRemoteDispatchReadinessReceiptV1 {
    let requestData = try TatwoRemoteDispatchReadinessTransportV1.encode(request)
    let signature = try originTrust.sign(
      payload: requestData,
      purpose: .loopAck,
      signedAt: Date())
    let envelope = TatwoRemoteDispatchReadinessRequestEnvelopeV1(
      request: request,
      originSignature: signature)
    let requestURL = TatwoRemoteDispatchReadinessTransportV1.requestURL(
      rootURL: rootURL,
      jobID: request.jobID)
    try TatwoRemoteDispatchReadinessTransportV1.write(
      envelope,
      to: requestURL)

    let responseURL = TatwoRemoteDispatchReadinessTransportV1.responseURL(
      rootURL: rootURL,
      jobID: request.jobID)
    let deadline = Date().addingTimeInterval(timeoutSec)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: responseURL.path) {
        let responseData = try Data(contentsOf: responseURL)
        if let failure = try? TatwoRemoteDispatchReadinessTransportV1.decode(
          TatwoRemoteDispatchReadinessFailureEnvelope.self,
          from: responseData)
        {
          let failurePayload = try TatwoRemoteDispatchReadinessTransportV1.encode(
            failure.unsigned)
          do {
            try originTrust.verify(
              payload: failurePayload,
              purpose: .loopTargetReadiness,
              signature: failure.targetTransportSignature,
              expectedDeviceID: request.targetDeviceID,
              enforceFreshness: true)
          } catch {
            throw TatwoRemoteDispatchReadinessError.signatureRejected
          }
          throw TatwoRemoteDispatchReadinessError.targetObservationUnavailable(
            failure.unsigned.code)
        }
        let response: TatwoRemoteDispatchReadinessResponseEnvelopeV1
        do {
          response = try TatwoRemoteDispatchReadinessTransportV1.decode(
            TatwoRemoteDispatchReadinessResponseEnvelopeV1.self,
            from: responseData)
        } catch {
          throw TatwoRemoteDispatchReadinessError.invalidReceipt(
            "transport_response_decode")
        }
        let receiptData = try TatwoRemoteDispatchReadinessTransportV1.encode(response.receipt)
        do {
          try originTrust.verify(
            payload: receiptData,
            purpose: .loopTargetReadiness,
            signature: response.targetTransportSignature,
            expectedDeviceID: request.targetDeviceID,
            enforceFreshness: true)
        } catch {
          throw TatwoRemoteDispatchReadinessError.signatureRejected
        }
        guard response.receipt.jobID == request.jobID,
          response.receipt.logicalJobID == request.logicalJobID,
          response.receipt.dispatchNonce == request.dispatchNonce,
          response.receipt.jobCanonicalDigest == request.jobCanonicalDigest
        else {
          throw TatwoRemoteDispatchReadinessError.scopeMismatch("transport_attempt")
        }
        return response.receipt
      }
      Thread.sleep(forTimeInterval: pollIntervalSec)
    }
    throw TatwoRemoteDispatchReadinessError.invalidReceipt("target_timeout")
  }
}

/// Target-side handler for the signed readiness request/response artifacts.
///
/// The observation closure is target-owned. It receives only the redacted
/// request, so an origin cannot smuggle an absolute path or display name into
/// target readiness evidence.
public struct TatwoRemoteDispatchReadinessTargetHandlerV1: Sendable {
  public typealias Observe = @Sendable (
    TatwoRemoteDispatchReadinessRequestV1
  ) throws -> TatwoRemoteDispatchReadinessObservationV1

  public let rootURL: URL
  public let targetTrust: TatwoLoopJobChannelTrust
  public let observe: Observe

  public init(
    channel: TatwoLoopJobChannel,
    observe: @escaping Observe
  ) {
    self.rootURL = channel.rootURL
    self.targetTrust = channel.trust
    self.observe = observe
  }

  public init(
    rootURL: URL,
    targetTrust: TatwoLoopJobChannelTrust,
    observe: @escaping Observe
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.targetTrust = targetTrust
    self.observe = observe
  }

  /// Service all currently visible requests. Incomplete or invalid requests
  /// are ignored; no unsigned response is ever emitted.
  @discardableResult
  public func servicePendingRequests() throws -> Int {
    let directory = TatwoRemoteDispatchReadinessTransportV1.requestDirectory(
      rootURL: rootURL)
    guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
    let requests = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
      .filter { $0.pathExtension == "json" }
    var serviced = 0
    for requestURL in requests {
      do {
        let envelope = try TatwoRemoteDispatchReadinessTransportV1.decode(
          TatwoRemoteDispatchReadinessRequestEnvelopeV1.self,
          from: Data(contentsOf: requestURL))
        guard requestURL.deletingPathExtension().lastPathComponent
          == TatwoLoopPathComponent.sanitize(envelope.request.jobID)
        else {
          continue
        }
        // A response is the durable acknowledgement for this attempt. Do not
        // replace one with a second observation for the same signed request.
        let responseURL = TatwoRemoteDispatchReadinessTransportV1.responseURL(
          rootURL: rootURL,
          jobID: envelope.request.jobID)
        guard !FileManager.default.fileExists(atPath: responseURL.path) else {
          continue
        }
        let requestData = try TatwoRemoteDispatchReadinessTransportV1.encode(
          envelope.request)
        try targetTrust.verify(
          payload: requestData,
          purpose: .loopAck,
          signature: envelope.originSignature,
          expectedDeviceID: envelope.request.originDeviceID,
          enforceFreshness: true)
        let observation: TatwoRemoteDispatchReadinessObservationV1
        do {
          observation = try observe(envelope.request)
        } catch let error as TatwoRemoteDispatchReadinessError {
          guard case let .targetObservationUnavailable(detail) = error else {
            throw error
          }
          let failure = TatwoRemoteDispatchReadinessFailureEnvelope.Unsigned(
            jobID: envelope.request.jobID,
            dispatchNonce: envelope.request.dispatchNonce,
            code: detail,
            occurredAt: Date())
          let failureSignature = try targetTrust.sign(
            payload: TatwoRemoteDispatchReadinessTransportV1.encode(failure),
            purpose: .loopTargetReadiness,
            signedAt: failure.occurredAt)
          try TatwoRemoteDispatchReadinessTransportV1.write(
            TatwoRemoteDispatchReadinessFailureEnvelope(
              unsigned: failure,
              targetTransportSignature: failureSignature),
            to: responseURL)
          serviced += 1
          continue
        } catch {
          throw TatwoRemoteDispatchReadinessError.targetObservationUnavailable(
            "observer_failed")
        }
        let receipt = try TatwoRemoteDispatchReadinessReceiptV1.issue(
          request: envelope.request,
          observation: observation,
          targetTrust: targetTrust)
        let receiptData = try TatwoRemoteDispatchReadinessTransportV1.encode(receipt)
        let transportSignature = try targetTrust.sign(
          payload: receiptData,
          purpose: .loopTargetReadiness,
          signedAt: receipt.issuedAt)
        let response = TatwoRemoteDispatchReadinessResponseEnvelopeV1(
          receipt: receipt,
          targetTransportSignature: transportSignature)
        try TatwoRemoteDispatchReadinessTransportV1.write(
          response,
          to: responseURL)
        serviced += 1
      } catch {
        // Invalid/tampered requests fail closed without producing a response.
        continue
      }
    }
    return serviced
  }
}

/// Default production observer gate. A target host must replace this with its
/// workspace/runtime/active-Skill readback adapter before it can answer a
/// readiness request; silently echoing origin claims is forbidden.
public enum TatwoRemoteDispatchReadinessTargetObservationProviderV1 {
  public static func production(
    registryStore: TatwoRemoteDispatchReadinessRegistryStoreV1,
    agentEngine: TatwoAgentEngineBinding = .production,
    skilletStore: TatwoSkilletRepositoryStore
  ) -> TatwoRemoteDispatchReadinessTargetHandlerV1.Observe {
    let skilletRootURL = skilletStore.rootURL
    return { request in
      do {
        return try registryStore.observation(
          for: request,
          agentEngine: agentEngine,
          skilletStore: TatwoSkilletRepositoryStore(rootURL: skilletRootURL))
      } catch let error as TatwoRemoteDispatchReadinessRegistryError {
        let code: String
        switch error {
        case .registryMissing:
          code = "readiness_registry_missing"
        case .bindingNotFound:
          code = "readiness_binding_not_found"
        case .bindingDrift(let field):
          code = "readiness_binding_drift:\(field)"
        case .signatureRejected:
          code = "readiness_registry_signature_rejected"
        default:
          code = "readiness_registry_invalid"
        }
        throw TatwoRemoteDispatchReadinessError.targetObservationUnavailable(code)
      } catch {
        throw TatwoRemoteDispatchReadinessError.targetObservationUnavailable(
          "readiness_observation_failed")
      }
    }
  }

  public static func production(
    _ request: TatwoRemoteDispatchReadinessRequestV1
  ) throws -> TatwoRemoteDispatchReadinessObservationV1 {
    _ = request
    throw TatwoRemoteDispatchReadinessError.targetObservationUnavailable(
      "workspace_binding,agent_model_capability,active_skill_set")
  }
}

private struct TatwoRemoteDispatchReadinessRequestEnvelopeV1: Codable {
  let schema = "TatwoRemoteDispatchReadinessRequestEnvelopeV1"
  let request: TatwoRemoteDispatchReadinessRequestV1
  let originSignature: TatwoDeviceSignatureV1
}

private struct TatwoRemoteDispatchReadinessResponseEnvelopeV1: Codable {
  let schema = "TatwoRemoteDispatchReadinessResponseEnvelopeV1"
  let receipt: TatwoRemoteDispatchReadinessReceiptV1
  let targetTransportSignature: TatwoDeviceSignatureV1
}

private struct TatwoRemoteDispatchReadinessFailureEnvelope: Codable {
  let schema = "TatwoRemoteDispatchReadinessFailureEnvelopeV1"
  let unsigned: Unsigned
  let targetTransportSignature: TatwoDeviceSignatureV1

  struct Unsigned: Codable {
    let schema = "TatwoRemoteDispatchReadinessFailureV1"
    let jobID: String
    let dispatchNonce: String
    let code: String
    let occurredAt: Date
  }
}

private enum TatwoRemoteDispatchReadinessTransportV1 {
  static func requestDirectory(rootURL: URL) -> URL {
    rootURL.appendingPathComponent("readiness", isDirectory: true)
      .appendingPathComponent("requests", isDirectory: true)
  }

  static func responseDirectory(rootURL: URL) -> URL {
    rootURL.appendingPathComponent("readiness", isDirectory: true)
      .appendingPathComponent("responses", isDirectory: true)
  }

  static func requestURL(rootURL: URL, jobID: String) -> URL {
    requestDirectory(rootURL: rootURL)
      .appendingPathComponent("\(TatwoLoopPathComponent.sanitize(jobID)).json")
  }

  static func responseURL(rootURL: URL, jobID: String) -> URL {
    responseDirectory(rootURL: rootURL)
      .appendingPathComponent("\(TatwoLoopPathComponent.sanitize(jobID)).json")
  }

  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }

  static func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try TatwoAtomicFile.write(try encode(value), to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

public struct TatwoRemoteDispatchReadinessReceiptV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoRemoteDispatchReadinessReceiptV1"
  public static let maximumLifetime: TimeInterval = 300
  public static let allowedClockSkew: TimeInterval = 30

  public let schema: String
  public let originDeviceID: String
  public let targetDeviceID: String
  public let targetKeyID: String
  public let targetKeyGeneration: UInt64
  public let contractID: String
  public let goalID: String
  public let jobID: String
  public let logicalJobID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  public let targetWorkspaceBindingID: String
  public let targetWorkspaceBindingDigest: String
  public let agentModelCapabilityDigest: String
  public let activeSkillSetDigest: String
  public let challengeNonce: String
  public let readbackNonce: String
  public let issuedAt: Date
  public let expiresAt: Date
  public let targetSignature: TatwoDeviceSignatureV1

  public init(
    schema: String = TatwoRemoteDispatchReadinessReceiptV1.schemaName,
    originDeviceID: String,
    targetDeviceID: String,
    targetKeyID: String,
    targetKeyGeneration: UInt64,
    contractID: String,
    goalID: String,
    jobID: String,
    logicalJobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    targetWorkspaceBindingID: String,
    targetWorkspaceBindingDigest: String,
    agentModelCapabilityDigest: String,
    activeSkillSetDigest: String,
    challengeNonce: String,
    readbackNonce: String,
    issuedAt: Date,
    expiresAt: Date,
    targetSignature: TatwoDeviceSignatureV1
  ) {
    self.schema = schema
    self.originDeviceID = originDeviceID
    self.targetDeviceID = targetDeviceID
    self.targetKeyID = targetKeyID
    self.targetKeyGeneration = targetKeyGeneration
    self.contractID = contractID
    self.goalID = goalID
    self.jobID = jobID
    self.logicalJobID = logicalJobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.targetWorkspaceBindingID = targetWorkspaceBindingID
    self.targetWorkspaceBindingDigest = targetWorkspaceBindingDigest
    self.agentModelCapabilityDigest = agentModelCapabilityDigest
    self.activeSkillSetDigest = activeSkillSetDigest
    self.challengeNonce = challengeNonce
    self.readbackNonce = readbackNonce
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.targetSignature = targetSignature
  }

  /// Test/transport helper. The target observation is independent from the
  /// origin requirements and is signed through channel trust, not bare crypto.
  public static func issue(
    job: TatwoLoopJobV1,
    requirements: TatwoRemoteDispatchReadinessRequirementsV1,
    observation: TatwoRemoteDispatchReadinessObservationV1,
    targetTrust: TatwoLoopJobChannelTrust,
    issuedAt: Date = Date(),
    expiresAt: Date? = nil
  ) throws -> TatwoRemoteDispatchReadinessReceiptV1 {
    let targetIdentity = targetTrust.localIdentity
    let resolvedExpiry = expiresAt ?? issuedAt.addingTimeInterval(60)
    let unsigned = Unsigned(
      originDeviceID: job.originDeviceID,
      targetDeviceID: targetIdentity.deviceID,
      targetKeyID: targetIdentity.keyID,
      targetKeyGeneration: targetIdentity.keyGeneration,
      contractID: job.contractID,
      goalID: job.goalID,
      jobID: job.jobID,
      logicalJobID: job.logicalJobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      targetWorkspaceBindingID: observation.targetWorkspaceBindingID,
      targetWorkspaceBindingDigest: observation.targetWorkspaceBindingDigest,
      agentModelCapabilityDigest: observation.agentModelCapabilityDigest,
      activeSkillSetDigest: observation.activeSkillSetDigest,
      challengeNonce: requirements.challengeNonce,
      readbackNonce: observation.readbackNonce,
      issuedAt: issuedAt,
      expiresAt: resolvedExpiry)
    let signature = try targetTrust.sign(
      payload: unsigned.canonicalData(),
      purpose: .loopTargetReadiness,
      signedAt: issuedAt)
    return unsigned.receipt(signature: signature)
  }

  /// Target transport helper that issues from the redacted request alone.
  /// The target never needs (or receives) the origin-local `workPath`.
  public static func issue(
    request: TatwoRemoteDispatchReadinessRequestV1,
    observation: TatwoRemoteDispatchReadinessObservationV1,
    targetTrust: TatwoLoopJobChannelTrust,
    issuedAt: Date = Date(),
    expiresAt: Date? = nil
  ) throws -> TatwoRemoteDispatchReadinessReceiptV1 {
    let targetIdentity = targetTrust.localIdentity
    let resolvedExpiry = expiresAt ?? issuedAt.addingTimeInterval(60)
    let unsigned = Unsigned(
      originDeviceID: request.originDeviceID,
      targetDeviceID: targetIdentity.deviceID,
      targetKeyID: targetIdentity.keyID,
      targetKeyGeneration: targetIdentity.keyGeneration,
      contractID: request.contractID,
      goalID: request.goalID,
      jobID: request.jobID,
      logicalJobID: request.logicalJobID,
      dispatchNonce: request.dispatchNonce,
      jobCanonicalDigest: request.jobCanonicalDigest,
      targetWorkspaceBindingID: observation.targetWorkspaceBindingID,
      targetWorkspaceBindingDigest: observation.targetWorkspaceBindingDigest,
      agentModelCapabilityDigest: observation.agentModelCapabilityDigest,
      activeSkillSetDigest: observation.activeSkillSetDigest,
      challengeNonce: request.challengeNonce,
      readbackNonce: observation.readbackNonce,
      issuedAt: issuedAt,
      expiresAt: resolvedExpiry)
    let signature = try targetTrust.sign(
      payload: unsigned.canonicalData(),
      purpose: .loopTargetReadiness,
      signedAt: issuedAt)
    return unsigned.receipt(signature: signature)
  }

  public func verify(
    job: TatwoLoopJobV1,
    requirements: TatwoRemoteDispatchReadinessRequirementsV1,
    trust: TatwoLoopJobChannelTrust,
    now: Date = Date(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    guard schema == Self.schemaName else {
      throw TatwoRemoteDispatchReadinessError.invalidReceipt("schema")
    }
    // Validate temporal fields before crypto so callers can distinguish
    // stale/future/overlong receipts from a malformed or forged signature.
    guard expiresAt > issuedAt else {
      throw TatwoRemoteDispatchReadinessError.invalidReceipt("freshness_window")
    }
    guard expiresAt.timeIntervalSince(issuedAt) <= Self.maximumLifetime else {
      throw TatwoRemoteDispatchReadinessError.lifetimeExceeded
    }
    guard issuedAt <= now.addingTimeInterval(Self.allowedClockSkew) else {
      throw TatwoRemoteDispatchReadinessError.notYetValid
    }
    guard expiresAt > now else {
      throw TatwoRemoteDispatchReadinessError.stale
    }
    guard targetSignature.signedAt == TatwoLoopJobChannelTrust.iso8601(issuedAt) else {
      throw TatwoRemoteDispatchReadinessError.invalidReceipt("signedAt")
    }
    do {
      try trust.verifyRemoteDispatchReadiness(
        payload: try canonicalSigningPayload(),
        signature: targetSignature,
        targetDeviceID: job.targetDeviceID,
        now: now,
        maxAgeSec: Self.maximumLifetime,
        environment: environment)
    } catch {
      throw TatwoRemoteDispatchReadinessError.signatureRejected
    }
    guard let expected = job.remoteDispatchReadiness else {
      throw TatwoRemoteDispatchReadinessError.missingJobBinding
    }
    let bindings: [(String, String, String)] = [
      ("originDeviceID", originDeviceID, job.originDeviceID),
      ("targetDeviceID", targetDeviceID, job.targetDeviceID),
      ("contractID", contractID, job.contractID),
      ("goalID", goalID, job.goalID),
      ("jobID", jobID, job.jobID),
      ("logicalJobID", logicalJobID, job.logicalJobID),
      ("dispatchNonce", dispatchNonce, job.dispatchNonce),
      ("jobCanonicalDigest", jobCanonicalDigest, try job.canonicalDigest()),
      ("targetWorkspaceBindingID", targetWorkspaceBindingID, expected.workspaceBindingID),
      ("targetWorkspaceBindingDigest", targetWorkspaceBindingDigest, expected.workspaceBindingDigest),
      ("agentModelCapabilityDigest", agentModelCapabilityDigest, expected.agentModelCapabilityDigest),
      ("activeSkillSetDigest", activeSkillSetDigest, expected.activeSkillSetDigest),
      ("jobChallengeNonce", challengeNonce, expected.challengeNonce),
      ("challengeNonce", challengeNonce, requirements.challengeNonce),
      ("readbackNonce", readbackNonce, requirements.challengeNonce),
    ]
    for (field, actual, expectedValue) in bindings where actual != expectedValue {
      throw TatwoRemoteDispatchReadinessError.scopeMismatch(field)
    }
    guard let pinned = try trust.currentPinnedIdentity(
      deviceID: job.targetDeviceID,
      environment: environment),
      pinned.keyStatus == .active,
      targetKeyID == pinned.keyID,
      targetKeyGeneration == pinned.keyGeneration
    else {
      throw TatwoRemoteDispatchReadinessError.scopeMismatch("target_identity")
    }
    let requiredValues = [
      targetWorkspaceBindingID,
      targetWorkspaceBindingDigest,
      agentModelCapabilityDigest,
      activeSkillSetDigest,
      challengeNonce,
      readbackNonce,
    ]
    guard requiredValues.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else {
      throw TatwoRemoteDispatchReadinessError.invalidReceipt("empty_binding")
    }
    guard TatwoRemoteDispatchCanonicalDigest.isSHA256(targetWorkspaceBindingDigest),
      TatwoRemoteDispatchCanonicalDigest.isSHA256(agentModelCapabilityDigest),
      TatwoRemoteDispatchCanonicalDigest.isSHA256(activeSkillSetDigest)
    else {
      throw TatwoRemoteDispatchReadinessError.invalidReceipt("digest_format")
    }
  }

  func canonicalSigningPayload() throws -> Data {
    try unsignedPayload.canonicalData()
  }

  private var unsignedPayload: Unsigned {
    Unsigned(
      originDeviceID: originDeviceID,
      targetDeviceID: targetDeviceID,
      targetKeyID: targetKeyID,
      targetKeyGeneration: targetKeyGeneration,
      contractID: contractID,
      goalID: goalID,
      jobID: jobID,
      logicalJobID: logicalJobID,
      dispatchNonce: dispatchNonce,
      jobCanonicalDigest: jobCanonicalDigest,
      targetWorkspaceBindingID: targetWorkspaceBindingID,
      targetWorkspaceBindingDigest: targetWorkspaceBindingDigest,
      agentModelCapabilityDigest: agentModelCapabilityDigest,
      activeSkillSetDigest: activeSkillSetDigest,
      challengeNonce: challengeNonce,
      readbackNonce: readbackNonce,
      issuedAt: issuedAt,
      expiresAt: expiresAt)
  }

  private struct Unsigned: Codable {
    let schema = TatwoRemoteDispatchReadinessReceiptV1.schemaName
    let originDeviceID: String
    let targetDeviceID: String
    let targetKeyID: String
    let targetKeyGeneration: UInt64
    let contractID: String
    let goalID: String
    let jobID: String
    let logicalJobID: String
    let dispatchNonce: String
    let jobCanonicalDigest: String
    let targetWorkspaceBindingID: String
    let targetWorkspaceBindingDigest: String
    let agentModelCapabilityDigest: String
    let activeSkillSetDigest: String
    let challengeNonce: String
    let readbackNonce: String
    let issuedAt: Date
    let expiresAt: Date

    func canonicalData() throws -> Data {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(self)
    }

    func receipt(signature: TatwoDeviceSignatureV1)
      -> TatwoRemoteDispatchReadinessReceiptV1
    {
      TatwoRemoteDispatchReadinessReceiptV1(
        originDeviceID: originDeviceID,
        targetDeviceID: targetDeviceID,
        targetKeyID: targetKeyID,
        targetKeyGeneration: targetKeyGeneration,
        contractID: contractID,
        goalID: goalID,
        jobID: jobID,
        logicalJobID: logicalJobID,
        dispatchNonce: dispatchNonce,
        jobCanonicalDigest: jobCanonicalDigest,
        targetWorkspaceBindingID: targetWorkspaceBindingID,
        targetWorkspaceBindingDigest: targetWorkspaceBindingDigest,
        agentModelCapabilityDigest: agentModelCapabilityDigest,
        activeSkillSetDigest: activeSkillSetDigest,
        challengeNonce: challengeNonce,
        readbackNonce: readbackNonce,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
        targetSignature: signature)
    }
  }
}
