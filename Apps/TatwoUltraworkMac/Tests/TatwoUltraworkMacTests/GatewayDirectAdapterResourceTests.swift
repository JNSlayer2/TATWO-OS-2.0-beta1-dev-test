import XCTest

final class GatewayDirectAdapterResourceTests: XCTestCase {
    // M3b 更新：deprecated 歷史相容組。正式 Chat route 已不再呼叫
    // gatewayDirect；資源暫留只為舊收據／fixture 可重播。
    func testDeprecatedGatewayDirectAdapterScriptRemainsPackagedForHistoricalFixtures()
        throws
    {
        let testBundleURL = Bundle(for: GatewayDirectAdapterResourceTests.self).bundleURL
        let searchRoots = [
            testBundleURL,
            testBundleURL.deletingLastPathComponent(),
        ]

        let packagedScript = searchRoots.lazy.compactMap { root -> URL? in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            else { return nil }
            return enumerator.compactMap { $0 as? URL }.first {
                $0.lastPathComponent == "tatwo-direct-gateway-chat.mjs"
                    && $0.path.contains("TatwoUltrawork_TatwoUltraworkMac.bundle")
            }
        }.first

        XCTAssertNotNil(
            packagedScript,
            "deprecated gateway-direct fixtures still require the historical adapter resource")
    }

    func testDeprecatedRuntimeSmokeRetainsHistoricalGatewayRouteMatrix()
        throws
    {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("scripts/tatwo-chat-runtime-smoke.mjs")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        for expected in [
            #""fable5": { adapter: "gateway-direct", model: "fable-5""#,
            #""haiku4.5": { adapter: "gateway-direct", model: "haiku-4-5""#,
            #""sonnet5": { adapter: "gateway-direct", model: "sonnet-5""#,
            #""opus5": { adapter: "gateway-direct", model: "opus-5""#,
        ] {
            XCTAssertTrue(script.contains(expected), expected)
        }
        XCTAssertFalse(script.contains(#""haiku4.6": { adapter:"#))
        XCTAssertFalse(script.contains(#"model: "haiku-4-6""#))
        XCTAssertFalse(script.contains(#""sonnet4.6": { adapter:"#))
        XCTAssertFalse(script.contains(#"adapter: "claude-cli-native""#))
    }

    func testAppServerContextGuardSmokeDefaultsToCurrentHaikuRoute() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent(
            "scripts/tatwo-app-server-context-guard-smoke.mjs")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(
            script.contains(
                #"APP_SERVER_CONTEXT_GUARD_MODEL || "haiku-4-5""#))
        XCTAssertFalse(script.contains(#"APP_SERVER_CONTEXT_GUARD_MODEL || "haiku-4-6""#))
    }
}
