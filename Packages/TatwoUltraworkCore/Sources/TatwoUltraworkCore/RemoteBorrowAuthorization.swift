import CryptoKit
import Foundation

public enum TatwoRemoteBorrowRiskV1: String, Codable, Sendable, Equatable {
  case lowRisk = "low_risk"
  case highRisk = "high_risk"
}

public enum TatwoRemoteBorrowModeV1: String, Codable, Sendable, Equatable {
  case automatic
  case manual
}

/// Signed, canonical authorization scope carried by every production remote job.
///
/// This is part of `TatwoLoopJobV1` and therefore part of the job digest. The
/// production dispatch gate binds the job to one main Chat session, target,
/// Work OS contract, risk class, and an exact durable approval record.
public struct TatwoRemoteBorrowInvocationV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let sessionID: String
  public let targetDeviceID: String
  public let contractID: String
  public let goalID: String
  public let mode: TatwoRemoteBorrowModeV1
  public let risk: TatwoRemoteBorrowRiskV1
  public let grantID: String?
  public let oneShotApprovalID: String?

  public init(
    schema: String = "TatwoRemoteBorrowInvocationV1",
    sessionID: String,
    targetDeviceID: String,
    contractID: String,
    goalID: String,
    mode: TatwoRemoteBorrowModeV1,
    risk: TatwoRemoteBorrowRiskV1,
    grantID: String? = nil,
    oneShotApprovalID: String? = nil
  ) {
    self.schema = schema
    self.sessionID = sessionID
    self.targetDeviceID = targetDeviceID
    self.contractID = contractID
    self.goalID = goalID
    self.mode = mode
    self.risk = risk
    self.grantID = grantID
    self.oneShotApprovalID = oneShotApprovalID
  }

  public func validate(
    targetDeviceID expectedTargetDeviceID: String,
    contractID expectedContractID: String,
    goalID expectedGoalID: String
  ) throws {
    guard schema == "TatwoRemoteBorrowInvocationV1" else {
      throw TatwoRemoteBorrowAuthorizationError.invalidInvocation("schema")
    }
    _ = try TatwoRemoteBorrowAuthorizationStore.normalizedIdentifier(
      sessionID,
      field: "sessionID")
    _ = try TatwoRemoteBorrowAuthorizationStore.normalizedIdentifier(
      targetDeviceID,
      field: "targetDeviceID")
    _ = try TatwoRemoteBorrowAuthorizationStore.normalizedIdentifier(
      contractID,
      field: "contractID")
    _ = try TatwoRemoteBorrowAuthorizationStore.normalizedIdentifier(
      goalID,
      field: "goalID")
    guard targetDeviceID == expectedTargetDeviceID else {
      throw TatwoRemoteBorrowAuthorizationError.invalidInvocation("targetDeviceID")
    }
    guard contractID == expectedContractID else {
      throw TatwoRemoteBorrowAuthorizationError.invalidInvocation("contractID")
    }
    guard goalID == expectedGoalID else {
      throw TatwoRemoteBorrowAuthorizationError.invalidInvocation("goalID")
    }
    switch risk {
    case .lowRisk:
      guard
        let grantID,
        !grantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        oneShotApprovalID == nil
      else {
        throw TatwoRemoteBorrowAuthorizationError.invalidInvocation(
          "low-risk grant binding")
      }
    case .highRisk:
      guard
        grantID == nil,
        let oneShotApprovalID,
        !oneShotApprovalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw TatwoRemoteBorrowAuthorizationError.invalidInvocation(
          "high-risk one-shot binding")
      }
    }
  }
}

public struct TatwoRemoteDeviceExecutionPolicyV1:
  Codable, Sendable, Equatable, Identifiable
{
  public let schema: String
  public let targetDeviceID: String
  public let autoBorrowEnabled: Bool
  public let updatedAt: Date

  public var id: String { targetDeviceID }

  public init(
    schema: String = "TatwoRemoteDeviceExecutionPolicyV1",
    targetDeviceID: String,
    autoBorrowEnabled: Bool,
    updatedAt: Date = Date()
  ) {
    self.schema = schema
    self.targetDeviceID = targetDeviceID
    self.autoBorrowEnabled = autoBorrowEnabled
    self.updatedAt = updatedAt
  }
}

public struct TatwoRemoteSessionGrantV1:
  Codable, Sendable, Equatable, Identifiable
{
  public let schema: String
  public let id: String
  public let sessionID: String
  public let targetDeviceID: String
  public let contractID: String
  public let risk: TatwoRemoteBorrowRiskV1
  public let issuedAt: Date
  public let expiresAt: Date
  public let previousGrantID: String?
  public let revokedAt: Date?

  public var isActive: Bool { isActive(at: Date()) }

  public func isActive(at date: Date) -> Bool {
    revokedAt == nil && expiresAt > date
  }

  public init(
    schema: String = "TatwoRemoteSessionGrantV1",
    id: String = "remote-grant-\(UUID().uuidString.lowercased())",
    sessionID: String,
    targetDeviceID: String,
    contractID: String,
    risk: TatwoRemoteBorrowRiskV1 = .lowRisk,
    issuedAt: Date = Date(),
    expiresAt: Date? = nil,
    previousGrantID: String? = nil,
    revokedAt: Date? = nil
  ) {
    self.schema = schema
    self.id = id
    self.sessionID = sessionID
    self.targetDeviceID = targetDeviceID
    self.contractID = contractID
    self.risk = risk
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt ?? issuedAt.addingTimeInterval(7 * 24 * 60 * 60)
    self.previousGrantID = previousGrantID
    self.revokedAt = revokedAt
  }

  fileprivate func revoking(at date: Date) -> Self {
    Self(
      schema: schema,
      id: id,
      sessionID: sessionID,
      targetDeviceID: targetDeviceID,
      contractID: contractID,
      risk: risk,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      previousGrantID: previousGrantID,
      revokedAt: revokedAt ?? date)
  }
}

public struct TatwoRemoteSessionGrantRevocationV1:
  Codable, Sendable, Equatable, Identifiable
{
  public let schema: String
  public let id: String
  public let grantID: String
  public let sessionID: String
  public let targetDeviceID: String
  public let contractID: String
  public let revokedAt: Date
  public let reason: String

  public init(
    schema: String = "TatwoRemoteSessionGrantRevocationV1",
    id: String = "remote-revoke-\(UUID().uuidString.lowercased())",
    grantID: String,
    sessionID: String,
    targetDeviceID: String,
    contractID: String,
    revokedAt: Date = Date(),
    reason: String
  ) {
    self.schema = schema
    self.id = id
    self.grantID = grantID
    self.sessionID = sessionID
    self.targetDeviceID = targetDeviceID
    self.contractID = contractID
    self.revokedAt = revokedAt
    self.reason = reason
  }
}

public enum TatwoRemoteBorrowAuthorizationBlockerV1:
  String, Codable, Sendable, Equatable
{
  case missingInvocation = "missing_invocation"
  case invocationScopeMismatch = "invocation_scope_mismatch"
  case authorizationStoreUnreadable = "authorization_store_unreadable"
  case automaticBorrowDisabled = "automatic_borrow_disabled"
  case sessionApprovalRequired = "session_approval_required"
  case grantIDMismatch = "grant_id_mismatch"
  case perInvocationApprovalRequired = "per_invocation_approval_required"
  case targetNotTrusted = "target_not_trusted"
}

public struct TatwoRemoteBorrowAuthorizationDecisionV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let allowed: Bool
  public let blocker: TatwoRemoteBorrowAuthorizationBlockerV1?

  public init(
    schema: String = "TatwoRemoteBorrowAuthorizationDecisionV1",
    allowed: Bool,
    blocker: TatwoRemoteBorrowAuthorizationBlockerV1?
  ) {
    self.schema = schema
    self.allowed = allowed
    self.blocker = blocker
  }
}

public enum TatwoRemoteBorrowAuthorizationEvaluator {
  public static func decide(
    mode: TatwoRemoteBorrowModeV1,
    risk: TatwoRemoteBorrowRiskV1,
    policy: TatwoRemoteDeviceExecutionPolicyV1,
    grant: TatwoRemoteSessionGrantV1?,
    sessionID: String,
    targetDeviceID: String,
    contractID: String,
    targetIsTrusted: Bool,
    now: Date = Date()
  ) -> TatwoRemoteBorrowAuthorizationDecisionV1 {
    guard risk == .lowRisk else {
      return TatwoRemoteBorrowAuthorizationDecisionV1(
        allowed: false,
        blocker: .perInvocationApprovalRequired)
    }
    guard targetIsTrusted else {
      return TatwoRemoteBorrowAuthorizationDecisionV1(
        allowed: false,
        blocker: .targetNotTrusted)
    }
    if mode == .automatic, !policy.autoBorrowEnabled {
      return TatwoRemoteBorrowAuthorizationDecisionV1(
        allowed: false,
        blocker: .automaticBorrowDisabled)
    }
    guard
      let grant,
      grant.isActive(at: now),
      grant.risk == .lowRisk,
      grant.sessionID == sessionID,
      grant.targetDeviceID == targetDeviceID,
      grant.contractID == contractID
    else {
      return TatwoRemoteBorrowAuthorizationDecisionV1(
        allowed: false,
        blocker: .sessionApprovalRequired)
    }
    return TatwoRemoteBorrowAuthorizationDecisionV1(allowed: true, blocker: nil)
  }
}

public enum TatwoRemoteBorrowAuthorizationError:
  Error, LocalizedError, Sendable, Equatable
{
  case invalidIdentifier(String)
  case invalidInvocation(String)
  case standingHighRiskGrantForbidden
  case unreadableRecord(String)
  case recordScopeMismatch

  public var errorDescription: String? {
    switch self {
    case .invalidIdentifier(let field):
      return "遠端借用授權缺少有效的 \(field)。"
    case .invalidInvocation(let field):
      return "遠端借用工作與授權範圍不一致：\(field)。"
    case .standingHighRiskGrantForbidden:
      return "高風險工作不能使用常駐借用授權，必須逐次確認。"
    case .unreadableRecord:
      return "遠端借用授權紀錄無法安全讀取，已停止操作。"
    case .recordScopeMismatch:
      return "遠端借用授權範圍不一致，已停止操作。"
    }
  }
}

public struct TatwoRemoteBorrowAuthorizationStore: Sendable {
  public let rootURL: URL

  private var policyDirectoryURL: URL {
    rootURL.appendingPathComponent("device-policies", isDirectory: true)
  }

  private var grantDirectoryURL: URL {
    rootURL.appendingPathComponent("session-grants", isDirectory: true)
  }

  private var revocationDirectoryURL: URL {
    rootURL.appendingPathComponent("session-grant-revocations", isDirectory: true)
  }

  private var lockDirectoryURL: URL {
    rootURL.appendingPathComponent("locks", isDirectory: true)
  }

  public init(rootURL: URL) {
    self.rootURL = rootURL
  }

  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    Self(
      rootURL: TatwoRuntimeLayout.stateRoot(environment: environment)
        .appendingPathComponent("remote-execution-authorization", isDirectory: true))
  }

  public static func production(stateRoot: URL) -> Self {
    Self(
      rootURL: stateRoot.standardizedFileURL
        .appendingPathComponent("remote-execution-authorization", isDirectory: true))
  }

  public func devicePolicy(
    targetDeviceID: String
  ) throws -> TatwoRemoteDeviceExecutionPolicyV1 {
    let normalizedTarget = try Self.normalized(targetDeviceID, field: "targetDeviceID")
    let url = try policyURL(targetDeviceID: normalizedTarget)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return TatwoRemoteDeviceExecutionPolicyV1(
        targetDeviceID: normalizedTarget,
        autoBorrowEnabled: false,
        updatedAt: .distantPast)
    }
    let policy: TatwoRemoteDeviceExecutionPolicyV1 = try read(
      TatwoRemoteDeviceExecutionPolicyV1.self,
      from: url)
    guard
      policy.schema == "TatwoRemoteDeviceExecutionPolicyV1",
      policy.targetDeviceID == normalizedTarget
    else {
      throw TatwoRemoteBorrowAuthorizationError.recordScopeMismatch
    }
    return policy
  }

  @discardableResult
  public func setAutoBorrow(
    targetDeviceID: String,
    enabled: Bool,
    now: Date = Date()
  ) throws -> TatwoRemoteDeviceExecutionPolicyV1 {
    let normalizedTarget = try Self.normalized(targetDeviceID, field: "targetDeviceID")
    let url = try policyURL(targetDeviceID: normalizedTarget)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      let policy = TatwoRemoteDeviceExecutionPolicyV1(
        targetDeviceID: normalizedTarget,
        autoBorrowEnabled: enabled,
        updatedAt: now)
      try write(policy, to: url)
      return policy
    }
  }

  public func sessionGrant(
    sessionID: String,
    targetDeviceID: String,
    contractID: String,
    now: Date = Date()
  ) throws -> TatwoRemoteSessionGrantV1? {
    try grantHistory(
      sessionID: sessionID,
      targetDeviceID: targetDeviceID,
      contractID: contractID)
      .filter { $0.isActive(at: now) }
      .max(by: Self.grantOrder)
  }

  /// Serializes one authorization decision with the mutation it authorizes.
  ///
  /// Lock ordering for remote dispatch is:
  /// GoalRun lifecycle -> this grant scope -> dispatch registry.
  /// Grant issuance/revocation takes only this scope lock and must never acquire
  /// either outer lifecycle state or the inner dispatch registry lock.
  func withSessionGrantScopeLock<T>(
    sessionID: String,
    targetDeviceID: String,
    contractID: String,
    _ body: () throws -> T
  ) throws -> T {
    let scope = try normalizedScope(
      sessionID: sessionID,
      targetDeviceID: targetDeviceID,
      contractID: contractID)
    let lockURL = try scopeLockURL(
      sessionID: scope.sessionID,
      targetDeviceID: scope.targetDeviceID,
      contractID: scope.contractID)
    return try TatwoFileLock.withExclusiveLock(for: lockURL, body)
  }

  public func grantHistory(
    sessionID: String,
    targetDeviceID: String,
    contractID: String
  ) throws -> [TatwoRemoteSessionGrantV1] {
    let scope = try normalizedScope(
      sessionID: sessionID,
      targetDeviceID: targetDeviceID,
      contractID: contractID)
    let grants = try allGrantIssuances().filter {
      $0.sessionID == scope.sessionID
        && $0.targetDeviceID == scope.targetDeviceID
        && $0.contractID == scope.contractID
    }
    let revocations = try allRevocations()
    let revokedAtByGrantID = Dictionary(
      revocations.map { ($0.grantID, $0.revokedAt) },
      uniquingKeysWith: min)
    return grants.map { grant in
      guard let revokedAt = revokedAtByGrantID[grant.id] else { return grant }
      return grant.revoking(at: revokedAt)
    }
    .sorted(by: Self.grantOrder)
  }

  @discardableResult
  public func issueSessionGrant(
    sessionID: String,
    targetDeviceID: String,
    contractID: String,
    risk: TatwoRemoteBorrowRiskV1 = .lowRisk,
    ttl: TimeInterval = 7 * 24 * 60 * 60,
    now: Date = Date()
  ) throws -> TatwoRemoteSessionGrantV1 {
    guard risk == .lowRisk else {
      throw TatwoRemoteBorrowAuthorizationError.standingHighRiskGrantForbidden
    }
    let scope = try normalizedScope(
      sessionID: sessionID,
      targetDeviceID: targetDeviceID,
      contractID: contractID)
    let lockURL = try scopeLockURL(
      sessionID: scope.sessionID,
      targetDeviceID: scope.targetDeviceID,
      contractID: scope.contractID)
    return try TatwoFileLock.withExclusiveLock(for: lockURL) {
      let history = try grantHistory(
        sessionID: scope.sessionID,
        targetDeviceID: scope.targetDeviceID,
        contractID: scope.contractID)
      if let existing = history.last(where: { $0.isActive(at: now) }) {
        return existing
      }
      let duration = max(5 * 60, min(ttl, 30 * 24 * 60 * 60))
      let grant = TatwoRemoteSessionGrantV1(
        sessionID: scope.sessionID,
        targetDeviceID: scope.targetDeviceID,
        contractID: scope.contractID,
        risk: .lowRisk,
        issuedAt: now,
        expiresAt: now.addingTimeInterval(duration),
        previousGrantID: history.last?.id)
      try writeCreateOnly(grant, to: try grantURL(grantID: grant.id))
      return grant
    }
  }

  @discardableResult
  public func revokeSession(
    sessionID: String,
    now: Date = Date()
  ) throws -> [TatwoRemoteSessionGrantV1] {
    let normalizedSession = try Self.normalized(sessionID, field: "sessionID")
    return try revokeMatching(now: now, reason: "session_archived") {
      $0.sessionID == normalizedSession
    }
  }

  @discardableResult
  public func revokeTarget(
    targetDeviceID: String,
    now: Date = Date()
  ) throws -> [TatwoRemoteSessionGrantV1] {
    let normalizedTarget = try Self.normalized(targetDeviceID, field: "targetDeviceID")
    return try revokeMatching(now: now, reason: "target_revoked") {
      $0.targetDeviceID == normalizedTarget
    }
  }

  private func revokeMatching(
    now: Date,
    reason: String,
    predicate: (TatwoRemoteSessionGrantV1) -> Bool
  ) throws -> [TatwoRemoteSessionGrantV1] {
    let candidates = try allEffectiveGrantProjections(now: now)
      .filter { predicate($0) && $0.isActive(at: now) }
    var revoked: [TatwoRemoteSessionGrantV1] = []
    for candidate in candidates {
      let lockURL = try scopeLockURL(
        sessionID: candidate.sessionID,
        targetDeviceID: candidate.targetDeviceID,
        contractID: candidate.contractID)
      let updated: TatwoRemoteSessionGrantV1? = try TatwoFileLock.withExclusiveLock(
        for: lockURL
      ) {
        guard
          let active = try sessionGrant(
            sessionID: candidate.sessionID,
            targetDeviceID: candidate.targetDeviceID,
            contractID: candidate.contractID,
            now: now),
          active.id == candidate.id
        else {
          return nil
        }
        let revocation = TatwoRemoteSessionGrantRevocationV1(
          grantID: active.id,
          sessionID: active.sessionID,
          targetDeviceID: active.targetDeviceID,
          contractID: active.contractID,
          revokedAt: now,
          reason: reason)
        try writeCreateOnly(
          revocation,
          to: try revocationURL(revocationID: revocation.id))
        return active.revoking(at: now)
      }
      if let updated { revoked.append(updated) }
    }
    return revoked
  }

  private func normalizedScope(
    sessionID: String,
    targetDeviceID: String,
    contractID: String
  ) throws -> (sessionID: String, targetDeviceID: String, contractID: String) {
    (
      try Self.normalized(sessionID, field: "sessionID"),
      try Self.normalized(targetDeviceID, field: "targetDeviceID"),
      try Self.normalized(contractID, field: "contractID")
    )
  }

  private func policyURL(targetDeviceID: String) throws -> URL {
    policyDirectoryURL.appendingPathComponent(
      "\(try Self.filenameToken(targetDeviceID)).json",
      isDirectory: false)
  }

  private func scopeLockURL(
    sessionID: String,
    targetDeviceID: String,
    contractID: String
  ) throws -> URL {
    let material = [sessionID, targetDeviceID, contractID].joined(separator: "\u{1F}")
    return lockDirectoryURL.appendingPathComponent(
      "\(try Self.filenameToken(material)).state",
      isDirectory: false)
  }

  private func grantURL(grantID: String) throws -> URL {
    grantDirectoryURL.appendingPathComponent(
      "\(try Self.filenameToken(grantID)).json",
      isDirectory: false)
  }

  private func revocationURL(revocationID: String) throws -> URL {
    revocationDirectoryURL.appendingPathComponent(
      "\(try Self.filenameToken(revocationID)).json",
      isDirectory: false)
  }

  private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    do {
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw TatwoRemoteBorrowAuthorizationError.unreadableRecord(url.lastPathComponent)
      }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(type, from: Data(contentsOf: url))
    } catch let error as TatwoRemoteBorrowAuthorizationError {
      throw error
    } catch {
      throw TatwoRemoteBorrowAuthorizationError.unreadableRecord(url.lastPathComponent)
    }
  }

  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try TatwoAtomicFile.write(try encoder.encode(value), to: url)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path)
  }

  private func writeCreateOnly<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try TatwoCreateOnlyFile.write(data, to: url, onDuplicate: {
      guard let existing = try? Data(contentsOf: url), existing == data else {
        throw TatwoRemoteBorrowAuthorizationError.recordScopeMismatch
      }
    })
  }

  private func allGrantIssuances() throws -> [TatwoRemoteSessionGrantV1] {
    try listJSONFiles(in: grantDirectoryURL).map { url in
      let grant: TatwoRemoteSessionGrantV1 = try read(
        TatwoRemoteSessionGrantV1.self,
        from: url)
      try Self.validateStoredGrant(grant)
      return grant
    }
  }

  private func allRevocations() throws -> [TatwoRemoteSessionGrantRevocationV1] {
    try listJSONFiles(in: revocationDirectoryURL).map { url in
      let revocation: TatwoRemoteSessionGrantRevocationV1 = try read(
        TatwoRemoteSessionGrantRevocationV1.self,
        from: url)
      guard
        revocation.schema == "TatwoRemoteSessionGrantRevocationV1",
        !revocation.grantID.isEmpty,
        !revocation.sessionID.isEmpty,
        !revocation.targetDeviceID.isEmpty,
        !revocation.contractID.isEmpty
      else {
        throw TatwoRemoteBorrowAuthorizationError.recordScopeMismatch
      }
      return revocation
    }
  }

  private func allEffectiveGrantProjections(
    now: Date
  ) throws -> [TatwoRemoteSessionGrantV1] {
    let grants = try allGrantIssuances()
    let revocations = try allRevocations()
    let revokedAtByGrantID = Dictionary(
      revocations.map { ($0.grantID, $0.revokedAt) },
      uniquingKeysWith: min)
    return grants.map { grant in
      guard let revokedAt = revokedAtByGrantID[grant.id] else { return grant }
      return grant.revoking(at: revokedAt)
    }
  }

  private func listJSONFiles(in directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw TatwoRemoteBorrowAuthorizationError.unreadableRecord(
        directory.lastPathComponent)
    }
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func validate(
    _ grant: TatwoRemoteSessionGrantV1,
    sessionID: String,
    targetDeviceID: String,
    contractID: String
  ) throws {
    guard
      try validateStoredGrant(grant),
      grant.sessionID == sessionID,
      grant.targetDeviceID == targetDeviceID,
      grant.contractID == contractID
    else {
      throw TatwoRemoteBorrowAuthorizationError.recordScopeMismatch
    }
  }

  @discardableResult
  private static func validateStoredGrant(
    _ grant: TatwoRemoteSessionGrantV1
  ) throws -> Bool {
    guard
      grant.schema == "TatwoRemoteSessionGrantV1",
      grant.risk == .lowRisk,
      !grant.id.isEmpty,
      !grant.sessionID.isEmpty,
      !grant.targetDeviceID.isEmpty,
      !grant.contractID.isEmpty,
      grant.expiresAt > grant.issuedAt
    else {
      throw TatwoRemoteBorrowAuthorizationError.recordScopeMismatch
    }
    return true
  }

  private static func grantOrder(
    _ lhs: TatwoRemoteSessionGrantV1,
    _ rhs: TatwoRemoteSessionGrantV1
  ) -> Bool {
    if lhs.issuedAt != rhs.issuedAt { return lhs.issuedAt < rhs.issuedAt }
    return lhs.id < rhs.id
  }

  static func normalizedIdentifier(_ value: String, field: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      !trimmed.contains("\0"),
      !trimmed.contains("\n"),
      !trimmed.contains("\r"),
      trimmed.utf8.count <= 1_024
    else {
      throw TatwoRemoteBorrowAuthorizationError.invalidIdentifier(field)
    }
    return trimmed
  }

  private static func normalized(_ value: String, field: String) throws -> String {
    try normalizedIdentifier(value, field: field)
  }

  private static func filenameToken(_ value: String) throws -> String {
    let normalizedValue = try normalized(value, field: "scope")
    return SHA256.hash(data: Data(normalizedValue.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
