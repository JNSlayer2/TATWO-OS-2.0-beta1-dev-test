import XCTest

@testable import TatwoUltraworkCore

final class ValidationGateTests: XCTestCase {
  func testBuildPassAloneCannotPassUIChange() throws {
    let receipt = Self.receipt(visualEvidence: [], visualChecklist: [])
    let result = ValidationGate.evaluate(
      receipt, fileSystem: InMemoryEvidenceFileSystem(files: [:]))
    XCTAssertEqual(result.status, .failed)
    XCTAssertTrue(result.reasons.contains("missing_visual_evidence"))
    XCTAssertTrue(result.reasons.contains("missing_visual_checklist"))
  }

  func testProcessAliveDoesNotEqualUIPass() throws {
    let receipt = Self.receipt(
      build: BuildEvidence(
        status: .passed, command: "open app", appLaunched: true, processAlive: true,
        evidenceID: "build"), visualEvidence: [], visualChecklist: [])
    let result = ValidationGate.evaluate(
      receipt, fileSystem: InMemoryEvidenceFileSystem(files: [:]))
    XCTAssertEqual(result.status, .failed)
    XCTAssertTrue(result.reasons.contains("missing_visual_evidence"))
  }

  func testUIChangeRequiresScreenshotArtifactWithMatchingHash() throws {
    let data = Data("fake png bytes".utf8)
    let path = "/repo/.tatwo-ultrawork/evidence/run-1/panel.png"
    let hash = ValidationGate.sha256Hex(data)
    let artifact = VisualEvidenceArtifact(
      id: "shot-1", runID: "run-1", kind: .screenshot, path: path, sha256: hash, capturedAt: Date(),
      surfaceName: "panel", viewport: "800x600")
    let item = VisualChecklistItem(
      id: "panel-readable", description: "panel readable", expected: "readable glass cards",
      actual: "readable glass cards", evidenceArtifactIDs: ["shot-1"], verdict: .passed)
    let receipt = Self.receipt(visualEvidence: [artifact], visualChecklist: [item])
    let result = ValidationGate.evaluate(
      receipt, fileSystem: Self.fileSystem([path: data]))
    XCTAssertEqual(result.status, .passed, result.reasons.joined(separator: ","))
  }

  func testChatCodexAppStyleRequiresParityReceipt() throws {
    let (artifacts, checklist, files) = Self.codexParityEvidence()
    let receipt = Self.receipt(
      objective: "Chat UI must match current Codex App",
      acceptanceCriteria: [
        AcceptanceCriterion(id: "codex-parity", description: "Codex App current baseline parity")
      ],
      visualEvidence: artifacts,
      visualChecklist: checklist)

    let result = ValidationGate.evaluate(receipt, fileSystem: Self.fileSystem(files))

    XCTAssertEqual(result.status, .failed)
    XCTAssertTrue(result.reasons.contains("missing_codex_app_parity_receipt"))
  }

  func testChatCodexAppParityPassRequiresCodexAndSonnet5Consistency() throws {
    let (artifacts, checklist, files) = Self.codexParityEvidence()
    let parity = TatwoCodexAppParityReceiptV1(
      runID: "run-1",
      surface: "ChatPage",
      viewport: "1440x960",
      codexAppBaselineEvidenceID: "codex-baseline",
      tatwoCandidateEvidenceID: "tatwo-candidate",
      allowedTatwoDeltas: [
        TatwoAllowedTatwoDeltaV1(
          id: "permission-layer",
          description: "Tatwo permission/tools/receipts drawer requested by user",
          userRequestReference: "2026-07-06 user requirement 4")
      ],
      codexHostDecision: .consistent,
      codexVerifierActorID: "verifier",
      codexVerifierSessionID: "verifier-session",
      sonnet5Decision: .consistent,
      sonnet5ReviewerActorID: "reviewer",
      sonnet5ReviewerSessionID: "reviewer-session",
      sonnet5ModelID: "sonnet-5")
    let receipt = Self.receipt(
      objective: "Chat UI must match current Codex App",
      acceptanceCriteria: [
        AcceptanceCriterion(id: "codex-parity", description: "Codex App current baseline parity")
      ],
      visualEvidence: artifacts,
      visualChecklist: checklist,
      codexAppParity: parity)

    let result = ValidationGate.evaluate(receipt, fileSystem: Self.fileSystem(files))

    XCTAssertEqual(result.status, .passed, result.reasons.joined(separator: ","))
  }

  func testCodexAppParityFailsOnSonnetDriftOrUnbackedDelta() throws {
    let (artifacts, checklist, files) = Self.codexParityEvidence()
    let parity = TatwoCodexAppParityReceiptV1(
      runID: "run-1",
      surface: "ChatPage",
      viewport: "1440x960",
      codexAppBaselineEvidenceID: "codex-baseline",
      tatwoCandidateEvidenceID: "tatwo-candidate",
      allowedTatwoDeltas: [
        TatwoAllowedTatwoDeltaV1(
          id: "decorative-panel",
          description: "extra decoration",
          userRequestReference: "")
      ],
      codexHostDecision: .consistent,
      codexVerifierActorID: "verifier",
      codexVerifierSessionID: "verifier-session",
      sonnet5Decision: .drift,
      sonnet5ReviewerActorID: "reviewer",
      sonnet5ReviewerSessionID: "reviewer-session",
      sonnet5ModelID: "sonnet-5")
    let receipt = Self.receipt(
      objective: "Chat UI must match current Codex App",
      acceptanceCriteria: [
        AcceptanceCriterion(id: "codex-parity", description: "Codex App current baseline parity")
      ],
      visualEvidence: artifacts,
      visualChecklist: checklist,
      codexAppParity: parity)

    let result = ValidationGate.evaluate(receipt, fileSystem: Self.fileSystem(files))

    XCTAssertEqual(result.status, .failed)
    XCTAssertTrue(result.reasons.contains("codex_app_parity_sonnet5_decision_drift"))
    XCTAssertTrue(result.reasons.contains("codex_app_delta_missing_user_reference:decorative-panel"))
  }

  func testVisualChecklistItemMustReferenceVisualArtifact() throws {
    let path = "/repo/.tatwo-ultrawork/evidence/run-1/panel.png"
    let data = Data("fake".utf8)
    let visualArtifact = VisualEvidenceArtifact(
      id: "shot-1", runID: "run-1", kind: .screenshot, path: path,
      sha256: ValidationGate.sha256Hex(data), capturedAt: Date(), surfaceName: "panel",
      viewport: "800x600")
    let item = VisualChecklistItem(
      id: "c1", description: "panel check", expected: "ok", actual: "ok",
      evidenceArtifactIDs: ["build"], verdict: .passed)
    let receipt = Self.receipt(visualEvidence: [visualArtifact], visualChecklist: [item])
    let result = ValidationGate.evaluate(
      receipt, fileSystem: InMemoryEvidenceFileSystem(files: [path: data]))
    XCTAssertTrue(result.reasons.contains("visual_checklist_requires_visual_evidence:c1:build"))
  }

  func testVisualEvidenceFileMustExistWhenGateRuns() throws {
    let artifact = VisualEvidenceArtifact(
      id: "shot-1", runID: "run-1", kind: .screenshot,
      path: "/repo/.tatwo-ultrawork/evidence/run-1/panel.png", sha256: "abc", capturedAt: Date(),
      surfaceName: "panel", viewport: "800x600")
    let item = VisualChecklistItem(
      id: "panel-readable", description: "panel readable", expected: "ok", actual: "ok",
      evidenceArtifactIDs: ["shot-1"], verdict: .passed)
    let result = ValidationGate.evaluate(
      Self.receipt(visualEvidence: [artifact], visualChecklist: [item]),
      fileSystem: InMemoryEvidenceFileSystem(files: [:]))
    XCTAssertTrue(result.reasons.contains("visual_evidence_file_missing:shot-1"))
  }

  func testVisualEvidenceHashMustMatchFileContent() throws {
    let path = "/repo/.tatwo-ultrawork/evidence/run-1/panel.png"
    let artifact = VisualEvidenceArtifact(
      id: "shot-1", runID: "run-1", kind: .screenshot, path: path, sha256: "wrong",
      capturedAt: Date(), surfaceName: "panel", viewport: "800x600")
    let item = VisualChecklistItem(
      id: "panel-readable", description: "panel readable", expected: "ok", actual: "ok",
      evidenceArtifactIDs: ["shot-1"], verdict: .passed)
    let result = ValidationGate.evaluate(
      Self.receipt(visualEvidence: [artifact], visualChecklist: [item]),
      fileSystem: InMemoryEvidenceFileSystem(files: [path: Data("actual".utf8)]))
    XCTAssertTrue(result.reasons.contains("visual_evidence_hash_mismatch:shot-1"))
  }

  func testCLIOutputEvidenceHashIsAlsoChecked() throws {
    let shotPath = "/repo/.tatwo-ultrawork/evidence/run-1/panel.png"
    let shotData = Data("png".utf8)
    let logPath = "/repo/.tatwo-ultrawork/evidence/run-1/live-quota.json"
    let visualArtifact = VisualEvidenceArtifact(
      id: "shot-1", runID: "run-1", kind: .screenshot, path: shotPath,
      sha256: ValidationGate.sha256Hex(shotData), capturedAt: Date(), surfaceName: "panel",
      viewport: "800x600")
    let cliArtifact = VisualEvidenceArtifact(
      id: "quota-runtime-json", runID: "run-1", kind: .cliOutput, path: logPath,
      sha256: "wrong", capturedAt: Date(), surfaceName: "live quota runtime probe",
      viewport: "sanitized JSON")
    let item = VisualChecklistItem(
      id: "panel-readable", description: "panel readable", expected: "ok", actual: "ok",
      evidenceArtifactIDs: ["shot-1"], verdict: .passed)
    let result = ValidationGate.evaluate(
      Self.receipt(visualEvidence: [visualArtifact, cliArtifact], visualChecklist: [item]),
      fileSystem: InMemoryEvidenceFileSystem(files: [shotPath: shotData, logPath: Data("actual".utf8)]))
    XCTAssertTrue(result.reasons.contains("evidence_hash_mismatch:quota-runtime-json"))
  }

  func testRolesMustBeDistinctActors() throws {
    let receipt = Self.receipt(
      builder: RoleReceipt(
        actorID: "same", role: .builder, roleSessionID: "b", model: "gpt", summary: "build"),
      reviewer: RoleReceipt(
        actorID: "same", role: .reviewer, roleSessionID: "r", model: "gpt", summary: "review"),
      visualEvidence: [], visualChecklist: [])
    let result = ValidationGate.evaluate(
      receipt, fileSystem: InMemoryEvidenceFileSystem(files: [:]))
    XCTAssertTrue(result.reasons.contains("roles_must_be_distinct_actors"))
  }

  func testJudgeMustAddressAllBlockingFindings() throws {
    let finding = ValidationFinding(
      id: "f1", severity: .blocking, surface: .ui, title: "Unreadable contrast", evidenceIDs: [])
    let receipt = Self.receipt(
      visualEvidence: [], visualChecklist: [], findings: [finding],
      judgeDecision: JudgeDecision(
        finalVerdict: .passed, resolvedFindingIDs: [], acceptedRiskIDs: [], reason: "pass"))
    let result = ValidationGate.evaluate(
      receipt, fileSystem: InMemoryEvidenceFileSystem(files: [:]))
    XCTAssertTrue(result.reasons.contains("blocking_finding_unaddressed:f1"))
  }

  func testNonUIChangeMayPassWithoutScreenshotIfOtherEvidenceExists() throws {
    let receipt = Self.receipt(changedSurface: [.logic], visualEvidence: [], visualChecklist: [])
    let result = ValidationGate.evaluate(
      receipt, fileSystem: Self.fileSystem())
    XCTAssertEqual(result.status, .passed, result.reasons.joined(separator: ","))
  }

  func testPassedValidationRequiresCleanupInventoryMarkdown() throws {
    let path = "/repo/.tatwo-ultrawork/evidence/run-1/panel.png"
    let data = Data("fake png bytes".utf8)
    let artifact = VisualEvidenceArtifact(
      id: "shot-1", runID: "run-1", kind: .screenshot, path: path,
      sha256: ValidationGate.sha256Hex(data), capturedAt: Date(), surfaceName: "panel",
      viewport: "800x600")
    let item = VisualChecklistItem(
      id: "panel-readable", description: "panel readable", expected: "ok", actual: "ok",
      evidenceArtifactIDs: ["shot-1"], verdict: .passed)
    let receipt = Self.receipt(
      visualEvidence: [artifact],
      visualChecklist: [item],
      includeCleanupInventory: false)

    let result = ValidationGate.evaluate(
      receipt, fileSystem: InMemoryEvidenceFileSystem(files: [path: data]))

    XCTAssertEqual(result.status, .failed)
    XCTAssertTrue(result.reasons.contains("missing_cleanup_inventory"))
  }

  func testCleanupInventoryRequiresMarkdownHashAndHumanDeleteApproval() throws {
    let inventory = PostValidationCleanupInventoryV1(
      runID: "run-1",
      validatedGoalID: "goal-1",
      candidateFiles: [
        PostValidationCleanupCandidateV1(
          id: "tmp-1",
          relativePath: ".tatwo-ultrawork/tmp/render-cache",
          origin: "UI smoke test cache",
          removalReason: "驗收後不再需要的中間輸出",
          producedByReceiptID: "visual-evidence",
          safeToRemove: true,
          deletionRisk: "低；已保留 summary 與 final receipt")
      ],
      mustKeep: ["README.md"],
      markdownPath: ".tatwo-ultrawork/待刪垃圾檔案/run-1/README-待刪檔案來源.md",
      markdownSHA256: "wrong",
      trashBundlePath: ".tatwo-ultrawork/待刪垃圾檔案/run-1",
      deletionRequiresHumanApproval: false,
      summary: "驗收後盤點")
    let markdown = PostValidationCleanupInventoryFactory.markdownBody(for: inventory)

    let result = PostValidationCleanupInventoryGate.evaluate(
      inventory,
      fileSystem: InMemoryEvidenceFileSystem(files: [inventory.markdownPath: Data(markdown.utf8)]))

    XCTAssertEqual(result.status, .failed)
    XCTAssertTrue(result.reasons.contains("cleanup_inventory_requires_human_delete_approval"))
    XCTAssertTrue(result.reasons.contains("cleanup_inventory_markdown_hash_mismatch"))
  }

  func testUnsupportedSchemaVersionFailsClosed() throws {
    let receipt = Self.receipt(schemaVersion: 999, visualEvidence: [], visualChecklist: [])
    let result = ValidationGate.evaluate(
      receipt, fileSystem: InMemoryEvidenceFileSystem(files: [:]))
    XCTAssertTrue(result.reasons.contains("unsupported_schema_version"))
  }

  func testSafeMemoryRejectsSecretsAndPrivatePaths() throws {
    let unsafe = SafeMemoryReceipt(
      id: "bad", category: .failureMode,
      summary: "raw log from /Volumes/Private/project with api_key")
    let result = SafeMemoryGate.evaluate(unsafe)
    XCTAssertEqual(result.status, .failed)
    XCTAssertTrue(result.reasons.contains("unsafe_memory_content"))
  }

  private static func receipt(
    schemaVersion: Int = 1,
    objective: String = "Validate UI gate",
    acceptanceCriteria: [AcceptanceCriterion] = [
      AcceptanceCriterion(id: "c1", description: "must satisfy gate")
    ],
    changedSurface: Set<ChangedSurface> = [.ui],
    builder: RoleReceipt? = RoleReceipt(
      actorID: "builder", role: .builder, roleSessionID: "builder-session", model: "gpt-5.5",
      summary: "built", evidenceIDs: ["build"]),
    reviewer: RoleReceipt? = RoleReceipt(
      actorID: "reviewer", role: .reviewer, roleSessionID: "reviewer-session", model: "sonnet-5",
      summary: "reviewed", evidenceIDs: ["review"]),
    verifier: RoleReceipt? = RoleReceipt(
      actorID: "verifier", role: .verifier, roleSessionID: "verifier-session", model: "tests",
      summary: "verified", evidenceIDs: ["build", "shot-1"]),
    judge: RoleReceipt? = RoleReceipt(
      actorID: "judge", role: .judge, roleSessionID: "judge-session", model: "opus-5",
      summary: "judged", evidenceIDs: ["build", "shot-1"]),
    build: BuildEvidence? = BuildEvidence(
      status: .passed, command: "swift build", appLaunched: true, processAlive: true,
      evidenceID: "build"),
    visualEvidence: [VisualEvidenceArtifact],
    visualChecklist: [VisualChecklistItem],
    codexAppParity: TatwoCodexAppParityReceiptV1? = nil,
    findings: [ValidationFinding] = [],
    judgeDecision: JudgeDecision? = JudgeDecision(
      finalVerdict: .passed, resolvedFindingIDs: [], acceptedRiskIDs: [],
      reason: "all gates satisfied"),
    includeCleanupInventory: Bool = true,
    postValidationCleanupInventory: PostValidationCleanupInventoryV1? = nil
  ) -> ValidationReceipt {
    ValidationReceipt(
      schemaVersion: schemaVersion,
      runID: "run-1",
      objective: objective,
      changedSurface: changedSurface,
      acceptanceCriteria: acceptanceCriteria,
      builder: builder,
      reviewer: reviewer,
      verifier: verifier,
      judge: judge,
      build: build,
      visualEvidence: visualEvidence,
      visualChecklist: visualChecklist,
      codexAppParity: codexAppParity,
      findings: findings,
      judgeDecision: judgeDecision,
      postValidationCleanupInventory: includeCleanupInventory
        ? (postValidationCleanupInventory ?? Self.cleanupInventory)
        : nil
    )
  }

  private static var cleanupInventory: PostValidationCleanupInventoryV1 {
    PostValidationCleanupInventoryFactory.noCandidateInventory(
      runID: "run-1",
      validatedGoalID: "goal-run-1",
      validatedContractID: "contract-run-1",
      mustKeep: ["summary.json", "總評分報告.md"])
  }

  private static var cleanupMarkdownData: Data {
    Data(PostValidationCleanupInventoryFactory.markdownBody(for: cleanupInventory).utf8)
  }

  private static func fileSystem(_ files: [String: Data] = [:]) -> InMemoryEvidenceFileSystem {
    var merged = files
    merged[cleanupInventory.markdownPath] = cleanupMarkdownData
    return InMemoryEvidenceFileSystem(files: merged)
  }

  private static func codexParityEvidence() -> (
    [VisualEvidenceArtifact], [VisualChecklistItem], [String: Data]
  ) {
    let now = Date()
    let baselinePath = "/repo/.tatwo-ultrawork/evidence/run-1/codex-baseline.png"
    let candidatePath = "/repo/.tatwo-ultrawork/evidence/run-1/tatwo-candidate.png"
    let baselineData = Data("codex baseline".utf8)
    let candidateData = Data("tatwo candidate".utf8)
    let baseline = VisualEvidenceArtifact(
      id: "codex-baseline",
      runID: "run-1",
      kind: .screenshot,
      path: baselinePath,
      sha256: ValidationGate.sha256Hex(baselineData),
      capturedAt: now,
      surfaceName: "current Codex App Chat",
      viewport: "1440x960")
    let candidate = VisualEvidenceArtifact(
      id: "tatwo-candidate",
      runID: "run-1",
      kind: .screenshot,
      path: candidatePath,
      sha256: ValidationGate.sha256Hex(candidateData),
      capturedAt: now.addingTimeInterval(120),
      surfaceName: "Tatwo ChatPage",
      viewport: "1440x960")
    let checklist = [
      VisualChecklistItem(
        id: "codex-app-parity",
        description: "Tatwo chat aligns with current Codex App baseline",
        expected: "Codex-App-consistent except allowed Tatwo deltas",
        actual: "Codex-App-consistent except allowed Tatwo deltas",
        evidenceArtifactIDs: ["codex-baseline", "tatwo-candidate"],
        verdict: .passed)
    ]
    return (
      [baseline, candidate],
      checklist,
      [baselinePath: baselineData, candidatePath: candidateData])
  }
}
