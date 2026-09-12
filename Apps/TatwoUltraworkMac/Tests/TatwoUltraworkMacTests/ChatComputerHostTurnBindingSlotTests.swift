import XCTest
@testable import TatwoUltraworkMac

final class ChatComputerHostTurnBindingSlotTests: XCTestCase {
    func testDistinctRunsCanInstallConcurrentHostAuthority() {
        var slot = ChatComputerHostTurnBindingSlot()
        let sessionA = binding(runID: "run-session-a")
        let sessionB = binding(runID: "run-session-b")

        XCTAssertTrue(slot.install(sessionA))
        XCTAssertTrue(
            slot.install(sessionB),
            "A second chat session/run must be able to acquire Computer Host authority while another run is active")
        XCTAssertEqual(slot.binding(for: "run-session-a"), sessionA)
        XCTAssertEqual(slot.binding(for: "run-session-b"), sessionB)
    }

    func testSameRunCannotReinstallWhileItsBindingIsActive() {
        var slot = ChatComputerHostTurnBindingSlot()
        let first = binding(runID: "run-same-session")
        let duplicateSend = binding(runID: "run-same-session")

        XCTAssertTrue(slot.install(first))
        XCTAssertFalse(
            slot.install(duplicateSend),
            "same-session duplicate-send must not replace an in-flight run binding")
        XCTAssertEqual(slot.binding(for: "run-same-session"), first)
    }

    func testBindingLookupAndTakeAreFailClosedToTheRequestedRun() {
        var slot = ChatComputerHostTurnBindingSlot()
        let owned = binding(runID: "run-owned")
        let other = binding(runID: "run-other")
        XCTAssertTrue(slot.install(owned))
        XCTAssertTrue(slot.install(other))

        XCTAssertNil(slot.binding(for: "run-missing"))
        XCTAssertNil(slot.binding(for: ""))
        XCTAssertNil(slot.take(runID: "run-missing"))
        XCTAssertNil(slot.take(runID: ""))
        XCTAssertEqual(slot.binding(for: "run-owned"), owned)
        XCTAssertEqual(slot.binding(for: "run-other"), other)

        XCTAssertEqual(slot.take(runID: "run-owned"), owned)
        XCTAssertNil(slot.binding(for: "run-owned"))
        XCTAssertEqual(
            slot.binding(for: "run-other"),
            other,
            "per-run cancel/take must not revoke a different session's binding")
        XCTAssertTrue(slot.install(owned))
    }

    func testEmptyRunIDCannotAcquireAuthority() {
        var slot = ChatComputerHostTurnBindingSlot()

        XCTAssertFalse(slot.install(binding(runID: "")))
        XCTAssertNil(slot.binding(for: ""))
        XCTAssertNil(slot.take(runID: ""))
    }

    private func binding(runID: String) -> ChatComputerHostTurnBinding {
        ChatComputerHostTurnBinding(
            runID: runID,
            sessionID: "session-\(runID)",
            decision: .denied,
            contractID: nil,
            mainlineLoopID: nil,
            workspaceRoot: nil,
            lease: nil,
            appMCPEndpoint: nil)
    }
}
