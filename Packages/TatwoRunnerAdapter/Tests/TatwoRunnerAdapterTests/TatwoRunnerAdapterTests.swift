import Foundation
import XCTest
@testable import TatwoRunnerAdapter

final class TatwoRunnerAdapterTests: XCTestCase {
    func testRunnerExecutionNeverCreatesDomainTruthOrTriggersUpdate() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let runner = TatwoRunnerAdapter(
            now: { now },
            receiptID: { "runner-receipt" }
        )
        let request = TatwoRunnerSessionRequestV1(
            sessionID: "session-1",
            correlationID: "corr-1",
            sourceDeviceID: "mac-mini",
            sandboxReference: "sandbox/session-1",
            worktreeReference: "worktree/session-1"
        )

        for receipt in [
            runner.start(request),
            runner.resume(request),
            runner.cancel(request)
        ] {
            XCTAssertTrue(receipt.accepted)
            XCTAssertEqual(receipt.domainTruthWriteCount, 0)
            XCTAssertEqual(receipt.authorityMutationCount, 0)
            XCTAssertEqual(receipt.updateTriggerCount, 0)
        }

        let activity = try XCTUnwrap(runner.activitySnapshot().first)
        XCTAssertEqual(activity.state, .cancelled)
        XCTAssertFalse(activity.dataPlaneEligible)
    }

    func testRunnerStateCannotEncodeAsDomainEvent() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let runner = TatwoRunnerAdapter(
            now: { now },
            receiptID: { "runner-boundary-receipt" }
        )
        let command = runner.start(
            .init(
                sessionID: "session-1",
                correlationID: "corr-start",
                sourceDeviceID: "mac-mini",
                sandboxReference: "sandbox/session-1"
            )
        )
        let activity = try XCTUnwrap(command.activity)

        let boundary = runner.rejectDomainEventEncoding(
            activity: activity,
            correlationID: "corr-boundary",
            sourceDeviceID: "mac-mini"
        )

        XCTAssertEqual(boundary.boundary, .domainEventEncoding)
        XCTAssertFalse(boundary.allowed)
        XCTAssertEqual(boundary.domainTruthWriteCount, 0)
        XCTAssertEqual(boundary.domainReceiptAcceptedCount, 0)
        XCTAssertEqual(boundary.updateTriggerCount, 0)
    }

    func testRunnerProseCannotPassDomainReceipt() {
        let runner = TatwoRunnerAdapter(
            now: { Date(timeIntervalSince1970: 1_000) },
            receiptID: { "runner-prose-receipt" }
        )

        let boundary = runner.rejectProseAsDomainReceipt(
            #"{"status":"passed","authority":"primary"}"#,
            correlationID: "corr-prose",
            sourceDeviceID: "mac-mini"
        )

        XCTAssertEqual(boundary.boundary, .domainReceiptFromProse)
        XCTAssertFalse(boundary.allowed)
        XCTAssertEqual(boundary.domainTruthWriteCount, 0)
        XCTAssertEqual(boundary.domainReceiptAcceptedCount, 0)
        XCTAssertEqual(boundary.updateTriggerCount, 0)
    }

    func testRunnerSnapshotIsReadOnly() {
        let runner = TatwoRunnerAdapter(
            now: { Date(timeIntervalSince1970: 1_000) },
            receiptID: { "runner-snapshot-receipt" }
        )
        let before = runner.activitySnapshot()
        let after = runner.subscribeLocalEvents()

        XCTAssertEqual(before, [])
        XCTAssertEqual(after, [])
    }
}
