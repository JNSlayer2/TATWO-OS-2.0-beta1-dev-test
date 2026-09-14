import Foundation
import XCTest
@testable import TatwoUpdater

final class TatwoAppVersionAlignmentPlannerTests: XCTestCase {
    private let planner = TatwoAppVersionAlignmentPlannerV1()
    private let fixedDate = Date(timeIntervalSince1970: 1_721_606_400)

    func testSecondaryWithCompleteConfigurationBuildsDryRunPlanAndReceipt() {
        let plan = planner.plan(
            configuration: completeConfiguration,
            localRole: .secondary
        )

        XCTAssertTrue(plan.isValid)
        XCTAssertFalse(plan.executionAllowed)
        XCTAssertNil(plan.rejectionReason)
        XCTAssertEqual(
            plan.rsyncSource,
            "builder@mini.lan:/srv/tatwo/TatwoUltrawork.app"
        )
        XCTAssertEqual(
            plan.rsyncDestination,
            "/Users/example/Applications/.TatwoUltrawork-alignment-staging.app"
        )
        XCTAssertEqual(
            plan.stagingPath,
            "/Users/example/Applications/.TatwoUltrawork-alignment-staging.app"
        )
        XCTAssertEqual(
            plan.rollbackBackupPath,
            "/Users/example/Applications/.TatwoUltrawork-alignment-backups/TatwoUltrawork-previous.app"
        )
        XCTAssertEqual(
            plan.steps.map(\.kind),
            [.rsync, .staging, .atomicSwap, .relaunch, .backup]
        )
        XCTAssertTrue(
            plan.steps.allSatisfy {
                !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        )

        let receipt = planner.receipt(for: plan, observedAt: fixedDate)
        XCTAssertEqual(receipt.observedAt, fixedDate)
        XCTAssertTrue(receipt.dryRun)
        XCTAssertEqual(receipt.planHash.count, 64)
        XCTAssertTrue(receipt.planHash.allSatisfy(\.isHexDigit))
    }

    func testPrimaryDeviceIsRejected() {
        let plan = planner.plan(
            configuration: completeConfiguration,
            localRole: .primary
        )

        XCTAssertFalse(plan.isValid)
        XCTAssertFalse(plan.executionAllowed)
        XCTAssertEqual(plan.rejectionReason, .localDeviceIsNotSecondary)
        XCTAssertTrue(plan.steps.isEmpty)
    }

    func testMissingEnvironmentConfigurationIsRejected() {
        let plan = planner.plan(
            environment: [
                TatwoAppVersionAlignmentEnvironmentV1.primarySSHHostKey: "builder@mini.lan"
            ],
            localRole: .secondary
        )

        XCTAssertFalse(plan.isValid)
        XCTAssertFalse(plan.executionAllowed)
        XCTAssertEqual(plan.rejectionReason, .configurationMissing)
        XCTAssertTrue(plan.refusalDescription.contains("未設定，無法對齊"))
    }

    func testLoopbackSourceIsRejectedAsLocal() {
        let plan = planner.plan(
            configuration: .init(
                primarySSHHost: "localhost",
                primaryAppPath: "/srv/tatwo/TatwoUltrawork.app",
                localAppPath: "/Users/example/Applications/TatwoUltrawork.app"
            ),
            localRole: .secondary
        )

        XCTAssertFalse(plan.isValid)
        XCTAssertFalse(plan.executionAllowed)
        XCTAssertEqual(plan.rejectionReason, .primarySourceIsLocal)
        XCTAssertTrue(plan.steps.isEmpty)
    }

    private var completeConfiguration: TatwoAppVersionAlignmentConfigurationV1 {
        .init(
            primarySSHHost: "builder@mini.lan",
            primaryAppPath: "/srv/tatwo/TatwoUltrawork.app",
            localAppPath: "/Users/example/Applications/TatwoUltrawork.app"
        )
    }
}
