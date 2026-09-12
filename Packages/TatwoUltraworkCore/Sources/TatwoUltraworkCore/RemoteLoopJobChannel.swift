import Foundation
import TatwoDomainContracts
#if canImport(Security)
import Security
#endif

/// Durable monotonic consume high-water (external to deletable channel marker files).
public protocol TatwoLoopResultConsumeHighWaterAnchor: Sendable {
  func load(jobID: String) throws -> TatwoLoopResultConsumeHighWaterV1?
  func save(_ record: TatwoLoopResultConsumeHighWaterV1) throws
}

/// Test-mode file-backed high-water (under channel root). Production uses Keychain.
public struct TatwoLoopResultConsumeHighWaterFileAnchor: TatwoLoopResultConsumeHighWaterAnchor {
  public let directoryURL: URL

  public init(directoryURL: URL) {
    self.directoryURL = directoryURL.standardizedFileURL
  }

  public func url(forJobID jobID: String) -> URL {
    directoryURL.appendingPathComponent(
      "\(TatwoLoopPathComponent.sanitize(jobID)).json",
      isDirectory: false)
  }

  public func load(jobID: String) throws -> TatwoLoopResultConsumeHighWaterV1? {
    let url = url(forJobID: jobID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      throw TatwoLoopJobStateError.resultConsumeConflict(
        jobID: jobID,
        detail: "consume high-water symlink refused")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
      TatwoLoopResultConsumeHighWaterV1.self,
      from: Data(contentsOf: url))
  }

  public func save(_ record: TatwoLoopResultConsumeHighWaterV1) throws {
    let url = url(forJobID: record.jobID)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try TatwoAtomicFile.write(try encoder.encode(record), to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path)
  }
}

/// Production Keychain high-water (per channel root + device + job).
public struct TatwoLoopResultConsumeHighWaterKeychainAnchor: TatwoLoopResultConsumeHighWaterAnchor {
  public static let serviceEnvKey = "TATWO_LOOP_CONSUME_HIGHWATER_SERVICE"
  public static let canonicalService = "ai.tatwo.ultrawork.loop-consume-highwater"

  private let service: String
  private let accountPrefix: String

  public static func configuration(
    hostDeviceID: String,
    channelRoot: URL,
    environment: [String: String]
  ) throws -> (service: String, accountPrefix: String) {
    let testMode = environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1"
    let configured =
      environment[serviceEnvKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let override = configured.flatMap { $0.isEmpty ? nil : $0 }
    if override != nil, !testMode {
      throw TatwoLoopJobStateError.resultConsumeConflict(
        jobID: "*",
        detail:
          "\(serviceEnvKey) is only allowed when \(TatwoLoopJobChannelTrust.testModeEnvKey)=1")
    }
    let service = override ?? canonicalService
    let safeHost = hostDeviceID.replacingOccurrences(of: ":", with: "_")
    // Production: fixed global account (not channel-path hashed) so switching
    // --channel-dir / JOB_CHANNEL_DIR cannot open a clean high-water namespace.
    // Test mode retains path hash for fixture isolation.
    let accountPrefix: String
    if testMode {
      let rootToken = TatwoLoopJobChannelTrust.sha256Hex(
        Data(channelRoot.standardizedFileURL.path.utf8))
      accountPrefix = "consume-hw:\(safeHost):\(String(rootToken.prefix(24)))"
    } else {
      accountPrefix = "consume-hw:\(safeHost):global"
    }
    return (service, accountPrefix)
  }

  public init(service: String, accountPrefix: String) {
    self.service = service
    self.accountPrefix = accountPrefix
  }

  /// Fail-closed stand-in when production high-water policy is violated.
  public struct Rejecting: TatwoLoopResultConsumeHighWaterAnchor {
    public let detail: String

    public init(detail: String) {
      self.detail = detail
    }

    public func load(jobID: String) throws -> TatwoLoopResultConsumeHighWaterV1? {
      throw TatwoLoopJobStateError.resultConsumeConflict(jobID: jobID, detail: detail)
    }

    public func save(_ record: TatwoLoopResultConsumeHighWaterV1) throws {
      throw TatwoLoopJobStateError.resultConsumeConflict(
        jobID: record.jobID,
        detail: detail)
    }
  }

  private func account(forJobID jobID: String) -> String {
    "\(accountPrefix):\(TatwoLoopPathComponent.sanitize(jobID))"
  }

  public func load(jobID: String) throws -> TatwoLoopResultConsumeHighWaterV1? {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(forJobID: jobID),
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = value as? Data else {
      throw TatwoLoopJobStateError.resultConsumeConflict(
        jobID: jobID,
        detail: "consume high-water keychain read status \(status)")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TatwoLoopResultConsumeHighWaterV1.self, from: data)
    #else
    throw TatwoLoopJobStateError.resultConsumeConflict(
      jobID: jobID,
      detail: "consume high-water keychain unavailable")
    #endif
  }

  public func save(_ record: TatwoLoopResultConsumeHighWaterV1) throws {
    #if canImport(Security)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(forJobID: record.jobID),
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    if updateStatus == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(add as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw TatwoLoopJobStateError.resultConsumeConflict(
          jobID: record.jobID,
          detail: "consume high-water keychain add status \(addStatus)")
      }
      return
    }
    throw TatwoLoopJobStateError.resultConsumeConflict(
      jobID: record.jobID,
      detail: "consume high-water keychain update status \(updateStatus)")
    #else
    throw TatwoLoopJobStateError.resultConsumeConflict(
      jobID: record.jobID,
      detail: "consume high-water keychain unavailable")
    #endif
  }
}

/// File-backed remote loop job channel (signed job / ack / result / journal).
///
/// Trust pins come from `TatwoLoopJobChannelTrust` (process `withPin` and/or
/// durable `TatwoDeviceTrustPinStore`). Green same-process e2e proves crypto
/// wiring; live dual-host pin+run remains a separate gate.
///
/// ## JobID binding (R3 batch 2 / C1)
/// Signature `payloadDigest` covers artifact bytes (including the embedded
/// `jobID` field). Consume sites still require `artifact.jobID == expectedJobID`
/// where **expectedJobID is the caller argument** (never trusted from filename
/// alone after decode). That blocks cross-job rename/copy of signed pairs.
///
/// ## Signature freshness (consume path only)
/// Runner job listing and ack acceptance enforce `signedAt` freshness.
/// Journal/result audit reads do not, so historical ledgers never retroactively fail.
/// Atomic trust snapshot holder so channel copies share live-reload updates.
public final class TatwoLoopJobChannelTrustBox: @unchecked Sendable {
  private let lock = NSLock()
  private var trust: TatwoLoopJobChannelTrust
  private let environment: [String: String]

  public init(
    trust: TatwoLoopJobChannelTrust,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.trust = trust
    self.environment = environment
  }

  public func snapshot() -> TatwoLoopJobChannelTrust {
    lock.lock()
    defer { lock.unlock() }
    return trust
  }

  public func replace(_ trust: TatwoLoopJobChannelTrust) {
    lock.lock()
    self.trust = trust
    lock.unlock()
  }

  /// Reload durable pins when pin-store generation advanced (revocation live reload).
  @discardableResult
  public func refreshFromDurableStoreIfNeeded() throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let reloaded = try trust.reloadedFromDurableStoreIfNeeded(environment: environment)
    let changed = reloaded.pinStoreGeneration != trust.pinStoreGeneration
      || reloaded.pinnedIdentities != trust.pinnedIdentities
    trust = reloaded
    return changed
  }
}

public struct TatwoLoopCancelTombstoneV1: Codable, Sendable, Equatable {
  public let schema: String
  public let jobID: String
  public let logicalJobID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  public let reason: String
  public let requestedAt: Date

  public init(
    schema: String = "TatwoLoopCancelTombstoneV1",
    jobID: String,
    logicalJobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    reason: String,
    requestedAt: Date
  ) {
    self.schema = schema
    self.jobID = jobID
    self.logicalJobID = logicalJobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.reason = reason
    self.requestedAt = requestedAt
  }
}

public enum TatwoLoopCancelOutcomeV1: Sendable, Equatable {
  case cancelled
  case terminalWon(TatwoLoopJobStatusV1)
}

public enum TatwoLoopCancelFaultPoint: String, Sendable, Equatable {
  case afterBody
  case afterSignature
  case afterJournal
  case afterAck
}

public final class TatwoLoopCancelFaultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var failAt: TatwoLoopCancelFaultPoint?

  public init(failAt: TatwoLoopCancelFaultPoint? = nil) {
    self.failAt = failAt
  }

  public func setFailAt(_ point: TatwoLoopCancelFaultPoint?) {
    lock.lock()
    failAt = point
    lock.unlock()
  }

  func check(_ point: TatwoLoopCancelFaultPoint, jobID: String) throws {
    lock.lock()
    let shouldFail = failAt == point
    lock.unlock()
    if shouldFail {
      throw TatwoLoopJobStateError.enqueueIncomplete(
        jobID: jobID,
        stage: "cancel_\(point.rawValue)")
    }
  }
}

public enum TatwoLoopJournalFaultPoint: String, Sendable, Equatable {
  case afterAuthoritativeBundle
  case afterCanonicalBody
}

public final class TatwoLoopJournalFaultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var failAt: TatwoLoopJournalFaultPoint?

  public init(failAt: TatwoLoopJournalFaultPoint? = nil) {
    self.failAt = failAt
  }

  public func setFailAt(_ point: TatwoLoopJournalFaultPoint?) {
    lock.lock()
    failAt = point
    lock.unlock()
  }

  func check(_ point: TatwoLoopJournalFaultPoint, jobID: String) throws {
    lock.lock()
    let shouldFail = failAt == point
    lock.unlock()
    if shouldFail {
      throw TatwoLoopJobStateError.enqueueIncomplete(
        jobID: jobID,
        stage: "journal_\(point.rawValue)")
    }
  }
}

private struct TatwoLoopSignedJournalBundleV1: Codable {
  let schema: String
  let jobID: String
  let journalBytes: Data
  let detachedSignature: TatwoDeviceSignatureV1

  init(
    jobID: String,
    journalBytes: Data,
    detachedSignature: TatwoDeviceSignatureV1
  ) {
    self.schema = "TatwoLoopSignedJournalBundleV1"
    self.jobID = jobID
    self.journalBytes = journalBytes
    self.detachedSignature = detachedSignature
  }
}

public struct TatwoLoopJobChannel: Sendable {
  public let rootURL: URL
  private let trustBox: TatwoLoopJobChannelTrustBox
  private let consumeHighWaterAnchor: any TatwoLoopResultConsumeHighWaterAnchor
  private let globalAntiRollbackAnchor: (any TatwoLoopGlobalAntiRollbackAnchor)?
  public let originAuthorityProvider: any TatwoOriginAuthorityProviding
  private let environment: [String: String]
  /// Test-only: inject write failures at a specific enqueue stage.
  private let enqueueFaultBox: TatwoLoopChannelEnqueueFaultBox?
  /// Test-only: inject a crash gap between cancel tombstone body/signature.
  private let cancelFaultBox: TatwoLoopCancelFaultBox?
  /// Test-only: inject crash gaps after the authoritative signed journal bundle
  /// and after its legacy body projection but before the detached sidecar.
  private let journalFaultBox: TatwoLoopJournalFaultBox?

  public var trust: TatwoLoopJobChannelTrust {
    trustBox.snapshot()
  }

  /// Internal fixture authority seam. Production callers cannot reach legacy
  /// unbound dispatch paths unless the channel itself was explicitly created
  /// with `TATWO_TEST_MODE=1`.
  var testModeEnabled: Bool {
    environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1"
  }

  public init(
    rootURL: URL,
    trust: TatwoLoopJobChannelTrust,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    consumeHighWaterAnchor: (any TatwoLoopResultConsumeHighWaterAnchor)? = nil,
    globalAntiRollbackAnchor: (any TatwoLoopGlobalAntiRollbackAnchor)? = nil,
    enqueueFaultBox: TatwoLoopChannelEnqueueFaultBox? = nil,
    cancelFaultBox: TatwoLoopCancelFaultBox? = nil,
    journalFaultBox: TatwoLoopJournalFaultBox? = nil,
    originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil
  ) {
    let standardized = rootURL.standardizedFileURL
    self.rootURL = standardized
    self.trustBox = TatwoLoopJobChannelTrustBox(trust: trust, environment: environment)
    self.consumeHighWaterAnchor =
      consumeHighWaterAnchor
      ?? Self.defaultConsumeHighWaterAnchor(
        rootURL: standardized,
        hostDeviceID: trust.localIdentity.deviceID,
        environment: environment)
    self.globalAntiRollbackAnchor =
      globalAntiRollbackAnchor
      ?? Self.defaultGlobalAntiRollbackAnchor(
        hostDeviceID: trust.localIdentity.deviceID,
        environment: environment)
    self.originAuthorityProvider = Self.resolveOriginAuthorityProvider(
      originAuthorityProvider,
      environment: environment)
    self.environment = environment
    self.enqueueFaultBox = enqueueFaultBox
    self.cancelFaultBox = cancelFaultBox
    self.journalFaultBox = journalFaultBox
  }

  public init(
    rootURL: URL,
    trustBox: TatwoLoopJobChannelTrustBox,
    consumeHighWaterAnchor: (any TatwoLoopResultConsumeHighWaterAnchor)? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    globalAntiRollbackAnchor: (any TatwoLoopGlobalAntiRollbackAnchor)? = nil,
    enqueueFaultBox: TatwoLoopChannelEnqueueFaultBox? = nil,
    cancelFaultBox: TatwoLoopCancelFaultBox? = nil,
    journalFaultBox: TatwoLoopJournalFaultBox? = nil,
    originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil
  ) {
    let standardized = rootURL.standardizedFileURL
    self.rootURL = standardized
    self.trustBox = trustBox
    let hostID = trustBox.snapshot().localIdentity.deviceID
    self.consumeHighWaterAnchor =
      consumeHighWaterAnchor
      ?? Self.defaultConsumeHighWaterAnchor(
        rootURL: standardized,
        hostDeviceID: hostID,
        environment: environment)
    self.globalAntiRollbackAnchor =
      globalAntiRollbackAnchor
      ?? Self.defaultGlobalAntiRollbackAnchor(
        hostDeviceID: hostID,
        environment: environment)
    self.originAuthorityProvider = Self.resolveOriginAuthorityProvider(
      originAuthorityProvider,
      environment: environment)
    self.environment = environment
    self.enqueueFaultBox = enqueueFaultBox
    self.cancelFaultBox = cancelFaultBox
    self.journalFaultBox = journalFaultBox
  }

  /// Test mode: file under channel root. Production: Keychain side item (not FS-deletable).
  public static func defaultConsumeHighWaterAnchor(
    rootURL: URL,
    hostDeviceID: String,
    environment: [String: String]
  ) -> any TatwoLoopResultConsumeHighWaterAnchor {
    if environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1" {
      return TatwoLoopResultConsumeHighWaterFileAnchor(
        directoryURL: rootURL.appendingPathComponent("consume-highwater", isDirectory: true))
    }
    do {
      let config = try TatwoLoopResultConsumeHighWaterKeychainAnchor.configuration(
        hostDeviceID: hostDeviceID,
        channelRoot: rootURL,
        environment: environment)
      return TatwoLoopResultConsumeHighWaterKeychainAnchor(
        service: config.service,
        accountPrefix: config.accountPrefix)
    } catch {
      // Fail closed: do not fall back to a deletable filesystem high-water.
      return TatwoLoopResultConsumeHighWaterKeychainAnchor.Rejecting(
        detail: "\(error)")
    }
  }

  /// Production: fixed Keychain global anti-rollback. Test mode: nil (fixture isolation).
  public static func defaultGlobalAntiRollbackAnchor(
    hostDeviceID: String,
    environment: [String: String]
  ) -> (any TatwoLoopGlobalAntiRollbackAnchor)? {
    if environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1" {
      return nil
    }
    return TatwoLoopGlobalAntiRollbackKeychainAnchor(hostDeviceID: hostDeviceID)
  }

  /// Compare durable pin-store generation and atomically replace trust when stale.
  @discardableResult
  public func refreshTrustFromDurableStoreIfNeeded() throws -> Bool {
    try trustBox.refreshFromDurableStoreIfNeeded()
  }

  /// Target-side execution claim (gate 2): atomic claim of jobID+nonce+digest before
  /// any channel transition or engine run. No-op when global anti-rollback is unset
  /// (test-mode fixture isolation). Throws when already claimed or binding conflicts.
  public func claimTargetExecution(for job: TatwoLoopJobV1) throws {
    try requireOriginMutationAuthority(
      for: job,
      surface: "remote_loop_target_claim",
      now: Date())
    guard let global = globalAntiRollbackAnchor else { return }
    let digest = try job.canonicalDigest()
    try TatwoProductionLayoutLock.claimTargetExecution(
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: digest,
      anchor: global)
  }

  /// Whether a durable target-execution claim already blocks this attempt.
  public func hasTargetExecutionClaim(for job: TatwoLoopJobV1) throws -> Bool {
    guard let global = globalAntiRollbackAnchor else { return false }
    let digest = try job.canonicalDigest()
    guard let prior = try global.loadExecutedClaim(jobID: job.jobID) else { return false }
    return prior.bindingMatches(dispatchNonce: job.dispatchNonce, jobCanonicalDigest: digest)
  }

  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    trust: TatwoLoopJobChannelTrust
  ) throws -> TatwoLoopJobChannel {
    guard let raw = environment["TATWO_ULTRAWORK_JOB_CHANNEL_DIR"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else {
      throw TatwoLoopJobStateError.missingChannelRoot
    }
    return TatwoLoopJobChannel(
      rootURL: URL(fileURLWithPath: raw, isDirectory: true),
      trust: trust,
      environment: environment)
  }

  /// Test-only authority swap used to simulate lease recall.  Production
  /// environments return the original sealed channel and cannot rebind.
  internal func replacingOriginAuthorityProvider(
    _ provider: (any TatwoOriginAuthorityProviding)?
  ) -> TatwoLoopJobChannel {
    guard environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1" else {
      return self
    }
    return TatwoLoopJobChannel(
      rootURL: rootURL,
      trust: trust,
      environment: environment,
      consumeHighWaterAnchor: consumeHighWaterAnchor,
      globalAntiRollbackAnchor: globalAntiRollbackAnchor,
      enqueueFaultBox: enqueueFaultBox,
      cancelFaultBox: cancelFaultBox,
      originAuthorityProvider: provider)
  }

  private static func resolveOriginAuthorityProvider(
    _ provider: (any TatwoOriginAuthorityProviding)?,
    environment: [String: String]
  ) -> any TatwoOriginAuthorityProviding {
    let testMode = environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1"
    if testMode {
      return provider ?? TatwoDefaultOriginAuthorityProvider()
    }
    // Outside test mode, only the durable handoff implementation is a
    // production authority source.  Unknown providers and nil are fenced.
    if let provider, provider is TatwoHandoffLeaseTransferStoreV1 {
      return provider
    }
    return TatwoUnavailableOriginAuthorityProvider()
  }

  @discardableResult
  public func enqueue(_ job: TatwoLoopJobV1) throws -> TatwoLoopJobV1 {
    try job.validate()
    try requireOriginMutationAuthority(
      for: job,
      surface: "remote_loop_dispatch",
      now: Date())
    let journalURL = journalURL(forJobID: job.jobID)
    return try TatwoFileLock.withExclusiveLock(for: journalURL) {
      let destination = jobURL(for: job)
      let signatureURL = jobSignatureURL(for: job)
      let jobDigest = try job.canonicalDigest()
      if verifiedCancelTombstoneForTarget(job: job) != nil {
        throw TatwoLoopJobStateError.invalidPayload(
          "remote loop job \(job.jobID) was cancelled before publication")
      }

      if FileManager.default.fileExists(atPath: destination.path) {
        if FileManager.default.fileExists(atPath: signatureURL.path) {
          let existing = try decodeVerifiedJob(
            from: destination,
            expectedJobID: job.jobID,
            enforceFreshness: false)
          guard existing == job else {
            throw TatwoLoopJobStateError.duplicateJob(job.jobID)
          }
          // Fully committed enqueue is idempotent. Partial orphans resume remaining stages.
          if hasCommitMarkerFile(forJobID: job.jobID),
            FileManager.default.fileExists(
              atPath: commitMarkerSignatureURL(forJobID: job.jobID).path)
          {
            guard try commitMarkerMatches(job: existing, digest: jobDigest) else {
              throw TatwoLoopJobStateError.attemptBindingMismatch(
                jobID: job.jobID,
                detail: "commit marker does not match existing job")
            }
            return existing
          }
        } else {
          // Partial body without signature cannot be verified; only resume identical content.
          let partial = try decode(TatwoLoopJobV1.self, from: Data(contentsOf: destination))
          guard partial == job else {
            throw TatwoLoopJobStateError.duplicateJob(job.jobID)
          }
        }
      }

      // Stage 1: job body (without signature) — incomplete without later commit marker.
      if !FileManager.default.fileExists(atPath: destination.path) {
        try checkEnqueueStage(.job, jobID: job.jobID)
        try writeJobBodyCreateOnly(job, to: destination)
      }

      // Stage 2: job signature sidecar.
      if !FileManager.default.fileExists(atPath: signatureURL.path) {
        try checkEnqueueStage(.signature, jobID: job.jobID)
        try writeJobSignatureCreateOnly(
          for: job,
          bodyURL: destination,
          signatureURL: signatureURL)
      }

      // Stage 3: queued journal (signed ledger).
      if !FileManager.default.fileExists(atPath: journalURL.path)
        || !FileManager.default.fileExists(
          atPath: journalSignatureURL(forJobID: job.jobID).path)
      {
        try checkEnqueueStage(.journal, jobID: job.jobID)
        let initial = TatwoLoopJobJournalEntryV1(
          jobID: job.jobID,
          logicalJobID: job.logicalJobID,
          dispatchNonce: job.dispatchNonce,
          jobCanonicalDigest: jobDigest,
          sequence: 1,
          from: nil,
          to: .queued,
          reason: "origin-enqueued",
          occurredAt: job.createdAt)
        try writeInitialJournalEntryCreateOnly(initial, to: journalURL)
      }

      // Stage 4: queued ack.
      let ackPath = ackURL(forJobID: job.jobID).path
      if !FileManager.default.fileExists(atPath: ackPath)
        || !FileManager.default.fileExists(
          atPath: ackSignatureURL(forJobID: job.jobID).path)
      {
        try checkEnqueueStage(.ack, jobID: job.jobID)
        try writeAckCreateOnly(
          TatwoLoopJobAckV1(
            jobID: job.jobID,
            logicalJobID: job.logicalJobID,
            dispatchNonce: job.dispatchNonce,
            jobCanonicalDigest: jobDigest,
            status: .queued,
            updatedAt: job.createdAt),
          forJobID: job.jobID)
      }

      // Stage 5 (final): commit marker — atomic completeness signal for target fail-closed.
      if !hasCommitMarkerFile(forJobID: job.jobID)
        || !FileManager.default.fileExists(
          atPath: commitMarkerSignatureURL(forJobID: job.jobID).path)
      {
        if verifiedCancelTombstoneForTarget(job: job) != nil {
          throw TatwoLoopJobStateError.invalidPayload(
            "remote loop job \(job.jobID) was cancelled before commit marker")
        }
        try checkEnqueueStage(.commitMarker, jobID: job.jobID)
        try writeCommitMarkerCreateOnly(
          TatwoLoopJobCommitMarkerV1(
            jobID: job.jobID,
            logicalJobID: job.logicalJobID,
            dispatchNonce: job.dispatchNonce,
            jobCanonicalDigest: jobDigest,
            committedAt: job.createdAt),
          forJobID: job.jobID)
      }

      return job
    }
  }

  /// Whether the job has a final enqueue commit marker (complete channel write).
  public func hasCommitMarker(forJobID jobID: String) -> Bool {
    hasCommitMarkerFile(forJobID: jobID)
  }

  /// Fail-closed readiness: commit marker + matching queued ack required before target run.
  public func isReadyForTargetExecution(job: TatwoLoopJobV1) throws -> Bool {
    let digest = try job.canonicalDigest()
    // An attacker-writable body file is not cancellation authority. Only the
    // exact origin-signed tombstone may suppress target execution; malformed
    // candidates are rejected durably and otherwise ignored.
    if verifiedCancelTombstoneForTarget(job: job) != nil {
      return false
    }
    guard hasCommitMarkerFile(forJobID: job.jobID) else { return false }
    guard try commitMarkerMatches(job: job, digest: digest) else { return false }
    guard let ack = try ack(for: job.jobID) else { return false }
    guard ack.jobID == job.jobID,
      ack.dispatchNonce == job.dispatchNonce,
      ack.jobCanonicalDigest == digest
    else { return false }
    // Fresh path: still queued.
    if ack.status == .queued { return true }
    // C5 recovery: durable mid-flight (delivered/accepted/running) without a result.
    switch ack.status {
    case .delivered, .accepted, .running:
      if (try? resultForAudit(for: job.jobID)) != nil { return false }
      return true
    case .queued, .completed, .failed, .cancelled, .verified:
      return false
    }
  }

  @discardableResult
  public func transition(
    jobID: String,
    to status: TatwoLoopJobStatusV1,
    reason: String,
    result: TatwoLoopJobResultReceiptV1? = nil,
    /// Target raw output bytes; written content→signature before the result receipt.
    outputData: Data? = nil,
    now: Date = Date()
  ) throws -> TatwoLoopJobJournalEntryV1 {
    let job = try job(forJobID: jobID)
    let surface =
      status == .verified
      ? "remote_loop_origin_accept"
      : "remote_loop_channel_transition"
    try requireOriginMutationAuthority(for: job, surface: surface, now: now)
    let journalURL = journalURL(forJobID: jobID)
    return try TatwoFileLock.withExclusiveLock(for: journalURL) {
      let journal = try loadJournal(forJobID: jobID, url: journalURL)
      let current = try requireCurrentStatus(journal, jobID: jobID)
      let tombstone = verifiedCancelTombstoneForTarget(job: job)
      let cancellationWins =
        tombstone != nil
        && ![.completed, .failed, .cancelled, .verified].contains(current)
      let effectiveStatus: TatwoLoopJobStatusV1 = cancellationWins ? .cancelled : status
      // Cancellation authority is origin-owned. If it wins the race, target
      // completion bytes and its proposed result are late, non-authoritative
      // artifacts and must not be synthesized into a cancelled target receipt.
      let effectiveResult: TatwoLoopJobResultReceiptV1? = cancellationWins ? nil : result
      if cancellationWins {
        // The signed create-only tombstone is the stable per-job fence. It may
        // advance any non-terminal channel state directly to cancelled.
      } else {
        let isTerminalCommitRecovery =
          effectiveResult != nil
          && current == effectiveStatus
          && [.completed, .failed, .cancelled].contains(current)
          && effectiveResult?.projectionSequence == journal.last?.sequence
        if !isTerminalCommitRecovery {
          try TatwoLoopJobStateMachine.validate(from: current, to: effectiveStatus)
        }
      }
      if let effectiveResult, effectiveResult.status != effectiveStatus {
        throw TatwoLoopJobStateError.invalidPayload(
          "result status \(effectiveResult.status.rawValue) does not match \(effectiveStatus.rawValue)")
      }
      let jobDigest = try job.canonicalDigest()
      let isTerminalCommitRecovery =
        !cancellationWins
        && effectiveResult != nil
        && current == effectiveStatus
        && [.completed, .failed, .cancelled].contains(current)
        && effectiveResult?.projectionSequence == journal.last?.sequence
      let nextSequence =
        isTerminalCommitRecovery
        ? (journal.last?.sequence ?? UInt64(journal.count))
        : UInt64(journal.count) + 1
      if let effectiveResult {
        try requireAttemptBinding(
          jobID: jobID,
          dispatchNonce: effectiveResult.dispatchNonce,
          jobCanonicalDigest: effectiveResult.jobCanonicalDigest,
          job: job,
          artifact: .result)
        guard effectiveResult.projectionSequence == nextSequence else {
          throw TatwoLoopJobStateError.invalidPayload(
            "result projectionSequence \(effectiveResult.projectionSequence) != journal sequence \(nextSequence)")
        }
        if let outputData {
          let digest = TatwoLoopJobDigest.sha256(outputData)
          guard effectiveResult.outputDigest == digest else {
            throw TatwoLoopJobStateError.invalidPayload(
              "result outputDigest does not match provided outputData")
          }
          guard effectiveResult.outputBytes == outputData.count else {
            throw TatwoLoopJobStateError.invalidPayload(
              "result outputBytes does not match provided outputData length")
          }
        } else if effectiveResult.outputDigest != nil {
          throw TatwoLoopJobStateError.invalidPayload(
            "result with outputDigest requires outputData for prepare/commit write")
        }
      }
      let entry: TatwoLoopJobJournalEntryV1
      if isTerminalCommitRecovery, let committed = journal.last {
        entry = committed
      } else {
        entry = TatwoLoopJobJournalEntryV1(
          jobID: jobID,
          logicalJobID: job.logicalJobID,
          dispatchNonce: job.dispatchNonce,
          jobCanonicalDigest: jobDigest,
          sequence: nextSequence,
          from: current,
          to: effectiveStatus,
          reason: cancellationWins ? "origin-cancel-tombstone" : reason,
          occurredAt: now)
        try appendJournalEntry(entry, to: journalURL)
      }
      let previousResult =
        cancellationWins ? nil : try loadVerifiedResultIfPresent(forJobID: jobID, job: job)
      let resolvedResult = cancellationWins ? nil : effectiveResult ?? previousResult
      // Prepare/commit: raw output + signature first, then signed result, then ack.
      // Half-written output (content without signature) is never accepted by readers.
      if effectiveResult != nil, let outputData {
        try writeOutputArtifactBodyAndSignature(forJobID: jobID, data: outputData)
      }
      if let effectiveResult {
        try writeSignedJSON(
          effectiveResult,
          to: resultURL(forJobID: jobID),
          purpose: .loopResult,
          signatureURL: resultSignatureURL(forJobID: jobID),
          artifact: .result,
          jobID: jobID)
      }
      try writeAck(
        TatwoLoopJobAckV1(
          jobID: jobID,
          logicalJobID: job.logicalJobID,
          dispatchNonce: job.dispatchNonce,
          jobCanonicalDigest: jobDigest,
          status: effectiveStatus,
          updatedAt: now,
          result: resolvedResult),
        forJobID: jobID)
      return entry
    }
  }

  /// Origin/audit read: verified output bytes bound to the verified result receipt.
  /// Fail-closed on missing/invalid signature, digest mismatch, or attempt binding mismatch.
  public func outputArtifact(for jobID: String) throws -> TatwoLoopOutputArtifactV1 {
    _ = try refreshTrustFromDurableStoreIfNeeded()
    let job = try job(forJobID: jobID)
    guard let result = try loadVerifiedResultIfPresent(forJobID: jobID, job: job) else {
      throw TatwoLoopJobStateError.invalidPayload(
        "result receipt missing for output read of \(jobID)")
    }
    guard let expectedDigest = result.outputDigest else {
      throw TatwoLoopJobStateError.invalidPayload(
        "result has no outputDigest for \(jobID)")
    }
    let data = try loadVerifiedOutputBytes(forJobID: jobID, job: job)
    let actualDigest = TatwoLoopJobDigest.sha256(data)
    guard actualDigest == expectedDigest else {
      try recordRejection(
        jobID: jobID,
        artifact: .output,
        reason: .digestMismatch,
        detail: "output digest \(actualDigest) != receipt \(expectedDigest)")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: jobID,
        reason: TatwoLoopChannelRejectReasonV1.digestMismatch.rawValue)
    }
    guard data.count == result.outputBytes else {
      try recordRejection(
        jobID: jobID,
        artifact: .output,
        reason: .digestMismatch,
        detail: "output bytes \(data.count) != receipt \(result.outputBytes)")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: jobID,
        reason: TatwoLoopChannelRejectReasonV1.digestMismatch.rawValue)
    }
    // Attempt binding is enforced via the verified result (nonce/digest ↔ job).
    return TatwoLoopOutputArtifactV1(
      jobID: job.jobID,
      dispatchNonce: result.dispatchNonce,
      jobCanonicalDigest: result.jobCanonicalDigest,
      outputDigest: actualDigest,
      outputBytes: data.count,
      outputTruncated: result.outputTruncated,
      status: result.status,
      exitCode: result.exitCode,
      data: data)
  }

  public func jobs(forTargetDeviceID targetDeviceID: String) throws -> [TatwoLoopJobV1] {
    let directory = outboxURL(forTargetDeviceID: targetDeviceID)
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var accepted: [TatwoLoopJobV1] = []
    for url in urls {
      do {
        // Filename is a hint only; binding uses artifact.jobID after verify.
        let provisionalJobID = url.deletingPathExtension().lastPathComponent
        // Consume path: runner takes jobs for execution — enforce signedAt freshness.
        let job = try decodeVerifiedJob(
          from: url,
          expectedJobID: provisionalJobID,
          enforceFreshness: true)
        guard job.targetDeviceID == targetDeviceID else {
          try recordRejection(
            jobID: job.jobID,
            artifact: .job,
            reason: .producerMismatch,
            detail: "targetDeviceID mismatch")
          continue
        }
        accepted.append(job)
      } catch let error as TatwoLoopJobStateError {
        if case let .signatureRejected(jobID, reason) = error {
          // Already journaled inside verify path when possible.
          _ = jobID
          _ = reason
        }
        continue
      }
    }
    return accepted
  }

  public func job(forJobID jobID: String) throws -> TatwoLoopJobV1 {
    // expectedJobID is the caller argument — never derived solely from a filename.
    // Audit/converge path: do not enforce signedAt freshness (historical jobs remain readable).
    let root = rootURL.appendingPathComponent("outbox", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else {
      throw TatwoLoopJobStateError.jobNotFound(jobID)
    }
    let targets = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles])
    for target in targets {
      let candidate = target.appendingPathComponent("\(safeComponent(jobID)).json")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return try decodeVerifiedJob(
          from: candidate,
          expectedJobID: jobID,
          enforceFreshness: false)
      }
    }
    throw TatwoLoopJobStateError.jobNotFound(jobID)
  }

  public func currentStatus(for jobID: String) throws -> TatwoLoopJobStatusV1 {
    let entries = try journal(for: jobID)
    return try requireCurrentStatus(entries, jobID: jobID)
  }

  public func journal(for jobID: String) throws -> [TatwoLoopJobJournalEntryV1] {
    let url = journalURL(forJobID: jobID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      try loadJournal(forJobID: jobID, url: url)
    }
  }

  /// Typed reader for design 5.6-1「已啟動」(`TatwoLoopStartReceiptV1`).
  ///
  /// Projects from durable journal `to=.accepted` (prefer reason `runner-accepted`)
  /// plus the **current** verified journal ledger signature (origin or target).
  /// Does **not** write a separate start artifact — see `TatwoLoopStartReceiptV1`
  /// docs for signer semantics (not a frozen target-only accept proof).
  public func startReceipt(for jobID: String) throws -> TatwoLoopStartReceiptV1? {
    let job = try job(forJobID: jobID)
    let entries = try journal(for: jobID)
    let entry =
      entries.first(where: {
        $0.to == .accepted && $0.reason == TatwoLoopStartReceiptV1.runnerAcceptedReason
      })
      ?? entries.first(where: { $0.to == .accepted })
    guard let entry else { return nil }
    let signature = try loadSignature(
      from: journalSignatureURL(forJobID: jobID),
      jobID: jobID,
      artifact: .journal)
    return try TatwoLoopStartReceiptV1.fromJournalEntry(
      entry,
      job: job,
      journalSignature: signature)
  }

  public func ack(for jobID: String) throws -> TatwoLoopJobAckV1? {
    _ = try refreshTrustFromDurableStoreIfNeeded()
    let url = ackURL(forJobID: jobID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let job = try job(forJobID: jobID)
    // Consume path: accepting an ack enforces signedAt freshness.
    return try decodeVerifiedAck(from: url, job: job, enforceFreshness: true)
  }

  /// Read-only audit path: verify and return result without consume markers or state change.
  public func resultForAudit(for jobID: String) throws -> TatwoLoopJobResultReceiptV1? {
    let job = try job(forJobID: jobID)
    return try loadVerifiedResultIfPresent(forJobID: jobID, job: job)
  }

  /// Backward-compatible alias for audit reads (does not consume).
  public func result(for jobID: String) throws -> TatwoLoopJobResultReceiptV1? {
    try resultForAudit(for: jobID)
  }

  /// State-changing consume path: channel marker + durable high-water (dual check).
  /// Marker missing while high-water shows consumed → fail closed (not "never consumed").
  /// Same digest with both present is idempotent; different digest is rejected.
  @discardableResult
  public func consumeResult(
    for jobID: String,
    validating validate: (
      TatwoLoopJobResultReceiptV1,
      TatwoLoopJobV1
    ) throws -> Void = { _, _ in }
  ) throws -> TatwoLoopJobResultReceiptV1? {
    _ = try refreshTrustFromDurableStoreIfNeeded()
    let job = try job(forJobID: jobID)
    try requireOriginMutationAuthority(
      for: job,
      surface: "remote_loop_result_consume",
      now: Date())
    let markerURL = resultConsumeMarkerURL(forJobID: jobID)
    return try TatwoFileLock.withExclusiveLock(for: markerURL) {
      guard let result = try loadVerifiedResultIfPresent(forJobID: jobID, job: job) else {
        return nil
      }
      // Validate all semantic bindings while still inside the one-time consume
      // lock and before writing marker/high-water. Invalid target evidence must
      // never become durably consumed.
      try validate(result, job)
      let digest = try result.canonicalDigest()
      let jobDigest = try job.canonicalDigest()
      let markerPresent = FileManager.default.fileExists(atPath: markerURL.path)
      let highWater = try consumeHighWaterAnchor.load(jobID: jobID)

      // E2: global anti-rollback — old channel namespace below fixed high-water is rejected
      // even when per-job Keychain/marker state was relocated or wiped partially.
      if let global = globalAntiRollbackAnchor,
        let prior = try global.loadConsumedJob(jobID: jobID)
      {
        let matches =
          prior.dispatchNonce == job.dispatchNonce
          && prior.jobCanonicalDigest == jobDigest
          && prior.resultDigest == digest
          && prior.projectionSequence == result.projectionSequence
        if !matches {
          if result.projectionSequence < prior.projectionSequence
            || prior.dispatchNonce != job.dispatchNonce
            || prior.jobCanonicalDigest != jobDigest
          {
            throw TatwoLoopJobStateError.resultConsumeConflict(
              jobID: jobID,
              detail:
                "global anti-rollback: channel readback below consume high-water")
          }
          throw TatwoLoopJobStateError.resultConsumeConflict(
            jobID: jobID,
            detail: "global anti-rollback: consume evidence mismatch")
        }
      }

      // Dual-check: high-water without marker is fail-closed (FS wipe of marker only).
      if let highWater, !markerPresent {
        try verifyConsumeHighWater(highWater, job: job)
        throw TatwoLoopJobStateError.resultConsumeConflict(
          jobID: jobID,
          detail: "consume marker missing while high-water present")
      }

      if let highWater, markerPresent {
        try verifyConsumeHighWater(highWater, job: job)
        let marker = try decode(TatwoLoopResultConsumeMarkerV1.self, from: markerURL)
        guard highWater.dispatchNonce == job.dispatchNonce,
          highWater.jobCanonicalDigest == jobDigest,
          marker.jobID == jobID,
          marker.dispatchNonce == job.dispatchNonce,
          marker.jobCanonicalDigest == jobDigest
        else {
          throw TatwoLoopJobStateError.attemptBindingMismatch(
            jobID: jobID,
            detail: "consume high-water/marker attempt mismatch")
        }
        guard highWater.resultDigest == digest,
          highWater.projectionSequence == result.projectionSequence,
          marker.resultDigest == digest
        else {
          throw TatwoLoopJobStateError.resultConsumeConflict(
            jobID: jobID,
            detail: "stale result replay after consume high-water")
        }
        return result
      }

      if markerPresent, highWater == nil {
        let marker = try decode(TatwoLoopResultConsumeMarkerV1.self, from: markerURL)
        guard marker.jobID == jobID,
          marker.dispatchNonce == job.dispatchNonce,
          marker.jobCanonicalDigest == jobDigest
        else {
          throw TatwoLoopJobStateError.resultConsumeConflict(
            jobID: jobID,
            detail: "consume marker attempt mismatch")
        }
        guard marker.resultDigest == digest else {
          throw TatwoLoopJobStateError.resultConsumeConflict(
            jobID: jobID,
            detail: "stale result replay after consume")
        }
        // Backfill durable high-water when only legacy marker exists.
        try writeSignedConsumeHighWater(
          job: job,
          result: result,
          resultDigest: digest)
        return result
      }

      // First consume: write marker + durable high-water together.
      let now = Date()
      let unsignedBody = TatwoLoopResultConsumeMarkerV1(
        jobID: jobID,
        dispatchNonce: job.dispatchNonce,
        jobCanonicalDigest: jobDigest,
        resultDigest: digest,
        projectionSequence: result.projectionSequence,
        consumedAt: now,
        authorization: nil)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      let payload = try encoder.encode(unsignedBody)
      let signature = try trust.sign(payload: payload, purpose: .loopAck, signedAt: now)
      let marker = TatwoLoopResultConsumeMarkerV1(
        jobID: jobID,
        dispatchNonce: job.dispatchNonce,
        jobCanonicalDigest: jobDigest,
        resultDigest: digest,
        projectionSequence: result.projectionSequence,
        consumedAt: now,
        authorization: signature)
      try writeAtomic(try encoder.encode(marker), to: markerURL)
      try writeSignedConsumeHighWater(
        job: job,
        result: result,
        resultDigest: digest)
      return result
    }
  }

  public func resultConsumeMarkerURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("consume-markers", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).json")
  }

  /// Test-mode / inspection path for file high-water layout (production uses Keychain).
  public func resultConsumeHighWaterURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("consume-highwater", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).json")
  }

  public func rejections(for jobID: String) throws -> [TatwoLoopJobRejectEntryV1] {
    let url = rejectJournalURL(forJobID: jobID)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    let lines = String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isNewline)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try lines.map { line in
      try decoder.decode(TatwoLoopJobRejectEntryV1.self, from: Data(line.utf8))
    }
  }

  /// Internal primitive. Production cancellation is exposed by
  /// `TatwoGoalRunDispatchLifecycle.cancelRemoteOutbox`, which owns the
  /// GoalRun/registry projection around this per-job channel fence.
  @discardableResult
  func signalCancel(
    for job: TatwoLoopJobV1,
    reason: String = "origin-cancel-requested",
    now: Date = Date()
  ) throws -> TatwoLoopCancelOutcomeV1 {
    try requireOriginMutationAuthority(
      for: job,
      surface: "remote_loop_cancel",
      now: now)
    let journalURL = journalURL(forJobID: job.jobID)
    return try TatwoFileLock.withExclusiveLock(for: journalURL) {
      try publishCancelTombstoneLocked(
        for: job,
        reason: reason,
        now: now)
    }
  }

  /// Backward-compatible internal test seam for already-published jobs.
  @discardableResult
  func signalCancel(for jobID: String) throws -> TatwoLoopCancelOutcomeV1 {
    try signalCancel(for: job(forJobID: jobID))
  }

  /// Generic recovery is verify-only: it may observe and apply an exact
  /// origin-signed tombstone, but it never signs attacker-writable body bytes.
  /// The explicit durable origin `.cancelling` intent retries through
  /// `signalCancel(for:)`, which is the only recovery path allowed to complete
  /// a missing signature.
  @discardableResult
  func reconcileCancelTombstone(
    for job: TatwoLoopJobV1
  ) throws -> TatwoLoopCancelOutcomeV1? {
    try requireOriginMutationAuthority(
      for: job,
      surface: "remote_loop_cancel_reconcile",
      now: Date())
    let journalURL = journalURL(forJobID: job.jobID)
    return try TatwoFileLock.withExclusiveLock(for: journalURL) {
      guard let tombstone = verifiedCancelTombstoneForTarget(job: job) else {
        return nil
      }
      return try applyCancellationLocked(
        job: job,
        tombstone: tombstone)
    }
  }

  public func isCancelRequested(for job: TatwoLoopJobV1) -> Bool {
    guard job.stopConditions.cancelFileSignal else { return false }
    return verifiedCancelTombstoneForTarget(job: job) != nil
  }

  /// Target-side cancellation reader. Invalid/incomplete cancellation artifacts
  /// are evidence of a rejected request, not authority to stop or suppress work.
  /// Only the explicit origin signal path may complete a missing signature.
  private func verifiedCancelTombstoneForTarget(
    job: TatwoLoopJobV1
  ) -> TatwoLoopCancelTombstoneV1? {
    do {
      return try cancelTombstoneLocked(
        for: job,
        completeMissingSignature: false)
    } catch {
      return nil
    }
  }

  private func publishCancelTombstoneLocked(
    for job: TatwoLoopJobV1,
    reason: String,
    now: Date
  ) throws -> TatwoLoopCancelOutcomeV1 {
    if FileManager.default.fileExists(atPath: journalURL(forJobID: job.jobID).path),
      FileManager.default.fileExists(
        atPath: journalSignatureURL(forJobID: job.jobID).path)
    {
      let journal = try loadJournal(
        forJobID: job.jobID,
        url: journalURL(forJobID: job.jobID))
      let current = try requireCurrentStatus(journal, jobID: job.jobID)
      if [.completed, .failed, .verified].contains(current) {
        return .terminalWon(current)
      }
    }

    let expected = TatwoLoopCancelTombstoneV1(
      jobID: job.jobID,
      logicalJobID: job.logicalJobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      reason: reason,
      requestedAt: now)
    let bodyURL = cancelURL(forJobID: job.jobID)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let expectedData = try encoder.encode(expected)
    try TatwoCreateOnlyFile.write(
      expectedData,
      to: bodyURL,
      onDuplicate: {
        let existing = try self.decode(
          TatwoLoopCancelTombstoneV1.self,
          from: Data(contentsOf: bodyURL))
        try self.validateCancelTombstone(existing, for: job)
        guard existing.reason == reason else {
          throw TatwoLoopJobStateError.attemptBindingMismatch(
            jobID: job.jobID,
            detail: "cancel tombstone reason conflicts with existing request")
        }
      })
    try cancelFaultBox?.check(.afterBody, jobID: job.jobID)
    guard
      let tombstone = try cancelTombstoneLocked(
        for: job,
        completeMissingSignature: true)
    else {
      throw TatwoLoopJobStateError.invalidPayload(
        "cancel tombstone disappeared for \(job.jobID)")
    }
    try cancelFaultBox?.check(.afterSignature, jobID: job.jobID)
    return try applyCancellationLocked(job: job, tombstone: tombstone)
  }

  private func cancelTombstoneLocked(
    for job: TatwoLoopJobV1,
    completeMissingSignature: Bool
  ) throws -> TatwoLoopCancelTombstoneV1? {
    let bodyURL = cancelURL(forJobID: job.jobID)
    let signatureURL = cancelSignatureURL(forJobID: job.jobID)
    guard FileManager.default.fileExists(atPath: bodyURL.path) else {
      if FileManager.default.fileExists(atPath: signatureURL.path) {
        try recordRejection(
          jobID: job.jobID,
          artifact: .cancel,
          reason: .invalidSignature,
          detail: "cancel signature exists without tombstone body")
        throw TatwoLoopJobStateError.signatureRejected(
          jobID: job.jobID,
          reason: TatwoLoopChannelRejectReasonV1.invalidSignature.rawValue)
      }
      return nil
    }
    let data: Data
    do {
      data = try Data(contentsOf: bodyURL)
    } catch {
      try recordRejection(
        jobID: job.jobID,
        artifact: .cancel,
        reason: .invalidSignature,
        detail: "cancel tombstone body unreadable")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: job.jobID,
        reason: TatwoLoopChannelRejectReasonV1.invalidSignature.rawValue)
    }
    let tombstone: TatwoLoopCancelTombstoneV1
    do {
      tombstone = try decode(TatwoLoopCancelTombstoneV1.self, from: data)
    } catch {
      try recordRejection(
        jobID: job.jobID,
        artifact: .cancel,
        reason: .invalidSignature,
        detail: "cancel tombstone decode failed")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: job.jobID,
        reason: TatwoLoopChannelRejectReasonV1.invalidSignature.rawValue)
    }
    do {
      try validateCancelTombstone(tombstone, for: job)
    } catch {
      let reason: TatwoLoopChannelRejectReasonV1
      if tombstone.schema != "TatwoLoopCancelTombstoneV1" {
        reason = .invalidSignature
      } else if tombstone.jobID != job.jobID {
        reason = .jobIdMismatch
      } else {
        reason = .digestMismatch
      }
      try recordRejection(
        jobID: job.jobID,
        artifact: .cancel,
        reason: reason,
        detail: "cancel tombstone does not match exact job attempt")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: job.jobID,
        reason: reason.rawValue)
    }

    if !FileManager.default.fileExists(atPath: signatureURL.path) {
      guard completeMissingSignature else {
        try recordRejection(
          jobID: job.jobID,
          artifact: .cancel,
          reason: .missingSignature,
          detail: "missing cancel tombstone signature")
        throw TatwoLoopJobStateError.signatureRejected(
          jobID: job.jobID,
          reason: TatwoLoopChannelRejectReasonV1.missingSignature.rawValue)
      }
      guard trust.localIdentity.deviceID == job.originDeviceID else {
        try recordRejection(
          jobID: job.jobID,
          artifact: .cancel,
          reason: .producerMismatch,
          detail: "only origin may complete a missing cancel signature")
        throw TatwoLoopJobStateError.signatureRejected(
          jobID: job.jobID,
          reason: TatwoLoopChannelRejectReasonV1.producerMismatch.rawValue)
      }
      let signature = try trust.sign(payload: data, purpose: .loopAck)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let signatureData = try encoder.encode(signature)
      try TatwoCreateOnlyFile.write(
        signatureData,
        to: signatureURL,
        onDuplicate: {
          let existing = try self.decode(
            TatwoDeviceSignatureV1.self,
            from: Data(contentsOf: signatureURL))
          try self.trust.verify(
            payload: data,
            purpose: .loopAck,
            signature: existing,
            expectedDeviceID: job.originDeviceID,
            enforceFreshness: false)
        })
    }
    try verifyArtifactBytes(
      data,
      purpose: .loopAck,
      signatureURL: signatureURL,
      artifact: .cancel,
      jobID: job.jobID,
      expectedDeviceID: job.originDeviceID,
      enforceFreshness: false)
    return tombstone
  }

  private func validateCancelTombstone(
    _ tombstone: TatwoLoopCancelTombstoneV1,
    for job: TatwoLoopJobV1
  ) throws {
    guard tombstone.schema == "TatwoLoopCancelTombstoneV1",
      tombstone.jobID == job.jobID,
      tombstone.logicalJobID == job.logicalJobID,
      tombstone.dispatchNonce == job.dispatchNonce,
      tombstone.jobCanonicalDigest == (try job.canonicalDigest())
    else {
      throw TatwoLoopJobStateError.attemptBindingMismatch(
        jobID: job.jobID,
        detail: "cancel tombstone does not match exact job attempt")
    }
  }

  private func applyCancellationLocked(
    job: TatwoLoopJobV1,
    tombstone: TatwoLoopCancelTombstoneV1
  ) throws -> TatwoLoopCancelOutcomeV1 {
    let journalURL = journalURL(forJobID: job.jobID)
    var verifiedJournal: [TatwoLoopJobJournalEntryV1]?
    if FileManager.default.fileExists(atPath: journalURL.path),
      FileManager.default.fileExists(
        atPath: journalSignatureURL(forJobID: job.jobID).path)
    {
      let journal = try loadJournal(forJobID: job.jobID, url: journalURL)
      let current = try requireCurrentStatus(journal, jobID: job.jobID)
      if current == .cancelled {
        try writeCancelledAckLocked(job: job, tombstone: tombstone)
        try cancelFaultBox?.check(.afterAck, jobID: job.jobID)
        return .terminalWon(.cancelled)
      }
      if [.completed, .failed, .verified].contains(current) {
        return .terminalWon(current)
      }
      verifiedJournal = journal
    }

    guard hasCommitMarkerFile(forJobID: job.jobID) else {
      return .cancelled
    }
    guard try commitMarkerMatches(job: job, digest: try job.canonicalDigest()) else {
      throw TatwoLoopJobStateError.attemptBindingMismatch(
        jobID: job.jobID,
        detail: "cancelled job commit marker does not match exact attempt")
    }
    let journal =
      try verifiedJournal ?? loadJournal(forJobID: job.jobID, url: journalURL)
    let current = try requireCurrentStatus(journal, jobID: job.jobID)
    if [.completed, .failed, .cancelled, .verified].contains(current) {
      return .terminalWon(current)
    }
    let sequence = UInt64(journal.count) + 1
    let entry = TatwoLoopJobJournalEntryV1(
      jobID: job.jobID,
      logicalJobID: job.logicalJobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      sequence: sequence,
      from: current,
      to: .cancelled,
      reason: "origin-cancel-tombstone",
      occurredAt: tombstone.requestedAt)
    try appendJournalEntry(entry, to: journalURL)
    try cancelFaultBox?.check(.afterJournal, jobID: job.jobID)
    try writeCancelledAckLocked(job: job, tombstone: tombstone)
    try cancelFaultBox?.check(.afterAck, jobID: job.jobID)
    return .cancelled
  }

  private func writeCancelledAckLocked(
    job: TatwoLoopJobV1,
    tombstone: TatwoLoopCancelTombstoneV1
  ) throws {
    try writeAck(
      TatwoLoopJobAckV1(
        jobID: job.jobID,
        logicalJobID: job.logicalJobID,
        dispatchNonce: job.dispatchNonce,
        jobCanonicalDigest: try job.canonicalDigest(),
        status: .cancelled,
        updatedAt: tombstone.requestedAt,
        result: nil),
      forJobID: job.jobID)
  }

  public func jobURL(for job: TatwoLoopJobV1) -> URL {
    outboxURL(forTargetDeviceID: job.targetDeviceID)
      .appendingPathComponent("\(safeComponent(job.jobID)).json")
  }

  public func jobSignatureURL(for job: TatwoLoopJobV1) -> URL {
    rootURL
      .appendingPathComponent("signatures", isDirectory: true)
      .appendingPathComponent("jobs", isDirectory: true)
      .appendingPathComponent(safeComponent(job.targetDeviceID), isDirectory: true)
      .appendingPathComponent("\(safeComponent(job.jobID)).json")
  }

  public func ackURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("ack", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).json")
  }

  public func ackSignatureURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("signatures", isDirectory: true)
      .appendingPathComponent("acks", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).json")
  }

  public func resultURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("results", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).json")
  }

  public func resultSignatureURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("signatures", isDirectory: true)
      .appendingPathComponent("results", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).json")
  }

  /// Raw job output body (`outputs/<safeJobID>`). Path uses sanitize (no traversal).
  public func outputURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("outputs", isDirectory: true)
      .appendingPathComponent(safeComponent(jobID))
  }

  public func outputSignatureURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("signatures", isDirectory: true)
      .appendingPathComponent("outputs", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).json")
  }

  public func journalURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("journal", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).jsonl")
  }

  public func journalSignatureURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("signatures", isDirectory: true)
      .appendingPathComponent("journals", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).json")
  }

  public func journalBundleURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("journal-bundles", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).json")
  }

  public func commitMarkerURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("commit-markers", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).json")
  }

  public func commitMarkerSignatureURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("signatures", isDirectory: true)
      .appendingPathComponent("commit-markers", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).json")
  }

  public func rejectJournalURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("journal", isDirectory: true)
      .appendingPathComponent("rejects", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).jsonl")
  }

  public func cancelURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("cancel", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).signal")
  }

  public func cancelSignatureURL(forJobID jobID: String) -> URL {
    rootURL
      .appendingPathComponent("signatures", isDirectory: true)
      .appendingPathComponent("cancel", isDirectory: true)
      .appendingPathComponent("\(safeComponent(jobID)).json")
  }

  public static let skilletLaneRelativeRoot = "skillet"

  public static func isSkilletLaneURL(_ url: URL, channelRoot: URL) -> Bool {
    let root = channelRoot.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard path.hasPrefix(prefix) else { return false }
    let relative = String(path.dropFirst(prefix.count))
    return relative == skilletLaneRelativeRoot
      || relative.hasPrefix(skilletLaneRelativeRoot + "/")
  }

  private func outboxURL(forTargetDeviceID targetDeviceID: String) -> URL {
    rootURL
      .appendingPathComponent("outbox", isDirectory: true)
      .appendingPathComponent(safeComponent(targetDeviceID), isDirectory: true)
  }

  private func loadJournal(
    forJobID jobID: String,
    url: URL
  ) throws -> [TatwoLoopJobJournalEntryV1] {
    let job = try lookupJobIgnoringJournal(jobID: jobID)
    let data: Data
    let signature: TatwoDeviceSignatureV1
    let bundleURL = journalBundleURL(forJobID: jobID)
    if FileManager.default.fileExists(atPath: bundleURL.path) {
      let bundle: TatwoLoopSignedJournalBundleV1
      do {
        bundle = try decode(
          TatwoLoopSignedJournalBundleV1.self,
          from: Data(contentsOf: bundleURL))
      } catch {
        try recordRejection(
          jobID: jobID,
          artifact: .journal,
          reason: .invalidSignature,
          detail: "authoritative journal bundle decode failed")
        throw TatwoLoopJobStateError.signatureRejected(
          jobID: jobID,
          reason: TatwoLoopChannelRejectReasonV1.invalidSignature.rawValue)
      }
      guard bundle.schema == "TatwoLoopSignedJournalBundleV1",
        bundle.jobID == jobID
      else {
        try recordRejection(
          jobID: jobID,
          artifact: .journal,
          reason: .jobIdMismatch,
          detail: "authoritative journal bundle jobID mismatch")
        throw TatwoLoopJobStateError.signatureRejected(
          jobID: jobID,
          reason: TatwoLoopChannelRejectReasonV1.jobIdMismatch.rawValue)
      }
      data = bundle.journalBytes
      signature = bundle.detachedSignature
      try verifyJournalBytes(
        data,
        signature: signature,
        job: job,
        jobID: jobID)
      // The atomic bundle is recovery authority. Canonical body/sidecar are
      // legacy/direct-reader projections only; repair them from already
      // verified bytes and signature, never by signing surviving body bytes.
      try repairJournalCanonicalPair(
        data: data,
        signature: signature,
        journalURL: url,
        jobID: jobID,
        allowFaultInjection: false)
    } else {
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw TatwoLoopJobStateError.jobNotFound(jobID)
      }
      data = try Data(contentsOf: url)
      // Legacy pair compatibility. Both artifacts must verify before they can
      // be packaged as the new atomic recovery authority.
      try verifyArtifactBytes(
        data,
        purpose: .loopJournal,
        signatureURL: journalSignatureURL(forJobID: jobID),
        artifact: .journal,
        jobID: jobID,
        expectedDeviceID: nil)
      signature = try loadSignature(
        from: journalSignatureURL(forJobID: jobID),
        jobID: jobID,
        artifact: .journal)
      try verifyJournalSigner(signature, job: job, jobID: jobID)
      try writeJournalBundle(
        data: data,
        signature: signature,
        jobID: jobID,
        allowFaultInjection: false)
    }
    // Fail-closed: journal is a signed ledger (same trust as job/ack/result).
    // Unsigned or failed verification must not drive runner dedupe or converge.
    let allowedSigners = Set([job.originDeviceID, job.targetDeviceID])
    guard allowedSigners.contains(signature.deviceID) else {
      try recordRejection(
        jobID: jobID,
        artifact: .journal,
        reason: .producerMismatch,
        detail: "journal signer \(signature.deviceID) not origin/target")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: jobID,
        reason: TatwoLoopChannelRejectReasonV1.producerMismatch.rawValue)
    }

    let lines = String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isNewline)
    guard !lines.isEmpty else {
      throw TatwoLoopJobStateError.malformedJournal(jobID)
    }
    let entries = try lines.map { line in
      do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
          TatwoLoopJobJournalEntryV1.self,
          from: Data(line.utf8))
      } catch {
        throw TatwoLoopJobStateError.malformedJournal(jobID)
      }
    }
    guard entries.first?.from == nil, entries.first?.to == .queued else {
      throw TatwoLoopJobStateError.malformedJournal(jobID)
    }
    for pair in zip(entries, entries.dropFirst()) {
      guard pair.1.from == pair.0.to else {
        throw TatwoLoopJobStateError.malformedJournal(jobID)
      }
      if pair.1.to == .cancelled,
        pair.1.reason == "origin-cancel-tombstone",
        ![.completed, .failed, .cancelled, .verified].contains(pair.0.to)
      {
        guard
          (try cancelTombstoneLocked(
            for: job,
            completeMissingSignature: false)) != nil
        else {
          throw TatwoLoopJobStateError.malformedJournal(jobID)
        }
      } else {
        do {
          try TatwoLoopJobStateMachine.validate(from: pair.0.to, to: pair.1.to)
        } catch {
          throw TatwoLoopJobStateError.malformedJournal(jobID)
        }
      }
    }
    // Bind every ledger line to the caller-requested jobID (not filename alone).
    let jobDigest = try job.canonicalDigest()
    for (index, entry) in entries.enumerated() {
      if entry.jobID != jobID {
        try recordRejection(
          jobID: jobID,
          artifact: .journal,
          reason: .jobIdMismatch,
          detail: "journal entry jobID \(entry.jobID) != expected \(jobID)")
        throw TatwoLoopJobStateError.signatureRejected(
          jobID: jobID,
          reason: TatwoLoopChannelRejectReasonV1.jobIdMismatch.rawValue)
      }
      if entry.dispatchNonce != job.dispatchNonce
        || entry.jobCanonicalDigest != jobDigest
      {
        throw TatwoLoopJobStateError.attemptBindingMismatch(
          jobID: jobID,
          detail: "journal entry attempt mismatch at index \(index)")
      }
      if entry.sequence != UInt64(index + 1) {
        throw TatwoLoopJobStateError.malformedJournal(jobID)
      }
    }
    return entries
  }

  private func verifyJournalBytes(
    _ data: Data,
    signature: TatwoDeviceSignatureV1,
    job: TatwoLoopJobV1,
    jobID: String
  ) throws {
    do {
      try trust.verify(
        payload: data,
        purpose: .loopJournal,
        signature: signature,
        expectedDeviceID: nil,
        enforceFreshness: false)
    } catch let error as TatwoLoopJobStateError {
      let reason: TatwoLoopChannelRejectReasonV1
      if case let .signatureRejected(_, rawReason) = error {
        reason = TatwoLoopChannelRejectReasonV1(rawValue: rawReason) ?? .invalidSignature
      } else {
        throw error
      }
      try recordRejection(
        jobID: jobID,
        artifact: .journal,
        reason: reason,
        detail: "authoritative journal bundle signature rejected")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: jobID,
        reason: reason.rawValue)
    }
    try verifyJournalSigner(signature, job: job, jobID: jobID)
  }

  private func verifyJournalSigner(
    _ signature: TatwoDeviceSignatureV1,
    job: TatwoLoopJobV1,
    jobID: String
  ) throws {
    let allowedSigners = Set([job.originDeviceID, job.targetDeviceID])
    guard allowedSigners.contains(signature.deviceID) else {
      try recordRejection(
        jobID: jobID,
        artifact: .journal,
        reason: .producerMismatch,
        detail: "journal signer \(signature.deviceID) not origin/target")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: jobID,
        reason: TatwoLoopChannelRejectReasonV1.producerMismatch.rawValue)
    }
  }

  /// Locate a job artifact without reading the journal (avoids recursion on verify).
  private func lookupJobIgnoringJournal(jobID: String) throws -> TatwoLoopJobV1 {
    try job(forJobID: jobID)
  }

  private func requireCurrentStatus(
    _ journal: [TatwoLoopJobJournalEntryV1],
    jobID: String
  ) throws -> TatwoLoopJobStatusV1 {
    guard let status = journal.last?.to else {
      throw TatwoLoopJobStateError.malformedJournal(jobID)
    }
    return status
  }

  private func writeAck(_ ack: TatwoLoopJobAckV1, forJobID jobID: String) throws {
    try writeSignedJSON(
      ack,
      to: ackURL(forJobID: jobID),
      purpose: .loopAck,
      signatureURL: ackSignatureURL(forJobID: jobID),
      artifact: .ack,
      jobID: jobID)
  }

  private func writeAckCreateOnly(
    _ ack: TatwoLoopJobAckV1,
    forJobID jobID: String
  ) throws {
    try writeSignedJSONCreateOnly(
      ack,
      to: ackURL(forJobID: jobID),
      purpose: .loopAck,
      signatureURL: ackSignatureURL(forJobID: jobID),
      expectedSignerDeviceID: trust.localIdentity.deviceID)
  }

  private func checkEnqueueStage(_ stage: TatwoLoopChannelEnqueueStage, jobID: String) throws {
    try enqueueFaultBox?.check(stage, jobID: jobID)
  }

  private func hasCommitMarkerFile(forJobID jobID: String) -> Bool {
    FileManager.default.fileExists(atPath: commitMarkerURL(forJobID: jobID).path)
  }

  private func commitMarkerMatches(job: TatwoLoopJobV1, digest: String) throws -> Bool {
    let url = commitMarkerURL(forJobID: job.jobID)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let data = try Data(contentsOf: url)
    try verifyArtifactBytes(
      data,
      purpose: .loopAck,
      signatureURL: commitMarkerSignatureURL(forJobID: job.jobID),
      artifact: .ack,
      jobID: job.jobID,
      expectedDeviceID: job.originDeviceID)
    let marker = try decode(TatwoLoopJobCommitMarkerV1.self, from: data)
    return marker.jobID == job.jobID
      && marker.logicalJobID == job.logicalJobID
      && marker.dispatchNonce == job.dispatchNonce
      && marker.jobCanonicalDigest == digest
  }

  private func writeCommitMarker(
    _ marker: TatwoLoopJobCommitMarkerV1,
    forJobID jobID: String
  ) throws {
    try writeSignedJSON(
      marker,
      to: commitMarkerURL(forJobID: jobID),
      purpose: .loopAck,
      signatureURL: commitMarkerSignatureURL(forJobID: jobID),
      artifact: .ack,
      jobID: jobID)
  }

  private func writeCommitMarkerCreateOnly(
    _ marker: TatwoLoopJobCommitMarkerV1,
    forJobID jobID: String
  ) throws {
    try writeSignedJSONCreateOnly(
      marker,
      to: commitMarkerURL(forJobID: jobID),
      purpose: .loopAck,
      signatureURL: commitMarkerSignatureURL(forJobID: jobID),
      expectedSignerDeviceID: trust.localIdentity.deviceID)
  }

  /// Write job body only (signature is a separate enqueue stage).
  private func writeJobBodyCreateOnly(_ job: TatwoLoopJobV1, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(job)
    try writeCreateOnly(data, to: url)
  }

  private func writeJobSignatureCreateOnly(
    for job: TatwoLoopJobV1,
    bodyURL: URL,
    signatureURL: URL
  ) throws {
    let data = try Data(contentsOf: bodyURL)
    let signature = try trust.sign(payload: data, purpose: .loopJob)
    let signatureEncoder = JSONEncoder()
    signatureEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let signatureData = try signatureEncoder.encode(signature)
    try TatwoCreateOnlyFile.write(
      signatureData,
      to: signatureURL,
      onDuplicate: {
        let existing = try self.decode(
          TatwoDeviceSignatureV1.self,
          from: Data(contentsOf: signatureURL))
        try self.trust.verify(
          payload: data,
          purpose: .loopJob,
          signature: existing,
          expectedDeviceID: job.originDeviceID,
          enforceFreshness: false)
      })
  }

  private func decodeVerifiedJob(
    from url: URL,
    expectedJobID: String,
    enforceFreshness: Bool
  ) throws -> TatwoLoopJobV1 {
    let data = try Data(contentsOf: url)
    if Self.isSkilletLaneURL(url, channelRoot: rootURL) {
      throw TatwoLoopJobStateError.jobNotFound(expectedJobID)
    }
    // Path/filename is untrusted layout only; expectedJobID is the binding key.
    let signatureURL: URL
    // Prefer path-derived target from outbox layout: outbox/<target>/<job>.json
    let targetComponent = url.deletingLastPathComponent().lastPathComponent
    signatureURL = rootURL
      .appendingPathComponent("signatures", isDirectory: true)
      .appendingPathComponent("jobs", isDirectory: true)
      .appendingPathComponent(safeComponent(targetComponent), isDirectory: true)
      .appendingPathComponent("\(safeComponent(expectedJobID)).json")
    try verifyArtifactBytes(
      data,
      purpose: .loopJob,
      signatureURL: signatureURL,
      artifact: .job,
      jobID: expectedJobID,
      expectedDeviceID: nil,
      enforceFreshness: enforceFreshness)
    let job: TatwoLoopJobV1
    do {
      job = try decode(TatwoLoopJobV1.self, from: data)
    } catch {
      try recordRejection(
        jobID: expectedJobID,
        artifact: .job,
        reason: .invalidSignature,
        detail: "job decode failed after signature")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: expectedJobID,
        reason: TatwoLoopChannelRejectReasonV1.invalidSignature.rawValue)
    }
    try requireJobIDMatch(
      artifactJobID: job.jobID,
      expectedJobID: expectedJobID,
      artifact: .job)
    // Sidecar was verified against an unknown producer first; pin producer to origin.
    let signature = try loadSignature(from: signatureURL, jobID: job.jobID, artifact: .job)
    if signature.deviceID != job.originDeviceID {
      try recordRejection(
        jobID: job.jobID,
        artifact: .job,
        reason: .producerMismatch,
        detail: "job signer \(signature.deviceID) != origin \(job.originDeviceID)")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: job.jobID,
        reason: TatwoLoopChannelRejectReasonV1.producerMismatch.rawValue)
    }
    // Re-verify with expected origin so producerMismatch is enforced at trust layer too.
    try trust.verify(
      payload: data,
      purpose: .loopJob,
      signature: signature,
      expectedDeviceID: job.originDeviceID,
      enforceFreshness: enforceFreshness)
    try job.validate()
    return job
  }

  private func decodeVerifiedAck(
    from url: URL,
    job: TatwoLoopJobV1,
    enforceFreshness: Bool
  ) throws -> TatwoLoopJobAckV1 {
    let data = try Data(contentsOf: url)
    // job.jobID is caller-bound (via job(forJobID:) / enqueue), not filename-derived.
    let signatureURL = ackSignatureURL(forJobID: job.jobID)
    try verifyArtifactBytes(
      data,
      purpose: .loopAck,
      signatureURL: signatureURL,
      artifact: .ack,
      jobID: job.jobID,
      expectedDeviceID: nil,
      enforceFreshness: enforceFreshness)
    let ack = try decode(TatwoLoopJobAckV1.self, from: data)
    try requireJobIDMatch(
      artifactJobID: ack.jobID,
      expectedJobID: job.jobID,
      artifact: .ack)
    try requireAttemptBinding(
      jobID: job.jobID,
      dispatchNonce: ack.dispatchNonce,
      jobCanonicalDigest: ack.jobCanonicalDigest,
      job: job,
      artifact: .ack)
    if let nested = ack.result {
      try requireJobIDMatch(
        artifactJobID: nested.jobID,
        expectedJobID: job.jobID,
        artifact: .ack)
      try requireAttemptBinding(
        jobID: job.jobID,
        dispatchNonce: nested.dispatchNonce,
        jobCanonicalDigest: nested.jobCanonicalDigest,
        job: job,
        artifact: .result)
    }
    let signature = try loadSignature(from: signatureURL, jobID: job.jobID, artifact: .ack)
    let allowed = Set([job.originDeviceID, job.targetDeviceID])
    guard allowed.contains(signature.deviceID) else {
      try recordRejection(
        jobID: job.jobID,
        artifact: .ack,
        reason: .producerMismatch,
        detail: "ack signer \(signature.deviceID) not origin/target")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: job.jobID,
        reason: TatwoLoopChannelRejectReasonV1.producerMismatch.rawValue)
    }
    return ack
  }

  private func loadVerifiedResultIfPresent(
    forJobID jobID: String,
    job: TatwoLoopJobV1
  ) throws -> TatwoLoopJobResultReceiptV1? {
    // jobID is the caller argument to result(for:) / transition — binding key.
    let url = resultURL(forJobID: jobID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let data = try Data(contentsOf: url)
    try verifyArtifactBytes(
      data,
      purpose: .loopResult,
      signatureURL: resultSignatureURL(forJobID: jobID),
      artifact: .result,
      jobID: jobID,
      expectedDeviceID: job.targetDeviceID)
    let result = try decode(TatwoLoopJobResultReceiptV1.self, from: data)
    try requireJobIDMatch(
      artifactJobID: result.jobID,
      expectedJobID: jobID,
      artifact: .result)
    try requireAttemptBinding(
      jobID: jobID,
      dispatchNonce: result.dispatchNonce,
      jobCanonicalDigest: result.jobCanonicalDigest,
      job: job,
      artifact: .result)
    // A valid target signature proves producer identity, not that the provider
    // actually stayed on the exact Claude route requested by the signed job.
    // Historical receipts that predate attestation remain readable only when
    // they are not successful Claude completions; they can never be promoted.
    try result.validateModelExecutionAttestation(for: job)
    return result
  }

  /// Content then signature (prepare order). Unsigned content alone is not accepted.
  private func writeOutputArtifactBodyAndSignature(forJobID jobID: String, data: Data) throws {
    try writeSignedBytes(
      data,
      to: outputURL(forJobID: jobID),
      purpose: .loopOutput,
      signatureURL: outputSignatureURL(forJobID: jobID),
      artifact: .output,
      jobID: jobID)
  }

  private func loadVerifiedOutputBytes(forJobID jobID: String, job: TatwoLoopJobV1) throws -> Data {
    let url = outputURL(forJobID: jobID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      try recordRejection(
        jobID: jobID,
        artifact: .output,
        reason: .missingSignature,
        detail: "missing output body \(url.lastPathComponent)")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: jobID,
        reason: TatwoLoopChannelRejectReasonV1.missingSignature.rawValue)
    }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      throw TatwoLoopJobStateError.invalidPayload("output artifact symlink refused for \(jobID)")
    }
    let data = try Data(contentsOf: url)
    try verifyArtifactBytes(
      data,
      purpose: .loopOutput,
      signatureURL: outputSignatureURL(forJobID: jobID),
      artifact: .output,
      jobID: jobID,
      expectedDeviceID: job.targetDeviceID)
    return data
  }

  private func requireAttemptBinding(
    jobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    job: TatwoLoopJobV1,
    artifact: TatwoLoopChannelArtifactKindV1
  ) throws {
    let expectedDigest = try job.canonicalDigest()
    guard dispatchNonce == job.dispatchNonce, jobCanonicalDigest == expectedDigest else {
      try recordRejection(
        jobID: jobID,
        artifact: artifact,
        reason: .jobIdMismatch,
        detail: "attempt nonce/digest mismatch")
      throw TatwoLoopJobStateError.attemptBindingMismatch(
        jobID: jobID,
        detail: "artifact attempt binding mismatch for \(artifact.rawValue)")
    }
  }

  private func writeSignedConsumeHighWater(
    job: TatwoLoopJobV1,
    result: TatwoLoopJobResultReceiptV1,
    resultDigest: String
  ) throws {
    let now = Date()
    let jobDigest = try job.canonicalDigest()
    struct HighWaterBody: Codable {
      let schema: String
      let jobID: String
      let dispatchNonce: String
      let jobCanonicalDigest: String
      let resultDigest: String
      let projectionSequence: UInt64
      let updatedAt: Date
    }
    let body = HighWaterBody(
      schema: "TatwoLoopResultConsumeHighWaterV1",
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: jobDigest,
      resultDigest: resultDigest,
      projectionSequence: result.projectionSequence,
      updatedAt: now)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(body)
    let signature = try trust.sign(payload: payload, purpose: .loopAck, signedAt: now)
    let record = TatwoLoopResultConsumeHighWaterV1(
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: jobDigest,
      resultDigest: resultDigest,
      projectionSequence: result.projectionSequence,
      updatedAt: now,
      authorization: signature)
    // E2: global anti-rollback before durable high-water write (old namespace readback fails).
    if let global = globalAntiRollbackAnchor {
      try TatwoProductionLayoutLock.enforceConsumeAntiRollback(
        jobID: job.jobID,
        dispatchNonce: job.dispatchNonce,
        jobCanonicalDigest: jobDigest,
        resultDigest: resultDigest,
        projectionSequence: result.projectionSequence,
        anchor: global)
    }
    try consumeHighWaterAnchor.save(record)
  }

  private func verifyConsumeHighWater(
    _ highWater: TatwoLoopResultConsumeHighWaterV1,
    job: TatwoLoopJobV1
  ) throws {
    struct HighWaterBody: Codable {
      let schema: String
      let jobID: String
      let dispatchNonce: String
      let jobCanonicalDigest: String
      let resultDigest: String
      let projectionSequence: UInt64
      let updatedAt: Date
    }
    let body = HighWaterBody(
      schema: highWater.schema,
      jobID: highWater.jobID,
      dispatchNonce: highWater.dispatchNonce,
      jobCanonicalDigest: highWater.jobCanonicalDigest,
      resultDigest: highWater.resultDigest,
      projectionSequence: highWater.projectionSequence,
      updatedAt: highWater.updatedAt)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(body)
    try trust.verify(
      payload: payload,
      purpose: .loopAck,
      signature: highWater.authorization,
      expectedDeviceID: trust.localIdentity.deviceID,
      enforceFreshness: false)
  }

  /// Fail-closed binding: payloadDigest already covers the embedded jobID field,
  /// so cross-job copy of a signed pair is only useful if consumers ignore the field.
  private func requireJobIDMatch(
    artifactJobID: String,
    expectedJobID: String,
    artifact: TatwoLoopChannelArtifactKindV1
  ) throws {
    guard artifactJobID == expectedJobID else {
      try recordRejection(
        jobID: expectedJobID,
        artifact: artifact,
        reason: .jobIdMismatch,
        detail: "artifact jobID \(artifactJobID) != expected \(expectedJobID)")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: expectedJobID,
        reason: TatwoLoopChannelRejectReasonV1.jobIdMismatch.rawValue)
    }
  }

  private func verifyArtifactBytes(
    _ data: Data,
    purpose: TatwoLoopChannelSignaturePurposeV1,
    signatureURL: URL,
    artifact: TatwoLoopChannelArtifactKindV1,
    jobID: String,
    expectedDeviceID: String?,
    enforceFreshness: Bool = false
  ) throws {
    guard FileManager.default.fileExists(atPath: signatureURL.path) else {
      try recordRejection(
        jobID: jobID,
        artifact: artifact,
        reason: .missingSignature,
        detail: "missing sidecar \(signatureURL.lastPathComponent)")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: jobID,
        reason: TatwoLoopChannelRejectReasonV1.missingSignature.rawValue)
    }
    let signature: TatwoDeviceSignatureV1
    do {
      signature = try loadSignature(from: signatureURL, jobID: jobID, artifact: artifact)
    } catch {
      throw error
    }
    do {
      try trust.verify(
        payload: data,
        purpose: purpose,
        signature: signature,
        expectedDeviceID: expectedDeviceID,
        enforceFreshness: enforceFreshness)
    } catch let error as TatwoLoopJobStateError {
      if case let .signatureRejected(_, reasonRaw) = error {
        let reason =
          TatwoLoopChannelRejectReasonV1(rawValue: reasonRaw) ?? .invalidSignature
        try recordRejection(
          jobID: jobID,
          artifact: artifact,
          reason: reason,
          detail: error.localizedDescription)
        // Always surface the artifact jobID (not the signer deviceID) to callers.
        throw TatwoLoopJobStateError.signatureRejected(
          jobID: jobID,
          reason: reason.rawValue)
      }
      throw error
    }
  }

  private func loadSignature(
    from url: URL,
    jobID: String,
    artifact: TatwoLoopChannelArtifactKindV1
  ) throws -> TatwoDeviceSignatureV1 {
    do {
      return try decode(TatwoDeviceSignatureV1.self, from: Data(contentsOf: url))
    } catch {
      try recordRejection(
        jobID: jobID,
        artifact: artifact,
        reason: .invalidSignature,
        detail: "sidecar decode failed")
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: jobID,
        reason: TatwoLoopChannelRejectReasonV1.invalidSignature.rawValue)
    }
  }

  private func recordRejection(
    jobID: String,
    artifact: TatwoLoopChannelArtifactKindV1,
    reason: TatwoLoopChannelRejectReasonV1,
    detail: String?
  ) throws {
    let url = rejectJournalURL(forJobID: jobID)
    try TatwoFileLock.withExclusiveLock(for: url) {
      let entry = TatwoLoopJobRejectEntryV1(
        jobID: jobID,
        artifact: artifact,
        reason: reason,
        detail: detail,
        occurredAt: Date())
      try createParentDirectory(for: url)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      var existing = Data()
      if FileManager.default.fileExists(atPath: url.path) {
        existing = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = String(decoding: existing, as: UTF8.self)
          .split(whereSeparator: \.isNewline)
        let prior = lines
          .compactMap {
            try? decoder.decode(
              TatwoLoopJobRejectEntryV1.self,
              from: Data($0.utf8))
          }
        if prior.contains(where: {
          $0.jobID == entry.jobID
            && $0.artifact == entry.artifact
            && $0.reason == entry.reason
            && $0.detail == entry.detail
        }) {
          return
        }
        // Bounded durable evidence: retain the first distinct variants and
        // refuse unbounded attacker-controlled journal growth.
        guard lines.count < 64 else { return }
      }
      var data = try encoder.encode(entry)
      data.append(Data("\n".utf8))
      try writeAtomic(existing + data, to: url)
    }
  }

  private func requireOriginMutationAuthority(
    for job: TatwoLoopJobV1,
    surface: String,
    now: Date
  ) throws {
    let authorityEpoch = originAuthorityProvider.authorityEpoch ?? 0
    try originAuthorityProvider.requireOriginAuthority(
      deviceID: job.originDeviceID,
      epoch: authorityEpoch,
      surface: surface,
      now: now)
  }

  private func appendJournalEntry(
    _ entry: TatwoLoopJobJournalEntryV1,
    to url: URL
  ) throws {
    try createParentDirectory(for: url)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    var line = try encoder.encode(entry)
    line.append(Data("\n".utf8))
    var data = Data()
    if FileManager.default.fileExists(atPath: url.path) {
      data = try Data(contentsOf: url)
    }
    data.append(line)
    try writeJournalCheckpointAndProjections(
      data,
      journalURL: url,
      jobID: entry.jobID)
  }

  private func writeInitialJournalEntryCreateOnly(
    _ entry: TatwoLoopJobJournalEntryV1,
    to url: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(entry)
    data.append(Data("\n".utf8))
    try writeJournalCheckpointAndProjections(
      data,
      journalURL: url,
      jobID: entry.jobID)
  }

  /// The atomic bundle is the journal commit point. It contains the exact
  /// journal bytes and their detached signature in one rename, eliminating the
  /// unrecoverable body-then-sidecar crash gap. The historical pair remains a
  /// direct-reader projection and is always updated after the bundle.
  private func writeJournalCheckpointAndProjections(
    _ data: Data,
    journalURL: URL,
    jobID: String
  ) throws {
    let signature = try trust.sign(payload: data, purpose: .loopJournal)
    try writeJournalBundle(
      data: data,
      signature: signature,
      jobID: jobID,
      allowFaultInjection: true)
    try repairJournalCanonicalPair(
      data: data,
      signature: signature,
      journalURL: journalURL,
      jobID: jobID,
      allowFaultInjection: true)
  }

  private func writeJournalBundle(
    data: Data,
    signature: TatwoDeviceSignatureV1,
    jobID: String,
    allowFaultInjection: Bool
  ) throws {
    let bundle = TatwoLoopSignedJournalBundleV1(
      jobID: jobID,
      journalBytes: data,
      detachedSignature: signature)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writeAtomic(
      try encoder.encode(bundle),
      to: journalBundleURL(forJobID: jobID))
    if allowFaultInjection {
      try journalFaultBox?.check(.afterAuthoritativeBundle, jobID: jobID)
    }
  }

  private func repairJournalCanonicalPair(
    data: Data,
    signature: TatwoDeviceSignatureV1,
    journalURL: URL,
    jobID: String,
    allowFaultInjection: Bool
  ) throws {
    let signatureEncoder = JSONEncoder()
    signatureEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let signatureData = try signatureEncoder.encode(signature)
    let journalMatches: Bool
    if FileManager.default.fileExists(atPath: journalURL.path) {
      journalMatches = try Data(contentsOf: journalURL) == data
    } else {
      journalMatches = false
    }
    if !journalMatches {
      try writeAtomic(data, to: journalURL)
    }
    if allowFaultInjection {
      try journalFaultBox?.check(.afterCanonicalBody, jobID: jobID)
    }
    let signatureURL = journalSignatureURL(forJobID: jobID)
    let signatureMatches: Bool
    if FileManager.default.fileExists(atPath: signatureURL.path) {
      signatureMatches = try Data(contentsOf: signatureURL) == signatureData
    } else {
      signatureMatches = false
    }
    if !signatureMatches {
      try writeAtomic(signatureData, to: signatureURL)
    }
  }

  private func writeSignedJSON<T: Encodable>(
    _ value: T,
    to url: URL,
    purpose: TatwoLoopChannelSignaturePurposeV1,
    signatureURL: URL,
    artifact: TatwoLoopChannelArtifactKindV1,
    jobID: String
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try writeSignedBytes(
      data,
      to: url,
      purpose: purpose,
      signatureURL: signatureURL,
      artifact: artifact,
      jobID: jobID)
  }

  private func writeSignedBytes(
    _ data: Data,
    to url: URL,
    purpose: TatwoLoopChannelSignaturePurposeV1,
    signatureURL: URL,
    artifact: TatwoLoopChannelArtifactKindV1,
    jobID: String
  ) throws {
    let signature = try trust.sign(payload: data, purpose: purpose)
    let signatureEncoder = JSONEncoder()
    signatureEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let signatureData = try signatureEncoder.encode(signature)
    try writeAtomic(data, to: url)
    try writeAtomic(signatureData, to: signatureURL)
    _ = artifact
    _ = jobID
  }

  private func writeSignedJSONCreateOnly<T: Encodable>(
    _ value: T,
    to url: URL,
    purpose: TatwoLoopChannelSignaturePurposeV1,
    signatureURL: URL,
    expectedSignerDeviceID: String
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writeSignedBytesCreateOnly(
      encoder.encode(value),
      to: url,
      purpose: purpose,
      signatureURL: signatureURL,
      expectedSignerDeviceID: expectedSignerDeviceID)
  }

  private func writeSignedBytesCreateOnly(
    _ data: Data,
    to url: URL,
    purpose: TatwoLoopChannelSignaturePurposeV1,
    signatureURL: URL,
    expectedSignerDeviceID: String
  ) throws {
    try writeCreateOnly(data, to: url)
    let persisted = try Data(contentsOf: url)
    guard persisted == data else {
      throw TatwoLoopJobStateError.duplicateJob(
        url.deletingPathExtension().lastPathComponent)
    }
    let signature = try trust.sign(payload: persisted, purpose: purpose)
    let signatureEncoder = JSONEncoder()
    signatureEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let signatureData = try signatureEncoder.encode(signature)
    try TatwoCreateOnlyFile.write(
      signatureData,
      to: signatureURL,
      onDuplicate: {
        let existing = try self.decode(
          TatwoDeviceSignatureV1.self,
          from: Data(contentsOf: signatureURL))
        try self.trust.verify(
          payload: persisted,
          purpose: purpose,
          signature: existing,
          expectedDeviceID: expectedSignerDeviceID,
          enforceFreshness: false)
      })
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }

  private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try decode(type, from: Data(contentsOf: url))
  }

  private func writeAtomic(_ data: Data, to url: URL) throws {
    try TatwoAtomicFile.write(data, to: url)
  }

  private func writeCreateOnly(_ data: Data, to url: URL) throws {
    try TatwoCreateOnlyFile.write(
      data,
      to: url,
      onDuplicate: {
        guard try Data(contentsOf: url) == data else {
          throw TatwoLoopJobStateError.duplicateJob(
            url.deletingPathExtension().lastPathComponent)
        }
      })
  }

  private func createParentDirectory(for url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
  }

  /// Strict path component: ASCII alnum + `-` + `_` only (no `.` / `..` / separators).
  private func safeComponent(_ value: String) -> String {
    TatwoLoopPathComponent.sanitize(value)
  }
}
