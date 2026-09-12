import Foundation
import XCTest

@testable import TatwoUltraworkMac

final class EmbeddedBrowserEnginePolicyTests: XCTestCase {
    func testProductionBundleWithCEFConfigurationAndCompiledBridgeUsesChromium()
    {
        XCTAssertEqual(
            EmbeddedBrowserEnginePolicy.selectedEngine(
                bundleIdentifier:
                    EmbeddedBrowserEnginePolicy.productionBundleIdentifier,
                configuredEngine: EmbeddedBrowserEngine.chromiumCEF.rawValue,
                cefCompiled: true),
            .chromiumCEF)
    }

    func testProductionBundleFallsBackWhenAnyCEFRequirementIsMissing() {
        XCTAssertEqual(
            EmbeddedBrowserEnginePolicy.selectedEngine(
                bundleIdentifier:
                    EmbeddedBrowserEnginePolicy.productionBundleIdentifier,
                configuredEngine: nil,
                cefCompiled: true),
            .webKitLegacy)
        XCTAssertEqual(
            EmbeddedBrowserEnginePolicy.selectedEngine(
                bundleIdentifier:
                    EmbeddedBrowserEnginePolicy.productionBundleIdentifier,
                configuredEngine: EmbeddedBrowserEngine.chromiumCEF.rawValue,
                cefCompiled: false),
            .chromiumUnavailable)
        XCTAssertEqual(
            EmbeddedBrowserEnginePolicy.selectedEngine(
                bundleIdentifier: nil,
                configuredEngine: EmbeddedBrowserEngine.chromiumCEF.rawValue,
                cefCompiled: true),
            .webKitLegacy)
    }

    func testThirdPartyBundleNeverReceivesCEF() {
        for bundleIdentifier in [
            "com.example.third-party",
            "com.tatwo.ultrawork.preview",
            "com.tatwo.ultrawork.evil",
        ] {
            XCTAssertEqual(
                EmbeddedBrowserEnginePolicy.selectedEngine(
                    bundleIdentifier: bundleIdentifier,
                    configuredEngine:
                        EmbeddedBrowserEngine.chromiumCEF.rawValue,
                    cefCompiled: true),
                .webKitLegacy)
        }
    }

    func testStagingBundleRetainsExistingThreePartCEFPolicy() {
        let bundleIdentifier =
            EmbeddedBrowserEnginePolicy.stagingBundlePrefix + "fixture"
        XCTAssertEqual(
            EmbeddedBrowserEnginePolicy.selectedEngine(
                bundleIdentifier: bundleIdentifier,
                configuredEngine: EmbeddedBrowserEngine.chromiumCEF.rawValue,
                cefCompiled: true),
            .chromiumCEF)
        XCTAssertEqual(
            EmbeddedBrowserEnginePolicy.selectedEngine(
                bundleIdentifier: bundleIdentifier,
                configuredEngine: EmbeddedBrowserEngine.chromiumCEF.rawValue,
                cefCompiled: false),
            .chromiumUnavailable)
        XCTAssertEqual(
            EmbeddedBrowserEnginePolicy.selectedEngine(
                bundleIdentifier: bundleIdentifier,
                configuredEngine: nil,
                cefCompiled: true),
            .webKitLegacy)
    }

    func testProductionRootCreatesChromiumSecurityCacheAndLogDirectories()
        throws
    {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-cef-production-root-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let root = try XCTUnwrap(
            TatwoCEFProfileLocationResolver.productionRootCacheURL(
                applicationSupportURL: container))
        let chromiumRoot = container
            .appendingPathComponent("Tatwo Ultrawork", isDirectory: true)
            .appendingPathComponent("chromium", isDirectory: true)

        XCTAssertEqual(
            root,
            chromiumRoot.appendingPathComponent(
                "cef-root",
                isDirectory: true))
        for relativePath in [
            "cef-root",
            "cef-logs",
            "browser-security",
        ] {
            var isDirectory = ObjCBool(false)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: chromiumRoot
                        .appendingPathComponent(
                            relativePath,
                            isDirectory: true)
                        .path,
                    isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }
}
