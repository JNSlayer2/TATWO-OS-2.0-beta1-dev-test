import XCTest
@_spi(TatwoHumanGateApp) import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class ChatThinkingHeartbeatTests: XCTestCase {
    func testDelayedFirstTokenEmitsHeartbeatAndStopsAfterToken() {
        let recorder = HeartbeatEventRecorder()
        let heartbeat = ChatCLIThinkingHeartbeat(
            turnID: "turn-delayed",
            attempt: 1,
            interval: 0.03,
            queue: DispatchQueue(label: "heartbeat.delayed"),
            onEvent: recorder.record)

        heartbeat.start(installTimer: activate)
        XCTAssertTrue(recorder.waitForHeartbeat(timeout: 0.3))
        heartbeat.observe(.output("first token"))
        let countAfterToken = recorder.heartbeatCount
        Thread.sleep(forTimeInterval: 0.12)

        XCTAssertGreaterThanOrEqual(countAfterToken, 1)
        XCTAssertEqual(recorder.heartbeatCount, countAfterToken)
    }

    func testFastFirstTokenProducesNoHeartbeatPollution() {
        let recorder = HeartbeatEventRecorder()
        let heartbeat = ChatCLIThinkingHeartbeat(
            turnID: "turn-fast",
            attempt: 1,
            interval: 0.08,
            queue: DispatchQueue(label: "heartbeat.fast"),
            onEvent: recorder.record)

        heartbeat.start(installTimer: activate)
        heartbeat.observe(.output("fast token"))
        Thread.sleep(forTimeInterval: 0.16)

        XCTAssertEqual(recorder.heartbeatCount, 0)
    }

    func testProviderThinkingCountsAsActivityAndStopsSyntheticHeartbeat() {
        let recorder = HeartbeatEventRecorder()
        let heartbeat = ChatCLIThinkingHeartbeat(
            turnID: "turn-thinking",
            attempt: 1,
            interval: 0.08,
            queue: DispatchQueue(label: "heartbeat.thinking"),
            onEvent: recorder.record)

        heartbeat.start(installTimer: activate)
        heartbeat.observe(.thinking(ChatCLIActivity(
            text: "reasoning",
            rawType: "thought")))
        Thread.sleep(forTimeInterval: 0.16)

        XCTAssertEqual(recorder.heartbeatCount, 0)
    }
}

private func activate(_ timer: DispatchSourceTimer) -> Bool {
    timer.activate()
    return true
}

private final class HeartbeatEventRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0

    var heartbeatCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return count
    }

    func record(_ event: ChatCLIEvent) {
        guard case .activity(let activity) = event,
              activity.sourceType == ChatCLIThinkingHeartbeat.sourceType
        else { return }
        condition.lock()
        count += 1
        condition.broadcast()
        condition.unlock()
    }

    func waitForHeartbeat(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while count == 0, Date() < deadline {
            condition.wait(until: deadline)
        }
        return count > 0
    }
}
