import Foundation
import XCTest

@testable import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class ModesScenarioAuthorityTests: XCTestCase {
    func testCustomPreviewIsRetainedIndependentlyOfIssuedSession() throws {
        let fixture = try customScenarioFixture()
        let issued = try WorkOSFactory.preview(
            mode: .m,
            scenarioProfileID: "coding",
            objective: "issued coding session"
        )

        let presentation = ModesScenarioAuthorityPresentation.make(
            previewMode: .xxl,
            previewScenarioProfileID: fixture.scenarioID,
            scenarioBook: fixture.book,
            issuedContract: issued,
            issuedIntegrityState: .validated
        )

        XCTAssertEqual(presentation.previewScenarioProfileID, fixture.scenarioID)
        XCTAssertEqual(presentation.previewContract?.scenario, fixture.scenarioID)
        XCTAssertEqual(presentation.issuedContract?.scenario, "coding")
    }

    func testIssuedMismatchDoesNotOverwritePreview() throws {
        let fixture = try customScenarioFixture()
        let issued = try WorkOSFactory.preview(
            mode: .s,
            scenarioProfileID: "daily",
            objective: "issued daily session"
        )

        let presentation = ModesScenarioAuthorityPresentation.make(
            previewMode: .xxl,
            previewScenarioProfileID: fixture.scenarioID,
            scenarioBook: fixture.book,
            issuedContract: issued,
            issuedIntegrityState: .validated
        )

        XCTAssertEqual(presentation.previewContract?.mode, .xxl)
        XCTAssertEqual(presentation.previewContract?.scenario, fixture.scenarioID)
        XCTAssertEqual(presentation.issuedContract, issued)
        XCTAssertNotNil(presentation.mismatchMessage)
    }

    func testBlockedIntegrityDropsIssuedContractFailClosed() throws {
        let issued = try WorkOSFactory.preview(
            mode: .l,
            scenarioProfileID: "coding",
            objective: "invalid pointer fixture"
        )

        let presentation = ModesScenarioAuthorityPresentation.make(
            previewMode: .m,
            previewScenarioProfileID: "daily",
            scenarioBook: TatwoScenarioConfigDefaults.book,
            issuedContract: issued,
            issuedIntegrityState: .blocked("invalid pointer")
        )

        XCTAssertNil(presentation.issuedContract)
        XCTAssertEqual(
            presentation.issuedIntegrityState,
            .blocked("invalid pointer")
        )
        XCTAssertEqual(presentation.previewContract?.scenario, "daily")
        XCTAssertFalse(presentation.canRequestGoalRevision)
    }

    func testRevisionRequiredRetainsIssuedContractAndEnablesRevision() throws {
        let issued = try WorkOSFactory.preview(
            mode: .xxl,
            scenarioProfileID: "coding",
            objective: "issued contract requires topology revision"
        )

        let presentation = ModesScenarioAuthorityPresentation.make(
            previewMode: .xxl,
            previewScenarioProfileID: "coding",
            scenarioBook: TatwoScenarioConfigDefaults.book,
            issuedContract: issued,
            issuedIntegrityState: .revisionRequired("binding drift")
        )

        XCTAssertEqual(presentation.issuedContract, issued)
        XCTAssertEqual(
            presentation.issuedIntegrityState,
            .revisionRequired("binding drift"))
        XCTAssertTrue(presentation.canRequestGoalRevision)
    }

    func testNoPointerStillProducesPreview() {
        let presentation = ModesScenarioAuthorityPresentation.make(
            previewMode: .m,
            previewScenarioProfileID: "daily",
            scenarioBook: TatwoScenarioConfigDefaults.book,
            issuedContract: nil,
            issuedIntegrityState: .noPointer
        )

        XCTAssertNotNil(presentation.previewContract)
        XCTAssertNotNil(presentation.previewModePlan)
        XCTAssertNil(presentation.issuedContract)
        XCTAssertNil(presentation.mismatchMessage)
    }

    func testIssuedAuthorityResolverFailsClosedForInvalidPointer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(directoryURL: root)
        let sessionStore = TatwoSessionStore(directoryURL: root)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .l,
            scenarioProfileID: "coding",
            objective: "invalid issued pointer fixture",
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

        let result = TatwoModesIssuedAuthorityResolver.resolve(
            environment: [:],
            goalStore: goalStore,
            sessionStore: sessionStore,
            scenarioBook: TatwoScenarioConfigDefaults.book
        )

        XCTAssertNil(result.contract)
        guard case .blocked = result.integrityState else {
            return XCTFail("invalid current-session pointer must be blocked")
        }
    }

    func testIssuedAuthorityResolverReturnsExactValidatedContract() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(directoryURL: root)
        let sessionStore = TatwoSessionStore(directoryURL: root)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xl,
            scenarioProfileID: "coding",
            objective: "exact issued contract fixture",
            store: goalStore
        )
        try sessionStore.writeRawPointerFixtureForTesting(
            TatwoSessionPointer(
                contractID: contract.contractID,
                goalID: contract.goalID,
                mode: contract.mode,
                scenario: contract.scenario,
                objective: contract.objective
            )
        )

        let result = TatwoModesIssuedAuthorityResolver.resolve(
            environment: [:],
            goalStore: goalStore,
            sessionStore: sessionStore,
            scenarioBook: TatwoScenarioConfigDefaults.book
        )

        XCTAssertEqual(result.integrityState, .validated)
        XCTAssertEqual(result.contract?.contractID, contract.contractID)
        XCTAssertEqual(result.contract?.goalID, contract.goalID)
        XCTAssertEqual(result.contract?.mode, .xl)
        XCTAssertEqual(result.contract?.scenario, "coding")
    }

    func testModesPageSourceContainsNoBegin() throws {
        let source = try String(contentsOf: appSourceURL("ModesPage.swift"))

        XCTAssertTrue(source.contains("WorkOSFactory.preview("))
        XCTAssertTrue(source.contains("WorkOSFactory.previewModePlan("))
        XCTAssertFalse(source.contains("WorkOSFactory.projectContract("))
    }

    func testShellOwnsExactScenarioBindingAndInspectsIssuedSessionReadOnly() throws {
        let shellSource = try String(contentsOf: appSourceURL("AppShell.swift"))
        let modesSource = try String(contentsOf: appSourceURL("ModesPage.swift"))
        let scenarioSource = try String(contentsOf: appSourceURL("ScenarioPage.swift"))

        XCTAssertTrue(shellSource.contains("@State private var previewScenarioProfileID"))
        XCTAssertTrue(shellSource.contains("resolvedSessionStore.snapshotCurrent()"))
        XCTAssertTrue(
            shellSource.contains(
                "TatwoGoalRevisionPredecessorResolver.resolve("))
        XCTAssertTrue(
            shellSource.contains(
                "previewScenarioProfileID: $previewScenarioProfileID"))
        // 2026-08-20 三分頁收斂：Modes/Scenarios 併入單一配置總覽，共用
        // 綁定合約由「兩個呼叫點」改為「一頁接收同一 AppShell 綁定」。
        let overviewSource = try String(
            contentsOf: appSourceURL("TatwoConfigOverviewPage.swift"))
        XCTAssertTrue(
            overviewSource.contains("@Binding var previewScenarioProfileID"),
            "merged overview must receive the AppShell-owned scenario binding")
        XCTAssertTrue(
            modesSource.contains(
                "@Binding var previewScenarioProfileID"))
        XCTAssertTrue(
            modesSource.contains(
                "\"modes-preview-scenario-picker\""))
        XCTAssertTrue(
            modesSource.contains(
                "selection: previewScenarioBinding"))
        XCTAssertTrue(
            scenarioSource.contains(
                "@Binding var previewScenarioProfileID"))
        XCTAssertFalse(
            scenarioSource.contains(
                "@State private var selectedConfigScenarioID"))
    }

    func testAllReadOnlyPreviewSurfacesStayBeginFree() throws {
        let shellSource = try String(contentsOf: appSourceURL("AppShell.swift"))
        let scenarioSource = try String(contentsOf: appSourceURL("ScenarioPage.swift"))

        XCTAssertTrue(
            shellSource.contains(
                "TatwoGoalRevisionPredecessorResolver.resolve("))
        XCTAssertTrue(
            shellSource.contains(
                "return try WorkOSFactory.preview("))
        XCTAssertFalse(shellSource.contains("WorkOSFactory.projectContract("))
        XCTAssertTrue(
            scenarioSource.contains(
                "ScenarioWorkflowContractFactory.make("))
        XCTAssertFalse(scenarioSource.contains("WorkOSFactory.projectContract("))
    }

    private func customScenarioFixture() throws -> (
        book: TatwoScenarioConfigBookV1,
        scenarioID: String
    ) {
        var book = TatwoScenarioConfigDefaults.book
        var custom = try XCTUnwrap(
            book.scenarios.first(where: { $0.baseScenario == .coding })
        )
        custom.id = "custom-preview-coding"
        custom.displayName = "Coding Preview Copy"
        custom.builtin = false
        book.scenarios.append(custom)
        return (book, custom.id)
    }

    private func appSourceURL(_ filename: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TatwoUltraworkMac")
            .appendingPathComponent(filename)
    }
}
