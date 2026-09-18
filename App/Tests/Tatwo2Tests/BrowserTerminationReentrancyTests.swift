import AppKit
import XCTest
@testable import Tatwo2

final class BrowserTerminationReentrancyTests: XCTestCase {
    @MainActor
    func testConfirmationRunsInsideNestedRunLoopEnteredFromMainQueue() async {
        let finished = expectation(description: "nested termination returned")
        DispatchQueue.main.async {
            var presented = false
            var replies = 0
            let coordinator = TatwoTerminationCoordinator(present: { _, complete in
                presented = true
                complete(false)
            })
            let result = coordinator.request(requiresConfirmation: true, window: nil) { approved in
                XCTAssertFalse(approved)
                replies += 1
            }
            XCTAssertEqual(result, .terminateLater)
            let deadline = Date().addingTimeInterval(1)
            while !presented && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            XCTAssertTrue(presented, "Confirmation must not depend on draining the occupied main queue")
            XCTAssertEqual(replies, 1)
            XCTAssertFalse(coordinator.confirmationPending)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
    }
}
