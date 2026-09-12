import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class WebCheckIntegrationTests: XCTestCase {
  func testWebCheckPlanIsLocalOnlyReceiptSourceForUI() throws {
    let plan = TatwoWebCheckFactory.plan(
      mode: .l,
      scenarioProfileID: "ui-ux",
      target: "/private/project/ui")

    XCTAssertEqual(plan.schema, "TatwoWebCheckPlanV1")
    XCTAssertEqual(plan.targetKind, .localProject)
    XCTAssertEqual(plan.targetLabel, "<local-frontend-project>")
    XCTAssertTrue(plan.requiredForPass)
    XCTAssertTrue(plan.osReceiptIDs.contains("web-check-full-scan"))
    XCTAssertTrue(plan.localOnlyRules.contains { $0.contains("不把 source") })
    XCTAssertTrue(plan.humanGateNote.contains("visual") || plan.humanGateNote.contains("UI"))
  }

  func testWebCheckImportRequiresContractAndRedactsReportPath() throws {
    let report = """
      {"ok":true,"summary":{"errorCount":0,"warningCount":1,"total":1,"categories":{"Accessibility":{"total":1,"errorCount":0,"warningCount":1}}}}
      """.data(using: .utf8)!

    let missing = TatwoWebCheckFactory.importReceipt(
      reportData: report,
      reportPath: "/private/tmp/report.json",
      contractID: nil,
      goalID: nil,
      targetKind: .localProject,
      scanType: .full,
      blockingPolicy: .noNewError,
      command: "./bin/tatwo-frontend-doctor <local> --json")
    XCTAssertFalse(missing.ok)
    XCTAssertEqual(missing.decision.code, "missing_contract_id")

    let imported = TatwoWebCheckFactory.importReceipt(
      reportData: report,
      reportPath: "/private/tmp/report.json",
      contractID: "contract-l-ui-ux-abcdef123456",
      goalID: "goal-l-ui-ux-abcdef123456",
      targetKind: .localProject,
      scanType: .full,
      blockingPolicy: .noNewError,
      command: "./bin/tatwo-frontend-doctor <local> --json")
    XCTAssertTrue(imported.ok, imported.decision.message)
    XCTAssertEqual(imported.receipt?.schema, "TatwoWebCheckReceiptV1")
    XCTAssertEqual(imported.receipt?.reportPath, "local-only:report.json")
    XCTAssertEqual(imported.receipt?.summary.errors, 0)
    XCTAssertEqual(imported.receipt?.summary.warnings, 1)
    XCTAssertEqual(imported.receipt?.decision, .passed)
    XCTAssertEqual(imported.receipt?.externalUploadAvoided, true)
    XCTAssertEqual(imported.receipt?.projectFilesModified, false)
  }

  func testMCPWebCheckToolsAndAliasWork() throws {
    let plan = TatwoMCPRegistry.call(
      tool: "tatwo_web_check_plan",
      arguments: [
        "mode": .string("L"),
        "scenario": .string("ui-ux"),
        "target": .string("/private/project"),
      ])
    XCTAssertTrue(plan.ok, plan.error ?? "")
    let encodedPlan = String(data: try JSONEncoder().encode(plan), encoding: .utf8) ?? ""
    XCTAssertTrue(encodedPlan.contains("TatwoWebCheckPlanV1"))
    XCTAssertFalse(encodedPlan.contains("/private/project"))

    let reportJSON =
      "{\"ok\":true,\"summary\":{\"errorCount\":0,\"warningCount\":0,\"total\":0,\"categories\":{}}}"
    let imported = TatwoMCPRegistry.call(
      tool: "tatwo.web_check.import_receipt",
      arguments: [
        "contractID": .string("contract-l-ui-ux-abcdef123456"),
        "reportJSON": .string(reportJSON),
      ])
    XCTAssertTrue(imported.ok, imported.error ?? "")
    let encodedImport = String(data: try JSONEncoder().encode(imported), encoding: .utf8) ?? ""
    XCTAssertTrue(encodedImport.contains("TatwoWebCheckReceiptV1"))
    XCTAssertTrue(encodedImport.contains("externalUploadAvoided"))
  }
}
