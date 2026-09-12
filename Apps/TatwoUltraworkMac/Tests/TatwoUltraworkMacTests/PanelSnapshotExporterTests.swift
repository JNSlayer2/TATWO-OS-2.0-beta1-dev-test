import AppKit
import SwiftUI
import XCTest
@testable import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class PanelSnapshotExporterTests: XCTestCase {
    @MainActor
    func testPrimeAsyncContentTriggersAppearanceBeforeTheSettleWindow() throws {
        let probe = SnapshotAppearanceProbe()
        let view = NSHostingView(
            rootView: SnapshotAppearanceProbeView(probe: probe)
        )
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)

        XCTAssertFalse(probe.didAppear)

        try TatwoPanelSnapshotExporter.primeAsyncContent(in: view)

        XCTAssertTrue(probe.didAppear)
    }

    @MainActor
    func testAsyncSettleWindowAllowsLargeRepositoryViewsToFinish() {
        XCTAssertEqual(
            TatwoPanelSnapshotExporter.boundedAsyncSettleMilliseconds(15_000),
            15_000
        )
        XCTAssertEqual(
            TatwoPanelSnapshotExporter.boundedAsyncSettleMilliseconds(45_000),
            30_000
        )
        XCTAssertEqual(
            TatwoPanelSnapshotExporter.boundedAsyncSettleMilliseconds(-1),
            0
        )
    }

    func testExportScaleOverrideDefaultsAndClamps() {
        XCTAssertEqual(
            TatwoPanelSnapshotExporter.exportScaleOverride(env: [:]),
            1)
        XCTAssertEqual(
            TatwoPanelSnapshotExporter.exportScaleOverride(env: [
                "TATWO_ULTRAWORK_EXPORT_SCALE": "2",
            ]),
            2)
        XCTAssertEqual(
            TatwoPanelSnapshotExporter.exportScaleOverride(env: [
                "TATWO_ULTRAWORK_EXPORT_SCALE": "99",
            ]),
            4)
        XCTAssertEqual(
            TatwoPanelSnapshotExporter.exportScaleOverride(env: [
                "TATWO_ULTRAWORK_EXPORT_SCALE": "not-a-number",
            ]),
            1)
    }

    @MainActor
    func testWorkflowGraphContractRefusesInvalidCurrentSessionProjection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(directoryURL: root)
        let sessionStore = TatwoSessionStore(directoryURL: root)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID: "coding",
            objective: "workflow export continuity",
            store: goalStore
        )
        try sessionStore.writeRawPointerFixtureForTesting(
            TatwoSessionPointer(
                schema: "TatwoSessionPointerV0",
                contractID: contract.contractID,
                goalID: contract.goalID,
                mode: contract.mode,
                scenario: contract.scenario,
                objective: contract.objective
            )
        )
        let snapshot = TatwoAppSnapshotFactory.make(
            preferences: TatwoUserPreferences(
                selectedMode: .m,
                selectedScenario: .daily
            ),
            probe: .emptyForTests,
            goalRunStore: goalStore,
            sessionStore: sessionStore,
            dispatchRegistry: TatwoDispatchRegistry(directoryURL: root)
        )

        XCTAssertThrowsError(
            try TatwoPanelSnapshotExporter.resolveWorkflowGraphContract(
                snapshot: snapshot,
                goalRunStore: goalStore,
                sessionStore: sessionStore
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSessionAttachmentError,
                .unsupportedPointerSchema("TatwoSessionPointerV0")
            )
        }
    }

    @MainActor
    func testWorkflowGraphContractUsesSameCustomScenarioBookAsModesAuthority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let authorityRoot = root.appendingPathComponent("authority", isDirectory: true)
        let snapshotRoot = root.appendingPathComponent("snapshot", isDirectory: true)
        try FileManager.default.createDirectory(
            at: authorityRoot,
            withIntermediateDirectories: true)
        let goalStore = TatwoGoalRunStore(directoryURL: authorityRoot)
        let sessionStore = TatwoSessionStore(directoryURL: authorityRoot)
        var scenarioBook = TatwoScenarioConfigDefaults.book
        var customScenario = try XCTUnwrap(
            scenarioBook.scenarios.first(where: { $0.baseScenario == .coding })
        )
        customScenario.id = "custom-export-authority"
        customScenario.displayName = "Custom Export Authority"
        customScenario.builtin = false
        scenarioBook.scenarios.append(customScenario)

        let dispatchRegistry = TatwoDispatchRegistry(
            directoryURL: authorityRoot)
        let owner = TatwoSessionOwnerExpectationV1(
            provider: "tatwo-app-test",
            externalProviderSessionID: "panel-snapshot-exporter",
            workspacePath: authorityRoot.path)
        let proposed = try WorkOSFactory.projectContract(
            mode: .xxl,
            scenarioProfileID: customScenario.id,
            objective: "workflow export exact custom authority",
            scenarioBook: scenarioBook)
        _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
            goalStoreRoot: authorityRoot,
            contractID: proposed.contractID)
        let attachment = try sessionStore.beginCurrent(
            mode: .xxl,
            scenarioProfileID: customScenario.id,
            objective: "workflow export exact custom authority",
            scenarioBook: scenarioBook,
            owner: .session(owner),
            goalStore: goalStore,
            dispatchRegistry: dispatchRegistry
        )
        let snapshotGoalStore = TatwoGoalRunStore(directoryURL: snapshotRoot)
        let snapshot = TatwoAppSnapshotFactory.make(
            preferences: TatwoUserPreferences(
                selectedMode: .m,
                selectedScenario: .daily
            ),
            probe: .emptyForTests,
            goalRunStore: snapshotGoalStore,
            sessionStore: TatwoSessionStore(directoryURL: snapshotRoot),
            dispatchRegistry: TatwoDispatchRegistry(directoryURL: snapshotRoot)
        )

        let resolved = try TatwoPanelSnapshotExporter.resolveWorkflowGraphContract(
            snapshot: snapshot,
            goalRunStore: goalStore,
            sessionStore: sessionStore,
            environment: [:],
            scenarioBook: scenarioBook
        )

        XCTAssertEqual(resolved.contractID, attachment.contract.contractID)
        XCTAssertEqual(resolved.goalID, attachment.contract.goalID)
        XCTAssertEqual(resolved.mode, .xxl)
        XCTAssertEqual(resolved.scenario, customScenario.id)
    }
}

@MainActor
private final class SnapshotAppearanceProbe: ObservableObject {
    @Published var didAppear = false
}

private struct SnapshotAppearanceProbeView: View {
    @ObservedObject var probe: SnapshotAppearanceProbe

    var body: some View {
        Color.clear
            .onAppear {
                probe.didAppear = true
            }
    }
}
