import Foundation

public enum TatwoPluginLifecycleStateV1:
  String,
  Codable,
  Sendable,
  CaseIterable,
  Equatable
{
  case registered
  case staged
  case installed
  case updateAvailable = "update_available"
  case disabled
  case failed
  case rollbackRequired = "rollback_required"
}

public enum TatwoPluginLifecycleActionV1:
  String,
  Codable,
  Sendable,
  CaseIterable,
  Equatable
{
  case inspect
  case stage
  case install
  case update
  case enable
  case disable
  case rollback
  case archiveUninstall = "archive_uninstall"
}

public enum TatwoPluginSourceKindV1:
  String,
  Codable,
  Sendable,
  CaseIterable,
  Equatable
{
  case localPath = "local_path"
  case gitRepository = "git_repository"
  case managedBundle = "managed_bundle"
  case mcpConfig = "mcp_config"
}

public struct TatwoPluginSourceV1: Codable, Sendable, Equatable {
  public let kind: TatwoPluginSourceKindV1
  public let location: String
  public let version: String?
  public let revision: String?
  public let sha256: String?

  public init(
    kind: TatwoPluginSourceKindV1,
    location: String,
    version: String? = nil,
    revision: String? = nil,
    sha256: String? = nil
  ) {
    self.kind = kind
    self.location = location
    self.version = version
    self.revision = revision
    self.sha256 = sha256
  }
}

public struct TatwoPluginLifecycleRiskV1: Codable, Sendable, Equatable {
  public let level: SafetyLevel
  public let reasons: [String]
  public let humanGateRequired: Bool

  public init(
    level: SafetyLevel,
    reasons: [String] = [],
    humanGateRequired: Bool = false
  ) {
    self.level = level
    self.reasons = Self.uniqueNonBlank(reasons)
    self.humanGateRequired = humanGateRequired
  }

  private static func uniqueNonBlank(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
        return nil
      }
      return trimmed
    }
  }
}

public struct TatwoPluginLifecycleRecordV1:
  Codable,
  Sendable,
  Identifiable,
  Equatable
{
  public let schema: String
  public var id: String { entryID }
  public let entryID: String
  public let registryKind: RegistryKind
  public var state: TatwoPluginLifecycleStateV1
  public var enabled: Bool
  public var source: TatwoPluginSourceV1?
  public var installedVersion: String?
  public var availableVersion: String?
  public var installedRevision: String?
  public var availableRevision: String?
  public var targetScope: String
  public var lastAction: TatwoPluginLifecycleActionV1?
  public var receiptIDs: [String]
  public var rollbackPointer: String?
  public var rollbackVersion: String?
  public var rollbackRevision: String?
  public var rollbackState: TatwoPluginLifecycleStateV1?
  public var risk: TatwoPluginLifecycleRiskV1
  public var lastErrorCode: String?
  public var updatedAt: Date

  public init(
    schema: String = "TatwoPluginLifecycleRecordV1",
    entryID: String,
    registryKind: RegistryKind,
    state: TatwoPluginLifecycleStateV1 = .registered,
    enabled: Bool = false,
    source: TatwoPluginSourceV1? = nil,
    installedVersion: String? = nil,
    availableVersion: String? = nil,
    installedRevision: String? = nil,
    availableRevision: String? = nil,
    targetScope: String,
    lastAction: TatwoPluginLifecycleActionV1? = nil,
    receiptIDs: [String] = [],
    rollbackPointer: String? = nil,
    rollbackVersion: String? = nil,
    rollbackRevision: String? = nil,
    rollbackState: TatwoPluginLifecycleStateV1? = nil,
    risk: TatwoPluginLifecycleRiskV1 = .init(level: .low),
    lastErrorCode: String? = nil,
    updatedAt: Date
  ) {
    self.schema = schema
    self.entryID = entryID
    self.registryKind = registryKind
    self.state = state
    self.enabled = enabled
    self.source = source
    self.installedVersion = installedVersion
    self.availableVersion = availableVersion
    self.installedRevision = installedRevision
    self.availableRevision = availableRevision
    self.targetScope = targetScope
    self.lastAction = lastAction
    self.receiptIDs = receiptIDs
    self.rollbackPointer = rollbackPointer
    self.rollbackVersion = rollbackVersion
    self.rollbackRevision = rollbackRevision
    self.rollbackState = rollbackState
    self.risk = risk
    self.lastErrorCode = lastErrorCode
    self.updatedAt = updatedAt
  }
}

public enum TatwoPluginLifecycleEventV1: Codable, Sendable, Equatable {
  case stage(
    source: TatwoPluginSourceV1,
    risk: TatwoPluginLifecycleRiskV1)
  case install(
    version: String?,
    revision: String?,
    receiptID: String,
    rollbackPointer: String?,
    risk: TatwoPluginLifecycleRiskV1)
  case discoverUpdate(
    version: String?,
    revision: String?,
    risk: TatwoPluginLifecycleRiskV1)
  case update(
    version: String?,
    revision: String?,
    receiptID: String,
    rollbackPointer: String,
    risk: TatwoPluginLifecycleRiskV1)
  case enable(
    receiptID: String,
    risk: TatwoPluginLifecycleRiskV1)
  case disable(
    receiptID: String,
    rollbackPointer: String?,
    risk: TatwoPluginLifecycleRiskV1)
  case fail(
    action: TatwoPluginLifecycleActionV1,
    errorCode: String,
    rollbackPointer: String?,
    rollbackRequired: Bool,
    receiptID: String?,
    risk: TatwoPluginLifecycleRiskV1)
  case rollback(
    receiptID: String,
    risk: TatwoPluginLifecycleRiskV1)
}

public enum TatwoPluginLifecycleTransitionRejectionV1:
  String,
  Codable,
  Sendable,
  CaseIterable,
  Equatable
{
  case invalidTransition = "invalid_transition"
  case invalidSource = "invalid_source"
  case missingVersionIdentity = "missing_version_identity"
  case versionAlreadyInstalled = "version_already_installed"
  case availableVersionMismatch = "available_version_mismatch"
  case availableRevisionMismatch = "available_revision_mismatch"
  case missingRollbackPointer = "missing_rollback_pointer"
  case missingRollbackSnapshot = "missing_rollback_snapshot"
  case invalidErrorCode = "invalid_error_code"
}

public struct TatwoPluginLifecycleTransitionV1: Codable, Sendable, Equatable {
  public let record: TatwoPluginLifecycleRecordV1
  public let accepted: Bool
  public let rejection: TatwoPluginLifecycleTransitionRejectionV1?

  public init(
    record: TatwoPluginLifecycleRecordV1,
    accepted: Bool,
    rejection: TatwoPluginLifecycleTransitionRejectionV1? = nil
  ) {
    self.record = record
    self.accepted = accepted
    self.rejection = rejection
  }
}

public enum TatwoPluginLifecycleReducer {
  public static func transition(
    record: TatwoPluginLifecycleRecordV1,
    event: TatwoPluginLifecycleEventV1,
    at date: Date
  ) -> TatwoPluginLifecycleTransitionV1 {
    switch event {
    case .stage(let source, let risk):
      guard record.state == .registered else {
        return rejected(record, .invalidTransition)
      }
      guard !source.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return rejected(record, .invalidSource)
      }

      var next = record
      next.state = .staged
      next.enabled = false
      next.source = source
      next.lastAction = .stage
      next.risk = risk
      next.lastErrorCode = nil
      next.updatedAt = date
      return accepted(next)

    case .install(let version, let revision, let receiptID, let rollbackPointer, let risk):
      guard record.state == .staged else {
        return rejected(record, .invalidTransition)
      }
      guard hasIdentity(version: version, revision: revision) else {
        return rejected(record, .missingVersionIdentity)
      }

      var next = record
      captureRollback(on: &next, from: record, pointer: rollbackPointer)
      next.state = .installed
      next.enabled = true
      next.installedVersion = normalized(version)
      next.installedRevision = normalized(revision)
      next.availableVersion = nil
      next.availableRevision = nil
      next.lastAction = .install
      next.risk = risk
      next.lastErrorCode = nil
      appendReceipt(receiptID, to: &next)
      next.updatedAt = date
      return accepted(next)

    case .discoverUpdate(let version, let revision, let risk):
      guard [.installed, .updateAvailable, .disabled].contains(record.state) else {
        return rejected(record, .invalidTransition)
      }
      guard hasIdentity(version: version, revision: revision) else {
        return rejected(record, .missingVersionIdentity)
      }
      guard
        !sameIdentity(
          version: version,
          revision: revision,
          installedVersion: record.installedVersion,
          installedRevision: record.installedRevision)
      else {
        return rejected(record, .versionAlreadyInstalled)
      }

      var next = record
      next.availableVersion = normalized(version)
      next.availableRevision = normalized(revision)
      if record.state != .disabled {
        next.state = .updateAvailable
        next.enabled = true
      }
      next.lastAction = .inspect
      next.risk = risk
      next.lastErrorCode = nil
      next.updatedAt = date
      return accepted(next)

    case .update(let version, let revision, let receiptID, let rollbackPointer, let risk):
      guard record.state == .updateAvailable, record.enabled else {
        return rejected(record, .invalidTransition)
      }
      guard hasIdentity(version: version, revision: revision) else {
        return rejected(record, .missingVersionIdentity)
      }
      guard normalized(rollbackPointer) != nil else {
        return rejected(record, .missingRollbackPointer)
      }
      if let availableVersion = normalized(record.availableVersion),
        normalized(version) != availableVersion
      {
        return rejected(record, .availableVersionMismatch)
      }
      if let availableRevision = normalized(record.availableRevision),
        normalized(revision) != availableRevision
      {
        return rejected(record, .availableRevisionMismatch)
      }

      var next = record
      captureRollback(on: &next, from: record, pointer: rollbackPointer)
      next.state = .installed
      next.enabled = true
      next.installedVersion = normalized(version)
      next.installedRevision = normalized(revision)
      next.availableVersion = nil
      next.availableRevision = nil
      next.lastAction = .update
      next.risk = risk
      next.lastErrorCode = nil
      appendReceipt(receiptID, to: &next)
      next.updatedAt = date
      return accepted(next)

    case .disable(let receiptID, let rollbackPointer, let risk):
      guard [.installed, .updateAvailable].contains(record.state), record.enabled else {
        return rejected(record, .invalidTransition)
      }

      var next = record
      captureRollback(on: &next, from: record, pointer: rollbackPointer)
      next.state = .disabled
      next.enabled = false
      next.lastAction = .disable
      next.risk = risk
      next.lastErrorCode = nil
      appendReceipt(receiptID, to: &next)
      next.updatedAt = date
      return accepted(next)

    case .enable(let receiptID, let risk):
      guard record.state == .disabled, !record.enabled else {
        return rejected(record, .invalidTransition)
      }

      var next = record
      next.state = hasPendingUpdate(record) ? .updateAvailable : .installed
      next.enabled = true
      next.lastAction = .enable
      next.risk = risk
      next.lastErrorCode = nil
      appendReceipt(receiptID, to: &next)
      next.updatedAt = date
      return accepted(next)

    case .fail(
      let
        action,
      let
        errorCode,
      let
        rollbackPointer,
      let
        rollbackRequired,
      let
        receiptID,
      let
        risk):
      guard normalized(errorCode) != nil else {
        return rejected(record, .invalidErrorCode)
      }
      if rollbackRequired, normalized(rollbackPointer) == nil {
        return rejected(record, .missingRollbackPointer)
      }

      var next = record
      captureRollback(on: &next, from: record, pointer: rollbackPointer)
      next.state = rollbackRequired ? .rollbackRequired : .failed
      next.enabled = false
      next.lastAction = action
      next.risk = risk
      next.lastErrorCode = normalized(errorCode)
      appendReceipt(receiptID, to: &next)
      next.updatedAt = date
      return accepted(next)

    case .rollback(let receiptID, let risk):
      guard [.failed, .rollbackRequired].contains(record.state) else {
        return rejected(record, .invalidTransition)
      }
      guard normalized(record.rollbackPointer) != nil,
        let restoredState = record.rollbackState
      else {
        return rejected(record, .missingRollbackSnapshot)
      }

      var next = record
      next.state = restoredState
      next.enabled = restoredState == .installed || restoredState == .updateAvailable
      next.installedVersion = record.rollbackVersion
      next.installedRevision = record.rollbackRevision
      if restoredState != .updateAvailable && restoredState != .disabled {
        next.availableVersion = nil
        next.availableRevision = nil
      }
      next.lastAction = .rollback
      next.risk = risk
      next.lastErrorCode = nil
      appendReceipt(receiptID, to: &next)
      next.updatedAt = date
      return accepted(next)
    }
  }

  private static func accepted(
    _ record: TatwoPluginLifecycleRecordV1
  ) -> TatwoPluginLifecycleTransitionV1 {
    TatwoPluginLifecycleTransitionV1(record: record, accepted: true)
  }

  private static func rejected(
    _ record: TatwoPluginLifecycleRecordV1,
    _ rejection: TatwoPluginLifecycleTransitionRejectionV1
  ) -> TatwoPluginLifecycleTransitionV1 {
    TatwoPluginLifecycleTransitionV1(
      record: record,
      accepted: false,
      rejection: rejection)
  }

  private static func captureRollback(
    on next: inout TatwoPluginLifecycleRecordV1,
    from previous: TatwoPluginLifecycleRecordV1,
    pointer: String?
  ) {
    guard let pointer = normalized(pointer) else {
      next.rollbackPointer = nil
      next.rollbackVersion = nil
      next.rollbackRevision = nil
      next.rollbackState = nil
      return
    }
    next.rollbackPointer = pointer
    next.rollbackVersion = previous.installedVersion
    next.rollbackRevision = previous.installedRevision
    next.rollbackState = previous.state
  }

  private static func appendReceipt(
    _ receiptID: String?,
    to record: inout TatwoPluginLifecycleRecordV1
  ) {
    guard let receiptID = normalized(receiptID),
      !record.receiptIDs.contains(receiptID)
    else {
      return
    }
    record.receiptIDs.append(receiptID)
  }

  private static func hasPendingUpdate(
    _ record: TatwoPluginLifecycleRecordV1
  ) -> Bool {
    guard
      hasIdentity(
        version: record.availableVersion,
        revision: record.availableRevision)
    else {
      return false
    }
    return !sameIdentity(
      version: record.availableVersion,
      revision: record.availableRevision,
      installedVersion: record.installedVersion,
      installedRevision: record.installedRevision)
  }

  private static func hasIdentity(
    version: String?,
    revision: String?
  ) -> Bool {
    normalized(version) != nil || normalized(revision) != nil
  }

  private static func sameIdentity(
    version: String?,
    revision: String?,
    installedVersion: String?,
    installedRevision: String?
  ) -> Bool {
    let candidateVersion = normalized(version)
    let candidateRevision = normalized(revision)
    let currentVersion = normalized(installedVersion)
    let currentRevision = normalized(installedRevision)

    if let candidateVersion, candidateVersion != currentVersion {
      return false
    }
    if let candidateRevision, candidateRevision != currentRevision {
      return false
    }
    return candidateVersion != nil || candidateRevision != nil
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
