import CryptoKit
import Foundation

public enum ChangedSurface: String, Codable, Sendable, CaseIterable, Hashable {
  case ui
  case ux
  case logic
  case security
  case buildSystem = "build_system"
  case documentation
  case installer
  case modelRouting = "model_routing"
}

public enum RoleKind: String, Codable, Sendable, CaseIterable {
  case builder
  case reviewer
  case verifier
  case judge
}

public enum EvidenceKind: String, Codable, Sendable, CaseIterable {
  case unitTest = "unit_test"
  case build
  case smoke
  case screenshot
  case screenRecording = "screen_recording"
  case visualDiff = "visual_diff"
  case cliOutput = "cli_output"
  case redactionScan = "redaction_scan"
  case sandboxRun = "sandbox_run"
  case cleanupInventory = "cleanup_inventory"
}

public enum Verdict: String, Codable, Sendable, CaseIterable, Equatable {
  case passed
  case failed
  case blocked
  case needsHuman = "needs_human"
}

public enum FindingSeverity: String, Codable, Sendable, CaseIterable, Comparable {
  case info
  case minor
  case major
  case blocking

  public static func < (lhs: FindingSeverity, rhs: FindingSeverity) -> Bool {
    let order: [FindingSeverity] = [.info, .minor, .major, .blocking]
    return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
  }
}

public struct AcceptanceCriterion: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let description: String

  public init(id: String, description: String) {
    self.id = id
    self.description = description
  }
}

public struct RoleReceipt: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let actorID: String
  public let role: RoleKind
  public let roleSessionID: String
  public let model: String
  public let summary: String
  public let evidenceIDs: [String]
  public let attemptedFinalVerdict: Verdict?

  public init(
    id: String = UUID().uuidString,
    actorID: String,
    role: RoleKind,
    roleSessionID: String,
    model: String,
    summary: String,
    evidenceIDs: [String] = [],
    attemptedFinalVerdict: Verdict? = nil
  ) {
    self.id = id
    self.actorID = actorID
    self.role = role
    self.roleSessionID = roleSessionID
    self.model = model
    self.summary = summary
    self.evidenceIDs = evidenceIDs
    self.attemptedFinalVerdict = attemptedFinalVerdict
  }
}

public struct BuildEvidence: Codable, Sendable, Equatable {
  public let status: Verdict
  public let command: String
  public let appLaunched: Bool
  public let processAlive: Bool
  public let evidenceID: String

  public init(
    status: Verdict, command: String, appLaunched: Bool = false, processAlive: Bool = false,
    evidenceID: String
  ) {
    self.status = status
    self.command = command
    self.appLaunched = appLaunched
    self.processAlive = processAlive
    self.evidenceID = evidenceID
  }
}

public struct VisualEvidenceArtifact: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let runID: String
  public let kind: EvidenceKind
  public let path: String
  public let sha256: String
  public let capturedAt: Date
  public let surfaceName: String
  public let viewport: String

  public init(
    id: String,
    runID: String,
    kind: EvidenceKind,
    path: String,
    sha256: String,
    capturedAt: Date,
    surfaceName: String,
    viewport: String
  ) {
    self.id = id
    self.runID = runID
    self.kind = kind
    self.path = path
    self.sha256 = sha256
    self.capturedAt = capturedAt
    self.surfaceName = surfaceName
    self.viewport = viewport
  }
}

public struct VisualChecklistItem: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let description: String
  public let expected: String
  public let actual: String
  public let evidenceArtifactIDs: [String]
  public let verdict: Verdict

  public init(
    id: String, description: String, expected: String, actual: String,
    evidenceArtifactIDs: [String], verdict: Verdict
  ) {
    self.id = id
    self.description = description
    self.expected = expected
    self.actual = actual
    self.evidenceArtifactIDs = evidenceArtifactIDs
    self.verdict = verdict
  }
}

public enum CodexAppParityDecision: String, Codable, Sendable, CaseIterable, Equatable {
  case consistent
  case drift
  case blocked
}

public struct TatwoAllowedTatwoDeltaV1: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let description: String
  public let userRequestReference: String
  public let requiredForTatwoFeature: Bool

  public init(
    id: String,
    description: String,
    userRequestReference: String,
    requiredForTatwoFeature: Bool = true
  ) {
    self.id = id
    self.description = description
    self.userRequestReference = userRequestReference
    self.requiredForTatwoFeature = requiredForTatwoFeature
  }
}

public struct TatwoCodexAppParityReceiptV1: Codable, Sendable, Equatable {
  public let schema: String
  public let runID: String
  public let surface: String
  public let viewport: String
  public let timestamp: Date
  public let codexAppBaselineEvidenceID: String
  public let tatwoCandidateEvidenceID: String
  public let allowedTatwoDeltas: [TatwoAllowedTatwoDeltaV1]
  public let codexHostDecision: CodexAppParityDecision
  public let codexVerifierActorID: String
  public let codexVerifierSessionID: String
  public let sonnet5Decision: CodexAppParityDecision
  public let sonnet5ReviewerActorID: String
  public let sonnet5ReviewerSessionID: String
  public let sonnet5ModelID: String
  public let blockingFindings: [String]

  public init(
    schema: String = "TatwoCodexAppParityReceiptV1",
    runID: String,
    surface: String,
    viewport: String,
    timestamp: Date = Date(),
    codexAppBaselineEvidenceID: String,
    tatwoCandidateEvidenceID: String,
    allowedTatwoDeltas: [TatwoAllowedTatwoDeltaV1] = [],
    codexHostDecision: CodexAppParityDecision,
    codexVerifierActorID: String,
    codexVerifierSessionID: String,
    sonnet5Decision: CodexAppParityDecision,
    sonnet5ReviewerActorID: String,
    sonnet5ReviewerSessionID: String,
    sonnet5ModelID: String = "sonnet-5",
    blockingFindings: [String] = []
  ) {
    self.schema = schema
    self.runID = runID
    self.surface = surface
    self.viewport = viewport
    self.timestamp = timestamp
    self.codexAppBaselineEvidenceID = codexAppBaselineEvidenceID
    self.tatwoCandidateEvidenceID = tatwoCandidateEvidenceID
    self.allowedTatwoDeltas = allowedTatwoDeltas
    self.codexHostDecision = codexHostDecision
    self.codexVerifierActorID = codexVerifierActorID
    self.codexVerifierSessionID = codexVerifierSessionID
    self.sonnet5Decision = sonnet5Decision
    self.sonnet5ReviewerActorID = sonnet5ReviewerActorID
    self.sonnet5ReviewerSessionID = sonnet5ReviewerSessionID
    self.sonnet5ModelID = sonnet5ModelID
    self.blockingFindings = blockingFindings
  }
}

public struct ValidationFinding: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let severity: FindingSeverity
  public let surface: ChangedSurface
  public let title: String
  public let evidenceIDs: [String]

  public init(
    id: String, severity: FindingSeverity, surface: ChangedSurface, title: String,
    evidenceIDs: [String]
  ) {
    self.id = id
    self.severity = severity
    self.surface = surface
    self.title = title
    self.evidenceIDs = evidenceIDs
  }
}

public struct JudgeDecision: Codable, Sendable, Equatable {
  public let finalVerdict: Verdict
  public let resolvedFindingIDs: [String]
  public let acceptedRiskIDs: [String]
  public let reason: String

  public init(
    finalVerdict: Verdict, resolvedFindingIDs: [String], acceptedRiskIDs: [String], reason: String
  ) {
    self.finalVerdict = finalVerdict
    self.resolvedFindingIDs = resolvedFindingIDs
    self.acceptedRiskIDs = acceptedRiskIDs
    self.reason = reason
  }
}

public struct ValidationReceipt: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let runID: String
  public let objective: String
  public let changedSurface: Set<ChangedSurface>
  public let acceptanceCriteria: [AcceptanceCriterion]
  public let builder: RoleReceipt?
  public let reviewer: RoleReceipt?
  public let verifier: RoleReceipt?
  public let judge: RoleReceipt?
  public let build: BuildEvidence?
  public let visualEvidence: [VisualEvidenceArtifact]
  public let visualChecklist: [VisualChecklistItem]
  public let codexAppParity: TatwoCodexAppParityReceiptV1?
  public let findings: [ValidationFinding]
  public let judgeDecision: JudgeDecision?
  public let postValidationCleanupInventory: PostValidationCleanupInventoryV1?

  public init(
    schemaVersion: Int = 1,
    runID: String,
    objective: String,
    changedSurface: Set<ChangedSurface>,
    acceptanceCriteria: [AcceptanceCriterion],
    builder: RoleReceipt?,
    reviewer: RoleReceipt?,
    verifier: RoleReceipt?,
    judge: RoleReceipt?,
    build: BuildEvidence?,
    visualEvidence: [VisualEvidenceArtifact] = [],
    visualChecklist: [VisualChecklistItem] = [],
    codexAppParity: TatwoCodexAppParityReceiptV1? = nil,
    findings: [ValidationFinding] = [],
    judgeDecision: JudgeDecision?,
    postValidationCleanupInventory: PostValidationCleanupInventoryV1? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.runID = runID
    self.objective = objective
    self.changedSurface = changedSurface
    self.acceptanceCriteria = acceptanceCriteria
    self.builder = builder
    self.reviewer = reviewer
    self.verifier = verifier
    self.judge = judge
    self.build = build
    self.visualEvidence = visualEvidence
    self.visualChecklist = visualChecklist
    self.codexAppParity = codexAppParity
    self.findings = findings
    self.judgeDecision = judgeDecision
    self.postValidationCleanupInventory = postValidationCleanupInventory
  }
}

public enum GateStatus: String, Codable, Sendable, Equatable {
  case passed
  case failed
  case needsHuman = "needs_human"
}

public struct GateResult: Codable, Sendable, Equatable {
  public let status: GateStatus
  public let reasons: [String]

  public init(status: GateStatus, reasons: [String]) {
    self.status = status
    self.reasons = reasons
  }

  public var passed: Bool { status == .passed }
}

public protocol EvidenceFileSystem: Sendable {
  func fileExists(atPath path: String) -> Bool
  func data(atPath path: String) throws -> Data
}

public struct LocalEvidenceFileSystem: EvidenceFileSystem {
  public init() {}

  public func fileExists(atPath path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  public func data(atPath path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
  }
}

public struct InMemoryEvidenceFileSystem: EvidenceFileSystem {
  public let files: [String: Data]

  public init(files: [String: Data]) {
    self.files = files
  }

  public func fileExists(atPath path: String) -> Bool {
    files[path] != nil
  }

  public func data(atPath path: String) throws -> Data {
    if let data = files[path] { return data }
    throw CocoaError(.fileNoSuchFile)
  }
}

public enum ValidationGate {
  public static let supportedSchemaVersion = 1

  public static func evaluate(
    _ receipt: ValidationReceipt, fileSystem: EvidenceFileSystem = LocalEvidenceFileSystem()
  ) -> GateResult {
    var reasons: [String] = []

    if receipt.schemaVersion != supportedSchemaVersion {
      reasons.append("unsupported_schema_version")
    }
    if receipt.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      reasons.append("missing_run_id")
    }
    if receipt.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      reasons.append("missing_objective")
    }
    if receipt.changedSurface.isEmpty {
      reasons.append("missing_changed_surface")
    }
    if receipt.acceptanceCriteria.isEmpty
      || receipt.acceptanceCriteria.contains(where: {
        $0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    {
      reasons.append("missing_acceptance_criteria")
    }

    let rolePairs: [(RoleKind, RoleReceipt?)] = [
      (.builder, receipt.builder),
      (.reviewer, receipt.reviewer),
      (.verifier, receipt.verifier),
      (.judge, receipt.judge),
    ]
    for (expected, role) in rolePairs {
      guard let role else {
        reasons.append("missing_\(expected.rawValue)")
        continue
      }
      if role.role != expected {
        reasons.append("wrong_role_kind_\(expected.rawValue)")
      }
      if role.actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reasons.append("missing_actor_\(expected.rawValue)")
      }
      if role.roleSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reasons.append("missing_role_session_\(expected.rawValue)")
      }
    }

    let presentRoles = [receipt.builder, receipt.reviewer, receipt.verifier, receipt.judge]
      .compactMap { $0 }
    let actorIDs = presentRoles.map(\.actorID)
    if Set(actorIDs).count != actorIDs.count {
      reasons.append("roles_must_be_distinct_actors")
    }
    let sessionIDs = presentRoles.map(\.roleSessionID)
    if Set(sessionIDs).count != sessionIDs.count {
      reasons.append("roles_must_use_distinct_sessions")
    }
    if receipt.reviewer?.attemptedFinalVerdict != nil {
      reasons.append("reviewer_cannot_mark_final_pass")
    }
    if receipt.verifier?.attemptedFinalVerdict != nil {
      reasons.append("verifier_cannot_mark_final_pass")
    }

    let isUI = receipt.changedSurface.contains(.ui) || receipt.changedSurface.contains(.ux)
    if isUI {
      validateUIReceipt(receipt, fileSystem: fileSystem, reasons: &reasons)
    }

    validateBlockingFindings(receipt, reasons: &reasons)
    validateFinalPass(receipt, reasons: &reasons)
    validateCleanupInventoryAfterPass(receipt, fileSystem: fileSystem, reasons: &reasons)

    return GateResult(status: reasons.isEmpty ? .passed : .failed, reasons: reasons)
  }

  private static func validateUIReceipt(
    _ receipt: ValidationReceipt, fileSystem: EvidenceFileSystem, reasons: inout [String]
  ) {
    if receipt.build?.status != .passed {
      reasons.append("ui_change_requires_build_pass")
    }

    let visualKinds: Set<EvidenceKind> = [.screenshot, .screenRecording, .visualDiff]
    let visualArtifacts = receipt.visualEvidence.filter { visualKinds.contains($0.kind) }
    if visualArtifacts.isEmpty {
      reasons.append("missing_visual_evidence")
    }

    if receipt.visualChecklist.isEmpty {
      reasons.append("missing_visual_checklist")
    }

    let visualIDs = Set(visualArtifacts.map(\.id))
    for item in receipt.visualChecklist {
      if item.evidenceArtifactIDs.isEmpty {
        reasons.append("visual_checklist_item_missing_evidence:\(item.id)")
      }
      for evidenceID in item.evidenceArtifactIDs where !visualIDs.contains(evidenceID) {
        reasons.append("visual_checklist_requires_visual_evidence:\(item.id):\(evidenceID)")
      }
      if item.verdict != .passed {
        reasons.append("visual_checklist_item_not_passed:\(item.id)")
      }
    }

    for artifact in receipt.visualEvidence {
      let visualPrefix = visualKinds.contains(artifact.kind) ? "visual_evidence" : "evidence"
      if artifact.runID != receipt.runID {
        reasons.append("\(visualKinds.contains(artifact.kind) ? "stale_visual_evidence" : "stale_evidence"):\(artifact.id)")
      }
      if artifact.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || artifact.sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || artifact.surfaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || artifact.viewport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        reasons.append("\(visualPrefix)_missing_metadata:\(artifact.id)")
      }
      if !artifact.path.contains(".tatwo-ultrawork/evidence") {
        reasons.append("\(visualPrefix)_outside_allowed_root:\(artifact.id)")
      }
      guard fileSystem.fileExists(atPath: artifact.path) else {
        reasons.append("\(visualPrefix)_file_missing:\(artifact.id)")
        continue
      }
      do {
        let actual = sha256Hex(try fileSystem.data(atPath: artifact.path))
        if actual.lowercased() != artifact.sha256.lowercased() {
          reasons.append("\(visualPrefix)_hash_mismatch:\(artifact.id)")
        }
      } catch {
        reasons.append("\(visualPrefix)_unreadable:\(artifact.id)")
      }
    }

    if requiresCodexAppParity(receipt) || receipt.codexAppParity != nil {
      validateCodexAppParity(receipt, visualArtifacts: visualArtifacts, reasons: &reasons)
    }
  }

  private static func requiresCodexAppParity(_ receipt: ValidationReceipt) -> Bool {
    let haystack = (
      [receipt.objective]
        + receipt.acceptanceCriteria.map(\.id)
        + receipt.acceptanceCriteria.map(\.description)
        + receipt.visualEvidence.map(\.path)
        + receipt.visualEvidence.map(\.surfaceName)
    ).joined(separator: "\n").lowercased()
    return haystack.contains("codex app")
      || haystack.contains("codex-app")
      || haystack.contains("chatpage")
      || haystack.contains("chat page")
      || haystack.contains("chat ui")
      || haystack.contains("聊天")
  }

  private static func validateCodexAppParity(
    _ receipt: ValidationReceipt,
    visualArtifacts: [VisualEvidenceArtifact],
    reasons: inout [String]
  ) {
    guard let parity = receipt.codexAppParity else {
      reasons.append("missing_codex_app_parity_receipt")
      return
    }

    if parity.schema != "TatwoCodexAppParityReceiptV1" {
      reasons.append("codex_app_parity_unsupported_schema")
    }
    if parity.runID != receipt.runID {
      reasons.append("codex_app_parity_stale_run")
    }
    if parity.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || parity.viewport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      reasons.append("codex_app_parity_missing_surface_or_viewport")
    }

    let artifactsByID = Dictionary(uniqueKeysWithValues: visualArtifacts.map { ($0.id, $0) })
    guard let baseline = artifactsByID[parity.codexAppBaselineEvidenceID] else {
      reasons.append("codex_app_baseline_missing")
      return
    }
    guard let candidate = artifactsByID[parity.tatwoCandidateEvidenceID] else {
      reasons.append("codex_app_candidate_missing")
      return
    }
    if baseline.id == candidate.id {
      reasons.append("codex_app_baseline_and_candidate_must_differ")
    }
    if baseline.runID != receipt.runID || candidate.runID != receipt.runID {
      reasons.append("codex_app_parity_requires_same_run_evidence")
    }
    if baseline.viewport != candidate.viewport || baseline.viewport != parity.viewport {
      reasons.append("codex_app_parity_viewport_mismatch")
    }
    let maxSameRunInterval: TimeInterval = 6 * 60 * 60
    if abs(baseline.capturedAt.timeIntervalSince(candidate.capturedAt)) > maxSameRunInterval {
      reasons.append("codex_app_parity_evidence_too_far_apart")
    }
    if abs(parity.timestamp.timeIntervalSince(baseline.capturedAt)) > maxSameRunInterval
      || abs(parity.timestamp.timeIntervalSince(candidate.capturedAt)) > maxSameRunInterval
    {
      reasons.append("codex_app_parity_timestamp_outside_capture_window")
    }

    if parity.codexHostDecision != .consistent {
      reasons.append("codex_app_parity_codex_decision_\(parity.codexHostDecision.rawValue)")
    }
    if parity.sonnet5Decision != .consistent {
      reasons.append("codex_app_parity_sonnet5_decision_\(parity.sonnet5Decision.rawValue)")
    }
    if !parity.blockingFindings.isEmpty {
      reasons.append("codex_app_parity_blocking_findings_unresolved")
    }

    if parity.codexVerifierActorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || parity.codexVerifierSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      reasons.append("codex_app_parity_missing_codex_verifier_identity")
    }
    if parity.sonnet5ReviewerActorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || parity.sonnet5ReviewerSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      reasons.append("codex_app_parity_missing_sonnet5_reviewer_identity")
    }
    let sonnetModel = parity.sonnet5ModelID.lowercased()
    if !(sonnetModel.contains("sonnet") && sonnetModel.contains("5")) {
      reasons.append("codex_app_parity_requires_sonnet5_model")
    }
    if parity.codexVerifierActorID == parity.sonnet5ReviewerActorID
      || parity.codexVerifierSessionID == parity.sonnet5ReviewerSessionID
    {
      reasons.append("codex_app_parity_requires_distinct_codex_and_sonnet5_reviewers")
    }
    if let builder = receipt.builder {
      if builder.actorID == parity.codexVerifierActorID
        || builder.roleSessionID == parity.codexVerifierSessionID
      {
        reasons.append("codex_app_parity_codex_verifier_cannot_be_builder")
      }
      if builder.actorID == parity.sonnet5ReviewerActorID
        || builder.roleSessionID == parity.sonnet5ReviewerSessionID
      {
        reasons.append("codex_app_parity_sonnet5_reviewer_cannot_be_builder")
      }
    }

    for delta in parity.allowedTatwoDeltas {
      if delta.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reasons.append("codex_app_delta_missing_description:\(delta.id)")
      }
      if delta.userRequestReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reasons.append("codex_app_delta_missing_user_reference:\(delta.id)")
      }
      if !delta.requiredForTatwoFeature {
        reasons.append("codex_app_delta_not_required_for_feature:\(delta.id)")
      }
    }
  }

  private static func validateBlockingFindings(
    _ receipt: ValidationReceipt, reasons: inout [String]
  ) {
    let blocking = receipt.findings.filter { $0.severity == .blocking }
    guard !blocking.isEmpty else { return }
    guard let decision = receipt.judgeDecision else {
      reasons.append("blocking_findings_require_judge_decision")
      return
    }
    let addressed = Set(decision.resolvedFindingIDs + decision.acceptedRiskIDs)
    for finding in blocking where !addressed.contains(finding.id) {
      reasons.append("blocking_finding_unaddressed:\(finding.id)")
    }
  }

  private static func validateFinalPass(_ receipt: ValidationReceipt, reasons: inout [String]) {
    guard let decision = receipt.judgeDecision else {
      reasons.append("missing_judge_decision")
      return
    }

    if decision.finalVerdict != .passed {
      reasons.append("judge_final_verdict_not_passed")
    }
    if receipt.judge?.evidenceIDs.isEmpty ?? true {
      reasons.append("judge_requires_evidence")
    }
    if receipt.verifier?.evidenceIDs.isEmpty ?? true {
      reasons.append("judge_cannot_pass_without_verifier_evidence")
    }
  }

  private static func validateCleanupInventoryAfterPass(
    _ receipt: ValidationReceipt, fileSystem: EvidenceFileSystem, reasons: inout [String]
  ) {
    guard receipt.judgeDecision?.finalVerdict == .passed else { return }
    guard let inventory = receipt.postValidationCleanupInventory else {
      reasons.append("missing_cleanup_inventory")
      return
    }
    let result = PostValidationCleanupInventoryGate.evaluate(inventory, fileSystem: fileSystem)
    for reason in result.reasons {
      reasons.append(reason)
    }
  }

  public static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct SafeMemoryReceipt: Codable, Sendable, Equatable {
  public let id: String
  public let category: Category
  public let summary: String
  public let tags: [String]
  public let createdAt: Date

  public enum Category: String, Codable, Sendable, CaseIterable {
    case modePreference = "mode_preference"
    case scenarioWeight = "scenario_weight"
    case compatibilityScore = "compatibility_score"
    case successReceipt = "success_receipt"
    case failureMode = "failure_mode"
  }

  public init(
    id: String, category: Category, summary: String, tags: [String] = [], createdAt: Date = Date()
  ) {
    self.id = id
    self.category = category
    self.summary = summary
    self.tags = tags
    self.createdAt = createdAt
  }
}

public enum SafeMemoryGate {
  private static let deniedPatterns: [String] = [
    #"sk-[A-Za-z0-9_-]{10,}"#,
    #"(?i)(api[_-]?key|access[_-]?token|refresh[_-]?token|cookie|authorization:)"#,
    #"/Users/[^\s]+"#,
    #"/Volumes/[^\s]+"#,
    #"(?i)raw log|full chat|complete transcript|private thread"#,
  ]

  public static func evaluate(_ receipt: SafeMemoryReceipt) -> GateResult {
    let haystack = ([receipt.summary] + receipt.tags).joined(separator: "\n")
    var reasons: [String] = []
    for pattern in deniedPatterns {
      if haystack.range(of: pattern, options: .regularExpression) != nil {
        reasons.append("unsafe_memory_content")
        break
      }
    }
    if receipt.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      reasons.append("empty_memory_summary")
    }
    return GateResult(status: reasons.isEmpty ? .passed : .failed, reasons: reasons)
  }
}
