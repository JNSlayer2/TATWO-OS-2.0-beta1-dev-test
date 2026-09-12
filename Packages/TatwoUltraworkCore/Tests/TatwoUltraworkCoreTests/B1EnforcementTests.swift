import XCTest

@testable import TatwoUltraworkCore

/// B1: the S/M/L/XL/XXL helper caps the dispatch layer enforces, and the Phase 3b seal-aware
/// model-total shape. (The CLI `os dispatch begin` cap rejection is covered by the binary smoke;
/// here we pin the cap values it reads and the summary struct's compatibility.)
final class B1EnforcementTests: XCTestCase {
  func testHelperCapsPerModeMatchTheCatalog() {
    XCTAssertEqual(TatwoCatalog.defaults.mode(.s)?.maxHelpers, 0)
    XCTAssertEqual(TatwoCatalog.defaults.mode(.m)?.maxHelpers, 4)
    XCTAssertEqual(TatwoCatalog.defaults.mode(.l)?.maxHelpers, 16)
    XCTAssertEqual(TatwoCatalog.defaults.mode(.xl)?.maxHelpers, 48)
    XCTAssertEqual(TatwoCatalog.defaults.mode(.xxl)?.maxHelpers, 4)
  }

  func testModelTotalCarriesSealFieldsAndDecodesOldSummaryLeniently() throws {
    // New construction defaults the seal fields.
    let fresh = TatwoWebArenaModelTotal(
      modelFolderName: "gpt-5.5", reportCount: 3, totalScore: 210, averageScore: 70, blockedCount: 0)
    XCTAssertEqual(fresh.sealVerifiedReportCount, 0)
    XCTAssertEqual(fresh.sealVerifiedScore, 0)

    // An OLD summary.json (no seal fields) still decodes — the seal fields default to 0.
    let oldJSON = """
      {"modelFolderName":"fable-5","reportCount":2,"totalScore":180,"averageScore":90,"blockedCount":1}
      """
    let decoded = try JSONDecoder().decode(
      TatwoWebArenaModelTotal.self, from: Data(oldJSON.utf8))
    XCTAssertEqual(decoded.modelFolderName, "fable-5")
    XCTAssertEqual(decoded.totalScore, 180)
    XCTAssertEqual(decoded.sealVerifiedReportCount, 0)
    XCTAssertEqual(decoded.sealVerifiedScore, 0)
  }
}
