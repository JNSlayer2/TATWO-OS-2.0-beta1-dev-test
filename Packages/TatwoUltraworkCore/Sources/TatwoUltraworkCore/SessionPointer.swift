import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Durable identity of the one Chat session that owns a Work OS GoalRun.
///
/// `current-session.json` used to identify only the GoalRun. That was not
/// enough to safely reconnect a Codex project-mirror row because multiple rows
/// can share a workspace and stale row metadata can name another contract.
/// The owner binding makes the provider session + normalized workspace
/// explicit and repeats contract/goal identity so cross-field tampering fails
/// closed before any Chat row is mutated.
public enum TatwoSessionOwnerKindV1: String, Codable, Sendable, Equatable {
  case session
  case thread
}

public struct TatwoSessionOwnerBindingV1: Codable, Sendable, Equatable {
  public let schema: String
  public let provider: String
  public let sessionID: String
  /// Absent only on legacy V1/V2 pointer bytes. New formal V3 pointers must
  /// persist this tag and may not infer a legacy ID to be a thread.
  public let ownerKind: TatwoSessionOwnerKindV1?
  public let workspacePath: String
  public let contractID: String
  public let goalID: String

  public init(
    schema: String = "TatwoSessionOwnerBindingV1",
    provider: String,
    sessionID: String,
    ownerKind: TatwoSessionOwnerKindV1? = nil,
    workspacePath: String,
    contractID: String,
    goalID: String
  ) {
    self.schema = schema
    self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
    self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.ownerKind = ownerKind
    let trimmedWorkspace = workspacePath.trimmingCharacters(
      in: .whitespacesAndNewlines)
    self.workspacePath = trimmedWorkspace.isEmpty
      ? ""
      : URL(fileURLWithPath: trimmedWorkspace, isDirectory: true)
        .standardizedFileURL
        .path
    self.contractID = contractID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.goalID = goalID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Convenience spelling for external-provider adapters. The persisted V1
  /// owner-binding key remains `sessionID` for compatibility.
  public init(
    schema: String = "TatwoSessionOwnerBindingV1",
    provider: String,
    externalProviderSessionID: String,
    ownerKind: TatwoSessionOwnerKindV1? = nil,
    workspacePath: String,
    contractID: String,
    goalID: String
  ) {
    self.init(
      schema: schema,
      provider: provider,
      sessionID: externalProviderSessionID,
      ownerKind: ownerKind,
      workspacePath: workspacePath,
      contractID: contractID,
      goalID: goalID)
  }

  /// Semantic alias used by external-provider/project-mirror callers. The
  /// persisted V1 owner-binding key remains `sessionID` for compatibility.
  public var externalProviderSessionID: String { sessionID }
}

/// Read-only owner identity supplied by a Chat/project-mirror row.
///
/// This intentionally contains no contract or Goal IDs. Callers can ask the
/// session store to verify the persisted owner binding before trusting any
/// row-local Work OS metadata.
public struct TatwoSessionOwnerExpectationV1: Codable, Sendable, Equatable {
  public let provider: String
  public let externalProviderSessionID: String
  public let workspacePath: String

  public init(
    provider: String,
    externalProviderSessionID: String,
    workspacePath: String
  ) {
    self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
    self.externalProviderSessionID =
      externalProviderSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedWorkspace = workspacePath.trimmingCharacters(
      in: .whitespacesAndNewlines)
    self.workspacePath = trimmedWorkspace.isEmpty
      ? ""
      : URL(fileURLWithPath: trimmedWorkspace, isDirectory: true)
        .standardizedFileURL
        .path
  }

  /// Convenience spelling for adapters that already expose `sessionID`.
  public init(
    provider: String,
    sessionID: String,
    workspacePath: String
  ) {
    self.init(
      provider: provider,
      externalProviderSessionID: sessionID,
      workspacePath: workspacePath)
  }

  public var sessionID: String { externalProviderSessionID }
}

/// Schema-tagged proof presented when an owned session pointer is attached or
/// mutated. Legacy V2 pointers cannot assert an owner kind, while formal V3
/// authority pointers must verify the exact persisted session/thread kind.
public enum TatwoSessionOwnerVerificationV1: Sendable, Equatable {
  case legacyV2(TatwoSessionOwnerExpectationV1)
  case canonicalV3(TatwoCanonicalSessionOwnerV1)
}

/// Compile-time one-of for the external provider identity that owns a formal
/// Goal authority transaction. Product writers cannot represent "neither" or
/// "both"; parser adapters must choose exactly one case before entering Core.
public enum TatwoSessionOwnerLocatorV1: Sendable, Equatable {
  case session(String)
  case thread(String)

  public var externalProviderID: String {
    switch self {
    case .session(let value), .thread(let value):
      return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
}

public struct TatwoCanonicalSessionOwnerV1: Codable, Sendable, Equatable {
  public let provider: String
  public let ownerKind: TatwoSessionOwnerKindV1
  public let externalProviderID: String
  public let workspacePath: String

  public init(
    provider: String,
    locator: TatwoSessionOwnerLocatorV1,
    workspacePath: String
  ) {
    self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
    switch locator {
    case .session(let value):
      self.ownerKind = .session
      self.externalProviderID =
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    case .thread(let value):
      self.ownerKind = .thread
      self.externalProviderID =
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let trimmedWorkspace = workspacePath.trimmingCharacters(
      in: .whitespacesAndNewlines)
    self.workspacePath = trimmedWorkspace.isEmpty
      ? ""
      : URL(fileURLWithPath: trimmedWorkspace, isDirectory: true)
        .standardizedFileURL.path
  }

  public var locator: TatwoSessionOwnerLocatorV1 {
    switch ownerKind {
    case .session:
      return .session(externalProviderID)
    case .thread:
      return .thread(externalProviderID)
    }
  }

  public static func session(
    _ expectation: TatwoSessionOwnerExpectationV1
  ) -> TatwoCanonicalSessionOwnerV1 {
    TatwoCanonicalSessionOwnerV1(
      provider: expectation.provider,
      locator: .session(expectation.externalProviderSessionID),
      workspacePath: expectation.workspacePath)
  }

  public static func thread(
    _ expectation: TatwoSessionOwnerExpectationV1
  ) -> TatwoCanonicalSessionOwnerV1 {
    TatwoCanonicalSessionOwnerV1(
      provider: expectation.provider,
      locator: .thread(expectation.externalProviderSessionID),
      workspacePath: expectation.workspacePath)
  }

  public var expectation: TatwoSessionOwnerExpectationV1 {
    TatwoSessionOwnerExpectationV1(
      provider: provider,
      externalProviderSessionID: externalProviderID,
      workspacePath: workspacePath)
  }

  public func binding(
    contractID: String,
    goalID: String
  ) -> TatwoSessionOwnerBindingV1 {
    TatwoSessionOwnerBindingV1(
      provider: provider,
      sessionID: externalProviderID,
      ownerKind: ownerKind,
      workspacePath: workspacePath,
      contractID: contractID,
      goalID: goalID)
  }
}

/// Q1 (常態啟動) — a persisted pointer to the current OS session.
///
/// The pain: every new conversation had to re-type `$tatwo-ultrawork` to re-enter the OS.
/// This records the active GoalRun (contractID + mode/scenario/objective) so `os session
/// status` — and a Claude Code SessionStart hook — can re-attach to it automatically. It
/// reuses `TatwoGoalRunStore`'s resolved directory so the pointer sits beside the goal store.
public struct TatwoSessionPointer: Codable, Sendable, Equatable {
  public let schema: String
  public let contractID: String
  public let goalID: String
  public let mode: WorkModeID
  public let scenario: String
  public let objective: String
  public let startedAt: Date
  public let ownerBinding: TatwoSessionOwnerBindingV1?
  public let generation: UInt64?
  /// Durable authority-transaction bindings. They are optional only so legacy
  /// V1/V2 pointers remain readable; every new formal begin writes all three.
  public let authorityTransactionID: String?
  public let authorityPlanSHA256: String?
  public let executionManifestSHA256: String?

  public init(
    schema: String? = nil,
    contractID: String,
    goalID: String,
    mode: WorkModeID,
    scenario: String,
    objective: String,
    startedAt: Date = Date(),
    ownerBinding: TatwoSessionOwnerBindingV1? = nil,
    generation: UInt64? = 1,
    authorityTransactionID: String? = nil,
    authorityPlanSHA256: String? = nil,
    executionManifestSHA256: String? = nil
  ) {
    self.schema =
      schema
      ?? (authorityTransactionID != nil
        || authorityPlanSHA256 != nil
        || executionManifestSHA256 != nil
        ? "TatwoSessionAuthorityPointerV3"
        : (ownerBinding == nil
          ? "TatwoSessionPointerV1"
          : "TatwoSessionPointerV2"))
    self.contractID = contractID
    self.goalID = goalID
    self.mode = mode
    self.scenario = scenario
    self.objective = objective
    // JSONEncoder's `.iso8601` strategy persists whole seconds. Canonicalize
    // at construction so an in-memory pointer and its durable round-trip have
    // the same semantic identity; exact mutation authority still comes from
    // the opaque raw-byte CAS revision below.
    self.startedAt = Date(
      timeIntervalSince1970:
        startedAt.timeIntervalSince1970.rounded(.down))
    self.ownerBinding = ownerBinding
    self.generation = generation
    self.authorityTransactionID = authorityTransactionID
    self.authorityPlanSHA256 = authorityPlanSHA256
    self.executionManifestSHA256 = executionManifestSHA256
  }

  /// Pure migration constructor. Callers must place the returned V2 pointer
  /// behind an explicit human/CAS gate before saving it over a live V1 file.
  public func owned(
    provider: String,
    sessionID: String,
    workspacePath: String
  ) -> TatwoSessionPointer {
    TatwoSessionPointer(
      schema:
        authorityTransactionID == nil
          ? "TatwoSessionPointerV2"
          : "TatwoSessionAuthorityPointerV3",
      contractID: contractID,
      goalID: goalID,
      mode: mode,
      scenario: scenario,
      objective: objective,
      startedAt: startedAt,
      ownerBinding: TatwoSessionOwnerBindingV1(
        provider: provider,
        sessionID: sessionID,
        workspacePath: workspacePath,
        contractID: contractID,
        goalID: goalID),
      generation: generation,
      authorityTransactionID: authorityTransactionID,
      authorityPlanSHA256: authorityPlanSHA256,
      executionManifestSHA256: executionManifestSHA256)
  }
}

public struct TatwoSessionAttachmentV1: Codable, Sendable, Equatable {
  public let schema: String
  public let pointer: TatwoSessionPointer
  public let contract: TatwoWorkOSContractV1
  public let goalRecord: TatwoStoredGoalRun

  public init(
    schema: String = "TatwoSessionAttachmentV1",
    pointer: TatwoSessionPointer,
    contract: TatwoWorkOSContractV1,
    goalRecord: TatwoStoredGoalRun
  ) {
    self.schema = schema
    self.pointer = pointer
    self.contract = contract
    self.goalRecord = goalRecord
  }
}

public enum TatwoSessionAttachmentError: Error, LocalizedError, Sendable, Equatable {
  case noCurrentSession
  case unsupportedPointerSchema(String)
  case callerExpectationMismatch(String)
  case ownerExpectationMismatch(String)
  case pointerGoalRunMismatch(String)
  case invalidOwnerBinding(String)
  case terminalGoalRun(GoalRunStatus)

  public var errorDescription: String? {
    switch self {
    case .noCurrentSession:
      return "No active Work OS current-session pointer is available."
    case .unsupportedPointerSchema(let schema):
      return "Unsupported current-session pointer schema: \(schema)"
    case .callerExpectationMismatch(let field):
      return "Current-session \(field) does not match the caller expectation."
    case .ownerExpectationMismatch(let field):
      return "Current-session owner \(field) does not match the caller expectation."
    case .pointerGoalRunMismatch(let field):
      return "Current-session \(field) does not match the canonical stored GoalRun."
    case .invalidOwnerBinding(let field):
      return "Current-session owner binding is invalid for \(field)."
    case .terminalGoalRun(let status):
      return "Current-session points to terminal GoalRun status \(status.rawValue); refusing reattach."
    }
  }
}

/// Opaque exact-byte revision for compare-and-swap pointer mutations.
///
/// `current-session.json` is atomically replaced, so mtime or decoded-field
/// comparisons are insufficient: another process can write semantically
/// similar bytes between read and migration. The store therefore captures the
/// original bytes and compares them again while holding the shared per-file
/// `TatwoFileLock`.
public struct TatwoSessionPointerRevisionV1: Sendable, Equatable {
  fileprivate let rawData: Data

  fileprivate init(rawData: Data) {
    self.rawData = rawData
  }

  public var digest: String {
    TatwoGoalRevisionPromotionAuthorizationV1.digest(rawData)
  }
}

public struct TatwoSessionPointerSnapshotV1: Sendable, Equatable {
  public let pointer: TatwoSessionPointer
  public let revision: TatwoSessionPointerRevisionV1

  fileprivate init(
    pointer: TatwoSessionPointer,
    revision: TatwoSessionPointerRevisionV1
  ) {
    self.pointer = pointer
    self.revision = revision
  }
}

public enum TatwoSessionMutationError: Error, LocalizedError, Sendable, Equatable {
  case noCurrentSession
  case currentSessionChanged
  case currentSessionAlreadyExists
  case currentSessionNotPristinePlanned(GoalRunStatus)
  case currentSessionHasPublishedWork
  case currentSessionGoalCloseIncomplete
  case currentSessionSupersededPointerCleanupRequired
  case sourcePointerNotLegacyV1(String)
  case invalidOwnerExpectation(String)
  case unpublishedGoalRollbackFailed(String)
  case revisionPromotionAuthorization(String)
  case revisionPromotionOldGoalNotRunning(GoalRunStatus)
  case revisionPromotionNewGoalNotPristine(GoalRunStatus)
  case revisionPromotionDispatchActive([String])
  case revisionPromotionNewGoalPublishedWork
  case revisionPromotionJournalConflict
  case revisionPromotionReconciliationRequired(String)
  case currentSessionStopDenied(GoalRunStatus)

  public var errorDescription: String? {
    switch self {
    case .noCurrentSession:
      return "No current-session pointer exists for the requested mutation."
    case .currentSessionChanged:
      return "The current-session pointer changed after it was inspected; refusing stale mutation."
    case .currentSessionAlreadyExists:
      return "A current-session pointer already exists; refusing to mint or replace another GoalRun."
    case .currentSessionNotPristinePlanned(let status):
      return "Only a pristine planned current-session may be superseded before dispatch; found \(status.rawValue)."
    case .currentSessionHasPublishedWork:
      return "The planned current-session already contains receipts or lifecycle evidence; refusing route supersession."
    case .currentSessionGoalCloseIncomplete:
      return "The current-session Goal Judge close is incomplete; preserving the GoalRun and pointer so receipts can be completed and close retried."
    case .currentSessionSupersededPointerCleanupRequired:
      return "The pristine GoalRun was cancelled, but its terminal current-session pointer still requires exact cleanup."
    case .sourcePointerNotLegacyV1(let schema):
      return "Only an unowned TatwoSessionPointerV1 can be migrated; found \(schema)."
    case .invalidOwnerExpectation(let field):
      return "The proposed current-session owner is invalid for \(field)."
    case .unpublishedGoalRollbackFailed(let contractID):
      return "Current-session publication failed and the unpublished GoalRun could not be safely rolled back: \(contractID)"
    case .revisionPromotionAuthorization(let detail):
      return "Goal revision 主機操作授權 rejected: \(detail)"
    case .revisionPromotionOldGoalNotRunning(let status):
      return "Goal revision predecessor must be running or pristine planned; found \(status.rawValue)."
    case .revisionPromotionNewGoalNotPristine(let status):
      return "Goal revision successor must be pristine planned; found \(status.rawValue)."
    case .revisionPromotionDispatchActive(let ids):
      return "Goal revision predecessor still has active dispatch heads: \(ids.joined(separator: ","))"
    case .revisionPromotionNewGoalPublishedWork:
      return "Goal revision successor already has dispatch or outbox evidence."
    case .revisionPromotionJournalConflict:
      return "Goal revision promotion journal conflicts with current durable state."
    case .revisionPromotionReconciliationRequired(let stage):
      return "Goal revision promotion requires restart reconciliation at stage \(stage)."
    case .currentSessionStopDenied(let status):
      return "OS session stop cannot detach GoalRun status \(status.rawValue)."
    }
  }
}

public enum TatwoGoalRevisionPromotionJournalStageV1:
  String, Codable, Sendable, Equatable
{
  case prepared
  case oldSuperseded = "old_superseded"
  case newRunning = "new_running"
  case pointerReplaced = "pointer_replaced"
  case completed
}

public struct TatwoGoalRevisionPromotionJournalV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let authorizationID: String
  public let oldPointerRevisionDigest: String
  public let oldGoalRevisionDigest: String
  public let newGoalRevisionDigest: String
  public let metadata: TatwoGoalRevisionSupersessionMetadataV1
  public var stage: TatwoGoalRevisionPromotionJournalStageV1
  public let preparedAt: Date
  public var updatedAt: Date

  public init(
    schema: String = "TatwoGoalRevisionPromotionJournalV1",
    authorizationID: String,
    oldPointerRevisionDigest: String,
    oldGoalRevisionDigest: String,
    newGoalRevisionDigest: String,
    metadata: TatwoGoalRevisionSupersessionMetadataV1,
    stage: TatwoGoalRevisionPromotionJournalStageV1 = .prepared,
    preparedAt: Date,
    updatedAt: Date
  ) {
    self.schema = schema
    self.authorizationID = authorizationID
    self.oldPointerRevisionDigest = oldPointerRevisionDigest
    self.oldGoalRevisionDigest = oldGoalRevisionDigest
    self.newGoalRevisionDigest = newGoalRevisionDigest
    self.metadata = metadata
    self.stage = stage
    self.preparedAt = preparedAt
    self.updatedAt = updatedAt
  }
}

public struct TatwoGoalRevisionPromotionResultV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let authorizationID: String
  public let predecessor: TatwoStoredGoalRun
  public let successor: TatwoStoredGoalRun
  public let pointer: TatwoSessionPointer
  public let supersessionReceipt: TatwoGoalSupersessionReceiptV1
  public let reconciled: Bool

  public init(
    schema: String = "TatwoGoalRevisionPromotionResultV1",
    authorizationID: String,
    predecessor: TatwoStoredGoalRun,
    successor: TatwoStoredGoalRun,
    pointer: TatwoSessionPointer,
    supersessionReceipt: TatwoGoalSupersessionReceiptV1,
    reconciled: Bool
  ) {
    self.schema = schema
    self.authorizationID = authorizationID
    self.predecessor = predecessor
    self.successor = successor
    self.pointer = pointer
    self.supersessionReceipt = supersessionReceipt
    self.reconciled = reconciled
  }
}

public struct TatwoGoalSupersessionReceiptV1:
  Codable, Sendable, Equatable, Identifiable
{
  public let schema: String
  public let id: String
  public let promotionAuthorizationID: String
  public let humanGateReceiptID: String
  public let predecessorContractID: String
  public let predecessorGoalID: String
  public let predecessorRevision: UInt64
  public let successorContractID: String
  public let successorGoalID: String
  public let successorRevision: UInt64
  public let oldPointerRevisionDigest: String
  public let oldPointerGeneration: UInt64
  public let newPointerGeneration: UInt64
  public let promotionIssuerDomain: String?
  public let oldReceiptsDigest: String?
  public let oldActivationEpoch: UInt64?
  public let bootstrapRecoveryContextDigest: String?
  public let completedAt: Date

  public init(
    schema: String = "TatwoGoalSupersessionReceiptV1",
    id: String,
    promotionAuthorizationID: String,
    humanGateReceiptID: String,
    predecessorContractID: String,
    predecessorGoalID: String,
    predecessorRevision: UInt64,
    successorContractID: String,
    successorGoalID: String,
    successorRevision: UInt64,
    oldPointerRevisionDigest: String,
    oldPointerGeneration: UInt64,
    newPointerGeneration: UInt64,
    completedAt: Date,
    promotionIssuerDomain: String? = nil,
    oldReceiptsDigest: String? = nil,
    oldActivationEpoch: UInt64? = nil,
    bootstrapRecoveryContextDigest: String? = nil
  ) {
    self.schema = schema
    self.id = id
    self.promotionAuthorizationID = promotionAuthorizationID
    self.humanGateReceiptID = humanGateReceiptID
    self.predecessorContractID = predecessorContractID
    self.predecessorGoalID = predecessorGoalID
    self.predecessorRevision = predecessorRevision
    self.successorContractID = successorContractID
    self.successorGoalID = successorGoalID
    self.successorRevision = successorRevision
    self.oldPointerRevisionDigest = oldPointerRevisionDigest
    self.oldPointerGeneration = oldPointerGeneration
    self.newPointerGeneration = newPointerGeneration
    self.promotionIssuerDomain = promotionIssuerDomain
    self.oldReceiptsDigest = oldReceiptsDigest
    self.oldActivationEpoch = oldActivationEpoch
    self.bootstrapRecoveryContextDigest = bootstrapRecoveryContextDigest
    self.completedAt = completedAt
  }
}

public struct TatwoSessionStore: Sendable {
  public let directoryURL: URL
  private let afterSupersessionCancellation:
    (@Sendable () throws -> Void)?
  private let removeSupersededPointer:
    @Sendable (URL) throws -> Void
  private let revisionPromotionFault:
    (@Sendable (TatwoGoalRevisionPromotionJournalStageV1) throws -> Void)?

  public init(directoryURL: URL) {
    self.directoryURL = directoryURL
    self.afterSupersessionCancellation = nil
    self.removeSupersededPointer = { url in
      // The predecessor GoalRun is retained as audit evidence. Pointer cleanup
      // is idempotent only for an already-absent pointer; it never deletes or
      // recreates an authority artifact to make a new begin succeed.
      guard FileManager.default.fileExists(atPath: url.path) else { return }
      try FileManager.default.removeItem(at: url)
    }
    self.revisionPromotionFault = nil
  }

  init(
    directoryURL: URL,
    afterSupersessionCancellation:
      (@Sendable () throws -> Void)?,
    removeSupersededPointer:
      @escaping @Sendable (URL) throws -> Void
  ) {
    self.directoryURL = directoryURL
    self.afterSupersessionCancellation = afterSupersessionCancellation
    self.removeSupersededPointer = removeSupersededPointer
    self.revisionPromotionFault = nil
  }

  init(
    directoryURL: URL,
    revisionPromotionFault:
      (@Sendable (TatwoGoalRevisionPromotionJournalStageV1) throws -> Void)?
  ) {
    self.directoryURL = directoryURL
    self.afterSupersessionCancellation = nil
    self.removeSupersededPointer = { url in
      // The predecessor GoalRun is retained as audit evidence. Pointer cleanup
      // is idempotent only for an already-absent pointer; it never deletes or
      // recreates an authority artifact to make a new begin succeed.
      guard FileManager.default.fileExists(atPath: url.path) else { return }
      try FileManager.default.removeItem(at: url)
    }
    self.revisionPromotionFault = revisionPromotionFault
  }

  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoSessionStore {
    TatwoSessionStore(directoryURL: TatwoGoalRunStore.default(environment: environment).directoryURL)
  }

  private var fileURL: URL {
    directoryURL.appendingPathComponent("current-session.json", isDirectory: false)
  }

  var authorityPointerFileURL: URL { fileURL }

  private var revisionPromotionLockURL: URL {
    directoryURL
      .appendingPathComponent("goal-revision-promotion", isDirectory: true)
      .appendingPathComponent("current.state", isDirectory: false)
  }

  private func revisionPromotionJournalURL(
    authorizationID: String
  ) -> URL {
    directoryURL
      .appendingPathComponent("goal-revision-promotion", isDirectory: true)
      .appendingPathComponent(
        "\(TatwoLoopPathComponent.sanitize(authorizationID)).json",
        isDirectory: false)
  }

  /// Issue one Goal authority plan through the canonical durable transaction.
  ///
  /// New formal writes require a V2 owner binding and persist GoalRun, complete
  /// execution manifest, pointer-last publication, exact readback, and a
  /// create-only terminal decision under one fixed lock order. Legacy pointers
  /// remain readable but this writer never mints another unowned V1 pointer.
  /// The canonical root's global and contract lifecycle locks must already
  /// have create-only initialization receipts; this route never bootstraps or
  /// repairs authority locks implicitly.
  public func beginCurrent(
    mode: WorkModeID,
    scenarioProfileID: String,
    objective: String,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    routeBindingOverride: WorkOSRouteBindingOverride? = nil,
    authorityInstanceDiscriminator: String? = nil,
    owner: TatwoCanonicalSessionOwnerV1,
    goalStore: TatwoGoalRunStore? = nil,
    dispatchRegistry: TatwoDispatchRegistry? = nil
  ) throws -> TatwoSessionAttachmentV1 {
    let resolvedGoalStore = goalStore ?? TatwoGoalRunStore(directoryURL: directoryURL)
    let resolvedRegistry =
      dispatchRegistry ?? TatwoDispatchRegistry(directoryURL: directoryURL)
    return try WorkOSFactory.beginCanonical(
      mode: mode,
      scenarioProfileID: scenarioProfileID,
      objective: objective,
      catalog: catalog,
      scenarioBook: scenarioBook,
      routeBindingOverride: routeBindingOverride,
      authorityInstanceDiscriminator: authorityInstanceDiscriminator,
      store: resolvedGoalStore,
      registry: resolvedRegistry,
      sessionStore: self,
      owner: owner)
  }

  /// Read the current pointer together with an opaque exact-byte CAS token.
  ///
  /// The snapshot itself is read-only. A caller may pass it only to the
  /// purpose-specific V1 owner migration below; general blind replacement
  /// remains unavailable.
  public func snapshotCurrent() throws -> TatwoSessionPointerSnapshotV1? {
    try TatwoFileLock.withExclusiveLock(for: fileURL) {
      guard let data = try currentDataUnlocked() else { return nil }
      let pointer = try decoded(data)
      if pointer.schema == "TatwoSessionAuthorityPointerV3" {
        do {
          try TatwoGoalAuthorityTransaction
            .validateAuthorityReadback(
              pointer: pointer,
              stateRoot: directoryURL)
        } catch {
          throw TatwoSessionAttachmentError.pointerGoalRunMismatch(
            "v3_authority_artifacts")
        }
      }
      return TatwoSessionPointerSnapshotV1(
        pointer: pointer,
        revision: TatwoSessionPointerRevisionV1(rawData: data))
    }
  }

  /// Attach one uniquely proven provider/project owner to a legacy V1 pointer.
  ///
  /// The original pointer bytes are compared again while holding the same
  /// cross-process lock used by `save` and the owner-gated pointer-removal routes.
  /// Any intervening writer wins;
  /// this migration fails without touching the file.
  @discardableResult
  public func migrateCurrentV1Owner(
    snapshot: TatwoSessionPointerSnapshotV1,
    legacyOwnerExpectation: TatwoSessionOwnerExpectationV1
  ) throws -> TatwoSessionPointer {
    guard Self.normalized(legacyOwnerExpectation.provider) != nil else {
      throw TatwoSessionMutationError.invalidOwnerExpectation("provider")
    }
    guard Self.normalized(
      legacyOwnerExpectation.externalProviderSessionID) != nil
    else {
      throw TatwoSessionMutationError.invalidOwnerExpectation("sessionID")
    }
    guard Self.normalizedWorkspacePath(
      legacyOwnerExpectation.workspacePath) != nil
    else {
      throw TatwoSessionMutationError.invalidOwnerExpectation("workspacePath")
    }

    return try TatwoFileLock.withExclusiveLock(for: fileURL) {
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        throw TatwoSessionMutationError.noCurrentSession
      }
      let currentData = try Data(contentsOf: fileURL)
      guard currentData == snapshot.revision.rawData else {
        throw TatwoSessionMutationError.currentSessionChanged
      }
      let currentPointer = try decoded(currentData)
      guard currentPointer == snapshot.pointer else {
        throw TatwoSessionMutationError.currentSessionChanged
      }
      guard currentPointer.schema == "TatwoSessionPointerV1",
        currentPointer.ownerBinding == nil
      else {
        throw TatwoSessionMutationError.sourcePointerNotLegacyV1(
          currentPointer.schema)
      }

      let migrated = currentPointer.owned(
        provider: legacyOwnerExpectation.provider,
        sessionID: legacyOwnerExpectation.externalProviderSessionID,
        workspacePath: legacyOwnerExpectation.workspacePath)
      try encoded(migrated).write(to: fileURL, options: [.atomic])
      return migrated
    }
  }

  public func current() throws -> TatwoSessionPointer? {
    try snapshotCurrent()?.pointer
  }

  /// Clear a non-running current session only after resolving the exact stored
  /// Goal. A running Goal or either half of a supersession transaction remains
  /// attached for reconciliation.
  @discardableResult
  public func stopCurrent(
    ownerVerification: TatwoSessionOwnerVerificationV1? = nil,
    goalStore: TatwoGoalRunStore? = nil
  ) throws -> TatwoSessionAttachmentV1? {
    let resolvedGoalStore =
      goalStore ?? TatwoGoalRunStore(directoryURL: directoryURL)
    return try TatwoFileLock.withExclusiveLock(for: fileURL) {
      guard let data = try currentDataUnlocked() else { return nil }
      let pointer = try decoded(data)
      let attachment = try resolveCurrent(
        pointer: pointer,
        ownerVerification: ownerVerification,
        expectedContractID: pointer.contractID,
        expectedGoalID: pointer.goalID,
        expectedMode: pointer.mode,
        expectedScenario: pointer.scenario,
        expectedObjective: pointer.objective,
        scenarioBook: TatwoScenarioConfigDefaults.book,
        goalStore: resolvedGoalStore,
        requireOwnedOwnerVerification: true,
        requireAttachableGoal: false)
      if attachment.goalRecord.status == .running
        || attachment.goalRecord.status == .dispatching
        || attachment.goalRecord.status == .superseded
        || attachment.goalRecord.supersession != nil
      {
        throw TatwoSessionMutationError.currentSessionStopDenied(
          attachment.goalRecord.status)
      }
      guard let currentData = try currentDataUnlocked(), currentData == data else {
        throw TatwoSessionMutationError.currentSessionChanged
      }
      try FileManager.default.removeItem(at: fileURL)
      return attachment
    }
  }

  /// Replace the exact running current Goal, or an exact pristine planned Goal
  /// that has published no executable work, with an already-issued pristine
  /// planned revision. The only caller-supplied authority is a durable
  /// authorization ID; models and MCP cannot mint the authorization. Host
  /// operation authorization is a separate post-transition artifact.
  @discardableResult
  public func transitionCurrentToPlannedRevision(
    authorizationID: String,
    now: Date = Date(),
    goalStore: TatwoGoalRunStore? = nil,
    dispatchRegistry: TatwoDispatchRegistry? = nil,
    authorizationStore:
      TatwoGoalRevisionPromotionAuthorizationStore? = nil,
    humanGateReceiptStore: TatwoHumanGateReceiptStore? = nil,
    humanGateVerifier: (any TatwoHumanGateVerifying)? = nil
  ) throws -> TatwoGoalRevisionPromotionResultV1 {
    let resolvedGoalStore =
      goalStore ?? TatwoGoalRunStore(directoryURL: directoryURL)
    let resolvedRegistry =
      dispatchRegistry ?? TatwoDispatchRegistry(directoryURL: directoryURL)
    let resolvedAuthorizationStore =
      authorizationStore
      ?? TatwoGoalRevisionPromotionAuthorizationStore(
        directoryURL: directoryURL.appendingPathComponent(
          "goal-revision-authorizations", isDirectory: true))
    let resolvedHumanGateReceiptStore =
      humanGateReceiptStore
      ?? TatwoHumanGateReceiptStore(
        directoryURL: directoryURL.appendingPathComponent(
          "human-gate-receipts", isDirectory: true))

    return try TatwoFileLock.withExclusiveLock(
      for: revisionPromotionLockURL
    ) {
      try TatwoFileLock.withExclusiveLock(for: fileURL) {
        if let journal = try readRevisionPromotionJournal(
          authorizationID: authorizationID)
        {
          return try TatwoGoalRunDispatchLifecycle.withLifecycleLocks(
            contractIDs: [
              journal.metadata.predecessorContractID,
              journal.metadata.successorContractID,
            ],
            goalStore: resolvedGoalStore
          ) {
            try reconcileRevisionPromotionLocked(
              journal: journal,
              goalStore: resolvedGoalStore,
              dispatchRegistry: resolvedRegistry)
          }
        }

        guard let pointerData = try currentDataUnlocked() else {
          throw TatwoSessionMutationError.noCurrentSession
        }
        let pointer = try decoded(pointerData)
        let pointerDigest =
          TatwoGoalRevisionPromotionAuthorizationV1.digest(pointerData)
        let authorization: TatwoGoalRevisionPromotionAuthorizationV1
        do {
          authorization = try resolvedAuthorizationStore.require(
            id: authorizationID, now: now)
        } catch {
          throw TatwoSessionMutationError.revisionPromotionAuthorization(
            error.localizedDescription)
        }
        guard authorization.oldPointerRevisionDigest == pointerDigest else {
          throw TatwoSessionMutationError.revisionPromotionAuthorization(
            "old_pointer_revision")
        }
        guard pointer.contractID == authorization.oldContractID,
          pointer.goalID == authorization.oldGoalID,
          (pointer.generation ?? 1) == authorization.oldPointerGeneration
        else {
          throw TatwoSessionMutationError.revisionPromotionAuthorization(
            "old_pointer_identity")
        }
        let sessionID =
          pointer.ownerBinding?.sessionID
          ?? "unowned:\(pointer.contractID):\(pointer.goalID)"
        guard sessionID == authorization.sessionID else {
          throw TatwoSessionMutationError.revisionPromotionAuthorization(
            "session")
        }

        return try TatwoGoalRunDispatchLifecycle.withLifecycleLocks(
          contractIDs: [
            authorization.oldContractID,
            authorization.newContractID,
          ],
          goalStore: resolvedGoalStore
        ) {
          let oldSnapshot = try resolvedGoalStore.snapshot(
            forContractID: authorization.oldContractID)
          let newSnapshot = try resolvedGoalStore.snapshot(
            forContractID: authorization.newContractID)
          let old = oldSnapshot.record
          let new = newSnapshot.record

        let oldIsPristinePlanned =
          Self.isPristinePlannedForSupersession(old)
        guard old.status == .running || oldIsPristinePlanned else {
          throw TatwoSessionMutationError.revisionPromotionOldGoalNotRunning(
            old.status)
        }
        if oldIsPristinePlanned {
          guard try !Self.hasExecutablePublicationEvidenceForSupersession(
            pointer: pointer,
            goalRecord: old,
            goalStore: resolvedGoalStore)
          else {
            throw TatwoSessionMutationError.currentSessionHasPublishedWork
          }
        }
        guard old.goalID == authorization.oldGoalID,
          old.resolvedRevision == authorization.oldGoalRevision,
          authorization.oldObjectiveDigest
            == TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
              old.objective)
        else {
          throw TatwoSessionMutationError.revisionPromotionAuthorization(
            "old_goal_revision")
        }
        guard new.status == .planned,
          Self.isPristinePlannedForSupersession(new),
          new.contractID == authorization.newContractID,
          new.goalID == authorization.newGoalID,
          authorization.newGoalRevision == old.resolvedRevision + 1
        else {
          throw TatwoSessionMutationError.revisionPromotionNewGoalNotPristine(
            new.status)
        }
        guard authorization.newObjectiveDigest
          == TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
            new.objective)
        else {
          throw TatwoSessionMutationError.revisionPromotionAuthorization(
            "new_objective")
        }
        guard authorization.topologyDigest
          == TatwoGoalRevisionPromotionAuthorizationV1.topologyDigest(
            sessionID: sessionID,
            oldContractID: old.contractID,
            oldGoalID: old.goalID,
            newContractID: new.contractID,
            newGoalID: new.goalID)
        else {
          throw TatwoSessionMutationError.revisionPromotionAuthorization(
            "topology")
        }
        guard authorization.capabilityDigest
          == TatwoGoalRevisionPromotionAuthorizationV1.capabilityDigest(
            oldBindingsDigest: old.issuedIdentityBindingsDigest,
            newBindingsDigest: new.issuedIdentityBindingsDigest)
        else {
          throw TatwoSessionMutationError.revisionPromotionAuthorization(
            "capability")
        }
        if authorization.issuerDomain
          == TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain
        {
          guard authorization.oldReceiptsDigest
            == TatwoGoalRevisionPromotionAuthorizationV1.receiptsDigest(
              old.receipts)
          else {
            throw TatwoSessionMutationError.revisionPromotionAuthorization(
              "old_receipts")
          }
          guard authorization.oldActivationEpoch == old.resolvedRevision else {
            throw TatwoSessionMutationError.revisionPromotionAuthorization(
              "old_activation_epoch")
          }
        }
        do {
          let humanReceipt = try resolvedHumanGateReceiptStore.require(
            id: authorization.humanGateReceiptID)
          guard humanReceipt.sessionID == sessionID,
            humanReceipt.oldContractID == old.contractID,
            humanReceipt.oldGoalID == old.goalID,
            humanReceipt.newContractID == new.contractID,
            humanReceipt.newGoalID == new.goalID
          else {
            throw TatwoHumanGateVerificationError.invalid("scope")
          }
          if authorization.issuerDomain
            == TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain
          {
            guard let recoveryEvidence =
              humanReceipt.bootstrapRecoveryEvidence,
              recoveryEvidence.isExactBinding(for: authorization)
            else {
              throw TatwoHumanGateVerificationError.invalid(
                "bootstrap_recovery_scope")
            }
          }
          try (
            humanGateVerifier
              ?? TatwoProductionHumanGateVerifier(
                stateDirectoryURL: resolvedGoalStore.directoryURL)
          ).verify(
            receipt: humanReceipt,
            subjectDigest: authorization.humanGateSubjectDigest,
            now: now)
        } catch {
          throw TatwoSessionMutationError.revisionPromotionAuthorization(
            error.localizedDescription)
        }
        if Self.hasSuccessorExecutablePublicationEvidence(
          successor: new,
          goalStore: resolvedGoalStore,
          dispatchRegistry: resolvedRegistry)
        {
          throw TatwoSessionMutationError.revisionPromotionNewGoalPublishedWork
        }
        let activeDispatches = try Self.activeDispatchHeadIDs(
          contractID: old.contractID,
          goalID: old.goalID,
          registry: resolvedRegistry)
        guard activeDispatches.isEmpty else {
          throw TatwoSessionMutationError.revisionPromotionDispatchActive(
            activeDispatches)
        }
        let supersessionReceiptID =
          "goal-supersession-\(String(authorization.proofDigest.suffix(24)))"
        // JSONEncoder's `.iso8601` strategy persists whole seconds. Normalize
        // once before the same receipt is compared both pre- and post-write;
        // otherwise an ordinary fractional `Date()` self-conflicts on retry.
        let supersededAt = Date(
          timeIntervalSince1970:
            now.timeIntervalSince1970.rounded(.down))
        let metadata = TatwoGoalRevisionSupersessionMetadataV1(
          predecessorContractID: old.contractID,
          predecessorGoalID: old.goalID,
          predecessorRevision: old.resolvedRevision,
          successorContractID: new.contractID,
          successorGoalID: new.goalID,
          successorRevision: authorization.newGoalRevision,
          promotionAuthorizationID: authorization.id,
          humanGateReceiptID: authorization.humanGateReceiptID,
          supersessionReceiptID: supersessionReceiptID,
          oldPointerRevisionDigest: pointerDigest,
          oldPointerGeneration: authorization.oldPointerGeneration,
          oldObjectiveDigest: authorization.oldObjectiveDigest,
          newObjectiveDigest: authorization.newObjectiveDigest,
          topologyDigest: authorization.topologyDigest,
          capabilityDigest: authorization.capabilityDigest,
          requestedHostScopeDigest: authorization.requestedHostScopeDigest,
          supersededAt: supersededAt,
          promotionIssuerDomain: authorization.issuerDomain,
          oldReceiptsDigest: authorization.oldReceiptsDigest,
          oldActivationEpoch: authorization.oldActivationEpoch,
          bootstrapRecoveryContextDigest:
            authorization.bootstrapRecoveryContextDigest)
        var journal = TatwoGoalRevisionPromotionJournalV1(
          authorizationID: authorization.id,
          oldPointerRevisionDigest: pointerDigest,
          oldGoalRevisionDigest: oldSnapshot.persistedRevisionDigest,
          newGoalRevisionDigest: newSnapshot.persistedRevisionDigest,
          metadata: metadata,
          preparedAt: now,
          updatedAt: now)
        try writeRevisionPromotionJournal(journal)
        do {
          try revisionPromotionFault?(.prepared)
          try applyOldSupersession(
            journal: journal,
            snapshot: oldSnapshot,
            goalStore: resolvedGoalStore)
          journal.stage = .oldSuperseded
          journal.updatedAt = Date()
          try writeRevisionPromotionJournal(journal)
          try revisionPromotionFault?(.oldSuperseded)

          try applyNewRevisionRunning(
            journal: journal,
            snapshot: newSnapshot,
            goalStore: resolvedGoalStore)
          journal.stage = .newRunning
          journal.updatedAt = Date()
          try writeRevisionPromotionJournal(journal)
          try revisionPromotionFault?(.newRunning)

          guard let currentPointerData = try currentDataUnlocked(),
            TatwoGoalRevisionPromotionAuthorizationV1.digest(
              currentPointerData) == journal.oldPointerRevisionDigest,
            try decoded(currentPointerData) == pointer
          else {
            throw TatwoSessionMutationError.currentSessionChanged
          }
          let successorPointer = Self.successorPointer(
            from: pointer,
            metadata: metadata,
            successor: new)
          try encoded(successorPointer).write(
            to: fileURL, options: [.atomic])
          journal.stage = .pointerReplaced
          journal.updatedAt = Date()
          try writeRevisionPromotionJournal(journal)
          try revisionPromotionFault?(.pointerReplaced)

          _ = try writeSupersessionReceiptIfNeeded(journal: journal)
          journal.stage = .completed
          journal.updatedAt = Date()
          try writeRevisionPromotionJournal(journal)
          return try revisionPromotionResult(
            journal: journal,
            goalStore: resolvedGoalStore,
            reconciled: false)
        } catch {
          if error is TatwoSessionMutationError {
            throw error
          }
          throw TatwoSessionMutationError
            .revisionPromotionReconciliationRequired(journal.stage.rawValue)
        }
        }
      }
    }
  }

  /// Resume a prepared cross-file revision promotion after restart. A journal
  /// is append-forward only: each stage re-verifies the durable predecessor,
  /// successor, and pointer before completing the next mutation.
  @discardableResult
  public func reconcileRevisionPromotion(
    authorizationID: String,
    goalStore: TatwoGoalRunStore? = nil,
    dispatchRegistry: TatwoDispatchRegistry? = nil
  ) throws -> TatwoGoalRevisionPromotionResultV1 {
    let resolvedGoalStore =
      goalStore ?? TatwoGoalRunStore(directoryURL: directoryURL)
    let resolvedRegistry =
      dispatchRegistry ?? TatwoDispatchRegistry(directoryURL: directoryURL)
    return try TatwoFileLock.withExclusiveLock(
      for: revisionPromotionLockURL
    ) {
      try TatwoFileLock.withExclusiveLock(for: fileURL) {
        guard let journal = try readRevisionPromotionJournal(
          authorizationID: authorizationID)
        else {
          throw TatwoSessionMutationError.revisionPromotionJournalConflict
        }
        return try TatwoGoalRunDispatchLifecycle.withLifecycleLocks(
          contractIDs: [
            journal.metadata.predecessorContractID,
            journal.metadata.successorContractID,
          ],
          goalStore: resolvedGoalStore
        ) {
          try reconcileRevisionPromotionLocked(
            journal: journal,
            goalStore: resolvedGoalStore,
            dispatchRegistry: resolvedRegistry)
        }
      }
    }
  }

  /// Validate and project the current pointer for a read-only status surface.
  ///
  /// Unlike `attachCurrent`, this may return a terminal GoalRun so dashboards and
  /// export surfaces can show the canonical closed result. It still validates the
  /// pointer schema and every pointer/GoalRun/projection identity field, and it
  /// never calls `WorkOSFactory.begin`.
  public func inspectCurrent(
    ownerVerification: TatwoSessionOwnerVerificationV1? = nil,
    expectedContractID: String? = nil,
    expectedGoalID: String? = nil,
    expectedMode: WorkModeID? = nil,
    expectedScenario: String? = nil,
    expectedObjective: String? = nil,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    goalStore: TatwoGoalRunStore? = nil
  ) throws -> TatwoSessionAttachmentV1? {
    try TatwoFileLock.withExclusiveLock(for: fileURL) {
      guard let data = try currentDataUnlocked() else { return nil }
      return try resolveCurrent(
        pointer: try decoded(data),
        ownerVerification: ownerVerification,
        expectedContractID: expectedContractID,
        expectedGoalID: expectedGoalID,
        expectedMode: expectedMode,
        expectedScenario: expectedScenario,
        expectedObjective: expectedObjective,
        scenarioBook: scenarioBook,
        goalStore: goalStore,
        requireOwnedOwnerVerification: false,
        requireAttachableGoal: false)
    }
  }

  /// Rehydrate the exact active GoalRun without calling `WorkOSFactory.begin`.
  ///
  /// The pointer is only a locator. The stored GoalRun remains authoritative, every
  /// pointer/caller field is matched fail-closed, and terminal runs cannot be
  /// resurrected as an active session. Dispatch-finalized runs remain attachable
  /// while they await the explicit Goal Judge close.
  public func attachCurrent(
    ownerVerification: TatwoSessionOwnerVerificationV1? = nil,
    expectedContractID: String? = nil,
    expectedGoalID: String? = nil,
    expectedMode: WorkModeID? = nil,
    expectedScenario: String? = nil,
    expectedObjective: String? = nil,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    goalStore: TatwoGoalRunStore? = nil
  ) throws -> TatwoSessionAttachmentV1 {
    try TatwoFileLock.withExclusiveLock(for: fileURL) {
      guard let data = try currentDataUnlocked() else {
        throw TatwoSessionAttachmentError.noCurrentSession
      }
      return try resolveCurrent(
        pointer: try decoded(data),
        ownerVerification: ownerVerification,
        expectedContractID: expectedContractID,
        expectedGoalID: expectedGoalID,
        expectedMode: expectedMode,
        expectedScenario: expectedScenario,
        expectedObjective: expectedObjective,
        scenarioBook: scenarioBook,
        goalStore: goalStore,
        requireOwnedOwnerVerification: true,
        requireAttachableGoal: true)
    }
  }

  /// Remove the exact pointer revision only after re-validating its canonical
  /// owner, GoalRun identity, and stored projection under the pointer lock.
  ///
  /// Terminal GoalRuns are intentionally eligible: ending an already closed
  /// active session must clear its pointer without re-attaching it as live.
  @discardableResult
  public func compareAndClearCurrent(
    snapshot: TatwoSessionPointerSnapshotV1,
    ownerVerification: TatwoSessionOwnerVerificationV1? = nil,
    expectedContractID: String? = nil,
    expectedGoalID: String? = nil,
    expectedMode: WorkModeID? = nil,
    expectedScenario: String? = nil,
    expectedObjective: String? = nil,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    goalStore: TatwoGoalRunStore? = nil
  ) throws -> TatwoSessionAttachmentV1 {
    try TatwoFileLock.withExclusiveLock(for: fileURL) {
      guard let currentData = try currentDataUnlocked() else {
        throw TatwoSessionMutationError.noCurrentSession
      }
      guard currentData == snapshot.revision.rawData else {
        throw TatwoSessionMutationError.currentSessionChanged
      }
      let currentPointer = try decoded(currentData)
      guard currentPointer == snapshot.pointer else {
        throw TatwoSessionMutationError.currentSessionChanged
      }
      let attachment = try resolveCurrent(
        pointer: currentPointer,
        ownerVerification: ownerVerification,
        expectedContractID: expectedContractID,
        expectedGoalID: expectedGoalID,
        expectedMode: expectedMode,
        expectedScenario: expectedScenario,
        expectedObjective: expectedObjective,
        scenarioBook: scenarioBook,
        goalStore: goalStore,
        requireOwnedOwnerVerification: true,
        requireAttachableGoal: false)
      try FileManager.default.removeItem(at: fileURL)
      return attachment
    }
  }

  /// Cancel and clear an exact current-session only while it is still the
  /// pristine, pre-dispatch GoalRun issued by `beginCurrent`.
  ///
  /// This is the narrow route-picker revision boundary: changing primary or
  /// secondary models may supersede an untouched plan, but it must never detach
  /// a Goal that has begun dispatch, accumulated non-activation receipts, or
  /// reached a later lifecycle state. The cancelled GoalRun remains durable as
  /// audit evidence; only the exact pointer revision is removed.
  @discardableResult
  public func supersedePristinePlannedCurrent(
    ownerVerification: TatwoSessionOwnerVerificationV1? = nil,
    expectedContractID: String,
    expectedGoalID: String,
    expectedMode: WorkModeID,
    expectedScenario: String,
    expectedObjective: String,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    goalStore: TatwoGoalRunStore? = nil
  ) throws -> TatwoSessionAttachmentV1 {
    let resolvedGoalStore = goalStore ?? TatwoGoalRunStore(directoryURL: directoryURL)
    return try TatwoFileLock.withExclusiveLock(for: fileURL) {
      guard let originalData = try currentDataUnlocked() else {
        throw TatwoSessionMutationError.noCurrentSession
      }
      let pointer = try decoded(originalData)

      let before = try resolveCurrent(
        pointer: pointer,
        ownerVerification: ownerVerification,
        expectedContractID: expectedContractID,
        expectedGoalID: expectedGoalID,
        expectedMode: expectedMode,
        expectedScenario: expectedScenario,
        expectedObjective: expectedObjective,
        scenarioBook: scenarioBook,
        goalStore: resolvedGoalStore,
        requireOwnedOwnerVerification: true,
        requireAttachableGoal: false)
      guard before.goalRecord.status == .planned else {
        throw TatwoSessionMutationError.currentSessionNotPristinePlanned(
          before.goalRecord.status)
      }
      guard Self.isPristinePlannedForSupersession(before.goalRecord) else {
        throw TatwoSessionMutationError.currentSessionHasPublishedWork
      }

      let snapshot = try resolvedGoalStore.snapshot(
        forContractID: expectedContractID)
      guard snapshot.record == before.goalRecord else {
        throw TatwoSessionMutationError.currentSessionChanged
      }
      return try TatwoGoalRunDispatchLifecycle.withLifecycleLock(
        contractID: expectedContractID,
        goalStore: resolvedGoalStore
      ) {
        guard try !Self.hasExecutablePublicationEvidenceForSupersession(
          pointer: pointer,
          goalRecord: before.goalRecord,
          goalStore: resolvedGoalStore)
        else {
          throw TatwoSessionMutationError.currentSessionHasPublishedWork
        }
        try resolvedGoalStore.withVerifiedCurrentSnapshotTransaction(snapshot) { record in
          guard record.status == .planned else {
            throw TatwoSessionMutationError.currentSessionNotPristinePlanned(
              record.status)
          }
          guard Self.isPristinePlannedForSupersession(record) else {
            throw TatwoSessionMutationError.currentSessionHasPublishedWork
          }
          try resolvedGoalStore.transitionLockedRecord(
            &record,
            status: .cancelled,
            authority: .plannedSupersede,
            reason: "superseded_before_dispatch")
        }

        do {
          try afterSupersessionCancellation?()
          guard let currentData = try currentDataUnlocked(),
            currentData == originalData,
            try decoded(currentData) == pointer
          else {
            throw TatwoSessionMutationError
              .currentSessionSupersededPointerCleanupRequired
          }
          let cancelled = try resolveCurrent(
            pointer: pointer,
            ownerVerification: ownerVerification,
            expectedContractID: expectedContractID,
            expectedGoalID: expectedGoalID,
            expectedMode: expectedMode,
            expectedScenario: expectedScenario,
            expectedObjective: expectedObjective,
            scenarioBook: scenarioBook,
            goalStore: resolvedGoalStore,
            requireOwnedOwnerVerification: true,
            requireAttachableGoal: false)
          guard Self.isSupersededTerminalForCleanup(cancelled.goalRecord) else {
            throw TatwoSessionMutationError
              .currentSessionSupersededPointerCleanupRequired
          }
          try removeSupersededPointer(fileURL)
          return cancelled
        } catch let error as TatwoSessionMutationError
          where error == .currentSessionSupersededPointerCleanupRequired
        {
          throw error
        } catch {
          throw TatwoSessionMutationError
            .currentSessionSupersededPointerCleanupRequired
        }
      }
    }
  }

  /// Complete the exact pointer half of a pristine supersession that already
  /// durably cancelled its GoalRun before a crash or filesystem failure.
  ///
  /// This is intentionally narrower than generic terminal-pointer recovery:
  /// only the exact `superseded_before_dispatch` terminal record, with no
  /// dispatch/outbox evidence and no non-tracker receipts, is reclaimable.
  /// Returning `nil` means either no pointer exists or the current pointer is
  /// not this narrowly recoverable partial commit.
  @discardableResult
  public func reconcileSupersededTerminalCurrent(
    ownerVerification: TatwoSessionOwnerVerificationV1? = nil,
    expectedContractID: String? = nil,
    expectedGoalID: String? = nil,
    expectedMode: WorkModeID? = nil,
    expectedScenario: String? = nil,
    expectedObjective: String? = nil,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    goalStore: TatwoGoalRunStore? = nil
  ) throws -> TatwoSessionAttachmentV1? {
    let resolvedGoalStore = goalStore ?? TatwoGoalRunStore(directoryURL: directoryURL)
    return try TatwoFileLock.withExclusiveLock(for: fileURL) {
      guard let originalData = try currentDataUnlocked() else { return nil }
      let pointer = try decoded(originalData)
      let attachment = try resolveCurrent(
        pointer: pointer,
        ownerVerification: ownerVerification,
        expectedContractID: expectedContractID,
        expectedGoalID: expectedGoalID,
        expectedMode: expectedMode,
        expectedScenario: expectedScenario,
        expectedObjective: expectedObjective,
        scenarioBook: scenarioBook,
        goalStore: resolvedGoalStore,
        requireOwnedOwnerVerification: true,
        requireAttachableGoal: false)
      guard Self.isSupersededTerminalForCleanup(attachment.goalRecord) else {
        return nil
      }

      do {
        return try TatwoGoalRunDispatchLifecycle.withLifecycleLock(
          contractID: pointer.contractID,
          goalStore: resolvedGoalStore
        ) {
          guard try !Self.hasExecutablePublicationEvidenceForSupersession(
            pointer: pointer,
            goalRecord: attachment.goalRecord,
            goalStore: resolvedGoalStore)
          else {
            return nil
          }
          guard let currentData = try currentDataUnlocked(),
            currentData == originalData,
            try decoded(currentData) == pointer
          else {
            throw TatwoSessionMutationError
              .currentSessionSupersededPointerCleanupRequired
          }
          let currentAttachment = try resolveCurrent(
            pointer: pointer,
            ownerVerification: ownerVerification,
            expectedContractID: expectedContractID,
            expectedGoalID: expectedGoalID,
            expectedMode: expectedMode,
            expectedScenario: expectedScenario,
            expectedObjective: expectedObjective,
            scenarioBook: scenarioBook,
            goalStore: resolvedGoalStore,
            requireOwnedOwnerVerification: true,
            requireAttachableGoal: false)
          guard Self.isSupersededTerminalForCleanup(
            currentAttachment.goalRecord)
          else {
            return nil
          }
          try removeSupersededPointer(fileURL)
          return currentAttachment
        }
      } catch {
        throw TatwoSessionMutationError
          .currentSessionSupersededPointerCleanupRequired
      }
    }
  }

  /// Close the Goal Judge state and clear the exact current-session pointer as
  /// one cooperative pointer-lock transaction.
  ///
  /// The GoalRun file still has its own lock, so this is not a cross-file atomic
  /// filesystem commit. The invariant enforced here is narrower and explicit:
  /// no cooperative pointer writer can replace the current session between the
  /// canonical Goal close, terminal re-read, and pointer removal.
  ///
  /// Returns `nil` when no current pointer exists. In that case callers may
  /// close their already-bound GoalRun separately because there is no pointer
  /// mutation to race.
  @discardableResult
  public func closeAndClearCurrent(
    ownerVerification: TatwoSessionOwnerVerificationV1? = nil,
    expectedContractID: String,
    expectedGoalID: String,
    expectedMode: WorkModeID,
    expectedScenario: String,
    expectedObjective: String,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    goalStore: TatwoGoalRunStore? = nil
  ) throws -> TatwoSessionAttachmentV1? {
    let resolvedGoalStore = goalStore ?? TatwoGoalRunStore(directoryURL: directoryURL)
    let resolvedDispatchRegistry = TatwoDispatchRegistry(
      directoryURL: resolvedGoalStore.directoryURL)
    return try TatwoFileLock.withExclusiveLock(for: fileURL) {
      guard let originalData = try currentDataUnlocked() else { return nil }
      let pointer = try decoded(originalData)

      let before = try resolveCurrent(
        pointer: pointer,
        ownerVerification: ownerVerification,
        expectedContractID: expectedContractID,
        expectedGoalID: expectedGoalID,
        expectedMode: expectedMode,
        expectedScenario: expectedScenario,
        expectedObjective: expectedObjective,
        scenarioBook: scenarioBook,
        goalStore: resolvedGoalStore,
        requireOwnedOwnerVerification: true,
        requireAttachableGoal: false)

      switch before.goalRecord.status {
      case .failed, .cancelled, .passed, .rollbackRequired:
        break
      case .superseded:
        throw TatwoSessionMutationError.currentSessionStopDenied(.superseded)
      case .planned, .dispatching, .running, .succeeded, .humanGate,
        .awaitingNextCycle, .blocked:
        let result = try WorkOSFactory.closeGoal(
          goalID: expectedGoalID,
          contractID: expectedContractID,
          mode: expectedMode,
          scenarioProfileID: expectedScenario,
          objective: expectedObjective,
          suppliedReceiptIDs: [],
          scenarioBook: scenarioBook,
          store: resolvedGoalStore,
          dispatchRegistry: resolvedDispatchRegistry)
        guard result.ok else {
          throw TatwoSessionMutationError.currentSessionGoalCloseIncomplete
        }
        guard result.status == .passed else {
          throw TatwoGoalRunStoreError.illegalStatusTransition(
            from: before.goalRecord.status,
            to: result.status,
            authority: "session_close_and_clear")
        }
      }

      guard let currentData = try currentDataUnlocked(),
        currentData == originalData,
        try decoded(currentData) == pointer
      else {
        throw TatwoSessionMutationError.currentSessionChanged
      }
      let terminal = try resolveCurrent(
        pointer: pointer,
        ownerVerification: ownerVerification,
        expectedContractID: expectedContractID,
        expectedGoalID: expectedGoalID,
        expectedMode: expectedMode,
        expectedScenario: expectedScenario,
        expectedObjective: expectedObjective,
        scenarioBook: scenarioBook,
        goalStore: resolvedGoalStore,
        requireOwnedOwnerVerification: true,
        requireAttachableGoal: false)
      guard [.failed, .cancelled, .passed, .rollbackRequired]
        .contains(terminal.goalRecord.status)
      else {
        throw TatwoGoalRunStoreError.illegalStatusTransition(
          from: terminal.goalRecord.status,
          to: .rollbackRequired,
          authority: "session_close_and_clear_terminal_verify")
      }
      try FileManager.default.removeItem(at: fileURL)
      return terminal
    }
  }

  private func resolveCurrent(
    pointer: TatwoSessionPointer,
    ownerVerification: TatwoSessionOwnerVerificationV1?,
    expectedContractID: String?,
    expectedGoalID: String?,
    expectedMode: WorkModeID?,
    expectedScenario: String?,
    expectedObjective: String?,
    scenarioBook: TatwoScenarioConfigBookV1,
    goalStore: TatwoGoalRunStore?,
    requireOwnedOwnerVerification: Bool,
    requireAttachableGoal: Bool
  ) throws -> TatwoSessionAttachmentV1 {
    switch pointer.schema {
    case "TatwoSessionPointerV1":
      guard pointer.ownerBinding == nil else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding("v1_owner_presence")
      }
    case "TatwoSessionPointerV2":
      guard let owner = pointer.ownerBinding else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding("missing")
      }
      guard owner.schema == "TatwoSessionOwnerBindingV1" else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding("schema")
      }
      guard Self.normalized(owner.provider) != nil else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding("provider")
      }
      guard Self.normalized(owner.sessionID) != nil else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding("sessionID")
      }
      guard Self.normalizedWorkspacePath(owner.workspacePath) != nil else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding("workspacePath")
      }
      guard owner.contractID == pointer.contractID else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding("contractID")
      }
      guard owner.goalID == pointer.goalID else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding("goalID")
      }
      guard pointer.authorityTransactionID == nil,
        pointer.authorityPlanSHA256 == nil,
        pointer.executionManifestSHA256 == nil
      else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding(
          "v2_authority_fields")
      }
    case "TatwoSessionAuthorityPointerV3":
      guard let owner = pointer.ownerBinding else {
        throw TatwoSessionAttachmentError.ownerExpectationMismatch("missing")
      }
      guard owner.schema == "TatwoSessionOwnerBindingV1",
        Self.normalized(owner.provider) != nil,
        Self.normalized(owner.sessionID) != nil,
        owner.ownerKind != nil,
        Self.normalizedWorkspacePath(owner.workspacePath) != nil,
        owner.contractID == pointer.contractID,
        owner.goalID == pointer.goalID
      else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding(
          "v3_owner")
      }
      guard let transactionID =
        Self.normalized(pointer.authorityTransactionID),
        transactionID.hasPrefix("goal-authority-"),
        Self.isSHA256(pointer.authorityPlanSHA256),
        Self.isSHA256(pointer.executionManifestSHA256),
        let generation = pointer.generation,
        generation > 0
      else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding(
          "v3_authority_binding")
      }
      do {
        try TatwoGoalAuthorityTransaction
          .validateAuthorityReadback(
            pointer: pointer,
            stateRoot: directoryURL)
      } catch {
        throw TatwoSessionAttachmentError.pointerGoalRunMismatch(
          "v3_authority_artifacts")
      }
    default:
      throw TatwoSessionAttachmentError.unsupportedPointerSchema(pointer.schema)
    }

    try verifyOwner(
      pointer: pointer,
      ownerVerification: ownerVerification,
      requireOwnedOwnerVerification: requireOwnedOwnerVerification)

    let expectedContractID = Self.normalized(expectedContractID)
    let expectedGoalID = Self.normalized(expectedGoalID)
    let expectedScenario = Self.normalized(expectedScenario)
    if let expectedContractID, expectedContractID != pointer.contractID {
      throw TatwoSessionAttachmentError.callerExpectationMismatch("contractID")
    }
    if let expectedGoalID, expectedGoalID != pointer.goalID {
      throw TatwoSessionAttachmentError.callerExpectationMismatch("goalID")
    }
    if let expectedMode, expectedMode != pointer.mode {
      throw TatwoSessionAttachmentError.callerExpectationMismatch("mode")
    }
    if let expectedScenario, expectedScenario != pointer.scenario {
      throw TatwoSessionAttachmentError.callerExpectationMismatch("scenario")
    }
    if let expectedObjective,
      TatwoObjectiveIdentity.make(expectedObjective).objectiveHash
        != TatwoObjectiveIdentity.make(pointer.objective).objectiveHash
    {
      throw TatwoSessionAttachmentError.callerExpectationMismatch("objective")
    }

    let resolvedGoalStore = goalStore ?? TatwoGoalRunStore(directoryURL: directoryURL)
    let record = try resolvedGoalStore.requireIssuedContract(pointer.contractID)
    guard !requireAttachableGoal || Self.isAttachable(record) else {
      throw TatwoSessionAttachmentError.terminalGoalRun(record.status)
    }
    guard record.contractID == pointer.contractID else {
      throw TatwoSessionAttachmentError.pointerGoalRunMismatch("contractID")
    }
    guard record.goalID == pointer.goalID else {
      throw TatwoSessionAttachmentError.pointerGoalRunMismatch("goalID")
    }
    guard record.mode == pointer.mode else {
      throw TatwoSessionAttachmentError.pointerGoalRunMismatch("mode")
    }
    guard record.scenario == pointer.scenario else {
      throw TatwoSessionAttachmentError.pointerGoalRunMismatch("scenario")
    }
    guard TatwoObjectiveIdentity.make(record.objective).objectiveHash
      == TatwoObjectiveIdentity.make(pointer.objective).objectiveHash
    else {
      throw TatwoSessionAttachmentError.pointerGoalRunMismatch("objective")
    }

    let contract = try WorkOSFactory.storedContractProjection(
      contractID: record.contractID,
      fallbackMode: record.mode,
      fallbackScenarioProfileID: record.scenario,
      fallbackObjective: record.objective,
      scenarioBook: scenarioBook,
      store: resolvedGoalStore)
    guard contract.contractID == record.contractID,
      contract.goalID == record.goalID,
      contract.mode == record.mode,
      contract.scenario == record.scenario,
      TatwoObjectiveIdentity.make(contract.objective).objectiveHash
        == TatwoObjectiveIdentity.make(record.objective).objectiveHash,
      contract.routeBindingOverride == record.routeBindingOverride
    else {
      throw TatwoSessionAttachmentError.pointerGoalRunMismatch("contract_projection")
    }
    return TatwoSessionAttachmentV1(
      pointer: pointer,
      contract: contract,
      goalRecord: record)
  }

  private func reconcileRevisionPromotionLocked(
    journal originalJournal: TatwoGoalRevisionPromotionJournalV1,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws -> TatwoGoalRevisionPromotionResultV1 {
    var journal = originalJournal
    let metadata = journal.metadata

    let old = try goalStore.requireIssuedContract(
      metadata.predecessorContractID)
    let new = try goalStore.requireIssuedContract(
      metadata.successorContractID)

    let oldSnapshot: TatwoGoalRunSnapshotV1?
    if old.status == .running
      || Self.isPristinePlannedForSupersession(old)
    {
      if old.status == .planned {
        guard let pointerData = try currentDataUnlocked(),
          TatwoGoalRevisionPromotionAuthorizationV1.digest(pointerData)
            == journal.oldPointerRevisionDigest
        else {
          throw TatwoSessionMutationError.revisionPromotionJournalConflict
        }
        let pointer = try decoded(pointerData)
        guard try !Self.hasExecutablePublicationEvidenceForSupersession(
          pointer: pointer,
          goalRecord: old,
          goalStore: goalStore)
        else {
          throw TatwoSessionMutationError.currentSessionHasPublishedWork
        }
      }
      let active = try Self.activeDispatchHeadIDs(
        contractID: old.contractID,
        goalID: old.goalID,
        registry: dispatchRegistry)
      guard active.isEmpty else {
        throw TatwoSessionMutationError.revisionPromotionDispatchActive(active)
      }
      let snapshot = try goalStore.snapshot(forContractID: old.contractID)
      guard snapshot.persistedRevisionDigest == journal.oldGoalRevisionDigest else {
        throw TatwoSessionMutationError.revisionPromotionJournalConflict
      }
      oldSnapshot = snapshot
    } else {
      guard old.status == .superseded,
        old.supersession == metadata,
        old.successorContractID == metadata.successorContractID,
        old.successorGoalID == metadata.successorGoalID
      else {
        throw TatwoSessionMutationError.revisionPromotionJournalConflict
      }
      oldSnapshot = nil
    }

    let newSnapshot: TatwoGoalRunSnapshotV1?
    if new.status == .planned {
      guard Self.isPristinePlannedForSupersession(new),
        !Self.hasSuccessorExecutablePublicationEvidence(
          successor: new,
          goalStore: goalStore,
          dispatchRegistry: dispatchRegistry)
      else {
        throw TatwoSessionMutationError.revisionPromotionJournalConflict
      }
      let snapshot = try goalStore.snapshot(forContractID: new.contractID)
      guard snapshot.persistedRevisionDigest == journal.newGoalRevisionDigest else {
        throw TatwoSessionMutationError.revisionPromotionJournalConflict
      }
      newSnapshot = snapshot
    } else {
      guard new.status == .running,
        new.resolvedRevision == metadata.successorRevision,
        new.supersession == metadata,
        new.predecessorContractID == metadata.predecessorContractID,
        new.predecessorGoalID == metadata.predecessorGoalID
      else {
        throw TatwoSessionMutationError.revisionPromotionJournalConflict
      }
      newSnapshot = nil
    }

    if let oldSnapshot {
      try applyOldSupersession(
        journal: journal, snapshot: oldSnapshot, goalStore: goalStore)
    }
    journal.stage = .oldSuperseded
    journal.updatedAt = Date()
    try writeRevisionPromotionJournal(journal)

    if let newSnapshot {
      try applyNewRevisionRunning(
        journal: journal, snapshot: newSnapshot, goalStore: goalStore)
    }
    journal.stage = .newRunning
    journal.updatedAt = Date()
    try writeRevisionPromotionJournal(journal)

    guard let pointerData = try currentDataUnlocked() else {
      throw TatwoSessionMutationError.revisionPromotionJournalConflict
    }
    let pointer = try decoded(pointerData)
    if TatwoGoalRevisionPromotionAuthorizationV1.digest(pointerData)
      == journal.oldPointerRevisionDigest
    {
      guard pointer.contractID == metadata.predecessorContractID,
        pointer.goalID == metadata.predecessorGoalID,
        (pointer.generation ?? 1) == metadata.oldPointerGeneration
      else {
        throw TatwoSessionMutationError.revisionPromotionJournalConflict
      }
      let successor = try goalStore.requireIssuedContract(
        metadata.successorContractID)
      try encoded(
        Self.successorPointer(
          from: pointer,
          metadata: metadata,
          successor: successor)
      ).write(to: fileURL, options: [.atomic])
    } else {
      guard pointer.contractID == metadata.successorContractID,
        pointer.goalID == metadata.successorGoalID,
        (pointer.generation ?? 1) == metadata.oldPointerGeneration + 1
      else {
        throw TatwoSessionMutationError.revisionPromotionJournalConflict
      }
    }
    journal.stage = .pointerReplaced
    journal.updatedAt = Date()
    try writeRevisionPromotionJournal(journal)

    _ = try writeSupersessionReceiptIfNeeded(journal: journal)
    journal.stage = .completed
    journal.updatedAt = Date()
    try writeRevisionPromotionJournal(journal)
    return try revisionPromotionResult(
      journal: journal, goalStore: goalStore, reconciled: true)
  }

  private func applyOldSupersession(
    journal: TatwoGoalRevisionPromotionJournalV1,
    snapshot: TatwoGoalRunSnapshotV1,
    goalStore: TatwoGoalRunStore
  ) throws {
    let metadata = journal.metadata
    try goalStore.withVerifiedCurrentSnapshotTransaction(snapshot) { record in
      guard (record.status == .running
          || Self.isPristinePlannedForSupersession(record)),
        record.contractID == metadata.predecessorContractID,
        record.goalID == metadata.predecessorGoalID,
        record.resolvedRevision == metadata.predecessorRevision
      else {
        throw TatwoSessionMutationError.revisionPromotionJournalConflict
      }
      if record.status == .planned {
        try goalStore.transitionLockedRecord(
          &record,
          status: .running,
          authority: .revisionPromotion,
          reason:
            "activated_for_predispatch_goal_revision:"
            + metadata.successorContractID,
          now: metadata.supersededAt)
      }
      try goalStore.transitionLockedRecord(
        &record,
        status: .superseded,
        authority: .revisionPromotion,
        reason: "superseded_by_revision:\(metadata.successorContractID)",
        now: metadata.supersededAt)
      record.revision = metadata.predecessorRevision
      record.successorContractID = metadata.successorContractID
      record.successorGoalID = metadata.successorGoalID
      record.supersession = metadata
    }
  }

  private func applyNewRevisionRunning(
    journal: TatwoGoalRevisionPromotionJournalV1,
    snapshot: TatwoGoalRunSnapshotV1,
    goalStore: TatwoGoalRunStore
  ) throws {
    let metadata = journal.metadata
    try goalStore.withVerifiedCurrentSnapshotTransaction(snapshot) { record in
      guard Self.isPristinePlannedForSupersession(record),
        record.contractID == metadata.successorContractID,
        record.goalID == metadata.successorGoalID
      else {
        throw TatwoSessionMutationError.revisionPromotionJournalConflict
      }
      try goalStore.transitionLockedRecord(
        &record,
        status: .running,
        authority: .revisionPromotion,
        reason: "activated_by_goal_revision:\(metadata.predecessorContractID)",
        now: metadata.supersededAt)
      record.revision = metadata.successorRevision
      record.predecessorContractID = metadata.predecessorContractID
      record.predecessorGoalID = metadata.predecessorGoalID
      record.supersession = metadata
    }
  }

  private static func successorPointer(
    from predecessor: TatwoSessionPointer,
    metadata: TatwoGoalRevisionSupersessionMetadataV1,
    successor: TatwoStoredGoalRun
  ) -> TatwoSessionPointer {
    let owner = predecessor.ownerBinding.map {
      TatwoSessionOwnerBindingV1(
        provider: $0.provider,
        sessionID: $0.sessionID,
        ownerKind: $0.ownerKind,
        workspacePath: $0.workspacePath,
        contractID: successor.contractID,
        goalID: successor.goalID)
    }
    return TatwoSessionPointer(
      schema: owner == nil ? "TatwoSessionPointerV1" : "TatwoSessionPointerV2",
      contractID: successor.contractID,
      goalID: successor.goalID,
      mode: successor.mode,
      scenario: successor.scenario,
      objective: successor.objective,
      startedAt: metadata.supersededAt,
      ownerBinding: owner,
      generation: metadata.oldPointerGeneration + 1)
  }

  private static func activeDispatchHeadIDs(
    contractID: String,
    goalID: String,
    registry: TatwoDispatchRegistry
  ) throws -> [String] {
    guard let run = try registry.run(forContractID: contractID) else {
      return []
    }
    let scoped = run.records.filter { $0.goalID == nil || $0.goalID == goalID }
    let superseded = Set(scoped.compactMap(\.supersedes))
    return scoped.filter { record in
      guard !superseded.contains(record.id) else { return false }
      if record.status == .queued || record.status == .running {
        return true
      }
      if let remote = record.remoteStatus {
        return [.queued, .delivered, .accepted, .running].contains(remote)
      }
      return false
    }.map(\.id).sorted()
  }

  private func readRevisionPromotionJournal(
    authorizationID: String
  ) throws -> TatwoGoalRevisionPromotionJournalV1? {
    let url = revisionPromotionJournalURL(authorizationID: authorizationID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
      TatwoGoalRevisionPromotionJournalV1.self,
      from: Data(contentsOf: url))
  }

  private func writeRevisionPromotionJournal(
    _ journal: TatwoGoalRevisionPromotionJournalV1
  ) throws {
    let url = revisionPromotionJournalURL(
      authorizationID: journal.authorizationID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(journal).write(to: url, options: [.atomic])
  }

  private func supersessionReceiptURL(id: String) -> URL {
    directoryURL
      .appendingPathComponent("goal-revision-promotion", isDirectory: true)
      .appendingPathComponent("receipts", isDirectory: true)
      .appendingPathComponent("\(TatwoLoopPathComponent.sanitize(id)).json")
  }

  @discardableResult
  private func writeSupersessionReceiptIfNeeded(
    journal: TatwoGoalRevisionPromotionJournalV1
  ) throws -> TatwoGoalSupersessionReceiptV1 {
    let metadata = journal.metadata
    let receipt = TatwoGoalSupersessionReceiptV1(
      id: metadata.supersessionReceiptID,
      promotionAuthorizationID: metadata.promotionAuthorizationID,
      humanGateReceiptID: metadata.humanGateReceiptID,
      predecessorContractID: metadata.predecessorContractID,
      predecessorGoalID: metadata.predecessorGoalID,
      predecessorRevision: metadata.predecessorRevision,
      successorContractID: metadata.successorContractID,
      successorGoalID: metadata.successorGoalID,
      successorRevision: metadata.successorRevision,
      oldPointerRevisionDigest: metadata.oldPointerRevisionDigest,
      oldPointerGeneration: metadata.oldPointerGeneration,
      newPointerGeneration: metadata.oldPointerGeneration + 1,
      completedAt: metadata.supersededAt,
      promotionIssuerDomain: metadata.promotionIssuerDomain,
      oldReceiptsDigest: metadata.oldReceiptsDigest,
      oldActivationEpoch: metadata.oldActivationEpoch,
      bootstrapRecoveryContextDigest:
        metadata.bootstrapRecoveryContextDigest)
    let url = supersessionReceiptURL(id: receipt.id)
    if FileManager.default.fileExists(atPath: url.path) {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let existing = try decoder.decode(
        TatwoGoalSupersessionReceiptV1.self,
        from: Data(contentsOf: url))
      guard existing == receipt else {
        throw TatwoSessionMutationError.revisionPromotionJournalConflict
      }
      return existing
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(receipt).write(to: url, options: [.atomic])
    return receipt
  }

  private func revisionPromotionResult(
    journal: TatwoGoalRevisionPromotionJournalV1,
    goalStore: TatwoGoalRunStore,
    reconciled: Bool
  ) throws -> TatwoGoalRevisionPromotionResultV1 {
    guard let pointerData = try currentDataUnlocked() else {
      throw TatwoSessionMutationError.revisionPromotionJournalConflict
    }
    let receipt = try writeSupersessionReceiptIfNeeded(journal: journal)
    let predecessor = try goalStore.requireIssuedContract(
      journal.metadata.predecessorContractID)
    let successor = try goalStore.requireIssuedContract(
      journal.metadata.successorContractID)
    let pointer = try decoded(pointerData)
    guard predecessor.status == .superseded,
      predecessor.supersession == journal.metadata,
      successor.status == .running,
      successor.supersession == journal.metadata,
      pointer.contractID == successor.contractID,
      pointer.goalID == successor.goalID,
      (pointer.generation ?? 1)
        == journal.metadata.oldPointerGeneration + 1,
      receipt.promotionIssuerDomain
        == journal.metadata.promotionIssuerDomain,
      receipt.oldReceiptsDigest == journal.metadata.oldReceiptsDigest,
      receipt.oldActivationEpoch == journal.metadata.oldActivationEpoch,
      receipt.bootstrapRecoveryContextDigest
        == journal.metadata.bootstrapRecoveryContextDigest
    else {
      throw TatwoSessionMutationError.revisionPromotionJournalConflict
    }
    if journal.metadata.promotionIssuerDomain
      == TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain
    {
      guard TatwoGoalRevisionPromotionAuthorizationV1.receiptsDigest(
        predecessor.receipts) == journal.metadata.oldReceiptsDigest,
        journal.metadata.oldActivationEpoch
          == journal.metadata.predecessorRevision,
        journal.metadata.bootstrapRecoveryContextDigest
          .map(
            TatwoGoalRevisionBootstrapRecoveryEvidenceV1.isSHA256Digest)
          == true
      else {
        throw TatwoSessionMutationError.revisionPromotionJournalConflict
      }
    }
    return TatwoGoalRevisionPromotionResultV1(
      authorizationID: journal.authorizationID,
      predecessor: predecessor,
      successor: successor,
      pointer: pointer,
      supersessionReceipt: receipt,
      reconciled: reconciled)
  }

  private static func normalized(_ value: String?) -> String? {
    guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !normalized.isEmpty
    else { return nil }
    return normalized
  }

  private static func isPristinePlannedForSupersession(
    _ record: TatwoStoredGoalRun
  ) -> Bool {
    guard record.status == .planned,
      record.statusReason == nil,
      record.latestDispatchCycleEpoch == nil,
      record.latestDispatchCycleSealID == nil
    else {
      return false
    }
    return record.receipts.allSatisfy {
      $0.receiptID == "goal-tracker" && $0.kind == "goal_tracker"
    }
  }

  private static func isSupersededTerminalForCleanup(
    _ record: TatwoStoredGoalRun
  ) -> Bool {
    guard record.status == .cancelled,
      record.statusReason == "superseded_before_dispatch",
      record.latestDispatchCycleEpoch == nil,
      record.latestDispatchCycleSealID == nil
    else {
      return false
    }
    return record.receipts.allSatisfy {
      $0.receiptID == "goal-tracker" && $0.kind == "goal_tracker"
    }
  }

  /// Dispatch/outbox publication is protected by the same lifecycle lock used
  /// by dispatch begin. A V3 authority transaction persists a planning manifest
  /// before pointer publication; that manifest is not executable work by itself.
  /// Older pointers and any malformed/mismatched registry still fail closed as
  /// published work.
  private static func hasExecutablePublicationEvidenceForSupersession(
    pointer: TatwoSessionPointer,
    goalRecord: TatwoStoredGoalRun,
    goalStore: TatwoGoalRunStore
  ) throws -> Bool {
    if TatwoRemoteOutboxEvidence.hasPublishedEvidence(
      stateDirectoryURL: goalStore.directoryURL,
      contractID: pointer.contractID)
    {
      return true
    }
    let registry = TatwoDispatchRegistry(
      directoryURL: goalStore.directoryURL)
    guard let run = try registry.run(forContractID: pointer.contractID) else {
      return false
    }
    guard pointer.schema == "TatwoSessionAuthorityPointerV3",
      goalRecord.contractID == pointer.contractID,
      goalRecord.goalID == pointer.goalID,
      run.executionManifestSHA256 == pointer.executionManifestSHA256,
      run.executionManifest?.contractID == pointer.contractID,
      run.executionManifest?.goalID == pointer.goalID,
      !registry.hasExecutablePublicationEvidence(
        forContractID: pointer.contractID,
        issuedBindingIDs: goalRecord.issuedIdentityBindings?.map(\.id))
    else {
      return true
    }
    return false
  }

  /// Goal-revision promotion may preserve a canonical successor planning
  /// manifest, but still rejects any executable registry or remote-outbox
  /// publication. Other supersession paths intentionally keep the stricter
  /// "any registry exists" policy above.
  private static func hasSuccessorExecutablePublicationEvidence(
    successor: TatwoStoredGoalRun,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) -> Bool {
    if dispatchRegistry.hasExecutablePublicationEvidence(
      forContractID: successor.contractID,
      issuedBindingIDs: successor.issuedIdentityBindings?.map(\.id))
    {
      return true
    }
    return TatwoRemoteOutboxEvidence.hasPublishedEvidence(
      stateDirectoryURL: goalStore.directoryURL,
      contractID: successor.contractID)
  }

  private static func normalizedWorkspacePath(_ value: String?) -> String? {
    guard let normalized = normalized(value) else { return nil }
    return URL(fileURLWithPath: normalized, isDirectory: true)
      .standardizedFileURL
      .path
  }

  private static func isSHA256(_ value: String?) -> Bool {
    guard let value,
      value.hasPrefix("sha256:"),
      value.count == "sha256:".count + 64
    else {
      return false
    }
    return value.dropFirst("sha256:".count).allSatisfy {
      $0.isHexDigit
    }
  }

  private static func isAttachable(_ record: TatwoStoredGoalRun) -> Bool {
    if record.isAttachableAwaitingJudgment {
      return true
    }
    switch record.status {
    case .planned, .dispatching, .running, .humanGate, .awaitingNextCycle, .blocked:
      return true
    case .succeeded, .failed, .cancelled, .passed, .rollbackRequired, .superseded:
      return false
    }
  }

  func authorityPointerData() throws -> Data? {
    try TatwoFileLock.withExclusiveLock(for: fileURL) {
      try currentDataUnlocked()
    }
  }

  /// Authority pointer V3 is the transaction linearization point. Publication is
  /// create-only; an exact already-published value is accepted only for
  /// deterministic crash roll-forward.
  func publishAuthorityPointer(
    _ pointer: TatwoSessionPointer
  ) throws -> Data {
    let expected = try encoded(pointer)
    return try TatwoFileLock.withExclusiveLock(for: fileURL) {
      if let current = try currentDataUnlocked() {
        guard current == expected else {
          throw TatwoSessionMutationError.currentSessionChanged
        }
        return current
      }
      try TatwoAuthorityDurableArtifact.createOnly(
        expected,
        at: fileURL)
      guard let readback = try currentDataUnlocked(),
        readback == expected
      else {
        throw TatwoSessionMutationError.currentSessionChanged
      }
      return readback
    }
  }

  /// Fresh-transaction pointer handoff. Unlike normal create-only publication,
  /// this performs an exact-byte CAS against the foreign pointer admitted by
  /// preflight, then replaces it with a same-directory temp+rename operation.
  func replaceAuthorityPointerForHandoff(
    _ pointer: TatwoSessionPointer,
    replacing original: Data
  ) throws -> Data {
    let expected = try encoded(pointer)
    return try TatwoFileLock.withExclusiveLock(for: fileURL) {
      guard let current = try currentDataUnlocked(),
        current == original
      else {
        throw TatwoSessionMutationError.currentSessionChanged
      }
      let temporaryURL = directoryURL.appendingPathComponent(
        ".current-session.handoff.\(UUID().uuidString).tmp",
        isDirectory: false)
      defer { try? FileManager.default.removeItem(at: temporaryURL) }
      try expected.write(to: temporaryURL, options: [.atomic])
      guard rename(temporaryURL.path, fileURL.path) == 0 else {
        throw TatwoSessionMutationError.currentSessionChanged
      }
      guard let readback = try currentDataUnlocked(),
        readback == expected
      else {
        throw TatwoSessionMutationError.currentSessionChanged
      }
      return readback
    }
  }

  func resolveAuthorityCurrent(
    pointer: TatwoSessionPointer,
    ownerVerification: TatwoSessionOwnerVerificationV1,
    scenarioBook: TatwoScenarioConfigBookV1,
    goalStore: TatwoGoalRunStore
  ) throws -> TatwoSessionAttachmentV1 {
    try resolveCurrent(
      pointer: pointer,
      ownerVerification: ownerVerification,
      expectedContractID: pointer.contractID,
      expectedGoalID: pointer.goalID,
      expectedMode: pointer.mode,
      expectedScenario: pointer.scenario,
      expectedObjective: pointer.objective,
      scenarioBook: scenarioBook,
      goalStore: goalStore,
      requireOwnedOwnerVerification: true,
      requireAttachableGoal: true)
  }

  private func verifyOwner(
    pointer: TatwoSessionPointer,
    ownerVerification: TatwoSessionOwnerVerificationV1?,
    requireOwnedOwnerVerification: Bool
  ) throws {
    switch pointer.schema {
    case "TatwoSessionPointerV1":
      guard ownerVerification == nil else {
        throw TatwoSessionAttachmentError.ownerExpectationMismatch(
          "verificationSchema")
      }
    case "TatwoSessionPointerV2":
      guard let owner = pointer.ownerBinding else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding("missing")
      }
      guard let ownerVerification else {
        if requireOwnedOwnerVerification {
          throw TatwoSessionAttachmentError.ownerExpectationMismatch("missing")
        }
        return
      }
      guard case .legacyV2(let expectation) = ownerVerification else {
        throw TatwoSessionAttachmentError.ownerExpectationMismatch(
          "verificationSchema")
      }
      try verifyOwnerIdentity(
        owner: owner,
        provider: expectation.provider,
        externalProviderID: expectation.externalProviderSessionID,
        workspacePath: expectation.workspacePath,
        ownerKind: nil)
    case "TatwoSessionAuthorityPointerV3":
      guard let owner = pointer.ownerBinding else {
        throw TatwoSessionAttachmentError.invalidOwnerBinding("missing")
      }
      guard let ownerVerification else {
        if requireOwnedOwnerVerification {
          throw TatwoSessionAttachmentError.ownerExpectationMismatch("missing")
        }
        return
      }
      guard case .canonicalV3(let canonicalOwner) = ownerVerification else {
        throw TatwoSessionAttachmentError.ownerExpectationMismatch(
          "verificationSchema")
      }
      try verifyOwnerIdentity(
        owner: owner,
        provider: canonicalOwner.provider,
        externalProviderID: canonicalOwner.externalProviderID,
        workspacePath: canonicalOwner.workspacePath,
        ownerKind: canonicalOwner.ownerKind)
    default:
      throw TatwoSessionAttachmentError.unsupportedPointerSchema(pointer.schema)
    }
  }

  private func verifyOwnerIdentity(
    owner: TatwoSessionOwnerBindingV1,
    provider: String,
    externalProviderID: String,
    workspacePath: String,
    ownerKind: TatwoSessionOwnerKindV1?
  ) throws {
    guard Self.normalized(owner.provider) == Self.normalized(provider) else {
      throw TatwoSessionAttachmentError.ownerExpectationMismatch("provider")
    }
    guard Self.normalized(owner.sessionID)
      == Self.normalized(externalProviderID)
    else {
      throw TatwoSessionAttachmentError.ownerExpectationMismatch("sessionID")
    }
    guard Self.normalizedWorkspacePath(owner.workspacePath)
      == Self.normalizedWorkspacePath(workspacePath)
    else {
      throw TatwoSessionAttachmentError.ownerExpectationMismatch("workspacePath")
    }
    if let ownerKind {
      guard owner.ownerKind == ownerKind else {
        throw TatwoSessionAttachmentError.ownerExpectationMismatch("ownerKind")
      }
    }
  }

  private func encoded(_ pointer: TatwoSessionPointer) throws -> Data {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(pointer)
  }

  private func decoded(_ data: Data) throws -> TatwoSessionPointer {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TatwoSessionPointer.self, from: data)
  }

  private func currentDataUnlocked() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    return try Data(contentsOf: fileURL)
  }
}
