import XCTest
@testable import TatwoUltraworkMac

final class CanonicalVendorEventTests: XCTestCase {
    func testFrozenStreamsPreserveDeltaGranularityAndLegacyTerminalText() throws {
        let expected: [CanonicalVendorEvent] = [.assistantDelta("Hel"), .assistantDelta("lo"), .assistantMessage("Hello")]
        XCTAssertEqual(try events("codex-app-server", ChatNativeSubscriptionCanonicalAdapter.adapt).filter { $0 != .turnCompleted }, expected)
        XCTAssertEqual(try events("claude-runtime", ClaudeRuntimeCanonicalAdapter.adapt), expected)
        XCTAssertEqual(try events("grok-runtime", GrokRuntimeCanonicalAdapter.adapt), expected)
    }

    func testCanonicalReadPathIsDefaultAndRollbackFlagRestoresLegacyParser() {
        XCTAssertTrue(CanonicalVendorEventReadPath.usesCanonicalAdapter(environment: [:]))
        XCTAssertFalse(CanonicalVendorEventReadPath.usesCanonicalAdapter(
            environment: [CanonicalVendorEventReadPath.rollbackEnvironmentKey: "1"]))
        XCTAssertFalse(CanonicalVendorEventReadPath.usesCanonicalAdapter(
            environment: [CanonicalVendorEventReadPath.rollbackEnvironmentKey: "legacy"]))
        XCTAssertTrue(CanonicalVendorEventReadPath.usesCanonicalAdapter(
            environment: [CanonicalVendorEventReadPath.rollbackEnvironmentKey: "0"]))
    }

    func testAllThreeRuntimeReadPathsInvokeCanonicalAdapters() throws {
        let base = sourceRoot + "/Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/"
        let sources = try [
            "ChatNativeSubscriptionRuntime.swift",
            "ChatNativeClaudeSubscriptionRuntime.swift",
            "ChatNativeGrokSubscriptionRuntime.swift",
        ].map { try String(contentsOfFile: base + $0) }
        XCTAssertTrue(sources[0].contains("ChatNativeSubscriptionCanonicalAdapter.adapt"))
        XCTAssertTrue(sources[1].contains("ClaudeRuntimeCanonicalAdapter.adapt"))
        XCTAssertTrue(sources[2].contains("GrokRuntimeCanonicalAdapter.adapt"))
    }

    private func events(_ fixture: String, _ adapt: (Data) throws -> CanonicalVendorEvent?) throws -> [CanonicalVendorEvent] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/CanonicalVendorEvent/\(fixture).jsonl")
        return try String(contentsOf: url).split(separator: "\n").compactMap { try adapt(Data($0.utf8)) }
    }
    private var sourceRoot: String { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path }
}
