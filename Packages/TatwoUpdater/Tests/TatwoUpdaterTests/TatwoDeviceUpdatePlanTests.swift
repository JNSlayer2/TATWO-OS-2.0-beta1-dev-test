import Foundation
import XCTest
import TatwoModuleContracts
@testable import TatwoUpdater

final class TatwoDeviceUpdatePlanTests: XCTestCase {
    func testApprovedPlanOrdersSecondariesFirstAndSkipsEachIneligibleDeviceIndependently() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let fixture = try makePersistence("ordering")
        let coordinator = try TatwoDeviceUpdatePlanCoordinator(persistence: fixture.persistence)
        let primary = device("mini", role: .primary, now: now)
        let healthySecondary = device("book", role: .secondary, now: now)
        let offline = device("offline", role: .secondary, now: now, isOnline: false)
        let stale = device(
            "stale",
            role: .secondary,
            now: now.addingTimeInterval(-500)
        )
        let unhealthy = device("unhealthy", role: .secondary, now: now, isHealthy: false)
        let schemaMismatch = device(
            "schema",
            role: .secondary,
            now: now,
            schemaVersion: 2
        )
        let noRollback = device(
            "no-rollback",
            role: .secondary,
            now: now,
            hasRollback: false
        )
        let selected = [
            primary,
            noRollback,
            healthySecondary,
            schemaMismatch,
            offline,
            unhealthy,
            stale
        ]

        let created = try coordinator.createPlan(
            .init(
                planID: "plan-1",
                domainID: "domain-1",
                channel: .internalCanary,
                artifact: artifact(),
                selectedDevices: selected,
                createdAt: now
            )
        )
        XCTAssertEqual(created.status, .awaitingApproval)

        let approved = try coordinator.approvePlan(
            .init(
                planID: "plan-1",
                userApproved: true,
                deviceSnapshots: selected,
                observedAt: now
            )
        )

        XCTAssertEqual(approved.steps.last?.deviceID, "mini")
        XCTAssertEqual(approved.steps.last?.role, .primary)
        XCTAssertEqual(approved.status, .partiallyEligible)
        XCTAssertEqual(coordinator.nextEligibleDeviceID(planID: "plan-1"), "book")
        XCTAssertEqual(reason("offline", in: approved), .offline)
        XCTAssertEqual(reason("stale", in: approved), .staleHeartbeat)
        XCTAssertEqual(reason("unhealthy", in: approved), .unhealthy)
        XCTAssertEqual(reason("schema", in: approved), .schemaMismatch)
        XCTAssertEqual(reason("no-rollback", in: approved), .rollbackUnavailable)
        XCTAssertEqual(reason("book", in: approved), TatwoDeviceUpdateSkipReasonV1.none)
        XCTAssertEqual(reason("mini", in: approved), TatwoDeviceUpdateSkipReasonV1.none)
    }

    func testSingleApprovalSurvivesRestartAndEachDeviceMustRepreflight() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let fixture = try makePersistence("restart")
        let offlineBook = device("book", role: .secondary, now: now, isOnline: false)
        let mini = device("mini", role: .primary, now: now)

        do {
            let first = try TatwoDeviceUpdatePlanCoordinator(persistence: fixture.persistence)
            _ = try first.createPlan(
                .init(
                    planID: "plan-restart",
                    domainID: "domain-1",
                    channel: .internalCanary,
                    artifact: artifact(),
                    selectedDevices: [mini, offlineBook],
                    createdAt: now
                )
            )
            let approved = try first.approvePlan(
                .init(
                    planID: "plan-restart",
                    userApproved: true,
                    deviceSnapshots: [mini, offlineBook],
                    observedAt: now
                )
            )
            XCTAssertEqual(reason("book", in: approved), .offline)
        }

        let reopenedPersistence = try TatwoFileBackedDeviceUpdatePlanPersistence(
            rootURL: fixture.root
        )
        let reopened = try TatwoDeviceUpdatePlanCoordinator(persistence: reopenedPersistence)
        XCTAssertNotNil(reopened.deviceUpdatePlan(planID: "plan-restart")?.approvedAt)
        XCTAssertThrowsError(
            try reopened.approvePlan(
                .init(
                    planID: "plan-restart",
                    userApproved: true,
                    deviceSnapshots: [mini, offlineBook],
                    observedAt: now
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoDeviceUpdatePlanError,
                .planAlreadyApproved("plan-restart")
            )
        }

        let refreshed = try reopened.revalidateDevice(
            planID: "plan-restart",
            snapshot: device("book", role: .secondary, now: now.addingTimeInterval(10)),
            observedAt: now.addingTimeInterval(10)
        )
        XCTAssertEqual(reason("book", in: refreshed), TatwoDeviceUpdateSkipReasonV1.none)
        XCTAssertEqual(reopened.nextEligibleDeviceID(planID: "plan-restart"), "book")
    }

    func testExecutionRemainsSecondaryFirstAndPrimaryLast() throws {
        let now = Date(timeIntervalSince1970: 30_000)
        let fixture = try makePersistence("execution-order")
        let coordinator = try TatwoDeviceUpdatePlanCoordinator(persistence: fixture.persistence)
        let book = device("book", role: .secondary, now: now)
        let mini = device("mini", role: .primary, now: now)
        _ = try coordinator.createPlan(
            .init(
                planID: "plan-order",
                domainID: "domain-1",
                channel: .internalCanary,
                artifact: artifact(),
                selectedDevices: [mini, book],
                createdAt: now
            )
        )
        _ = try coordinator.approvePlan(
            .init(
                planID: "plan-order",
                userApproved: true,
                deviceSnapshots: [mini, book],
                observedAt: now
            )
        )

        XCTAssertEqual(coordinator.nextEligibleDeviceID(planID: "plan-order"), "book")
        let afterBook = try coordinator.recordDeviceOutcome(
            planID: "plan-order",
            deviceID: "book",
            outcome: .installed,
            detail: "book healthy",
            observedAt: now.addingTimeInterval(1)
        )
        XCTAssertEqual(afterBook.status, .inProgress)
        XCTAssertEqual(coordinator.nextEligibleDeviceID(planID: "plan-order"), "mini")

        let completed = try coordinator.recordDeviceOutcome(
            planID: "plan-order",
            deviceID: "mini",
            outcome: .installed,
            detail: "mini healthy",
            observedAt: now.addingTimeInterval(2)
        )
        XCTAssertEqual(completed.status, .completed)
        XCTAssertNil(coordinator.nextEligibleDeviceID(planID: "plan-order"))
    }

    func testHashChainTamperFailsClosedAcrossRestart() throws {
        let now = Date(timeIntervalSince1970: 40_000)
        let fixture = try makePersistence("tamper")
        let coordinator = try TatwoDeviceUpdatePlanCoordinator(persistence: fixture.persistence)
        let selected = [device("mini", role: .primary, now: now)]
        _ = try coordinator.createPlan(
            .init(
                planID: "plan-tamper",
                domainID: "domain-1",
                channel: .internalCanary,
                artifact: artifact(),
                selectedDevices: selected,
                createdAt: now
            )
        )
        _ = try coordinator.approvePlan(
            .init(
                planID: "plan-tamper",
                userApproved: true,
                deviceSnapshots: selected,
                observedAt: now
            )
        )

        let log = fixture.root.appendingPathComponent("device-update-plans.v1.jsonl")
        var text = try String(contentsOf: log, encoding: .utf8)
        text = text.replacingOccurrences(of: "domain-1", with: "domain-X")
        try text.write(to: log, atomically: true, encoding: .utf8)

        let reopened = try TatwoFileBackedDeviceUpdatePlanPersistence(rootURL: fixture.root)
        XCTAssertThrowsError(try reopened.loadValidatedRecords()) { error in
            guard case TatwoDeviceUpdatePlanPersistenceError.invalidPayloadHash = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func reason(
        _ deviceID: String,
        in plan: TatwoDeviceUpdatePlanV1
    ) -> TatwoDeviceUpdateSkipReasonV1? {
        plan.steps.first(where: { $0.deviceID == deviceID })?.skipReason
    }

    private func device(
        _ id: String,
        role: TatwoDeviceUpdateRoleV1,
        now: Date,
        isOnline: Bool = true,
        isHealthy: Bool = true,
        schemaVersion: Int = 1,
        protocolVersion: Int = 1,
        hasRollback: Bool = true
    ) -> TatwoDeviceUpdatePreflightSnapshotV1 {
        .init(
            deviceID: id,
            role: role,
            enrolledChannel: .internalCanary,
            currentVersion: .init(major: 1, minor: 0, patch: 0),
            schemaVersion: schemaVersion,
            protocolVersion: protocolVersion,
            isOnline: isOnline,
            isHealthy: isHealthy,
            lastSeenAt: now,
            hasVerifiedRollbackBundle: hasRollback
        )
    }

    private func artifact() -> TatwoUpdateArtifactMetadataV1 {
        .init(
            version: .init(major: 2, minor: 0, patch: 0),
            channel: .internalCanary,
            artifactURL: "https://updates.invalid/Tatwo.zip",
            artifactSHA256: String(repeating: "a", count: 64),
            sparkleEdDSASignature: "eddsa",
            developerIDTeamID: "TEAMID",
            notarizationTicketID: "ticket",
            sourceCommit: String(repeating: "b", count: 40),
            schemaVersion: 1,
            protocolVersion: 1,
            rollbackTargetVersion: .init(major: 1, minor: 0, patch: 0),
            publishedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makePersistence(
        _ label: String
    ) throws -> (root: URL, persistence: TatwoFileBackedDeviceUpdatePlanPersistence) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-device-update-\(label)-\(UUID().uuidString)")
        let persistence = try TatwoFileBackedDeviceUpdatePlanPersistence(
            rootURL: root,
            createRootIfMissing: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (root, persistence)
    }
}
