import XCTest

@testable import TatwoUltraworkCore

final class ProductDesignIntegrationTests: XCTestCase {
  func testProductDesignAuditIsRequiredForLAndXLUIScenariosOnly() throws {
    let lReceipts = TatwoProductDesignFactory.receiptRequirements(
      mode: .l, scenarioProfileID: "ui-ux")
    XCTAssertTrue(lReceipts.contains { $0.id == "product-design-audit" && $0.requiredForPass })

    let xlReceipts = TatwoProductDesignFactory.receiptRequirements(
      mode: .xl, scenarioProfileID: "editing")
    XCTAssertTrue(xlReceipts.contains { $0.id == "product-design-audit" && $0.requiredForPass })

    let mReceipts = TatwoProductDesignFactory.receiptRequirements(
      mode: .m, scenarioProfileID: "ui-ux")
    XCTAssertTrue(mReceipts.contains { $0.id == "product-design-audit" && !$0.requiredForPass })

    XCTAssertTrue(
      TatwoProductDesignFactory.receiptRequirements(mode: .xl, scenarioProfileID: "debug")
        .isEmpty)
  }

  func testProductDesignRulesRejectTextOnlySelfApproval() throws {
    XCTAssertTrue(
      TatwoProductDesignFactory.screenshotGroundingRules.contains {
        $0.contains("本輪截圖") && $0.contains("不接受模型純文字自評")
      })
    XCTAssertTrue(
      TatwoProductDesignFactory.screenshotGroundingRules.contains {
        $0.contains("不取代 Swift tests") && $0.contains("web-check")
      })
  }
}
