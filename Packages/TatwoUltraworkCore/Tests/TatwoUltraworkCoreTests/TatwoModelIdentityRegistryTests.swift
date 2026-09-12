import XCTest

@testable import TatwoUltraworkCore

final class TatwoModelIdentityRegistryTests: XCTestCase {
  func testOpus5AliasesResolveToOneCanonicalModel() throws {
    for alias in ["opus5", "opus-5", "claude-opus-5", "opus"] {
      XCTAssertEqual(TatwoModelIdentityRegistry.canonicalModelID(for: alias), "opus-5")
    }
    XCTAssertEqual(
      TatwoModelIdentityRegistry.records.filter { $0.canonicalModelID == "opus-5" }.count,
      1)
  }

  func testSonnetCompatibilityAliasesResolveWithoutBecomingIndependentCanonicalIDs() throws {
    for alias in ["sonnet5", "claude-sonnet-5", "sonnet4.6", "sonnet-4-6", "claude-sonnet-4-6"] {
      XCTAssertEqual(TatwoModelIdentityRegistry.canonicalModelID(for: alias), "sonnet-5")
    }
    XCTAssertFalse(TatwoModelIdentityRegistry.canonicalModelIDs.contains("sonnet-4-6"))

    let sonnet = try XCTUnwrap(TatwoModelIdentityRegistry.record(for: "sonnet-4-6"))
    XCTAssertEqual(sonnet.canonicalModelID, "sonnet-5")
    XCTAssertEqual(sonnet.currentHealth, .deferUntilRouteHealthV2)
    XCTAssertFalse(TatwoModelIdentityRegistry.isActiveDispatchEligible("sonnet-5"))
  }

  func testHaiku45IsCanonicalAndUnavailable46NamesDoNotSilentlyDowngrade() throws {
    for alias in [
      "haiku4.5",
      "haiku-4-5",
      "claude-haiku-4-5",
      "haiku",
    ] {
      XCTAssertEqual(TatwoModelIdentityRegistry.canonicalModelID(for: alias), "haiku-4-5")
    }
    XCTAssertTrue(TatwoModelIdentityRegistry.canonicalModelIDs.contains("haiku-4-5"))
    XCTAssertFalse(TatwoModelIdentityRegistry.canonicalModelIDs.contains("haiku-4-6"))
    XCTAssertTrue(TatwoModelIdentityRegistry.isActiveDispatchEligible("haiku-4-5"))
    for unavailable in ["haiku4.6", "haiku-4-6", "claude-haiku-4-6"] {
      XCTAssertNil(TatwoModelIdentityRegistry.canonicalModelID(for: unavailable))
      XCTAssertFalse(TatwoModelIdentityRegistry.isActiveDispatchEligible(unavailable))
    }
  }

  func testGrok46AliasesResolveToGrokBuildAndLegacy45AliasesFailClosed() throws {
    for alias in ["grok", "grok-4.6", "grok4.6"] {
      XCTAssertEqual(TatwoModelIdentityRegistry.canonicalModelID(for: alias), "grok-build")
      XCTAssertTrue(TatwoModelIdentityRegistry.isActiveDispatchEligible(alias))
    }
    for legacy45 in ["grok-4.5", "grok4.5"] {
      XCTAssertNil(TatwoModelIdentityRegistry.canonicalModelID(for: legacy45))
      XCTAssertFalse(TatwoModelIdentityRegistry.isActiveDispatchEligible(legacy45))
    }
    XCTAssertFalse(TatwoModelIdentityRegistry.canonicalModelIDs.contains("grok-4.5"))
    XCTAssertFalse(TatwoModelIdentityRegistry.canonicalModelIDs.contains("grok-4.6"))
  }

  func testHistoricalEvidenceIDsNeverResolveAsAliases() throws {
    for evidenceID in [
      "sonnet-5-web-arena-v1-20260702",
      "sonnet-5-blender-q1-20260702",
      "gpt55-sonnet5-vs-fable5-20260706",
    ] {
      XCTAssertTrue(TatwoModelIdentityRegistry.datedHistoricalEvidenceIDs.contains(evidenceID))
      XCTAssertNil(TatwoModelIdentityRegistry.canonicalModelID(for: evidenceID))
      XCTAssertFalse(TatwoModelIdentityRegistry.isActiveDispatchEligible(evidenceID))
    }
  }

  func testGatewayCatalogAndExecutionManifestShareRegistryResolution() {
    for input in ["sonnet5", "sonnet-4-6", "claude-sonnet-4-6", "sonnet-5"] {
      XCTAssertEqual(TatwoGatewayDispatchCatalog.normalize(input), "sonnet-5")
      XCTAssertFalse(
        TatwoExecutionManifestFactory.isDispatchable(modelID: input),
        "Human direction defers active Sonnet dispatch until RouteHealthReceiptV2.")
    }
    XCTAssertTrue(TatwoExecutionManifestFactory.isDispatchable(modelID: "minimax"))
  }
}
