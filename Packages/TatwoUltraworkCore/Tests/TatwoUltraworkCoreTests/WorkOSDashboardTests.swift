import XCTest

@testable import TatwoUltraworkCore

final class WorkOSDashboardTests: XCTestCase {
  func testDashboardSnapshotIsReadOnlyAndShowsContractRail() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "dashboard m4")

    let dashboard = TatwoWorkOSDashboardFactory.make(contract: contract)

    XCTAssertEqual(dashboard.schema, "TatwoWorkOSDashboardSnapshotV1")
    XCTAssertTrue(dashboard.readOnly)
    XCTAssertFalse(dashboard.canPromoteRunState)
    XCTAssertEqual(dashboard.goal.goalID, contract.goalID)
    XCTAssertEqual(dashboard.contract.contractID, contract.contractID)
    XCTAssertTrue(dashboard.contract.failClosed)
    XCTAssertFalse(dashboard.contract.visualizerCanPromoteRunState)
    XCTAssertTrue(dashboard.lanes.contains { $0.kind == .mainline })
    XCTAssertTrue(dashboard.lanes.contains { $0.kind == .domain })
    XCTAssertTrue(dashboard.lanes.contains { $0.kind == .receipts })
    XCTAssertTrue(dashboard.receiptRail.requiredCount > 0)
    XCTAssertEqual(dashboard.receiptRail.missingCount, dashboard.receiptRail.requiredCount)
    XCTAssertTrue(dashboard.outcome.readyLabel.contains("READY"))
    XCTAssertTrue(dashboard.outcome.rollbackLabel.contains("ROLLBACK"))
    XCTAssertFalse(dashboard.outcome.canPassFromDashboard)
    XCTAssertTrue(dashboard.dashboardRules.contains { $0.contains("控制台") || $0.contains("pass") })
  }

  func testDashboardReceiptRailMovesTowardReadyWhenReceiptsSupplied() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .l,
      scenarioProfileID: "coding",
      objective: "receipt dashboard")
    let required = contract.receiptRequirements.filter(\.requiredForPass).map(\.id)

    let dashboard = TatwoWorkOSDashboardFactory.make(
      contract: contract,
      submittedReceiptIDs: required)

    XCTAssertEqual(dashboard.receiptRail.missingCount, 0)
    XCTAssertTrue(dashboard.outcome.readyLabel.contains("等待人工") || dashboard.outcome.readyLabel.contains("receipt 齊全"))
    XCTAssertFalse(dashboard.canPromoteRunState)
  }

  func testDashboardToolRailUsesContractAllowedToolsAndOSCoreTools() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "tool rail")
    let dashboard = TatwoWorkOSDashboardFactory.make(contract: contract)

    XCTAssertTrue(dashboard.toolRail.registeredOnly)
    XCTAssertTrue(dashboard.toolRail.allowedTools.contains("tatwo.os.next"))
    XCTAssertTrue(dashboard.toolRail.allowedTools.contains("tatwo.os.dashboard"))
    XCTAssertTrue(dashboard.toolRail.allowedTools.contains("multi_agent_v1.send_input"))
    XCTAssertTrue(dashboard.toolRail.allowedTools.contains("computer-use"))
    XCTAssertTrue(dashboard.toolRail.allowedTools.contains("tatwo.gateway.fanout"))
    XCTAssertTrue(dashboard.toolRail.deniedByDefault.contains { $0.contains("unregistered") || $0.contains("未登記") })
  }
}
