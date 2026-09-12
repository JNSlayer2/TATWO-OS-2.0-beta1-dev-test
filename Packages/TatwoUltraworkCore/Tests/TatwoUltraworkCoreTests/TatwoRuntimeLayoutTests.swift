import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoRuntimeLayoutTests: XCTestCase {
  func testCanonicalIdentityAndPathsUseOneMainAppAndOneDataRoot() {
    let base = URL(fileURLWithPath: "/Users/test/Library/Application Support", isDirectory: true)
    let root = TatwoRuntimeLayout.applicationSupportRoot(
      environment: [:],
      applicationSupportBase: base)

    XCTAssertEqual(TatwoRuntimeLayout.appName, "Tatwo Ultrawork")
    XCTAssertEqual(TatwoRuntimeLayout.bundleIdentifier, "com.tatwo.ultrawork")
    XCTAssertEqual(root.path, "/Users/test/Library/Application Support/Tatwo Ultrawork")
    XCTAssertEqual(
      TatwoRuntimeLayout.stateRoot(environment: [:], applicationSupportBase: base).path,
      "/Users/test/Library/Application Support/Tatwo Ultrawork/state")
  }

  func testExplicitAppSupportIsAlreadyCanonicalAndIsNotNestedAgain() {
    let explicit = "/tmp/tatwo-fixture/app-support"
    let environment = ["TATWO_ULTRAWORK_APP_SUPPORT": explicit]

    XCTAssertEqual(
      TatwoRuntimeLayout.applicationSupportRoot(environment: environment).path,
      explicit)
    XCTAssertEqual(
      TatwoNativeChatStore.defaultURL(environment: environment).path,
      "\(explicit)/native-chat-threads.json")
    XCTAssertEqual(
      TatwoUnifiedSessionLedger.default(environment: environment).fileURL.path,
      "\(explicit)/sessions/unified-session-ledger.jsonl")
  }

  func testLegacyRootsRemainDiscoverableForExplicitMigration() {
    let base = URL(fileURLWithPath: "/Users/test/Library/Application Support", isDirectory: true)
    XCTAssertEqual(
      TatwoRuntimeLayout.legacyApplicationSupportRoots(applicationSupportBase: base).map(\.path),
      [
        "/Users/test/Library/Application Support/Tatwo Ultrawork/TatwoUltrawork",
        "/Users/test/Library/Application Support/TatwoUltrawork",
      ])
  }

  func testScenarioAndPluginStoresUseCanonicalRootWithoutLegacyNesting() {
    let explicit = "/tmp/tatwo-fixture/app-support"
    let environment = ["TATWO_ULTRAWORK_APP_SUPPORT": explicit]
    XCTAssertEqual(
      TatwoScenarioConfigStore.defaultFileURL(environment: environment).path,
      "\(explicit)/scenario-config.json")
    XCTAssertEqual(
      TatwoPluginRegistryStore.defaultFileURL(environment: environment).path,
      "\(explicit)/plugin-registry.json")
    XCTAssertEqual(
      TatwoPluginRegistryStore.defaultClaudeStagingURL(environment: environment).path,
      "\(explicit)/claude-mcp-staging.json")
  }

  func testDeviceTrustPinStorePathsAreCentralizedUnderAppSupport() {
    let base = URL(fileURLWithPath: "/Users/test/Library/Application Support", isDirectory: true)
    XCTAssertEqual(
      TatwoRuntimeLayout.deviceTrustRoot(environment: [:], applicationSupportBase: base).path,
      "/Users/test/Library/Application Support/Tatwo Ultrawork/device-trust")
    XCTAssertEqual(
      TatwoRuntimeLayout.deviceTrustPinStoreRoot(environment: [:], applicationSupportBase: base)
        .path,
      "/Users/test/Library/Application Support/Tatwo Ultrawork/device-trust/pin-store")
    let explicit = ["TATWO_ULTRAWORK_APP_SUPPORT": "/tmp/tatwo-fixture/app-support"]
    XCTAssertEqual(
      TatwoDeviceTrustPinStore.defaultRoot(environment: explicit).path,
      "/tmp/tatwo-fixture/app-support/device-trust/pin-store")
  }
}
