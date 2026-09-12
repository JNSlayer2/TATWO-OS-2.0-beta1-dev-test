import Foundation
import XCTest
import TatwoRunnerAdapter
@testable import TatwoHostDaemon

final class TatwoHostDaemonTests: XCTestCase {
    func testHostOnlineNeverPromotesAuthority() {
        let runner = TatwoRunnerAdapter(
            now: { Date(timeIntervalSince1970: 1_000) },
            receiptID: { "runner-receipt" }
        )
        let host = TatwoHostDaemon(
            hostID: "host-mini",
            sourceDeviceID: "mac-mini",
            runner: runner,
            now: { Date(timeIntervalSince1970: 1_000) },
            receiptID: { "host-receipt" }
        )

        let reconnect = host.requestReconnect(correlationID: "reconnect")
        let snapshot = host.hostActivitySnapshot()
        let promotion = host.rejectAuthorityPromotion(
            correlationID: "promote"
        )

        XCTAssertTrue(reconnect.accepted)
        XCTAssertEqual(snapshot.connectionState, .connected)
        XCTAssertFalse(snapshot.dataPlaneEligible)
        XCTAssertEqual(snapshot.authorityPromotionCount, 0)
        XCTAssertEqual(snapshot.domainTruthWriteCount, 0)
        XCTAssertEqual(snapshot.updateTriggerCount, 0)
        XCTAssertFalse(promotion.accepted)
        XCTAssertEqual(promotion.authorityPromotionCount, 0)
    }

    func testRunnerHostStateNeverCreatesDomainTruthOrTriggersUpdate() throws {
        let runner = TatwoRunnerAdapter(
            now: { Date(timeIntervalSince1970: 1_000) },
            receiptID: { "runner-receipt" }
        )
        let host = TatwoHostDaemon(
            hostID: "host-mini",
            sourceDeviceID: "mac-mini",
            runner: runner,
            initiallyConnected: true,
            now: { Date(timeIntervalSince1970: 1_000) },
            receiptID: { "host-receipt" }
        )
        let request = TatwoHostSessionRequestV1(
            sessionID: "session-1",
            correlationID: "start",
            sourceDeviceID: "mac-mini",
            sandboxReference: "sandbox/session-1",
            worktreeReference: "worktree/session-1"
        )

        let started = host.startLocalSession(request)
        XCTAssertTrue(started.accepted)
        XCTAssertEqual(started.authorityPromotionCount, 0)
        XCTAssertEqual(started.domainTruthWriteCount, 0)
        XCTAssertEqual(started.updateTriggerCount, 0)
        XCTAssertEqual(started.runnerReceipt?.domainTruthWriteCount, 0)
        XCTAssertEqual(started.runnerReceipt?.updateTriggerCount, 0)

        let activity = try XCTUnwrap(runner.activitySnapshot().first)
        let boundary = runner.rejectDomainEventEncoding(
            activity: activity,
            correlationID: "domain-boundary",
            sourceDeviceID: "mac-mini"
        )
        XCTAssertFalse(boundary.allowed)
        XCTAssertEqual(boundary.domainTruthWriteCount, 0)
        XCTAssertEqual(boundary.updateTriggerCount, 0)
    }

    func testHealthSnapshotCannotInvokeCommand() {
        let runner = CountingRunner()
        let host = TatwoHostDaemon(
            hostID: "host-mini",
            sourceDeviceID: "mac-mini",
            runner: runner,
            initiallyConnected: true,
            now: { Date(timeIntervalSince1970: 1_000) },
            receiptID: { "host-receipt" }
        )

        _ = host.hostActivitySnapshot()
        _ = host.hostActivitySnapshot()

        XCTAssertEqual(runner.startCount, 0)
        XCTAssertEqual(runner.resumeCount, 0)
        XCTAssertEqual(runner.cancelCount, 0)
        XCTAssertEqual(runner.subscribeCount, 2)
    }
}

private final class CountingRunner: TatwoRunnerAdapterCommandPort {
    private(set) var startCount = 0
    private(set) var resumeCount = 0
    private(set) var cancelCount = 0
    private(set) var subscribeCount = 0

    func start(
        _ request: TatwoRunnerSessionRequestV1
    ) -> TatwoRunnerCommandReceiptV1 {
        startCount += 1
        return receipt(request: request)
    }

    func resume(
        _ request: TatwoRunnerSessionRequestV1
    ) -> TatwoRunnerCommandReceiptV1 {
        resumeCount += 1
        return receipt(request: request)
    }

    func cancel(
        _ request: TatwoRunnerSessionRequestV1
    ) -> TatwoRunnerCommandReceiptV1 {
        cancelCount += 1
        return receipt(request: request)
    }

    func subscribeLocalEvents() -> [TatwoRunnerActivityProjectionV1] {
        subscribeCount += 1
        return []
    }

    private func receipt(
        request: TatwoRunnerSessionRequestV1
    ) -> TatwoRunnerCommandReceiptV1 {
        TatwoRunnerCommandReceiptV1(
            metadata: .init(
                receiptID: "counting-runner",
                schema: "TatwoRunnerCommandReceiptV1",
                version: 1,
                correlationID: request.correlationID,
                createdAt: Date(timeIntervalSince1970: 1_000),
                sourceDeviceID: request.sourceDeviceID
            ),
            accepted: true,
            activity: nil,
            processMutationCount: 0,
            detail: "test"
        )
    }
}
