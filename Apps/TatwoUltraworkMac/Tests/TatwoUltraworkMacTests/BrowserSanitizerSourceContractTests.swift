import Foundation
import XCTest

final class BrowserSanitizerSourceContractTests: XCTestCase {
    func testCEFExtractorUsesInternalDOMSnapshotAndHasNoPageJSFallback()
        throws
    {
        let source = try read(
            "Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm")

        XCTAssertTrue(source.contains("\"DOMSnapshot.captureSnapshot\""))
        XCTAssertTrue(source.contains("ExecuteDevToolsMethod"))
        XCTAssertTrue(source.contains("snapshot_unavailable"))
        XCTAssertTrue(source.contains("navigation_binding_unavailable"))
        XCTAssertFalse(source.contains("ExecuteJavaScript"))
        XCTAssertFalse(source.contains("\"Runtime.evaluate\""))
    }

    func testCEFExtractorCarriesAttackCorpusVisibilityAndRedactionGates()
        throws
    {
        let source = try read(
            "Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm")
        for required in [
            "aria-hidden",
            "cumulative_opacity",
            "opacity < 0.1",
            "font-size",
            "clip-path",
            "NSIntersectionRect",
            "contrast < 1.5",
            "contrast < 3.0",
            "paintOrders",
            "instructionLikeContent",
            "sensitive_probe",
            "one-time",
            "cc-",
            "destinationPath",
            "crossOriginFrameExcluded",
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
        XCTAssertFalse(source.contains("inputValue"))
        XCTAssertFalse(source.contains("formValues"))
        XCTAssertFalse(source.contains("innerHTML"))
    }

    func testBrowserMCPBridgeIsIndependentAndNeverEmbedsBrowserImages()
        throws
    {
        let source = try read("scripts/tatwo-computer-mcp.mjs")

        XCTAssertTrue(source.contains("browserTools"))
        XCTAssertTrue(source.contains("tatwo.browser.read_sanitized"))
        XCTAssertTrue(source.contains("tatwo.browser.plan_actions"))
        XCTAssertTrue(
            source.contains("tatwo.browser.execute_approved_plan"))
        XCTAssertTrue(source.contains("forbiddenBrowserPayloadKeys"))
        XCTAssertTrue(source.contains("TATWO_COMPUTER_CONTRACT_ID"))
        XCTAssertTrue(source.contains("TATWO_COMPUTER_LEASE_ID"))
        XCTAssertTrue(source.contains("TATWO_COMPUTER_RUN_ID"))
        XCTAssertTrue(source.contains("grant: _ignoredGrant"))
        XCTAssertTrue(
            source.contains(
                "browser_screenshot_requires_visual_readonly_grant"))
        let browserResult = try XCTUnwrap(
            source.range(of: "function sendBrowserToolResult"))
        let screenshotAppender = try XCTUnwrap(
            source.range(of: "function appendScreenshotBlocks"))
        XCTAssertLessThan(
            source.distance(
                from: source.startIndex,
                to: browserResult.lowerBound),
            source.distance(
                from: source.startIndex,
                to: screenshotAppender.lowerBound))
    }

    func testRunnerKeepsEnvelopeInToolResultDataChannel() throws {
        let source = try read(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/"
                + "ChatPageModel+Workflows.swift")

        XCTAssertTrue(source.contains("browserToolResultDataChannel"))
        XCTAssertTrue(source.contains("\"channel\": .string(\"tool_result\")"))
        XCTAssertTrue(source.contains("\"trust\": .string(\"untrusted_web\")"))
        XCTAssertTrue(source.contains("activePlanArtifact?.state == .confirmed"))
        XCTAssertTrue(source.contains("updateBrowserAgentActivePage"))
        XCTAssertTrue(source.contains("issueBrowserAgentGrantForMCP"))
        XCTAssertTrue(source.contains("committedPageUnavailable"))
        XCTAssertTrue(source.contains("freezeBrowserAgentPlan"))
    }

    private func read(_ relativePath: String) throws -> String {
        let root = try repositoryRoot()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Package.swift").path)
            {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw NSError(
            domain: "BrowserSanitizerSourceContractTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "repository root missing"])
    }
}
