import Foundation

/// Explicit continuation modes understood by the Tatwo model-gateway.
///
/// `providerResume` is stronger than replaying a transcript. It may only be
/// claimed when the gateway returns a receipt proving that the same
/// provider-native session was resumed behind an opaque gateway handle.
public enum TatwoGatewayContinuationModeV1:
  String, Codable, Sendable, Equatable, Hashable
{
  case none
  case contextReplay = "context_replay"
  case providerResume = "provider_resume"
}

/// App-to-adapter continuation request.
///
/// The previous handle is gateway-opaque. It is never a raw Claude/Grok
/// session identifier and must remain bound to one Tatwo conversation,
/// adapter, and canonical model.
public struct TatwoGatewayContinuationRequestV1:
  Codable, Sendable, Equatable, Hashable
{
  public static let schemaName = "TatwoGatewayContinuationV1"

  public let schema: String
  public let mode: TatwoGatewayContinuationModeV1
  public let threadID: String
  public let discussionID: String?
  public let runtimeAdapterID: String
  public let canonicalModelID: String
  public let previousResponseHandle: String?
  public let previousGatewayInstanceID: String?
  public let contextSHA256: String

  private enum CodingKeys: String, CodingKey {
    case schema
    case mode
    case threadID = "thread_id"
    case discussionID = "discussion_id"
    case runtimeAdapterID = "runtime_adapter_id"
    case canonicalModelID = "canonical_model_id"
    case previousResponseHandle = "previous_response_handle"
    case previousGatewayInstanceID = "previous_gateway_instance_id"
    case contextSHA256 = "context_sha256"
  }

  public init(
    schema: String = Self.schemaName,
    mode: TatwoGatewayContinuationModeV1,
    threadID: String,
    discussionID: String? = nil,
    runtimeAdapterID: String,
    canonicalModelID: String,
    previousResponseHandle: String? = nil,
    previousGatewayInstanceID: String? = nil,
    contextSHA256: String
  ) {
    self.schema = schema
    self.mode = mode
    self.threadID = threadID
    self.discussionID = discussionID
    self.runtimeAdapterID = runtimeAdapterID
    self.canonicalModelID = canonicalModelID
    self.previousResponseHandle = previousResponseHandle
    self.previousGatewayInstanceID = previousGatewayInstanceID
    self.contextSHA256 = contextSHA256
  }

  public var isValid: Bool {
    guard schema == Self.schemaName,
      Self.isConversationID(threadID),
      discussionID.map(Self.isConversationID) ?? true,
      runtimeAdapterID == TatwoChatRuntimeAdapter.gatewayDirect.rawValue,
      Self.isCanonicalModelID(canonicalModelID),
      Self.isSHA256(contextSHA256)
    else {
      return false
    }
    switch mode {
    case .none, .contextReplay:
      return previousResponseHandle == nil
        && previousGatewayInstanceID == nil
    case .providerResume:
      return previousResponseHandle.map(Self.isOpaqueHandle) == true
        && previousGatewayInstanceID.map(Self.isConversationID) == true
    }
  }

  fileprivate static func isConversationID(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
      && trimmed.utf8.count <= 160
      && trimmed.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#,
        options: .regularExpression) != nil
  }

  fileprivate static func isCanonicalModelID(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
      && trimmed.utf8.count <= 120
      && trimmed.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#,
        options: .regularExpression) != nil
  }

  fileprivate static func isOpaqueHandle(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return (16...256).contains(trimmed.utf8.count)
      && trimmed.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#,
        options: .regularExpression) != nil
  }

  fileprivate static func isSHA256(_ value: String) -> Bool {
    value.range(
      of: #"^[a-f0-9]{64}$"#,
      options: .regularExpression) != nil
  }
}

/// Gateway-to-App continuation proof emitted only for an exact successful
/// terminal turn. The App does not advance its stored handle unless this
/// receipt matches the immutable outbound request.
public struct TatwoGatewayContinuationReceiptV1:
  Codable, Sendable, Equatable, Hashable
{
  public static let schemaName = "TatwoGatewayContinuationReceiptV1"

  public let schema: String
  public let requestedMode: TatwoGatewayContinuationModeV1
  public let appliedMode: TatwoGatewayContinuationModeV1
  public let threadID: String
  public let discussionID: String?
  public let runtimeAdapterID: String
  public let canonicalModelID: String
  public let previousResponseHandle: String?
  public let responseHandle: String
  public let contextSHA256: String
  public let gatewayInstanceID: String
  public let continuationSource: String
  public let providerSessionReused: Bool
  public let fallbackCount: UInt
  public let modelAttestationOutcome: String
  public let terminalStatus: String

  private enum CodingKeys: String, CodingKey {
    case schema
    case requestedMode = "requested_mode"
    case appliedMode = "applied_mode"
    case threadID = "thread_id"
    case discussionID = "discussion_id"
    case runtimeAdapterID = "runtime_adapter_id"
    case canonicalModelID = "canonical_model_id"
    case previousResponseHandle = "previous_response_handle"
    case responseHandle = "response_handle"
    case contextSHA256 = "context_sha256"
    case gatewayInstanceID = "gateway_instance_id"
    case continuationSource = "continuation_source"
    case providerSessionReused = "provider_session_reused"
    case fallbackCount = "fallback_count"
    case modelAttestationOutcome = "model_attestation_outcome"
    case terminalStatus = "terminal_status"
  }

  public init(
    schema: String = Self.schemaName,
    requestedMode: TatwoGatewayContinuationModeV1,
    appliedMode: TatwoGatewayContinuationModeV1,
    threadID: String,
    discussionID: String? = nil,
    runtimeAdapterID: String,
    canonicalModelID: String,
    previousResponseHandle: String? = nil,
    responseHandle: String,
    contextSHA256: String,
    gatewayInstanceID: String,
    continuationSource: String,
    providerSessionReused: Bool,
    fallbackCount: UInt,
    modelAttestationOutcome: String,
    terminalStatus: String
  ) {
    self.schema = schema
    self.requestedMode = requestedMode
    self.appliedMode = appliedMode
    self.threadID = threadID
    self.discussionID = discussionID
    self.runtimeAdapterID = runtimeAdapterID
    self.canonicalModelID = canonicalModelID
    self.previousResponseHandle = previousResponseHandle
    self.responseHandle = responseHandle
    self.contextSHA256 = contextSHA256
    self.gatewayInstanceID = gatewayInstanceID
    self.continuationSource = continuationSource
    self.providerSessionReused = providerSessionReused
    self.fallbackCount = fallbackCount
    self.modelAttestationOutcome = modelAttestationOutcome
    self.terminalStatus = terminalStatus
  }

  public func promotableHandle(
    matching request: TatwoGatewayContinuationRequestV1
  ) -> TatwoGatewayConversationHandleV1? {
    guard request.isValid,
      schema == Self.schemaName,
      requestedMode == request.mode,
      appliedMode == request.mode,
      threadID == request.threadID,
      discussionID == request.discussionID,
      runtimeAdapterID == request.runtimeAdapterID,
      canonicalModelID == request.canonicalModelID,
      previousResponseHandle == request.previousResponseHandle,
      (request.previousGatewayInstanceID.map {
        $0 == gatewayInstanceID
      } ?? true),
      contextSHA256 == request.contextSHA256,
      TatwoGatewayContinuationRequestV1.isOpaqueHandle(responseHandle),
      TatwoGatewayContinuationRequestV1.isConversationID(gatewayInstanceID),
      fallbackCount == 0,
      modelAttestationOutcome == "VERIFIED_EXACT",
      terminalStatus == "completed"
    else {
      return nil
    }

    switch request.mode {
    case .none:
      guard !providerSessionReused,
        continuationSource == "provider_session_started"
      else { return nil }
    case .contextReplay:
      guard !providerSessionReused,
        continuationSource == "gateway_replayed_input"
      else { return nil }
    case .providerResume:
      guard providerSessionReused,
        continuationSource == "provider_session_resumed",
        responseHandle != request.previousResponseHandle
      else { return nil }
    }

    return TatwoGatewayConversationHandleV1(
      opaqueResponseHandle: responseHandle,
      threadID: threadID,
      discussionID: discussionID,
      runtimeAdapterID: runtimeAdapterID,
      canonicalModelID: canonicalModelID,
      gatewayInstanceID: gatewayInstanceID)
  }
}

/// Durable App-side continuation pointer. This is deliberately separate from
/// `TatwoNativeAdapterSessionHandle`: the value is a gateway response handle,
/// not a provider session ID.
public struct TatwoGatewayConversationHandleV1:
  Codable, Sendable, Equatable, Hashable, Identifiable
{
  public static let schemaName = "TatwoGatewayConversationHandleV1"

  public let schema: String
  public let opaqueResponseHandle: String
  public let threadID: String
  public let discussionID: String?
  public let runtimeAdapterID: String
  public let canonicalModelID: String
  public let gatewayInstanceID: String
  public let updatedISO: String

  private enum CodingKeys: String, CodingKey {
    case schema
    case opaqueResponseHandle = "opaque_response_handle"
    case threadID = "thread_id"
    case discussionID = "discussion_id"
    case runtimeAdapterID = "runtime_adapter_id"
    case canonicalModelID = "canonical_model_id"
    case gatewayInstanceID = "gateway_instance_id"
    case updatedISO = "updated_iso"
  }

  public init(
    schema: String = Self.schemaName,
    opaqueResponseHandle: String,
    threadID: String,
    discussionID: String? = nil,
    runtimeAdapterID: String,
    canonicalModelID: String,
    gatewayInstanceID: String,
    updatedISO: String = ISO8601DateFormatter().string(from: Date())
  ) {
    self.schema = schema
    self.opaqueResponseHandle = opaqueResponseHandle
    self.threadID = threadID
    self.discussionID = discussionID
    self.runtimeAdapterID = runtimeAdapterID
    self.canonicalModelID = canonicalModelID
    self.gatewayInstanceID = gatewayInstanceID
    self.updatedISO = updatedISO
  }

  public var id: String {
    [
      runtimeAdapterID,
      canonicalModelID,
      threadID,
      discussionID ?? "thread",
    ].joined(separator: "|")
  }

  public var isValid: Bool {
    schema == Self.schemaName
      && TatwoGatewayContinuationRequestV1.isOpaqueHandle(opaqueResponseHandle)
      && TatwoGatewayContinuationRequestV1.isConversationID(threadID)
      && (discussionID.map(
        TatwoGatewayContinuationRequestV1.isConversationID) ?? true)
      && runtimeAdapterID == TatwoChatRuntimeAdapter.gatewayDirect.rawValue
      && TatwoGatewayContinuationRequestV1.isCanonicalModelID(canonicalModelID)
      && TatwoGatewayContinuationRequestV1.isConversationID(gatewayInstanceID)
  }
}

/// Stable gateway error class for a same-thread resume handle the adapter
/// no longer recognizes. After a gateway restart or TTL expiry the stored
/// opaque handle is stale; the turn must degrade to a handle-less replay
/// instead of failing the user.
public enum TatwoGatewayContinuationHandleErrorClassifierV1:
  Sendable, Equatable
{
  public static let unknownOrExpiredCode =
    "continuation_handle_unknown_or_expired"

  private static let exactTokens = [
    "continuation_handle_unknown_or_expired",
    "continuation_handle_unknown",
    "continuation_handle_expired",
    "previous_response_handle_unknown",
    "previous_response_handle_expired",
    "previous_response_id_unknown",
    "previous_response_id_expired",
    "handle_unknown_or_expired",
  ]

  public static func isUnknownOrExpiredHandleError(_ message: String) -> Bool {
    let lower = message
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !lower.isEmpty else { return false }
    if exactTokens.contains(where: { lower.contains($0) }) {
      return true
    }
    let mentionsContinuationHandle =
      lower.contains("continuation") && lower.contains("handle")
    let mentionsPreviousResponse =
      lower.contains("previous_response")
      || lower.contains("previous-response")
      || lower.contains("previous response")
    return (mentionsContinuationHandle || mentionsPreviousResponse)
      && (lower.contains("unknown") || lower.contains("expired"))
  }
}

public enum TatwoGatewayContinuationStaleHandleFallbackDecisionV1:
  Sendable, Equatable
{
  /// Retry this same turn once without the stale handle.
  case retryWithoutHandle
  /// Fallback already used, or the error is handle-class but not retryable.
  case surfaceFailure
  /// Not a stale-handle error. Leave the existing failure path alone.
  case notApplicable
}

/// Exactly-one handle-less fallback for a stale gateway continuation handle.
public enum TatwoGatewayContinuationStaleHandleFallbackV1:
  Sendable, Equatable
{
  public static func decide(
    errorMessage: String,
    request: TatwoGatewayContinuationRequestV1?,
    fallbackAlreadyAttempted: Bool
  ) -> TatwoGatewayContinuationStaleHandleFallbackDecisionV1 {
    guard TatwoGatewayContinuationHandleErrorClassifierV1
      .isUnknownOrExpiredHandleError(errorMessage)
    else {
      return .notApplicable
    }
    if fallbackAlreadyAttempted {
      return .surfaceFailure
    }
    guard let request,
      request.mode == .providerResume,
      request.previousResponseHandle != nil
    else {
      return .surfaceFailure
    }
    return .retryWithoutHandle
  }

  public static func shouldClearStoredHandle(
    errorMessage: String,
    request: TatwoGatewayContinuationRequestV1?
  ) -> Bool {
    TatwoGatewayContinuationHandleErrorClassifierV1
      .isUnknownOrExpiredHandleError(errorMessage)
      && request?.previousResponseHandle != nil
  }
}

extension TatwoGatewayContinuationRequestV1 {
  /// Fresh-send equivalent: drop the opaque resume pointer so the next
  /// dispatch rebuilds context from the local journal/recap path.
  public func handlelessFallbackRequest(
    rebuiltContextSHA256: String
  ) -> TatwoGatewayContinuationRequestV1 {
    TatwoGatewayContinuationRequestV1(
      schema: schema,
      mode: .none,
      threadID: threadID,
      discussionID: discussionID,
      runtimeAdapterID: runtimeAdapterID,
      canonicalModelID: canonicalModelID,
      previousResponseHandle: nil,
      previousGatewayInstanceID: nil,
      contextSHA256: rebuiltContextSHA256)
  }
}
