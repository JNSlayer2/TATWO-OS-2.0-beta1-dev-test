import XCTest

@testable import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class ChatCooldownGateTests: XCTestCase {
    func testSessionLimitBlocksDispatchAndResumeWithRetryTime() {
        let record = TatwoGatewayCooldownRecordV1(
            provider: "fable-5",
            scope: "model",
            reason: "session_limit",
            tripAtUTC: "2026-07-15T08:00:00Z",
            resetAtUTC: "2026-07-15T08:20:00Z",
            sourceEventID: "event-1",
            contractID: "contract-1")
        let projection = TatwoGatewayCooldownProjectionV1(
            state: .blocked,
            code: "cooldown_blocked_before_reset_margin",
            record: record,
            retryAtUTC: "2026-07-15T08:21:00Z")

        let gate = TatwoChatCooldownGate(
            projection: projection,
            modelDisplayName: "Fable 5")

        XCTAssertFalse(gate.canDispatch)
        XCTAssertFalse(gate.canResume)
        XCTAssertTrue(gate.statusText.contains("session_limit"))
        XCTAssertTrue(gate.statusText.contains("2026-07-15T08:21:00Z"))
    }

    func testPostResetProbeRequirementStillBlocksAppResume() {
        let record = TatwoGatewayCooldownRecordV1(
            provider: "fable-5",
            scope: "model",
            reason: "session_limit",
            tripAtUTC: "2026-07-15T08:00:00Z",
            resetAtUTC: "2026-07-15T08:20:00Z",
            sourceEventID: "event-2",
            contractID: "contract-1")
        let projection = TatwoGatewayCooldownProjectionV1(
            state: .requiresProbe,
            code: "cooldown_probe_required",
            record: record,
            retryAtUTC: "2026-07-15T08:21:00Z")

        let gate = TatwoChatCooldownGate(
            projection: projection,
            modelDisplayName: "Fable 5")

        XCTAssertFalse(gate.canDispatch)
        XCTAssertFalse(gate.canResume)
        XCTAssertTrue(gate.statusText.contains("健康探針"))
    }

    func testClearProjectionAllowsDispatchAndResume() {
        let projection = TatwoGatewayCooldownProjectionV1(
            state: .clear,
            code: "clear",
            record: nil,
            retryAtUTC: nil)
        let gate = TatwoChatCooldownGate(
            projection: projection,
            modelDisplayName: "Fable 5")

        XCTAssertTrue(gate.canDispatch)
        XCTAssertTrue(gate.canResume)
        XCTAssertEqual(gate.statusText, "")
    }
}
