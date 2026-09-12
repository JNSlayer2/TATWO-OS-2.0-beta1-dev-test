import XCTest
@testable import TatwoUltraworkMac
import TatwoUltraworkCore

@MainActor
final class WebMCPBridgeTests: XCTestCase {
    func testRegistryPublishesPerTabToolsAndNavigationInvalidatesThem()
        throws
    {
        let runtime = TatwoWebMCPRuntime.shared
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }

        runtime.activate(tabID: "tab-a")
        runtime.attach(tabID: "tab-a") { _, _, _, completion in
            completion(#"{"ok":true}"#, nil)
        }
        let first = runtime.update(
            tabID: "tab-a",
            snapshotJSONString: snapshot(
                generation: 7,
                description: "Read title"))

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].mcpToolName.hasPrefix(
            "tatwo.webmcp."))
        XCTAssertEqual(
            TatwoMCPRegistry.tools.first {
                $0.name == first[0].mcpToolName
            }?.metadata["trust"],
            "untrusted_web")

        runtime.invalidate(tabID: "tab-a")
        XCTAssertNil(runtime.descriptor(named: first[0].mcpToolName))
        XCTAssertFalse(TatwoMCPRegistry.tools.contains {
            $0.name == first[0].mcpToolName
        })

        let second = runtime.update(
            tabID: "tab-a",
            snapshotJSONString: snapshot(
                generation: 8,
                description: "Read title"))
        XCTAssertEqual(second.first?.navigationGeneration, 8)
        XCTAssertNotEqual(
            first.first?.bindingHash,
            second.first?.bindingHash)
    }

    func testMetadataAndSchemaStringsPassUnicodeSanitizer() throws {
        let runtime = TatwoWebMCPRuntime.shared
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }
        runtime.activate(tabID: "tab-sanitize")

        let tools = runtime.update(
            tabID: "tab-sanitize",
            snapshotJSONString: snapshot(
                generation: 3,
                description: "Safe\u{200B}\u{202E} description",
                schema:
                    #"{"type":"object","properties":{"q\u200B":{"type":"string","description":"Va\u202Elue"}}}"#))
        let tool = try XCTUnwrap(tools.first)

        XCTAssertEqual(tool.description, "Safe description")
        XCTAssertFalse(tool.inputSchemaJSON.contains("\\u200b"))
        XCTAssertFalse(tool.inputSchemaJSON.contains("\\u202e"))
        XCTAssertTrue(tool.inputSchemaJSON.contains("\"q\""))
        XCTAssertTrue(tool.inputSchemaJSON.contains("Value"))
    }

    func testDynamicToolCallOnlyFreezesPlanAndHumanGateBlocksExecution()
        throws
    {
        let runtime = TatwoWebMCPRuntime.shared
        runtime.resetForTesting()
        defer { runtime.resetForTesting() }
        let probe = TatwoWebMCPInvocationProbe()
        runtime.activate(tabID: "tab-gate")
        runtime.attach(tabID: "tab-gate") { _, _, _, completion in
            probe.markInvoked()
            completion(#"{"ok":true}"#, nil)
        }
        let descriptor = try XCTUnwrap(runtime.update(
            tabID: "tab-gate",
            snapshotJSONString: snapshot(
                generation: 11,
                description: "Submit request")).first)
        let grant = try TatwoBrowserAgentSecurityRuntime.shared.issueGrant(
            contractID: "contract-webmcp",
            runID: "run-webmcp",
            leaseID: "lease-webmcp",
            sessionID: "session-webmcp",
            origin: descriptor.origin,
            navigationGeneration: descriptor.navigationGeneration,
            capabilities: [.planActions, .executeApprovedPlan],
            ttl: 120)

        let planned = TatwoAppManagementMCP.call(
            tool: descriptor.mcpToolName,
            arguments: [
                "grant": try JSONValue.fromEncodable(grant),
                "query": .string("hello"),
            ])
        XCTAssertTrue(
            planned.ok,
            "planning failed: \(planned.error ?? "unknown")")
        XCTAssertFalse(planned.hostMutationAllowed)
        XCTAssertFalse(probe.wasInvoked)
        guard case let .object(plannedPayload)? = planned.payload,
              case let .bool(invoked)? = plannedPayload["invoked"],
              case let .object(tokenObject)? =
                plannedPayload["approvedPlanToken"]
        else {
            return XCTFail("missing WebMCP frozen plan")
        }
        XCTAssertFalse(invoked)
        let token = try decode(
            JSONValue.object(tokenObject),
            as: TatwoBrowserTypedPlanTokenV1.self)

        let blocked = TatwoAppManagementMCP.call(
            tool: "tatwo.browser.execute_approved_plan",
            arguments: [
                "grant": try JSONValue.fromEncodable(grant),
                "approvedPlanToken": try JSONValue.fromEncodable(token),
                "workspaceRoot": .string("/tmp"),
            ])
        XCTAssertFalse(blocked.ok)
        XCTAssertEqual(blocked.error, "human_approval_required")
        XCTAssertFalse(probe.wasInvoked)
    }

    private func snapshot(
        generation: UInt64,
        description: String,
        schema: String =
            #"{"type":"object","properties":{"query":{"type":"string"}}}"#
    ) -> String {
        let object: [String: Any] = [
            "schema": "TatwoCEFWebMCPToolsSnapshotV1",
            "origin": "https://example.com",
            "navigationGeneration": generation,
            "tools": [
                [
                    "name": "search",
                    "description": description,
                    "inputSchemaJSON": schema,
                    "origin": "https://example.com",
                    "navigationGeneration": generation,
                ],
            ],
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func decode<T: Decodable>(
        _ value: JSONValue,
        as type: T.Type
    ) throws -> T {
        let data = try JSONEncoder().encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

private final class TatwoWebMCPInvocationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invoked = false

    var wasInvoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invoked
    }

    func markInvoked() {
        lock.lock()
        invoked = true
        lock.unlock()
    }
}
