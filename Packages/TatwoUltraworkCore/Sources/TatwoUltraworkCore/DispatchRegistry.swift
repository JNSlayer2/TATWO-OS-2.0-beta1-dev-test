import CryptoKit
import Darwin
import Foundation
import TatwoDomainContracts

/// B2 (真分工橋) — the run/session registry.
///
/// Records each real dispatch of an identity-role subtask to a remote TATWO OS loop, keyed by
/// contractID, so the dashboard can show REAL running subs (and, when no session is live,
/// the last-known state) instead of a fake projection. It mirrors `TatwoGoalRunStore`'s
/// structure exactly (atomic writes, env-cascade directory, traversal-guarded filename) and
/// reuses that store's already-resolved base directory so the two never drift.
///
/// It deliberately does NOT gate itself on `requireIssuedContract`: the contract-authenticity
/// check happens once at the caller (the CLI `os dispatch` command / the gateway.dispatch
/// tool), exactly as `applyScenarioConfigMutation` gates before calling the config store.
public enum TatwoDispatchStatus: String, Codable, Sendable, Equatable, CaseIterable {
  /// Local presentation of remote-loop lifecycle.
  /// `verified` is origin acceptance (≠ completed execution terminal); must not fold into completed.
  case queued, running, completed, failed, verified

  /// Design 5.6-1 presentation labels for local dispatch status.
  /// Prefer `remoteStatus?.designSemanticLabel` when the remote five-state is known
  /// (covers wire `.accepted` → 已啟動(runner接受) which has no local case).
  public var designSemanticLabel: String {
    switch self {
    case .queued: return "已排隊"
    case .running: return "執行中"
    case .completed: return "已完成"
    case .failed: return "失敗"
    case .verified: return "已驗收"
    }
  }
}

public enum TatwoDispatchFailureClass: String, Codable, Sendable, Equatable, CaseIterable {
  case retryable
  case terminal
  case unknown

  public static func classify(code: String?, message: String?) -> TatwoDispatchFailureClass {
    let haystack = [code, message]
      .compactMap { $0?.lowercased() }
      .joined(separator: " ")
    if [
      "policy_violation", "policy violation", "scope_violation", "scope violation",
      "fatal", "invalid_contract", "unauthorized_host_mutation",
    ].contains(where: haystack.contains) {
      return .terminal
    }
    if [
      "server_error", "timeout", "timed out", "session_limit", "rate_limit",
      "rate limit", "network", "connection reset", "temporarily unavailable",
    ].contains(where: haystack.contains) {
      return .retryable
    }
    return .unknown
  }
}

public struct TatwoDispatchFailureReceipt: Codable, Sendable, Equatable {
  public let schema: String
  public let failureClass: TatwoDispatchFailureClass
  public let errorCode: String?
  public let httpStatus: Int?
  public let operatorMessage: String
  public let rawErrorDigest: String?
  public let backendRequestID: String?
  public let backendResponseID: String?
  public let occurredAt: Date

  public init(
    schema: String = "TatwoDispatchFailureReceiptV1",
    failureClass: TatwoDispatchFailureClass,
    errorCode: String?,
    httpStatus: Int?,
    operatorMessage: String,
    rawErrorDigest: String?,
    backendRequestID: String?,
    backendResponseID: String?,
    occurredAt: Date
  ) {
    self.schema = schema
    self.failureClass = failureClass
    self.errorCode = errorCode
    self.httpStatus = httpStatus
    self.operatorMessage = operatorMessage
    self.rawErrorDigest = rawErrorDigest
    self.backendRequestID = backendRequestID
    self.backendResponseID = backendResponseID
    self.occurredAt = occurredAt
  }

  static func sanitized(
    declaredClass: TatwoDispatchFailureClass?,
    errorCode: String?,
    httpStatus: Int?,
    rawErrorDigest: String?,
    backendRequestID: String?,
    backendResponseID: String?,
    rawError: String?,
    occurredAt: Date
  ) -> TatwoDispatchFailureReceipt {
    let rawMaterial = rawError ?? errorCode ?? "dispatch failed"
    let safeCode = safeErrorCode(errorCode)
    let inferredClass = TatwoDispatchFailureClass.classify(
      code: safeCode,
      message: rawError)
    let failureClass =
      declaredClass == nil || declaredClass == .unknown
      ? inferredClass
      : declaredClass ?? inferredClass
    let digest = validDigest(rawErrorDigest) ?? sha256(rawMaterial)
    return TatwoDispatchFailureReceipt(
      failureClass: failureClass,
      errorCode: safeCode,
      httpStatus: httpStatus,
      operatorMessage: operatorSummary(
        rawError ?? safeCode ?? "dispatch failed",
        errorCode: safeCode),
      rawErrorDigest: digest,
      backendRequestID: compact(backendRequestID, limit: 160),
      backendResponseID: compact(backendResponseID, limit: 160),
      occurredAt: occurredAt)
  }

  private static func operatorSummary(_ raw: String, errorCode: String?) -> String {
    let parsedObject: Any? = raw.data(using: .utf8).flatMap {
      try? JSONSerialization.jsonObject(with: $0)
    }
    var summary =
      parsedObject.flatMap(findMessage(in:))
      ?? (parsedObject == nil ? raw : "dispatch failed")
    summary = summary.replacingOccurrences(
      of: #""encrypted_content"\s*:\s*"[^"]*""#,
      with: "\"encrypted_content\":\"[redacted]\"",
      options: .regularExpression)
    summary = summary.replacingOccurrences(
      of: #"encrypted_content\s*[:=]\s*\S+"#,
      with: "encrypted_content=[redacted]",
      options: .regularExpression)
    summary = summary.replacingOccurrences(
      of: #"\b[A-Za-z0-9_-]{64,}\b"#,
      with: "[redacted-opaque]",
      options: .regularExpression)
    summary = TatwoPrivacyRedactor.redacted(summary)
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = errorCode.flatMap { compact($0, limit: 120) }
    if let prefix, !summary.lowercased().contains(prefix.lowercased()) {
      summary = "\(prefix): \(summary)"
    }
    return String(summary.prefix(512))
  }

  private static func findMessage(in value: Any) -> String? {
    if let dictionary = value as? [String: Any] {
      if let message = dictionary["message"] as? String, !message.isEmpty {
        return message
      }
      for key in ["error", "response"] {
        if let nested = dictionary[key], let message = findMessage(in: nested) {
          return message
        }
      }
      for nested in dictionary.values {
        if let message = findMessage(in: nested) { return message }
      }
    } else if let array = value as? [Any] {
      for nested in array {
        if let message = findMessage(in: nested) { return message }
      }
    }
    return nil
  }

  private static func safeErrorCode(_ value: String?) -> String? {
    guard let normalized = compact(value?.lowercased(), limit: 120) else { return nil }
    let known = Set([
      "server_error", "timeout", "session_limit", "rate_limit", "network_error",
      "connection_reset", "temporarily_unavailable", "policy_violation", "scope_violation",
      "fatal", "invalid_contract", "unauthorized_host_mutation", "response_failed",
      "degraded_completion", "operational_failure", "gateway_error",
      "channel_enqueue_failed", "cancelled", "tool_unavailable",
      "native_terminal_receipt_missing",
      "grok_dev_attestation_unverified",
      "single_model_runner_not_started",
    ])
    if known.contains(normalized) { return normalized }
    if normalized.range(of: #"^http_[1-5][0-9]{2}$"#, options: .regularExpression) != nil {
      return normalized
    }
    return "gateway_error"
  }

  private static func compact(_ value: String?, limit: Int) -> String? {
    guard let normalized = value?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !normalized.isEmpty
    else { return nil }
    return String(normalized.prefix(limit))
  }

  private static func validDigest(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.lowercased()
    guard normalized.hasPrefix("sha256:"),
      normalized.dropFirst("sha256:".count).count == 64,
      normalized.dropFirst("sha256:".count).allSatisfy(\.isHexDigit)
    else { return nil }
    return normalized
  }

  private static func sha256(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(digest)"
  }
}

public struct TatwoDispatchRecord: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let id: String
  public let contractID: String
  public let goalID: String?
  public let bindingID: String
  public let sourceSlotID: String
  public let identity: IdentityKind
  public let modelID: String
  public let subtask: String
  public let logicalDispatchID: String?
  public let supersedes: String?
  public let attempt: Int?
  /// Immutable dispatch-cycle membership. Legacy records decode as cycle 1.
  public let cycleEpoch: UInt64?
  public var status: TatwoDispatchStatus
  public let startedAt: Date
  public var updatedAt: Date
  public var receiptID: String?
  /// A pointer / truncated hash to the produced output — never the raw output or any secret.
  public var outputRef: String?
  public var errorMessage: String?
  public var failureReceipt: TatwoDispatchFailureReceipt?
  public let remoteJobID: String?
  public let originDeviceID: String?
  public let targetDeviceID: String?
  public var remoteStatus: TatwoLoopJobStatusV1?
  /// Signed job canonical digest bound at beginRemote (replay guard).
  public var remoteJobDigest: String?
  /// Non-reusable dispatch nonce from the bound job.
  public var remoteDispatchNonce: String?
  /// One-time consumed result digest (monotonic; state-changing converge path).
  public var consumedResultDigest: String?
  /// Monotonic projection sequence for terminal evidence updates.
  public var remoteProjectionSequence: UInt64?

  public init(
    schema: String = "TatwoDispatchRecordV1",
    id: String,
    contractID: String,
    goalID: String? = nil,
    bindingID: String,
    sourceSlotID: String,
    identity: IdentityKind,
    modelID: String,
    subtask: String,
    logicalDispatchID: String? = nil,
    supersedes: String? = nil,
    attempt: Int? = nil,
    cycleEpoch: UInt64? = nil,
    status: TatwoDispatchStatus,
    startedAt: Date,
    updatedAt: Date,
    receiptID: String? = nil,
    outputRef: String? = nil,
    errorMessage: String? = nil,
    failureReceipt: TatwoDispatchFailureReceipt? = nil,
    remoteJobID: String? = nil,
    originDeviceID: String? = nil,
    targetDeviceID: String? = nil,
    remoteStatus: TatwoLoopJobStatusV1? = nil,
    remoteJobDigest: String? = nil,
    remoteDispatchNonce: String? = nil,
    consumedResultDigest: String? = nil,
    remoteProjectionSequence: UInt64? = nil
  ) {
    self.schema = schema
    self.id = id
    self.contractID = contractID
    self.goalID = goalID
    self.bindingID = bindingID
    self.sourceSlotID = sourceSlotID
    self.identity = identity
    self.modelID = modelID
    self.subtask = subtask
    self.logicalDispatchID = logicalDispatchID
    self.supersedes = supersedes
    self.attempt = attempt
    self.cycleEpoch = cycleEpoch
    self.status = status
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.receiptID = receiptID
    self.outputRef = outputRef
    self.errorMessage = errorMessage
    self.failureReceipt = failureReceipt
    self.remoteJobID = remoteJobID
    self.originDeviceID = originDeviceID
    self.targetDeviceID = targetDeviceID
    self.remoteStatus = remoteStatus
    self.remoteJobDigest = remoteJobDigest
    self.remoteDispatchNonce = remoteDispatchNonce
    self.consumedResultDigest = consumedResultDigest
    self.remoteProjectionSequence = remoteProjectionSequence
  }

  public var resolvedLogicalDispatchID: String {
    logicalDispatchID ?? id
  }

  public var resolvedAttempt: Int {
    attempt ?? 1
  }

  public var resolvedCycleEpoch: UInt64 {
    cycleEpoch ?? 1
  }
}

/// Append-only immutable boundary for one dispatch cycle.
///
/// `sealID` freezes membership for exactly one epoch. Sealing a cycle never
/// means that the parent GoalRun passed.
public struct TatwoDispatchCycleSealV1: Codable, Sendable, Equatable {
  public let schema: String
  public let epoch: UInt64
  public let sealID: String
  public let sealedAt: Date
  public let recordIDs: [String]
  public let goalID: String?
  public let migratedLegacy: Bool

  public init(
    schema: String = "TatwoDispatchCycleSealV1",
    epoch: UInt64,
    sealID: String,
    sealedAt: Date,
    recordIDs: [String],
    goalID: String?,
    migratedLegacy: Bool = false
  ) {
    self.schema = schema
    self.epoch = epoch
    self.sealID = sealID
    self.sealedAt = sealedAt
    self.recordIDs = recordIDs.sorted()
    self.goalID = goalID
    self.migratedLegacy = migratedLegacy
  }
}

public struct TatwoStoredDispatchRun: Codable, Sendable, Equatable {
  public var schema: String
  public let contractID: String
  /// Canonical complete dispatch plan. Legacy runs may decode with `nil`, but
  /// every new authority transaction must persist this value before pointer
  /// publication.
  public var executionManifest: TatwoExecutionManifestV1?
  public var executionManifestSHA256: String?
  public var manifestEntryIDs: [String]
  public var records: [TatwoDispatchRecord]
  public var updatedAt: Date
  public var sealID: String?
  public var sealedAt: Date?
  public var sealedRecordIDs: [String]?
  public var sealedGoalID: String?
  /// Active/open epoch. At a sealed boundary it equals the latest seal epoch;
  /// after an explicit advance it is latestSeal.epoch + 1.
  public var activeCycleEpoch: UInt64?
  /// Append-only seal history. Legacy single-seal fields remain as read aliases.
  public var cycleSeals: [TatwoDispatchCycleSealV1]?

  public init(
    schema: String = "TatwoStoredDispatchRunV1",
    contractID: String,
    executionManifest: TatwoExecutionManifestV1? = nil,
    executionManifestSHA256: String? = nil,
    manifestEntryIDs: [String] = [],
    records: [TatwoDispatchRecord] = [],
    updatedAt: Date = Date(),
    sealID: String? = nil,
    sealedAt: Date? = nil,
    sealedRecordIDs: [String]? = nil,
    sealedGoalID: String? = nil,
    activeCycleEpoch: UInt64? = nil,
    cycleSeals: [TatwoDispatchCycleSealV1]? = nil
  ) {
    self.schema = schema
    self.contractID = contractID
    self.executionManifest = executionManifest
    self.executionManifestSHA256 = executionManifestSHA256
    self.manifestEntryIDs = manifestEntryIDs
    self.records = records
    self.updatedAt = updatedAt
    self.sealID = sealID
    self.sealedAt = sealedAt
    self.sealedRecordIDs = sealedRecordIDs
    self.sealedGoalID = sealedGoalID
    self.activeCycleEpoch = activeCycleEpoch
    self.cycleSeals = cycleSeals
  }
}

public enum TatwoDispatchRegistryError: Error, LocalizedError, Sendable, Equatable {
  case invalidContractID(String)
  case unknownDispatch(String)
  case helperCapReached(cap: Int, existing: Int)
  case cannotSealEmpty(String)
  case cannotSealIncomplete([String])
  case runSealed(String)
  case sealedSetMismatch(String)
  case invalidCycleLedger(String)
  case staleCycleBoundary(expected: String, actual: String)
  case invalidSupersedes(String)
  case logicalDispatchMismatch(expected: String, actual: String)
  case immutableDispatch(id: String, status: TatwoDispatchStatus)
  case supersedesGoalMismatch(parent: String)
  case terminalDispatchCannotRetry(String)
  case retryBudgetExhausted(String)
  /// Stale projection attempted to move `remoteStatus` backwards (e.g. completed → running).
  case remoteStatusRegression(from: TatwoLoopJobStatusV1, to: TatwoLoopJobStatusV1)
  /// beginRemote / converge job digest or dispatch nonce does not match registry binding.
  case remoteJobBindingMismatch(jobID: String, detail: String)
  /// Terminal/verified evidence cannot be overwritten by stale receipt/output.
  case terminalEvidenceRegression(jobID: String, detail: String)
  /// State-changing result consume conflicts with prior consumed digest.
  case resultConsumeConflict(jobID: String, detail: String)
  case manifestConflict(String)
  case manifestReadbackMismatch(String)

  public var errorDescription: String? {
    switch self {
    case .invalidContractID(let id): return "Invalid contractID for dispatch storage: \(id)"
    case .unknownDispatch(let id): return "Unknown dispatch id: \(id)"
    case .helperCapReached(let cap, let existing):
      return "Helper cap reached: \(cap) allowed, \(existing) already dispatched for this contract"
    case .cannotSealEmpty(let contractID):
      return "Cannot seal empty dispatch set for \(contractID)"
    case .cannotSealIncomplete(let dispatchIDs):
      return "Cannot seal incomplete dispatches: \(dispatchIDs.joined(separator: ", "))"
    case .runSealed(let sealID):
      return "Dispatch run is sealed: \(sealID)"
    case .sealedSetMismatch(let sealID):
      return "Sealed dispatch set no longer matches its receipt: \(sealID)"
    case .invalidCycleLedger(let detail):
      return "Invalid dispatch cycle ledger: \(detail)"
    case let .staleCycleBoundary(expected, actual):
      return "Stale dispatch cycle boundary: expected \(expected), latest is \(actual)"
    case .invalidSupersedes(let dispatchID):
      return "Dispatch retry must supersede the active failed head: \(dispatchID)"
    case let .logicalDispatchMismatch(expected, actual):
      return "Retry logicalDispatchID mismatch: expected \(expected), got \(actual)"
    case let .immutableDispatch(id, status):
      return "Dispatch \(id) is immutable after \(status.rawValue)."
    case .supersedesGoalMismatch(let id):
      return "Dispatch retry cannot cross GoalRun scope: \(id)"
    case .terminalDispatchCannotRetry(let id):
      return "Terminal dispatch cannot be superseded: \(id)"
    case .retryBudgetExhausted(let logicalID):
      return "Retry budget exhausted for logical dispatch: \(logicalID)"
    case let .remoteStatusRegression(from, to):
      return "Remote status regression rejected: \(from.rawValue) -> \(to.rawValue)"
    case let .remoteJobBindingMismatch(jobID, detail):
      return "Remote job binding mismatch for \(jobID): \(detail)"
    case let .terminalEvidenceRegression(jobID, detail):
      return "Terminal evidence regression for \(jobID): \(detail)"
    case let .resultConsumeConflict(jobID, detail):
      return "Result consume conflict for \(jobID): \(detail)"
    case .manifestConflict(let contractID):
      return "Execution manifest conflicts with durable run \(contractID)."
    case .manifestReadbackMismatch(let contractID):
      return "Execution manifest exact readback mismatch for \(contractID)."
    }
  }
}

public struct TatwoDispatchRegistry: Sendable {
  public let directoryURL: URL
  public let originAuthorityProvider: any TatwoOriginAuthorityProviding

  public init(
    directoryURL: URL,
    originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil
  ) {
    self.directoryURL = directoryURL
    self.originAuthorityProvider =
      originAuthorityProvider ?? TatwoDefaultOriginAuthorityProvider()
  }

  /// Reuses `TatwoGoalRunStore`'s already-resolved base directory so the dispatch registry
  /// and the goal store always agree (one env cascade, no second resolver to drift).
  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil
  ) -> TatwoDispatchRegistry {
    TatwoDispatchRegistry(
      directoryURL: TatwoGoalRunStore.default(environment: environment).directoryURL,
      originAuthorityProvider: originAuthorityProvider)
  }

  // MARK: Manifest

  @discardableResult
  func recordManifest(_ manifest: TatwoExecutionManifestV1) throws -> TatwoStoredDispatchRun {
    let url = try fileURL(forContractID: manifest.contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      var run = try loadOrCreateRun(contractID: manifest.contractID)
      try materializeCycleLedger(&run)
      try requireActiveCycleOpen(run)
      let digest = try manifest.canonicalSHA256()
      if let existing = run.executionManifest {
        guard run.schema == "TatwoStoredDispatchRunV2",
          existing == manifest,
          run.executionManifestSHA256 == digest,
          run.manifestEntryIDs == manifest.entries.map(\.id)
        else {
          throw TatwoDispatchRegistryError.manifestConflict(
            manifest.contractID)
        }
        return run
      }
      guard run.records.isEmpty,
        run.sealID == nil,
        run.sealedAt == nil,
        run.sealedRecordIDs == nil,
        run.sealedGoalID == nil,
        (run.cycleSeals ?? []).isEmpty,
        run.manifestEntryIDs.isEmpty
          || run.manifestEntryIDs == manifest.entries.map(\.id)
      else {
        throw TatwoDispatchRegistryError.manifestConflict(
          manifest.contractID)
      }
      run.executionManifest = manifest
      run.executionManifestSHA256 = digest
      run.manifestEntryIDs = manifest.entries.map(\.id)
      run.schema = "TatwoStoredDispatchRunV2"
      run.updatedAt = manifest.generatedAt
      try write(run)
      guard let readback = try self.run(
        forContractID: manifest.contractID),
        readback.executionManifest == manifest,
        readback.executionManifestSHA256 == digest,
        readback.manifestEntryIDs == manifest.entries.map(\.id)
      else {
        throw TatwoDispatchRegistryError.manifestReadbackMismatch(
          manifest.contractID)
      }
      return readback
    }
  }

  func requireExecutionManifest(
    contractID: String,
    expectedSHA256: String? = nil
  ) throws -> TatwoExecutionManifestV1 {
    guard let run = try run(forContractID: contractID),
      run.schema == "TatwoStoredDispatchRunV2",
      let manifest = run.executionManifest,
      let digest = run.executionManifestSHA256,
      digest == (try manifest.canonicalSHA256()),
      expectedSHA256 == nil || expectedSHA256 == digest,
      run.manifestEntryIDs == manifest.entries.map(\.id)
    else {
      throw TatwoDispatchRegistryError.manifestReadbackMismatch(
        contractID)
    }
    return manifest
  }

  // MARK: Dispatch lifecycle

  @discardableResult
  func begin(
    contractID: String,
    goalID: String? = nil,
    bindingID: String,
    sourceSlotID: String,
    identity: IdentityKind,
    modelID: String,
    subtask: String,
    logicalDispatchID: String? = nil,
    supersedes: String? = nil,
    retryAttemptCap: Int = 2,
    helperCap: Int? = nil,
    now: Date = Date(),
    remoteJobID: String? = nil,
    originDeviceID: String? = nil,
    targetDeviceID: String? = nil,
    remoteStatus: TatwoLoopJobStatusV1? = nil,
    remoteJobDigest: String? = nil,
    remoteDispatchNonce: String? = nil
  ) throws -> TatwoDispatchRecord {
    let url = try fileURL(forContractID: contractID)
    // B1/#3: hold a cross-process lock across read → cap-check → append → write so two
    // simultaneous begins can't both pass the helper cap or clobber each other's record.
    return try TatwoFileLock.withExclusiveLock(for: url) {
      var run = try loadOrCreateRun(contractID: contractID)
      try materializeCycleLedger(&run)
      try requireActiveCycleOpen(run)
      let cycleEpoch = try activeCycleEpoch(in: run)
      // The cap bounds CONCURRENT helpers (queued/running), not lifetime dispatches — a
      // completed helper frees its slot, so a long run (e.g. an arena exam grading many
      // models over time on one contract) is never permanently blocked by its own history.
      if let helperCap {
        let activeCount = run.records.filter { $0.status == .queued || $0.status == .running }.count
        if activeCount >= helperCap {
          throw TatwoDispatchRegistryError.helperCapReached(cap: helperCap, existing: activeCount)
        }
      }
      let previous: TatwoDispatchRecord?
      if let supersedes {
        guard let candidate = run.records.first(where: { $0.id == supersedes }),
          candidate.status == .failed,
          !run.records.contains(where: { $0.supersedes == supersedes })
        else {
          throw TatwoDispatchRegistryError.invalidSupersedes(supersedes)
        }
        guard candidate.goalID == goalID else {
          throw TatwoDispatchRegistryError.supersedesGoalMismatch(parent: supersedes)
        }
        guard candidate.failureReceipt?.failureClass != .terminal else {
          throw TatwoDispatchRegistryError.terminalDispatchCannotRetry(supersedes)
        }
        guard candidate.resolvedAttempt < retryAttemptCap else {
          throw TatwoDispatchRegistryError.retryBudgetExhausted(
            candidate.resolvedLogicalDispatchID)
        }
        previous = candidate
      } else {
        previous = nil
      }
      let resolvedLogicalID: String
      if let previous {
        let inherited = previous.resolvedLogicalDispatchID
        if let logicalDispatchID, logicalDispatchID != inherited {
          throw TatwoDispatchRegistryError.logicalDispatchMismatch(
            expected: inherited,
            actual: logicalDispatchID)
        }
        resolvedLogicalID = inherited
      } else if let logicalDispatchID, !logicalDispatchID.isEmpty {
        resolvedLogicalID = logicalDispatchID
      } else {
        resolvedLogicalID =
          "logical-\(bindingID)-\(Int(now.timeIntervalSince1970 * 1000))-\(run.records.count)"
      }
      let attempt = (previous?.resolvedAttempt ?? 0) + 1
      let record = TatwoDispatchRecord(
        id: "dispatch-\(bindingID)-\(Int(now.timeIntervalSince1970 * 1000))-\(run.records.count)",
        contractID: contractID,
        goalID: goalID,
        bindingID: bindingID,
        sourceSlotID: sourceSlotID,
        identity: identity,
        modelID: modelID,
        subtask: subtask,
        logicalDispatchID: resolvedLogicalID,
        supersedes: supersedes,
        attempt: attempt,
        cycleEpoch: cycleEpoch,
        status: .queued,
        startedAt: now,
        updatedAt: now,
        remoteJobID: remoteJobID,
        originDeviceID: originDeviceID,
        targetDeviceID: targetDeviceID,
        remoteStatus: remoteStatus,
        remoteJobDigest: remoteJobDigest,
        remoteDispatchNonce: remoteDispatchNonce)
      run.records.append(record)
      run.updatedAt = now
      try write(run)
      return record
    }
  }

  @discardableResult
  func beginRemote(
    job: TatwoLoopJobV1,
    issuedBinding: TatwoIssuedIdentityBindingV1
  ) throws -> TatwoDispatchRecord {
    try job.validate()
    guard issuedBinding.identity == job.identity else {
      throw TatwoDispatchRegistryError.remoteJobBindingMismatch(
        jobID: job.jobID,
        detail: "issued binding identity does not match job")
    }
    guard let issuedModelID = issuedBinding.modelID,
      !issuedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw TatwoDispatchRegistryError.remoteJobBindingMismatch(
        jobID: job.jobID,
        detail: "issued binding has no persistable model ID")
    }
    if case let .tatwoLoop(payload) = job.payload {
      guard let exactModelRouteID = payload.exactModelRouteID,
        TatwoGatewayDispatchCatalog.normalize(exactModelRouteID)
          == TatwoGatewayDispatchCatalog.normalize(issuedModelID)
      else {
        throw TatwoDispatchRegistryError.remoteJobBindingMismatch(
          jobID: job.jobID,
          detail: "issued binding model does not match exact remote route")
      }
    }
    return try beginRemote(
      job: job,
      bindingID: issuedBinding.id,
      sourceSlotID: issuedBinding.sourceSlotID,
      modelID: issuedModelID,
      requireExactIssuedBinding: true)
  }

  /// Test-only fixture seam for registry mechanics that intentionally have no
  /// issued GoalRun binding. Production callers must use `beginRemote(job:issuedBinding:)`.
  @discardableResult
  func beginRemoteTestFixtureUnbound(job: TatwoLoopJobV1) throws -> TatwoDispatchRecord {
    try beginRemote(
      job: job,
      bindingID: "remote-loop-\(job.jobID)",
      sourceSlotID: "remote:\(job.targetDeviceID)",
      modelID: "tatwo-os-loop",
      requireExactIssuedBinding: false)
  }

  private func beginRemote(
    job: TatwoLoopJobV1,
    bindingID: String,
    sourceSlotID: String,
    modelID: String,
    requireExactIssuedBinding: Bool
  ) throws -> TatwoDispatchRecord {
    try job.validate()
    let digest = try job.canonicalDigest()
    let authorityEpoch = originAuthorityProvider.authorityEpoch ?? 0
    try originAuthorityProvider.requireOriginAuthority(
      deviceID: job.originDeviceID,
      epoch: authorityEpoch,
      surface: "dispatch_registry_begin_remote",
      now: Date())
    let url = try fileURL(forContractID: job.contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      var run = try loadOrCreateRun(contractID: job.contractID)
      try materializeCycleLedger(&run)
      if let index = run.records.firstIndex(where: { $0.remoteJobID == job.jobID }) {
        var existing = run.records[index]
        if requireExactIssuedBinding {
          guard existing.bindingID == bindingID,
            existing.sourceSlotID == sourceSlotID,
            existing.identity == job.identity,
            existing.modelID == modelID
          else {
            throw TatwoDispatchRegistryError.remoteJobBindingMismatch(
              jobID: job.jobID,
              detail: "existing record does not match exact issued binding")
          }
        }
        if let boundDigest = existing.remoteJobDigest {
          guard boundDigest == digest,
            existing.remoteDispatchNonce == job.dispatchNonce
          else {
            throw TatwoDispatchRegistryError.remoteJobBindingMismatch(
              jobID: job.jobID,
              detail: "existing record digest/nonce does not match job")
          }
          return existing
        }
        // Legacy unbound record: claim binding once if still non-terminal.
        if let status = existing.remoteStatus,
          [.completed, .failed, .cancelled, .verified].contains(status)
        {
          throw TatwoDispatchRegistryError.remoteJobBindingMismatch(
            jobID: job.jobID,
            detail: "cannot rebind terminal record without matching digest")
        }
        existing.remoteJobDigest = digest
        existing.remoteDispatchNonce = job.dispatchNonce
        existing.updatedAt = Date()
        run.records[index] = existing
        run.updatedAt = existing.updatedAt
        try write(run)
        return existing
      }
      try requireActiveCycleOpen(run)
      let cycleEpoch = try activeCycleEpoch(in: run)
      let now = job.createdAt
      let attempt = try Self.nextRemoteAttempt(
        logicalJobID: job.logicalJobID,
        records: run.records.filter { $0.resolvedCycleEpoch == cycleEpoch })
      let record = TatwoDispatchRecord(
        id:
          "dispatch-remote-loop-\(job.jobID)-\(Int(now.timeIntervalSince1970 * 1000))-\(run.records.count)",
        contractID: job.contractID,
        goalID: job.goalID,
        bindingID: bindingID,
        sourceSlotID: sourceSlotID,
        identity: job.identity,
        modelID: modelID,
        subtask: "remote loop job \(job.jobID)",
        logicalDispatchID: job.logicalJobID,
        attempt: attempt,
        cycleEpoch: cycleEpoch,
        status: .queued,
        startedAt: now,
        updatedAt: now,
        remoteJobID: job.jobID,
        originDeviceID: job.originDeviceID,
        targetDeviceID: job.targetDeviceID,
        remoteStatus: .queued,
        remoteJobDigest: digest,
        remoteDispatchNonce: job.dispatchNonce)
      run.records.append(record)
      run.updatedAt = now
      try write(run)
      return record
    }
  }

  /// Target-side local projection mirror for an inbound remote job.
  ///
  /// Creates a display/ledger record when the target has no prior run for this
  /// `jobID`. Same-jobID re-entry is idempotent: existing origin or inbound
  /// records with matching digest/nonce are returned unchanged (never duplicated
  /// or overwritten). Local mirror only — not used for signature verification,
  /// claim, or consume decisions.
  @discardableResult
  public func ensureInboundRemoteMirror(job: TatwoLoopJobV1) throws -> TatwoDispatchRecord {
    try job.validate()
    let digest = try job.canonicalDigest()
    let url = try fileURL(forContractID: job.contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      var run = try loadOrCreateRun(contractID: job.contractID)
      try materializeCycleLedger(&run)
      if let index = run.records.firstIndex(where: { $0.remoteJobID == job.jobID }) {
        var existing = run.records[index]
        if let boundDigest = existing.remoteJobDigest {
          guard boundDigest == digest,
            existing.remoteDispatchNonce == job.dispatchNonce
          else {
            throw TatwoDispatchRegistryError.remoteJobBindingMismatch(
              jobID: job.jobID,
              detail: "existing record digest/nonce does not match inbound job")
          }
          // Idempotent: preserve origin-side or prior inbound fields as-is.
          return existing
        }
        if let status = existing.remoteStatus,
          [.completed, .failed, .cancelled, .verified].contains(status)
        {
          throw TatwoDispatchRegistryError.remoteJobBindingMismatch(
            jobID: job.jobID,
            detail: "cannot rebind terminal record without matching digest")
        }
        existing.remoteJobDigest = digest
        existing.remoteDispatchNonce = job.dispatchNonce
        existing.updatedAt = Date()
        run.records[index] = existing
        run.updatedAt = existing.updatedAt
        try write(run)
        return existing
      }
      try requireActiveCycleOpen(run)
      let cycleEpoch = try activeCycleEpoch(in: run)
      let now = job.createdAt
      let attempt = try Self.nextRemoteAttempt(
        logicalJobID: job.logicalJobID,
        records: run.records.filter { $0.resolvedCycleEpoch == cycleEpoch })
      let record = TatwoDispatchRecord(
        id:
          "dispatch-inbound-remote-loop-\(job.jobID)-\(Int(now.timeIntervalSince1970 * 1000))-\(run.records.count)",
        contractID: job.contractID,
        goalID: job.goalID,
        bindingID: "inbound-remote-loop-\(job.jobID)",
        sourceSlotID: "inbound-remote:\(job.originDeviceID)",
        identity: job.identity,
        modelID: "tatwo-os-loop",
        subtask: "inbound remote loop job \(job.jobID)",
        logicalDispatchID: job.logicalJobID,
        attempt: attempt,
        cycleEpoch: cycleEpoch,
        status: .queued,
        startedAt: now,
        updatedAt: now,
        remoteJobID: job.jobID,
        originDeviceID: job.originDeviceID,
        targetDeviceID: job.targetDeviceID,
        remoteStatus: .queued,
        remoteJobDigest: digest,
        remoteDispatchNonce: job.dispatchNonce)
      run.records.append(record)
      run.updatedAt = now
      try write(run)
      return record
    }
  }

  /// Verify channel job matches the registry binding before state-changing converge.
  public func requireRemoteJobBinding(job: TatwoLoopJobV1) throws -> TatwoDispatchRecord {
    try job.validate()
    let digest = try job.canonicalDigest()
    guard let record = try run(forContractID: job.contractID)?.records.first(where: {
      $0.remoteJobID == job.jobID
    }) else {
      throw TatwoDispatchRegistryError.unknownDispatch(job.jobID)
    }
    guard let boundDigest = record.remoteJobDigest else {
      throw TatwoDispatchRegistryError.remoteJobBindingMismatch(
        jobID: job.jobID,
        detail: "registry missing signed job digest")
    }
    guard boundDigest == digest else {
      throw TatwoDispatchRegistryError.remoteJobBindingMismatch(
        jobID: job.jobID,
        detail: "signed job digest mismatch")
    }
    guard record.remoteDispatchNonce == job.dispatchNonce else {
      throw TatwoDispatchRegistryError.remoteJobBindingMismatch(
        jobID: job.jobID,
        detail: "dispatch nonce mismatch")
    }
    return record
  }

  @discardableResult
  func update(
    contractID: String,
    dispatchID: String,
    status: TatwoDispatchStatus,
    receiptID: String? = nil,
    outputRef: String? = nil,
    failureClass: TatwoDispatchFailureClass? = nil,
    errorCode: String? = nil,
    httpStatus: Int? = nil,
    rawErrorDigest: String? = nil,
    backendRequestID: String? = nil,
    backendResponseID: String? = nil,
    errorMessage: String? = nil,
    now: Date = Date()
  ) throws -> TatwoDispatchRecord {
    let url = try fileURL(forContractID: contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      guard var run = try run(forContractID: contractID),
        let index = run.records.firstIndex(where: { $0.id == dispatchID })
      else {
        throw TatwoDispatchRegistryError.unknownDispatch(dispatchID)
      }
      try materializeCycleLedger(&run)
      try requireActiveCycleOpen(run)
      try requireRecordInActiveCycle(run.records[index], run: run)
      let persisted = run.records[index]
      if persisted.status == .failed
        || persisted.status == .completed
        || persisted.status == .verified
      {
        throw TatwoDispatchRegistryError.immutableDispatch(
          id: persisted.id,
          status: persisted.status)
      }
      run.records[index].status = status
      run.records[index].updatedAt = now
      if let receiptID { run.records[index].receiptID = receiptID }
      if let outputRef { run.records[index].outputRef = outputRef }
      if status == .failed {
        let receipt = TatwoDispatchFailureReceipt.sanitized(
          declaredClass: failureClass,
          errorCode: errorCode,
          httpStatus: httpStatus,
          rawErrorDigest: rawErrorDigest,
          backendRequestID: backendRequestID,
          backendResponseID: backendResponseID,
          rawError: errorMessage,
          occurredAt: now)
        run.records[index].failureReceipt = receipt
        run.records[index].errorMessage = receipt.operatorMessage
      } else if let errorMessage {
        run.records[index].errorMessage = String(
          TatwoPrivacyRedactor.redacted(errorMessage).prefix(512))
      }
      run.updatedAt = now
      try write(run)
      return run.records[index]
    }
  }

  @discardableResult
  public func projectRemoteStatus(
    contractID: String,
    remoteJobID: String,
    remoteStatus: TatwoLoopJobStatusV1? = nil,
    receiptID: String? = nil,
    outputRef: String? = nil,
    failureCode: String? = nil,
    errorMessage: String? = nil,
    resultDigest: String? = nil,
    projectionSequence: UInt64? = nil,
    now: Date = Date()
  ) throws -> TatwoDispatchRecord {
    let url = try fileURL(forContractID: contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      guard var run = try run(forContractID: contractID),
        let index = run.records.firstIndex(where: { $0.remoteJobID == remoteJobID })
      else {
        throw TatwoDispatchRegistryError.unknownDispatch(remoteJobID)
      }
      try materializeCycleLedger(&run)
      try requireActiveCycleOpen(run)
      try requireRecordInActiveCycle(run.records[index], run: run)
      var record = run.records[index]
      let authorityEpoch = originAuthorityProvider.authorityEpoch ?? 0
      try originAuthorityProvider.requireOriginAuthority(
        deviceID: record.originDeviceID ?? "",
        epoch: authorityEpoch,
        surface: "dispatch_registry_project_remote_status",
        now: now)
      let priorStatus = record.remoteStatus
      let terminalLocked = Self.isTerminalOrVerified(priorStatus)

      // nil remoteStatus path: never rewrite terminal evidence.
      if remoteStatus == nil {
        if terminalLocked,
          receiptID != nil || outputRef != nil || failureCode != nil || errorMessage != nil
            || resultDigest != nil || projectionSequence != nil
        {
          try Self.rejectEvidenceMutationUnlessIdentical(
            record: record,
            receiptID: receiptID,
            outputRef: outputRef,
            resultDigest: resultDigest,
            failureCode: failureCode,
            errorMessage: errorMessage,
            remoteJobID: remoteJobID,
            detail: "nil remoteStatus cannot mutate terminal evidence")
        } else if !terminalLocked {
          if let receiptID { record.receiptID = receiptID }
          if let outputRef { record.outputRef = outputRef }
          if let resultDigest {
            try Self.mergeConsumedResultDigest(
              into: &record,
              resultDigest: resultDigest,
              remoteJobID: remoteJobID)
          }
        }
        record.updatedAt = now
        run.records[index] = record
        run.updatedAt = now
        try write(run)
        return record
      }

      let remoteStatus = remoteStatus!
      if let current = priorStatus,
        !TatwoLoopJobStatusV1.allowsRemoteStatusProjection(from: current, to: remoteStatus)
      {
        throw TatwoDispatchRegistryError.remoteStatusRegression(
          from: current,
          to: remoteStatus)
      }

      let nextTerminal = Self.isTerminalOrVerified(remoteStatus)
      if terminalLocked || nextTerminal {
        try Self.mergeTerminalEvidence(
          into: &record,
          remoteJobID: remoteJobID,
          receiptID: receiptID,
          outputRef: outputRef,
          resultDigest: resultDigest,
          projectionSequence: projectionSequence,
          failureCode: failureCode,
          errorMessage: errorMessage,
          remoteStatus: remoteStatus,
          now: now)
      } else {
        if let receiptID { record.receiptID = receiptID }
        if let outputRef { record.outputRef = outputRef }
        if let resultDigest {
          try Self.mergeConsumedResultDigest(
            into: &record,
            resultDigest: resultDigest,
            remoteJobID: remoteJobID)
        }
        if let projectionSequence {
          let currentSeq = record.remoteProjectionSequence ?? 0
          guard projectionSequence >= currentSeq else {
            throw TatwoDispatchRegistryError.terminalEvidenceRegression(
              jobID: remoteJobID,
              detail: "projection sequence regression")
          }
          record.remoteProjectionSequence = projectionSequence
        }
      }

      record.remoteStatus = remoteStatus
      switch remoteStatus {
      case .queued, .delivered, .accepted:
        // Early remote states map to local queued; never regress completed/failed/verified.
        if record.status != .completed, record.status != .failed, record.status != .verified {
          record.status = .queued
        }
      case .running:
        if record.status != .completed, record.status != .failed, record.status != .verified {
          record.status = .running
        }
      case .completed:
        // Target-signed execution terminal only — not origin acceptance.
        if record.status != .failed, record.status != .verified {
          record.status = .completed
        }
      case .verified:
        // H3/C2: origin acceptance is an independent presentation value; never fold to completed.
        // Keep failed when channel verified a failed/cancelled attempt after origin consume.
        if record.status != .failed {
          record.status = .verified
        }
      case .failed, .cancelled:
        record.status = .failed
        // mergeTerminalEvidence already applied write-once failure evidence when terminal.
        // Non-terminal→failed first write only when still empty after merge path.
        if record.failureReceipt == nil {
          let receipt = TatwoDispatchFailureReceipt.sanitized(
            declaredClass: remoteStatus == .cancelled ? .terminal : nil,
            errorCode: failureCode ?? remoteStatus.rawValue,
            httpStatus: nil,
            rawErrorDigest: nil,
            backendRequestID: nil,
            backendResponseID: nil,
            rawError: errorMessage ?? "remote loop job \(remoteStatus.rawValue)",
            occurredAt: now)
          record.failureReceipt = receipt
          record.errorMessage = receipt.operatorMessage
        }
      }
      record.updatedAt = now
      run.records[index] = record
      run.updatedAt = now
      try write(run)
      return record
    }
  }

  private static func isTerminalOrVerified(_ status: TatwoLoopJobStatusV1?) -> Bool {
    guard let status else { return false }
    switch status {
    case .completed, .failed, .cancelled, .verified:
      return true
    case .queued, .delivered, .accepted, .running:
      return false
    }
  }

  /// Must be called while holding the dispatch-run file lock.
  ///
  /// Physical remote jobs are idempotent by `remoteJobID` before this helper is
  /// reached. A genuinely new physical job advances the logical attempt. Only
  /// the highest attempt head can close the logical job: delayed success from
  /// an older attempt must not block an already-created recovery attempt.
  private static func nextRemoteAttempt(
    logicalJobID: String,
    records: [TatwoDispatchRecord]
  ) throws -> Int {
    let logicalRecords = records.filter {
      $0.resolvedLogicalDispatchID == logicalJobID
    }
    guard let highestAttempt = logicalRecords.map(\.resolvedAttempt).max() else {
      return 1
    }
    let heads = logicalRecords.filter {
      $0.resolvedAttempt == highestAttempt
    }
    if let successfulHead = heads.first(where: remoteLogicalSuccess) {
      throw TatwoDispatchRegistryError.terminalDispatchCannotRetry(successfulHead.id)
    }
    guard highestAttempt < Int.max else {
      throw TatwoDispatchRegistryError.retryBudgetExhausted(logicalJobID)
    }
    return highestAttempt + 1
  }

  private static func remoteLogicalSuccess(_ record: TatwoDispatchRecord) -> Bool {
    if let remoteStatus = record.remoteStatus {
      return remoteStatus == .completed || remoteStatus == .verified
    }
    return record.status == .completed || record.status == .verified
  }

  private static func mergeConsumedResultDigest(
    into record: inout TatwoDispatchRecord,
    resultDigest: String,
    remoteJobID: String
  ) throws {
    if let existing = record.consumedResultDigest, existing != resultDigest {
      throw TatwoDispatchRegistryError.resultConsumeConflict(
        jobID: remoteJobID,
        detail: "consumed result digest mismatch")
    }
    record.consumedResultDigest = resultDigest
  }

  private static func rejectEvidenceMutationUnlessIdentical(
    record: TatwoDispatchRecord,
    receiptID: String?,
    outputRef: String?,
    resultDigest: String?,
    failureCode: String? = nil,
    errorMessage: String? = nil,
    remoteJobID: String,
    detail: String
  ) throws {
    if let receiptID, receiptID != record.receiptID {
      throw TatwoDispatchRegistryError.terminalEvidenceRegression(
        jobID: remoteJobID,
        detail: detail)
    }
    if let outputRef, outputRef != record.outputRef {
      throw TatwoDispatchRegistryError.terminalEvidenceRegression(
        jobID: remoteJobID,
        detail: detail)
    }
    if let resultDigest, let existing = record.consumedResultDigest, resultDigest != existing {
      throw TatwoDispatchRegistryError.terminalEvidenceRegression(
        jobID: remoteJobID,
        detail: detail)
    }
    if let existing = record.failureReceipt, failureCode != nil || errorMessage != nil {
      let candidate = TatwoDispatchFailureReceipt.sanitized(
        declaredClass: existing.failureClass,
        errorCode: failureCode ?? existing.errorCode,
        httpStatus: existing.httpStatus,
        rawErrorDigest: existing.rawErrorDigest,
        backendRequestID: existing.backendRequestID,
        backendResponseID: existing.backendResponseID,
        rawError: errorMessage ?? existing.operatorMessage,
        occurredAt: existing.occurredAt)
      try requireFailureEvidenceCompatible(
        existing: existing,
        candidate: candidate,
        remoteJobID: remoteJobID)
    }
  }

  /// Terminal/verified evidence is write-once for digests/refs.
  /// Higher `projectionSequence` may only advance the sequence (or fill empty slots)
  /// when evidence is identical — bare caller sequence cannot replace signed evidence.
  private static func mergeTerminalEvidence(
    into record: inout TatwoDispatchRecord,
    remoteJobID: String,
    receiptID: String?,
    outputRef: String?,
    resultDigest: String?,
    projectionSequence: UInt64?,
    failureCode: String?,
    errorMessage: String?,
    remoteStatus: TatwoLoopJobStatusV1,
    now: Date
  ) throws {
    let currentSeq = record.remoteProjectionSequence ?? 0
    let incomingSeq = projectionSequence ?? currentSeq

    if incomingSeq < currentSeq {
      throw TatwoDispatchRegistryError.terminalEvidenceRegression(
        jobID: remoteJobID,
        detail: "projection sequence regression \(incomingSeq) < \(currentSeq)")
    }

    let hasExistingEvidence =
      record.receiptID != nil || record.outputRef != nil || record.consumedResultDigest != nil
      || record.failureReceipt != nil

    // Always refuse non-identical evidence replacement, even with a higher bare sequence.
    if hasExistingEvidence || Self.isTerminalOrVerified(record.remoteStatus) {
      if let receiptID, let existing = record.receiptID, receiptID != existing {
        throw TatwoDispatchRegistryError.terminalEvidenceRegression(
          jobID: remoteJobID,
          detail: "receiptID mismatch; projection sequence cannot replace signed evidence")
      }
      if let outputRef, let existing = record.outputRef, outputRef != existing {
        throw TatwoDispatchRegistryError.terminalEvidenceRegression(
          jobID: remoteJobID,
          detail: "outputRef mismatch; projection sequence cannot replace signed evidence")
      }
      if let resultDigest, let existing = record.consumedResultDigest, resultDigest != existing {
        throw TatwoDispatchRegistryError.resultConsumeConflict(
          jobID: remoteJobID,
          detail: "result digest mismatch; projection sequence cannot replace signed evidence")
      }
      // Identical / missing fields: fill only empty slots (monotonic merge).
      if record.receiptID == nil { record.receiptID = receiptID }
      if record.outputRef == nil { record.outputRef = outputRef }
      if let resultDigest {
        try mergeConsumedResultDigest(
          into: &record,
          resultDigest: resultDigest,
          remoteJobID: remoteJobID)
      }
      if incomingSeq > currentSeq {
        record.remoteProjectionSequence = incomingSeq
      }
    } else {
      // First terminal write: accept evidence + sequence from signed result path.
      if let receiptID { record.receiptID = receiptID }
      if let outputRef { record.outputRef = outputRef }
      if let resultDigest {
        record.consumedResultDigest = resultDigest
      }
      record.remoteProjectionSequence = incomingSeq
    }

    if record.remoteProjectionSequence == nil {
      record.remoteProjectionSequence = incomingSeq
    }

    switch remoteStatus {
    case .failed, .cancelled:
      // E4: failure evidence is write-once. Higher bare projectionSequence cannot
      // rebuild failureReceipt / code / message; only identical evidence is accepted.
      let candidate = TatwoDispatchFailureReceipt.sanitized(
        declaredClass: remoteStatus == .cancelled ? .terminal : nil,
        errorCode: failureCode ?? remoteStatus.rawValue,
        httpStatus: nil,
        rawErrorDigest: nil,
        backendRequestID: nil,
        backendResponseID: nil,
        rawError: errorMessage ?? "remote loop job \(remoteStatus.rawValue)",
        occurredAt: now)
      if let existing = record.failureReceipt {
        if failureCode != nil || errorMessage != nil {
          try Self.requireFailureEvidenceCompatible(
            existing: existing,
            candidate: candidate,
            remoteJobID: remoteJobID)
        }
        // Keep original occurredAt / receipt; do not rebuild on higher sequence.
      } else {
        record.failureReceipt = candidate
        record.errorMessage = candidate.operatorMessage
      }
    default:
      break
    }
  }

  /// Compare failure evidence ignoring occurredAt timestamps (write-once semantic fields).
  private static func requireFailureEvidenceCompatible(
    existing: TatwoDispatchFailureReceipt,
    candidate: TatwoDispatchFailureReceipt,
    remoteJobID: String
  ) throws {
    let same =
      existing.failureClass == candidate.failureClass
      && existing.errorCode == candidate.errorCode
      && existing.httpStatus == candidate.httpStatus
      && existing.operatorMessage == candidate.operatorMessage
      && existing.rawErrorDigest == candidate.rawErrorDigest
      && existing.backendRequestID == candidate.backendRequestID
      && existing.backendResponseID == candidate.backendResponseID
    if !same {
      throw TatwoDispatchRegistryError.terminalEvidenceRegression(
        jobID: remoteJobID,
        detail:
          "failure evidence mismatch; projection sequence cannot rebuild failureReceipt")
    }
  }

  @discardableResult
  func sealCompletedSet(
    contractID: String,
    goalID: String? = nil,
    now: Date = Date()
  ) throws -> TatwoStoredDispatchRun {
    let url = try fileURL(forContractID: contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      var run = try loadOrCreateRun(contractID: contractID)
      try materializeCycleLedger(&run)
      let epoch = try activeCycleEpoch(in: run)
      let heads = activeLogicalHeads(in: run, goalID: goalID, cycleEpoch: epoch)
      let recordIDs = heads.map(\.id).sorted()
      if let existing = try latestCycleSeal(in: run),
        existing.epoch == epoch
      {
        guard existing.recordIDs == recordIDs,
          (existing.goalID == goalID || existing.goalID == nil),
          !recordIDs.isEmpty,
          heads.allSatisfy({ $0.status == .completed || $0.status == .verified })
        else {
          throw TatwoDispatchRegistryError.sealedSetMismatch(existing.sealID)
        }
        return run
      }
      try requireActiveCycleOpen(run)
      guard !recordIDs.isEmpty else {
        throw TatwoDispatchRegistryError.cannotSealEmpty(contractID)
      }
      // Seal accepts execution-complete or origin-accepted success terminals.
      let incomplete = heads
        .filter { $0.status != .completed && $0.status != .verified }
        .map(\.id)
        .sorted()
      guard incomplete.isEmpty else {
        throw TatwoDispatchRegistryError.cannotSealIncomplete(incomplete)
      }
      let sealID = Self.sealID(
        contractID: contractID,
        goalID: goalID,
        epoch: epoch,
        recordIDs: recordIDs)
      let seal = TatwoDispatchCycleSealV1(
        epoch: epoch,
        sealID: sealID,
        sealedAt: now,
        recordIDs: recordIDs,
        goalID: goalID)
      var seals = run.cycleSeals ?? []
      seals.append(seal)
      run.cycleSeals = seals
      run.activeCycleEpoch = epoch
      // Compatibility aliases always point at the latest immutable cycle.
      run.sealID = sealID
      run.sealedAt = now
      run.sealedRecordIDs = recordIDs
      run.sealedGoalID = goalID
      run.updatedAt = now
      try write(run)
      return run
    }
  }

  /// Opens the next dispatch cycle without mutating any prior record or seal.
  ///
  /// Repeating the same advance after it already succeeded is idempotent. A
  /// stale expected seal fails closed, which gives lifecycle callers a CAS-like
  /// boundary while both GoalRun and registry are held by the outer lock.
  @discardableResult
  func advanceCycle(
    contractID: String,
    goalID: String? = nil,
    expectedSealID: String,
    now: Date = Date()
  ) throws -> TatwoStoredDispatchRun {
    let url = try fileURL(forContractID: contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      var run = try loadOrCreateRun(contractID: contractID)
      try materializeCycleLedger(&run)
      guard let latest = try latestCycleSeal(in: run) else {
        throw TatwoDispatchRegistryError.invalidCycleLedger(
          "cannot advance without a prior cycle seal")
      }
      guard latest.sealID == expectedSealID else {
        throw TatwoDispatchRegistryError.staleCycleBoundary(
          expected: expectedSealID,
          actual: latest.sealID)
      }
      guard latest.goalID == goalID || latest.goalID == nil else {
        throw TatwoDispatchRegistryError.invalidCycleLedger(
          "latest seal goalID does not match the issued GoalRun")
      }
      let current = try activeCycleEpoch(in: run)
      let next = latest.epoch + 1
      if current == next {
        return run
      }
      guard current == latest.epoch else {
        throw TatwoDispatchRegistryError.invalidCycleLedger(
          "active epoch \(current) is not the sealed epoch \(latest.epoch)")
      }
      run.activeCycleEpoch = next
      run.updatedAt = now
      try write(run)
      return run
    }
  }

  // MARK: Reads

  public func run(forContractID contractID: String) throws -> TatwoStoredDispatchRun? {
    let url = try fileURL(forContractID: contractID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TatwoStoredDispatchRun.self, from: try Data(contentsOf: url))
  }

  /// Successor-revision gate for distinguishing a canonical planning manifest
  /// from executable publication. This is intentionally narrower than the
  /// general "any registry exists" policy used by silent planned-current
  /// supersession.
  ///
  /// A present registry is planning-only only when every persisted field still
  /// describes the first open cycle and its manifest IDs exactly match the
  /// issued identity bindings. Any malformed or unexpected state fails closed
  /// as executable publication.
  func hasExecutablePublicationEvidence(
    forContractID contractID: String,
    issuedBindingIDs: [String]?
  ) -> Bool {
    let run: TatwoStoredDispatchRun
    do {
      guard let stored = try self.run(forContractID: contractID) else {
        return false
      }
      run = stored
    } catch {
      return true
    }

    guard let manifest = run.executionManifest,
      let manifestSHA256 = run.executionManifestSHA256,
      run.schema == "TatwoStoredDispatchRunV2",
      run.contractID == contractID,
      manifestSHA256 == (try? manifest.canonicalSHA256()),
      run.records.isEmpty,
      run.sealID == nil,
      run.sealedAt == nil,
      run.sealedRecordIDs == nil,
      run.sealedGoalID == nil,
      (run.cycleSeals ?? []).isEmpty,
      run.activeCycleEpoch == nil || run.activeCycleEpoch == 1,
      let issuedBindingIDs
    else {
      return true
    }

    let expected = issuedBindingIDs.map { "dispatch-plan-\($0)" }
    guard Set(expected).count == expected.count,
      Set(run.manifestEntryIDs).count == run.manifestEntryIDs.count,
      expected.sorted() == run.manifestEntryIDs.sorted()
    else {
      return true
    }
    return false
  }

  /// One record per bindingID — the most recently updated. The dashboard uses this so a
  /// finished/failed dispatch is still shown ("last known") rather than disappearing.
  public func latestRecordsByBinding(forContractID contractID: String) throws -> [TatwoDispatchRecord] {
    guard let run = try run(forContractID: contractID) else { return [] }
    var latest: [String: TatwoDispatchRecord] = [:]
    for record in run.records {
      if let existing = latest[record.bindingID], existing.updatedAt >= record.updatedAt { continue }
      latest[record.bindingID] = record
    }
    return latest.values.sorted { $0.bindingID < $1.bindingID }
  }

  /// Every dispatch run on disk, most recently updated first. The App's Working page uses
  /// this to show one status light per agent across ALL contracts (not just the active
  /// session), so the user can see at a glance whether anything is moving. Unreadable
  /// files are skipped, not fatal — a live status board must never crash on one bad record.
  public func allRuns(updatedSince cutoff: Date? = nil) -> [TatwoStoredDispatchRun] {
    let dir = directoryURL.appendingPathComponent("dispatches", isDirectory: true)
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)) ?? []
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return files
      .filter { $0.pathExtension == "json" }
      .compactMap { url in
        (try? Data(contentsOf: url)).flatMap {
          try? decoder.decode(TatwoStoredDispatchRun.self, from: $0)
        }
        .map { run in
          guard let cutoff else { return run }
          var filtered = run
          filtered.records = run.records.filter { $0.updatedAt >= cutoff }
          return filtered
        }
        .flatMap { run in
          guard let cutoff else { return run }
          return (run.updatedAt >= cutoff || !run.records.isEmpty) ? run : nil
        }
      }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  // MARK: Storage

  private func loadOrCreateRun(contractID: String) throws -> TatwoStoredDispatchRun {
    if let existing = try run(forContractID: contractID) { return existing }
    return TatwoStoredDispatchRun(contractID: contractID)
  }

  private func write(_ run: TatwoStoredDispatchRun) throws {
    let url = try fileURL(forContractID: run.contractID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try TatwoAtomicFile.write(encoder.encode(run), to: url)
  }

  private func materializeCycleLedger(_ run: inout TatwoStoredDispatchRun) throws {
    var seals = run.cycleSeals ?? []
    if let legacySealID = run.sealID,
      !seals.contains(where: { $0.sealID == legacySealID })
    {
      guard seals.isEmpty else {
        throw TatwoDispatchRegistryError.invalidCycleLedger(
          "legacy seal alias disagrees with append-only seal history")
      }
      guard let sealedAt = run.sealedAt,
        let recordIDs = run.sealedRecordIDs,
        !recordIDs.isEmpty
      else {
        throw TatwoDispatchRegistryError.invalidCycleLedger(
          "legacy seal is missing sealedAt or record membership")
      }
      seals.append(
        TatwoDispatchCycleSealV1(
          epoch: 1,
          sealID: legacySealID,
          sealedAt: sealedAt,
          recordIDs: recordIDs,
          goalID: run.sealedGoalID,
          migratedLegacy: true))
    }
    seals.sort { $0.epoch < $1.epoch }
    for (index, seal) in seals.enumerated() {
      guard seal.epoch == UInt64(index + 1) else {
        throw TatwoDispatchRegistryError.invalidCycleLedger(
          "cycle seal epochs must be contiguous from 1")
      }
      guard !seal.recordIDs.isEmpty else {
        throw TatwoDispatchRegistryError.invalidCycleLedger(
          "cycle \(seal.epoch) seal has no records")
      }
      if index > 0, seals[index - 1].sealID == seal.sealID {
        throw TatwoDispatchRegistryError.invalidCycleLedger(
          "adjacent cycle seals cannot reuse a sealID")
      }
    }
    run.cycleSeals = seals
    if run.activeCycleEpoch == nil {
      run.activeCycleEpoch = seals.last?.epoch ?? 1
    }
    _ = try activeCycleEpoch(in: run)
  }

  private func activeCycleEpoch(in run: TatwoStoredDispatchRun) throws -> UInt64 {
    guard let epoch = run.activeCycleEpoch, epoch > 0 else {
      throw TatwoDispatchRegistryError.invalidCycleLedger(
        "activeCycleEpoch must be a positive integer")
    }
    let latest = try latestCycleSeal(in: run)?.epoch ?? 0
    guard epoch == max(UInt64(1), latest) || epoch == latest + 1 else {
      throw TatwoDispatchRegistryError.invalidCycleLedger(
        "active epoch \(epoch) is inconsistent with latest sealed epoch \(latest)")
    }
    return epoch
  }

  private func latestCycleSeal(
    in run: TatwoStoredDispatchRun
  ) throws -> TatwoDispatchCycleSealV1? {
    let seals = run.cycleSeals ?? []
    guard Set(seals.map(\.epoch)).count == seals.count else {
      throw TatwoDispatchRegistryError.invalidCycleLedger(
        "duplicate cycle seal epoch")
    }
    return seals.max { $0.epoch < $1.epoch }
  }

  private func requireActiveCycleOpen(_ run: TatwoStoredDispatchRun) throws {
    let active = try activeCycleEpoch(in: run)
    if let latest = try latestCycleSeal(in: run),
      active <= latest.epoch
    {
      throw TatwoDispatchRegistryError.runSealed(latest.sealID)
    }
  }

  private func requireRecordInActiveCycle(
    _ record: TatwoDispatchRecord,
    run: TatwoStoredDispatchRun
  ) throws {
    let active = try activeCycleEpoch(in: run)
    guard record.resolvedCycleEpoch == active else {
      let sealID = try latestCycleSeal(in: run)?.sealID ?? "unknown-cycle-seal"
      throw TatwoDispatchRegistryError.runSealed(sealID)
    }
  }

  private func activeLogicalHeads(
    in run: TatwoStoredDispatchRun,
    goalID: String?,
    cycleEpoch: UInt64
  ) -> [TatwoDispatchRecord] {
    let scoped: [TatwoDispatchRecord]
    if let goalID {
      scoped = run.records.filter {
        $0.goalID == goalID && $0.resolvedCycleEpoch == cycleEpoch
      }
    } else {
      scoped = run.records.filter { $0.resolvedCycleEpoch == cycleEpoch }
    }
    let supersededIDs = Set(scoped.compactMap(\.supersedes))
    return scoped.filter { !supersededIDs.contains($0.id) }
  }

  private static func sealID(
    contractID: String,
    goalID: String?,
    epoch: UInt64,
    recordIDs: [String]
  ) -> String {
    let material = ([contractID, goalID ?? "legacy-goal-scope", String(epoch)] + recordIDs)
      .joined(separator: "\n")
    let digest = SHA256.hash(data: Data(material.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "dispatch-cycle-seal-\(digest)"
  }

  func fileURL(forContractID contractID: String) throws -> URL {
    let normalized = contractID.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    guard !normalized.isEmpty,
      normalized.lowercased() == normalized,
      normalized.allSatisfy({ allowed.contains($0) })
    else {
      throw TatwoDispatchRegistryError.invalidContractID(contractID)
    }
    return
      directoryURL
      .appendingPathComponent("dispatches", isDirectory: true)
      .appendingPathComponent("\(normalized).json", isDirectory: false)
  }
}

/// Fail-closed remote-outbox evidence query shared by revision-promotion and
/// bootstrap-recovery gates. The parent and contract directory are opened with
/// `O_NOFOLLOW`; symlinks, non-directories, unreadable paths, path races, and
/// enumeration errors all count as publication evidence.
enum TatwoRemoteOutboxEvidence {
  static func hasPublishedEvidence(
    stateDirectoryURL: URL,
    contractID: String
  ) -> Bool {
    let parentURL = stateDirectoryURL.appendingPathComponent(
      "remote-outbox-intents", isDirectory: true)
    let contractComponent = TatwoLoopPathComponent.sanitize(contractID)

    var parentPathStatus = stat()
    guard lstat(parentURL.path, &parentPathStatus) == 0 else {
      return errno == ENOENT ? false : true
    }
    guard isDirectory(parentPathStatus), !isSymbolicLink(parentPathStatus) else {
      return true
    }

    let parentFD = Darwin.open(
      parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentFD >= 0 else { return true }
    defer { Darwin.close(parentFD) }

    var parentFDStatus = stat()
    guard fstat(parentFD, &parentFDStatus) == 0,
      sameFile(parentPathStatus, parentFDStatus)
    else {
      return true
    }

    var contractPathStatus = stat()
    let contractStatResult = contractComponent.withCString {
      fstatat(parentFD, $0, &contractPathStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard contractStatResult == 0 else {
      return errno == ENOENT ? false : true
    }
    guard isDirectory(contractPathStatus),
      !isSymbolicLink(contractPathStatus)
    else {
      return true
    }

    let contractFD = contractComponent.withCString {
      Darwin.openat(
        parentFD, $0,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard contractFD >= 0 else { return true }
    defer { Darwin.close(contractFD) }

    var contractFDStatus = stat()
    guard fstat(contractFD, &contractFDStatus) == 0,
      sameFile(contractPathStatus, contractFDStatus)
    else {
      return true
    }

    let enumerationFD = Darwin.dup(contractFD)
    guard enumerationFD >= 0 else { return true }
    guard let directory = fdopendir(enumerationFD) else {
      Darwin.close(enumerationFD)
      return true
    }
    defer { closedir(directory) }

    errno = 0
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) {
          String(cString: $0)
        }
      }
      if name != ".", name != ".." {
        return true
      }
      errno = 0
    }
    guard errno == 0 else { return true }

    var reboundStatus = stat()
    guard contractComponent.withCString({
      fstatat(parentFD, $0, &reboundStatus, AT_SYMLINK_NOFOLLOW)
    }) == 0,
      sameFile(contractFDStatus, reboundStatus),
      isDirectory(reboundStatus),
      !isSymbolicLink(reboundStatus)
    else {
      return true
    }
    return false
  }

  private static func isDirectory(_ status: stat) -> Bool {
    (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
  }

  private static func isSymbolicLink(_ status: stat) -> Bool {
    (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
  }

  private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }
}
