import XCTest
@testable import TatwoUltraworkMac
import TatwoUltraworkCore

final class TatwoAppManagementMCPTests: XCTestCase {
    func testComputerLeaseRenewalConditionMatrixFailsClosed() {
        let valid = ChatComputerLeaseRenewalContext(
            requestedRunID: "run-1",
            activeRunID: "run-1",
            requestedContractID: "contract-1",
            activeContractID: "contract-1",
            contractIsValid: true,
            turnIsRunning: true,
            userInterrupted: false)
        XCTAssertTrue(valid.mayRenew)

        XCTAssertFalse(ChatComputerLeaseRenewalContext(
            requestedRunID: "run-1",
            activeRunID: "run-1",
            requestedContractID: "contract-1",
            activeContractID: "contract-1",
            contractIsValid: false,
            turnIsRunning: true,
            userInterrupted: false).mayRenew)
        XCTAssertFalse(ChatComputerLeaseRenewalContext(
            requestedRunID: "run-1",
            activeRunID: "run-1",
            requestedContractID: "contract-1",
            activeContractID: "contract-1",
            contractIsValid: true,
            turnIsRunning: false,
            userInterrupted: false).mayRenew)
        XCTAssertFalse(ChatComputerLeaseRenewalContext(
            requestedRunID: "run-1",
            activeRunID: "run-1",
            requestedContractID: "contract-1",
            activeContractID: "contract-1",
            contractIsValid: true,
            turnIsRunning: true,
            userInterrupted: true).mayRenew)
        XCTAssertFalse(ChatComputerLeaseRenewalContext(
            requestedRunID: "run-1",
            activeRunID: "run-other",
            requestedContractID: "contract-1",
            activeContractID: "contract-1",
            contractIsValid: true,
            turnIsRunning: true,
            userInterrupted: false).mayRenew)
    }

    func testComputerAutoContinuationBudgetStopsAtConfiguredLimit() {
        var budget = ChatComputerAutoContinuationBudget(maximumSteps: 2)
        XCTAssertTrue(budget.consumeStep())
        XCTAssertFalse(budget.isExhausted)
        XCTAssertTrue(budget.consumeStep())
        XCTAssertTrue(budget.isExhausted)
        XCTAssertFalse(budget.consumeStep())
        XCTAssertEqual(budget.completedSteps, 2)
    }

    // 2026-08-23 回歸鎖：HTTP server 從背景 queue 呼叫工具。舊版 list_loops
    // 裸 assumeIsolated，在背景執行緒直接 SIGTRAP 弄死整個 App——chat 端
    // 症狀是每次工具呼叫都回 "user cancelled MCP tool call"。
    func testListLoopsFromBackgroundQueueDoesNotCrash() {
        let expectation = expectation(description: "background tool call")
        DispatchQueue.global(qos: .utility).async {
            let result = TatwoAppManagementMCP.call(
                tool: "tatwo.app.list_loops",
                arguments: [:])
            XCTAssertTrue(result.ok)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    func testReadOSStateFromBackgroundQueueDoesNotCrash() {
        let expectation = expectation(description: "background read_os_state")
        DispatchQueue.global(qos: .utility).async {
            let result = TatwoAppManagementMCP.call(
                tool: "tatwo.app.read_os_state",
                arguments: [:])
            XCTAssertTrue(result.ok)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    func testBrowserToolsAreRegisteredWithCorrectMutationBoundary() {
        let tools = Dictionary(uniqueKeysWithValues:
            TatwoMCPRegistry.tools.map { ($0.name, $0) })

        XCTAssertEqual(
            tools["tatwo.browser.read_sanitized"]?.hostMutationAllowed,
            false)
        XCTAssertEqual(
            tools["tatwo.browser.plan_actions"]?.hostMutationAllowed,
            false)
        XCTAssertEqual(
            tools["tatwo.browser.execute_approved_plan"]?
                .hostMutationAllowed,
            true)
        XCTAssertEqual(
            TatwoMCPRegistry.call(
                tool: "tatwo.browser.read_sanitized").error,
            "app_runtime_required")
    }

    func testSanitizedReadFailsClosedWhenCEFSnapshotIsUnavailable() throws {
        let grant = try TatwoBrowserAgentSecurityRuntime.shared.issueGrant(
            contractID: "contract-test",
            runID: "run-test",
            leaseID: "lease-test",
            sessionID: "session-test",
            origin: "https://example.com",
            navigationGeneration: 1,
            capabilities: [.readSanitized],
            ttl: 120)
        let result = TatwoAppManagementMCP.call(
            tool: "tatwo.browser.read_sanitized",
            arguments: [
                "grant": try JSONValue.fromEncodable(grant),
            ])

        XCTAssertFalse(result.ok)
        XCTAssertNil(result.payload)
        XCTAssertFalse(result.hostMutationAllowed)
        XCTAssertEqual(result.error, "snapshot_unavailable")
    }
}
