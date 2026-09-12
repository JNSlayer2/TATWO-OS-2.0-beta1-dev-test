import XCTest

@testable import TatwoUltraworkCore

/// #2 universal chokepoint + the surfaces routed through it, plus the #6 store-backed
/// next/loopStatus, #1 seal-exclusion aggregation, and #3 config audit log.
final class WorkOSChokepointTests: XCTestCase {
  private func makeStore() -> (TatwoGoalRunStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    return (TatwoGoalRunStore(directoryURL: root), root)
  }

  // MARK: Chokepoint core

  func testChokepointFailsClosedOnMissingContract() {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let decision = TatwoWorkOSChokepoint.authorize(
      contractID: "  ", action: "test", store: store, environment: [:])
    XCTAssertFalse(decision.ok)
    XCTAssertEqual(decision.code, "missing_contract")
  }

  func testChokepointFailsClosedOnForgedContract() {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let decision = TatwoWorkOSChokepoint.authorize(
      contractID: "contract-xl-coding-deadbeef0000", action: "test", store: store,
      environment: [:])
    XCTAssertFalse(decision.ok)
    XCTAssertEqual(decision.code, "unregistered_contract")
  }

  func testChokepointAuthorizesIssuedContract() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m, scenarioProfileID: "coding", objective: "toll", store: store)
    let decision = TatwoWorkOSChokepoint.authorize(
      contractID: contract.contractID, action: "test", store: store, environment: [:])
    XCTAssertTrue(decision.ok)
    XCTAssertEqual(decision.code, "authorized")
    XCTAssertFalse(decision.bypassed)
  }

  func testDevBypassAuthorizesButIsMarked() {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let decision = TatwoWorkOSChokepoint.authorize(
      contractID: nil, action: "test", store: store,
      environment: ["TATWO_ULTRAWORK_DEV_BYPASS": "1"])
    XCTAssertTrue(decision.ok)
    XCTAssertEqual(decision.code, "dev_bypass")
    XCTAssertTrue(decision.bypassed)
    XCTAssertTrue(
      TatwoConfigAuditLog(directoryURL: root).entries().contains {
        $0.action == "dev_bypass_applied"
          && $0.detail == "action=test"
      })
    // Only explicit truthy values enable it.
    XCTAssertFalse(TatwoWorkOSChokepoint.isDevBypassEnabled(environment: ["TATWO_ULTRAWORK_DEV_BYPASS": "0"]))
    XCTAssertFalse(TatwoWorkOSChokepoint.isDevBypassEnabled(environment: [:]))
  }

  // MiniMax M3 sub 對抗案例: bypass 值夾空白/換行仍生效（trim 語意固定）、
  // 相似字首的偽 key 絕不觸發 bypass。
  func testDevBypassTrimsValueAndIgnoresLookalikeKeys() {
    XCTAssertTrue(
      TatwoWorkOSChokepoint.isDevBypassEnabled(environment: ["TATWO_ULTRAWORK_DEV_BYPASS": " 1 \n"]))
    XCTAssertTrue(
      TatwoWorkOSChokepoint.isDevBypassEnabled(environment: ["TATWO_ULTRAWORK_DEV_BYPASS": "TRUE"]))
    XCTAssertFalse(
      TatwoWorkOSChokepoint.isDevBypassEnabled(
        environment: ["TATWO_ULTRAWORK_DEV_BYPASS_OTHER": "1", "TATWO_ULTRAWORK_BYPASS": "1"]))
  }

  func testDevBypassDoesNotBypassHostAuthorization() {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let decision = TatwoWorkOSChokepoint.authorize(
      contractID: nil,
      action: "tatwo.host.authorize",
      store: store,
      environment: ["TATWO_ULTRAWORK_DEV_BYPASS": "1"])

    XCTAssertFalse(decision.ok)
    XCTAssertEqual(decision.code, "missing_contract")
    XCTAssertFalse(decision.bypassed)
    XCTAssertTrue(
      TatwoConfigAuditLog(directoryURL: root).entries().contains {
        $0.action == "dev_bypass_denied_sensitive_action"
          && $0.detail == "action=tatwo.host.authorize"
      })
  }

  func testDevBypassDoesNotBypassHostMutationActions() {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    for action in [
      "tatwo.host.write_file",
      "tatwo.host.run_command",
      "tatwo.host.computer_use",
      "tatwo.host.rollback",
      "tatwo.computer.type_text",
    ] {
      let decision = TatwoWorkOSChokepoint.authorize(
        contractID: nil,
        action: action,
        store: store,
        environment: ["TATWO_ULTRAWORK_DEV_BYPASS": "true"])
      XCTAssertFalse(decision.ok, action)
      XCTAssertEqual(decision.code, "missing_contract", action)
      XCTAssertFalse(decision.bypassed, action)
    }
  }

  func testDevBypassStillAppliesToKnownReadOnlyHostActions() {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    for action in [
      "tatwo.host.plan",
      "tatwo.host.read_file",
      "tatwo.computer.status",
      "tatwo.computer.screenshot",
    ] {
      let decision = TatwoWorkOSChokepoint.authorize(
        contractID: nil,
        action: action,
        store: store,
        environment: ["TATWO_ULTRAWORK_DEV_BYPASS": "yes"])
      XCTAssertTrue(decision.ok, action)
      XCTAssertEqual(decision.code, "dev_bypass", action)
      XCTAssertTrue(decision.bypassed, action)
    }
  }

  // MARK: #6 next / loopStatus answer from the ledger

  func testNextFailsClosedOnForgedContractWithStore() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try WorkOSFactory.next(
      goalID: nil, contractID: "contract-m-coding-000000000000", mode: .m,
      scenarioProfileID: "coding", store: store)
    XCTAssertFalse(result.ok)
    XCTAssertEqual(result.decision.code, "unregistered_contract")
  }

  func testNextUsesStoredModeAndDropsSubmittedReceipts() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl, scenarioProfileID: "coding", objective: "next-ledger", store: store)
    let required = contract.receiptRequirements.filter(\.requiredForPass).map(\.id)
    let first = try XCTUnwrap(required.first)
    _ = try store.appendReceipt(
      contractID: contract.contractID, receiptID: first, kind: "test")
    // Caller lies about the mode; the ledger must win and the journaled receipt drops out.
    let result = try WorkOSFactory.next(
      goalID: nil, contractID: contract.contractID, mode: .s,
      scenarioProfileID: "daily", store: store)
    XCTAssertTrue(result.ok)
    XCTAssertFalse(result.requiredReceiptsBeforePass.contains(first))
    XCTAssertEqual(
      Set(result.requiredReceiptsBeforePass),
      Set(required).subtracting([first, "goal-tracker"]))
  }

  func testLoopStatusFailsClosedOnForgedContractWithStore() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try WorkOSFactory.loopStatus(
      goalID: nil, contractID: "contract-m-coding-000000000000", mode: .m,
      scenarioProfileID: "coding", store: store)
    XCTAssertFalse(report.ok)
    XCTAssertEqual(report.decision.code, "unregistered_contract")
  }

  // MARK: #1 (縮減版) formal runs drop unsealed reports from the aggregation

  func testRunSummaryExcludesUnsealedReportsOnlyWhenGraderKeyConfigured() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try TatwoWebArenaFactory.scaffoldRun(
      root: root, suite: .v1, runID: "20260703-seal-exclusion", models: ["gpt-5.5", "fable-5"])
    let runRoot = root.appendingPathComponent(
      ".tatwo-ultrawork/網頁設計沙盒/20260703-seal-exclusion")
    // Grader-sign one model folder's submission; the other five stay scaffold-unsealed.
    let key = "grader-key-123"
    let sealedFolder = runRoot.appendingPathComponent("01-刺青網頁/GPT5.5")
    let generated = sealedFolder.appendingPathComponent("generated-project", isDirectory: true)
    let seal = try TatwoArenaSubmissionSealer.seal(directory: generated, signingKey: key)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(seal).write(
      to: sealedFolder.appendingPathComponent("final-submission/seal.json"))

    // Casual run (no key): nothing is excluded, all six scaffold reports aggregate.
    let lenient = try TatwoWebArenaFactory.runSummary(
      root: root, runID: "20260703-seal-exclusion", signingKey: nil)
    XCTAssertEqual(lenient.reportCount, 6)
    XCTAssertEqual(lenient.excludedUnsealedReportCount, 0)

    // Formal graded run (key set): only the grader-sealed report survives the aggregation.
    let formal = try TatwoWebArenaFactory.runSummary(
      root: root, runID: "20260703-seal-exclusion", signingKey: key)
    XCTAssertEqual(formal.reportCount, 1)
    XCTAssertEqual(formal.excludedUnsealedReportCount, 5)
    XCTAssertEqual(formal.sealVerifiedReportCount, 1)
    XCTAssertEqual(formal.modelTotals.count, 1)
    XCTAssertEqual(formal.modelTotals.first?.modelFolderName, "GPT5.5")
  }

  // MARK: #3 config audit log

  func testConfigAuditLogAppendsAndReadsBack() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = TatwoConfigAuditLog(directoryURL: root)
    log.append(actor: "app-human", action: "新增情境", detail: "scenario=custom-1", configHash: "abc")
    log.append(actor: "app-human", action: "刪除情境", configHash: "def")
    let entries = log.entries()
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries.first?.action, "新增情境")
    XCTAssertEqual(entries.last?.configHash, "def")
  }
}
