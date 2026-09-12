import XCTest

@testable import TatwoUltraworkCore

final class ActiveSonnetRoutingTests: XCTestCase {
  func testSonnetCandidateIdentityNormalizesLegacy46InputsButDefersActiveDispatch() {
    XCTAssertTrue(TatwoGatewayDispatchCatalog.allowedModels.contains("sonnet-5"))
    XCTAssertFalse(TatwoGatewayDispatchCatalog.allowedModels.contains("sonnet-4-6"))
    XCTAssertEqual(TatwoGatewayDispatchCatalog.normalize("sonnet5"), "sonnet-5")
    XCTAssertEqual(TatwoGatewayDispatchCatalog.normalize("claude-sonnet-5"), "sonnet-5")
    XCTAssertEqual(TatwoGatewayDispatchCatalog.normalize("sonnet4.6"), "sonnet-5")
    XCTAssertEqual(TatwoGatewayDispatchCatalog.normalize("sonnet-4-6"), "sonnet-5")
    XCTAssertEqual(TatwoGatewayDispatchCatalog.normalize("claude-sonnet-4-6"), "sonnet-5")
    XCTAssertEqual(TatwoGatewayDispatchCatalog.models(for: .consultant), ["sonnet-5"])
    XCTAssertFalse(TatwoModelIdentityRegistry.isActiveDispatchEligible("sonnet-5"))
  }

  func testActiveTeamRoutingUsesSonnet5AndHistoricalEvidenceKeepsOriginalModelLabel() {
    XCTAssertTrue(TeamRoutingCatalog.modelTraits.contains { $0.id == "sonnet-5" })
    XCTAssertFalse(TeamRoutingCatalog.modelTraits.contains { $0.id == "sonnet-4-6" })
    XCTAssertTrue(TeamRoutingCatalog.leadStrategies.contains { $0.leadModelID == "sonnet-5" })
    XCTAssertFalse(TeamRoutingCatalog.leadStrategies.contains { $0.leadModelID == "sonnet-4-6" })

    let historical = TeamRoutingCatalog.collaborationEvidence.first {
      $0.id == "gpt55-sonnet5-vs-fable5-20260706"
    }
    XCTAssertEqual(historical?.members.map(\.model), ["gpt-5.5", "sonnet-5"])
  }
}
