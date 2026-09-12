import XCTest

@testable import TatwoUltraworkCore

final class AppSnapshotTests: XCTestCase {
  func testAppSnapshotCombinesSelectedModeWorkflowTeamsAndEnvironmentForAppFirstReview() throws {
    let root = try makeFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = TatwoUserPreferences(selectedMode: .xl, selectedScenario: .design)
    let stateRoot = root.appendingPathComponent("state", isDirectory: true)

    let snapshot = TatwoAppSnapshotFactory.make(
      preferences: preferences,
      probe: TatwoEnvironmentProbe(
        projectRoot: root.appendingPathComponent("project"),
        skillRoot: root.appendingPathComponent("skills"),
        archiveRoot: root.appendingPathComponent("archives/tatwo-ultrawork-legacy-current"),
        gatewayRoot: root.appendingPathComponent("gateway")
      ),
      goalRunStore: TatwoGoalRunStore(directoryURL: stateRoot),
      sessionStore: TatwoSessionStore(directoryURL: stateRoot),
      dispatchRegistry: TatwoDispatchRegistry(directoryURL: stateRoot)
    )

    XCTAssertEqual(snapshot.schema, "TatwoAppSnapshotV1")
    XCTAssertEqual(snapshot.phase, .appFirstReview)
    XCTAssertEqual(snapshot.selectedMode, .xl)
    XCTAssertEqual(snapshot.selectedScenario, .design)
    XCTAssertFalse(snapshot.hostMutationAllowed)
    XCTAssertFalse(snapshot.skillSyncAllowed)
    XCTAssertFalse(snapshot.mcpSyncAllowed)
    XCTAssertEqual(snapshot.catalog.workModes.map(\.mode), [.s, .m, .l, .xl, .xxl])
    XCTAssertEqual(snapshot.workflow.mode, .xl)
    XCTAssertEqual(snapshot.workflow.scenario, .design)
    XCTAssertEqual(snapshot.workOSDashboard.schema, "TatwoWorkOSDashboardSnapshotV1")
    XCTAssertEqual(snapshot.workOSDashboard.goal.mode, .xl)
    XCTAssertTrue(snapshot.workOSDashboard.readOnly)
    XCTAssertFalse(snapshot.workOSDashboard.canPromoteRunState)
    XCTAssertTrue(snapshot.plainSummary.contains("規劃預覽"))
    XCTAssertTrue(snapshot.plainSummary.contains("尚未派發"))
    XCTAssertTrue(snapshot.plainSummary.contains("無 runtime receipt"))
    XCTAssertTrue(snapshot.workOSDashboard.outcome.readyLabel.contains("READY"))
    XCTAssertTrue(snapshot.workOSDashboard.outcome.rollbackLabel.contains("ROLLBACK"))
    XCTAssertTrue(snapshot.workflow.nodes.contains { $0.kind == .sandbox })
    XCTAssertTrue(
      snapshot.workflowPlan.gates.contains {
        $0.id.contains("visual")
          || $0.requiredBeforePass.contains { $0.contains("screenshot") || $0.contains("visual") }
      })
    XCTAssertEqual(snapshot.teamDashboard.scenario, .design)
    XCTAssertTrue(snapshot.teamDashboard.selectedTeams.contains { $0.team.id == "design-team" })
    XCTAssertTrue(
      snapshot.environment.components.contains { $0.id == "tatwo-skill" && $0.status == .installed }
    )
    XCTAssertTrue(
      snapshot.environment.components.contains {
        $0.id == "colima-sandbox-runner" && $0.severity == .medium
      })
    XCTAssertTrue(
      snapshot.environment.safeRefreshCommands.contains { $0.contains("colima preflight") })
    XCTAssertTrue(snapshot.discussionPrompts.contains { $0.contains("UI") || $0.contains("驗收") })
  }

  func testEnvironmentSnapshotMarksArchivedLegacyAndActiveLegacySkillAbsenceAsHealthy() throws {
    let root = try makeFixtureRoot()
    let snapshot = TatwoAppSnapshotFactory.make(
      preferences: TatwoUserPreferences(selectedMode: .m, selectedScenario: .coding),
      probe: TatwoEnvironmentProbe(
        projectRoot: root.appendingPathComponent("project"),
        skillRoot: root.appendingPathComponent("skills"),
        archiveRoot: root.appendingPathComponent("archives/tatwo-ultrawork-legacy-current"),
        gatewayRoot: root.appendingPathComponent("gateway")
      )
    )

    let activeOpen = try XCTUnwrap(
      snapshot.environment.components.first { $0.id == "legacy-open-active-hidden" })
    XCTAssertEqual(activeOpen.status, .installed)
    XCTAssertTrue(
      activeOpen.plainStatus.contains("不出現在主線選單")
        || activeOpen.plainStatus.contains("回滾參考"))

    let archiveGateway = try XCTUnwrap(
      snapshot.environment.components.first { $0.id == "legacy-gateway-archive" })
    XCTAssertEqual(archiveGateway.status, .installed)
    XCTAssertTrue(
      archiveGateway.nextAction.contains("回滾") || archiveGateway.nextAction.contains("對照"))
  }

  func testSnapshotKeepsSyncDeferredUntilAppReviewProducesAdjustmentPlan() throws {
    let root = try makeFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state", isDirectory: true)
    let snapshot = TatwoAppSnapshotFactory.make(
      preferences: TatwoUserPreferences(selectedMode: .xl, selectedScenario: .coding),
      probe: .emptyForTests,
      goalRunStore: TatwoGoalRunStore(directoryURL: stateRoot),
      sessionStore: TatwoSessionStore(directoryURL: stateRoot),
      dispatchRegistry: TatwoDispatchRegistry(directoryURL: stateRoot)
    )

    XCTAssertEqual(snapshot.phase, .appFirstReview)
    XCTAssertFalse(snapshot.skillSyncAllowed)
    XCTAssertFalse(snapshot.mcpSyncAllowed)
    XCTAssertTrue(snapshot.nextBoundaries.contains { $0.contains("先用 App") })
    XCTAssertTrue(snapshot.nextBoundaries.contains { $0.contains("最後再同步") || $0.contains("sync") })
    XCTAssertTrue(snapshot.environment.readOnly)
    XCTAssertTrue(snapshot.workOSDashboard.readOnly)
    XCTAssertTrue(snapshot.workOSDashboard.dashboardRules.contains { $0.contains("Dashboard") })
  }

  func testAppSnapshotUsesStoredSessionStatusAndReceipts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let dispatchRegistry = TatwoDispatchRegistry(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .l,
      scenarioProfileID: "coding",
      objective: "app snapshot stored status",
      store: goalStore)
    let required = contract.receiptRequirements.filter(\.requiredForPass).map(\.id)
    for id in required {
      _ = WorkOSFactory.submitReceipt(
        goalID: contract.goalID,
        contractID: contract.contractID,
        loopID: nil,
        receiptID: id,
        receiptKind: "test",
        store: goalStore)
    }
    try GoalStoreTestSupport.finalizeSuccessfulDispatch(
      contract: contract, store: goalStore, registry: dispatchRegistry)
    let close = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: .l,
      scenarioProfileID: "coding",
      objective: "app snapshot stored status",
      suppliedReceiptIDs: [],
      store: goalStore,
      dispatchRegistry: dispatchRegistry)
    XCTAssertEqual(close.status, .passed)
    try sessionStore.writeRawPointerFixtureForTesting(
      TatwoSessionPointer(
        contractID: contract.contractID,
        goalID: contract.goalID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective))

    let snapshot = TatwoAppSnapshotFactory.make(
      preferences: TatwoUserPreferences(selectedMode: .m, selectedScenario: .daily),
      probe: .emptyForTests,
      goalRunStore: goalStore,
      sessionStore: sessionStore,
      dispatchRegistry: dispatchRegistry)

    XCTAssertEqual(snapshot.workOSDashboard.contract.contractID, contract.contractID)
    XCTAssertEqual(snapshot.workOSDashboard.goal.status, .passed)
    XCTAssertEqual(snapshot.workOSDashboard.goal.mode, .l)
    XCTAssertEqual(snapshot.workOSDashboard.receiptRail.missingCount, 0)
    XCTAssertEqual(
      snapshot.workOSDashboard.lanes.first(where: { $0.id == "goal" })?.status,
      .passed)
  }

  func testInvalidCurrentSessionDoesNotFallbackToSyntheticContract() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let dispatchRegistry = TatwoDispatchRegistry(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "invalid pointer must not mint a replacement",
      store: goalStore)
    try sessionStore.writeRawPointerFixtureForTesting(
      TatwoSessionPointer(
        schema: "TatwoSessionPointerV0",
        contractID: contract.contractID,
        goalID: contract.goalID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective))
    let goalDirectory = root.appendingPathComponent("goals", isDirectory: true)
    let goalFilesBefore = try FileManager.default.contentsOfDirectory(
      at: goalDirectory,
      includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }

    let snapshot = TatwoAppSnapshotFactory.make(
      preferences: TatwoUserPreferences(selectedMode: .m, selectedScenario: .daily),
      probe: .emptyForTests,
      goalRunStore: goalStore,
      sessionStore: sessionStore,
      dispatchRegistry: dispatchRegistry)

    XCTAssertEqual(
      snapshot.workOSDashboard.contract.contractID,
      "current-session-unverifiable")
    XCTAssertEqual(snapshot.workOSDashboard.goal.status, .blocked)
    XCTAssertTrue(snapshot.workOSDashboard.identitySlots.isEmpty)
    XCTAssertTrue(snapshot.workOSDashboard.runningWorkers.isEmpty)
    XCTAssertNotNil(snapshot.workOSDashboard.sessionIntegrityIssue)
    XCTAssertTrue(snapshot.plainSummary.contains("Session 驗證受阻"))
    XCTAssertTrue(snapshot.plainSummary.contains("未建立替代 Goal"))
    let goalFilesAfter = try FileManager.default.contentsOfDirectory(
      at: goalDirectory,
      includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
    XCTAssertEqual(
      goalFilesAfter.map(\.lastPathComponent).sorted(),
      goalFilesBefore.map(\.lastPathComponent).sorted())
  }

  func testAppSnapshotUsesRuntimeDispatchInsteadOfPlannedRowsForProgressWording() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let dispatchRegistry = TatwoDispatchRegistry(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .l,
      scenarioProfileID: "coding",
      objective: "app snapshot runtime truth",
      store: goalStore)
    try sessionStore.writeRawPointerFixtureForTesting(
      TatwoSessionPointer(
        contractID: contract.contractID,
        goalID: contract.goalID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective))
    let binding = try XCTUnwrap(contract.identityBindings.first)
    _ = try dispatchRegistry.begin(
      contractID: contract.contractID,
      goalID: contract.goalID,
      bindingID: binding.id,
      sourceSlotID: binding.sourceSlotID,
      identity: binding.identity,
      modelID: binding.modelID ?? "gpt-5.6-sol",
      subtask: "runtime truth smoke")

    let snapshot = TatwoAppSnapshotFactory.make(
      preferences: TatwoUserPreferences(selectedMode: .m, selectedScenario: .daily),
      probe: .emptyForTests,
      goalRunStore: goalStore,
      sessionStore: sessionStore,
      dispatchRegistry: dispatchRegistry)

    XCTAssertTrue(snapshot.plainSummary.contains("已派發"))
    XCTAssertTrue(snapshot.plainSummary.contains("已排隊"))
    XCTAssertTrue(snapshot.plainSummary.contains("尚未執行"))
    XCTAssertTrue(snapshot.plainSummary.contains("無 runtime receipt"))
    XCTAssertFalse(snapshot.plainSummary.contains("planned agents"))
  }

  func testCurrentProbeDefaultsToAppSupportCacheNotProcessCWD() throws {
    let support = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let probe = TatwoEnvironmentProbe.current(environment: [
      "TATWO_ULTRAWORK_APP_SUPPORT": support.path,
      "HOME": FileManager.default.temporaryDirectory.path,
    ])

    XCTAssertEqual(probe.projectRoot.path, support.appendingPathComponent("project-cache").path)
    XCTAssertEqual(
      probe.skillRoot.path,
      support.appendingPathComponent("capabilities/skills").path)
    XCTAssertEqual(
      probe.archiveRoot.path, support.appendingPathComponent("skill-archives-cache").path)
    XCTAssertNil(probe.gatewayRoot)
  }

  func testCurrentProbeDoesNotAutoScanExternalVolumeSkillSymlink() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let codexLink = home.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: codexLink,
      withDestinationURL: URL(fileURLWithPath: "/Volumes/ExampleCodexHome", isDirectory: true))

    let probe = TatwoEnvironmentProbe.current(environment: [
      "TATWO_ULTRAWORK_APP_SUPPORT": support.path,
      "HOME": home.path,
    ])

    XCTAssertEqual(
      probe.skillRoot.path,
      support.appendingPathComponent("capabilities/skills").path)
  }

  func testNoPointerFallbackSourceUsesPurePreview() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/TatwoUltraworkCore/AppSnapshot.swift")
    let source = try String(contentsOf: sourceURL)
    let start = try XCTUnwrap(source.range(of: "// With no pointer"))
    let end = try XCTUnwrap(
      source.range(
        of: "let submittedReceiptIDs",
        range: start.upperBound..<source.endIndex))
    let fallback = String(source[start.lowerBound..<end.lowerBound])

    XCTAssertTrue(fallback.contains("WorkOSFactory.preview("))
    XCTAssertFalse(fallback.contains("WorkOSFactory.projectContract("))
  }

  private func makeFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("project")
    let skills = root.appendingPathComponent("skills")
    let archives = root.appendingPathComponent("archives/tatwo-ultrawork-legacy-current")
    let gateway = root.appendingPathComponent("gateway")

    try FileManager.default.createDirectory(
      at: project.appendingPathComponent("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac"),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try "// package".write(
      to: project.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "// app".write(
      to: project.appendingPathComponent(
        "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TatwoUltraworkMacApp.swift"),
      atomically: true, encoding: .utf8)
    try "// mcp".write(
      to: project.appendingPathComponent("scripts/tatwo-ultrawork-mcp.mjs"), atomically: true,
      encoding: .utf8)

    try FileManager.default.createDirectory(
      at: skills.appendingPathComponent("tatwo-ultrawork"), withIntermediateDirectories: true)
    try "---\nname: tatwo-ultrawork\n---".write(
      to: skills.appendingPathComponent("tatwo-ultrawork/SKILL.md"), atomically: true,
      encoding: .utf8)

    try FileManager.default.createDirectory(
      at: archives.appendingPathComponent("open-ultrawork"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: archives.appendingPathComponent("codex-app-model-gateway"),
      withIntermediateDirectories: true)
    try "legacy open".write(
      to: archives.appendingPathComponent("open-ultrawork/SKILL.md"), atomically: true,
      encoding: .utf8)
    try "legacy gateway".write(
      to: archives.appendingPathComponent("codex-app-model-gateway/SKILL.md"), atomically: true,
      encoding: .utf8)

    try FileManager.default.createDirectory(
      at: gateway.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try "// post".write(
      to: gateway.appendingPathComponent("scripts/post-update-check.sh"), atomically: true,
      encoding: .utf8)
    return root
  }
}
