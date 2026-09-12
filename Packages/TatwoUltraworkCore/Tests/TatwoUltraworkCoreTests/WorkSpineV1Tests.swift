import XCTest
@testable import TatwoUltraworkCore

final class WorkSpineV1Tests: XCTestCase {
  func testCreateOnlyRowHasStableContentHashAndRejectsGoalCollision() throws {
    let root = temporaryRoot()
    let store = TatwoWorkSpineStoreV1(directoryURL: root)
    let row = TatwoWorkSpineV1(goalID: "goal-1", contractID: "contract-1", cycleEpoch: 1, threadID: "thread-1")
    let written = try store.create(row)
    XCTAssertEqual(written.contentSHA256, try row.canonicalContentSHA256())
    XCTAssertThrowsError(try store.create(row))
  }

  func testLocatorRequiresUniqueGoalContractAndAgentRunIDs() throws {
    let store = TatwoWorkSpineStoreV1(directoryURL: temporaryRoot())
    _ = try store.create(.init(goalID: "g1", contractID: "c1", cycleEpoch: 1, agentRunID: "a1", threadID: "t1"))
    XCTAssertEqual(try store.locator().byGoalID("g1").threadID, "t1")
    XCTAssertEqual(try store.locator().byContractID("c1").goalID, "g1")
    XCTAssertEqual(try store.locator().byAgentRunID("a1").contractID, "c1")
    XCTAssertEqual(try store.locator().byThreadID("t1").cycleEpoch, 1)
  }

  func testBindAgentRunFencesRebindStaleRevisionAndTerminalGoal() throws {
    let store = TatwoWorkSpineStoreV1(directoryURL: temporaryRoot())
    _ = try store.create(.init(goalID: "g1", contractID: "c1", cycleEpoch: 1, threadID: "t1"))
    let active = goal(status: .running, revision: 2)
    XCTAssertThrowsError(try store.bindAgentRun("a1", goal: active, expectedGoalRevision: 1))
    let bound = try store.bindAgentRun("a1", goal: active, expectedGoalRevision: 2)
    XCTAssertEqual(bound.agentRunID, "a1")
    XCTAssertThrowsError(try store.bindAgentRun("a2", goal: active, expectedGoalRevision: 2))
    XCTAssertThrowsError(try store.bindAgentRun("a3", goal: goal(status: .succeeded, revision: 2), expectedGoalRevision: 2))
  }

  func testProjectionReferencesAreReadOnlyIdentityLinks() throws {
    let reference = TatwoWorkSpineProjectionReferenceV1(goalID: "g1", contractID: "c1")
    XCTAssertEqual(reference.schema, "WorkSpineProjectionReferenceV1")
    XCTAssertEqual(reference.goalID, "g1")
  }

  func testAuditReportsExactFourStoreIdentityAgreementWithoutMigration() throws {
    let row = try TatwoWorkSpineV1(goalID: "g1", contractID: "c1", cycleEpoch: 1, agentRunID: "a1", threadID: "t1", loopsSessionID: "l1").sealedForTesting()
    let report = TatwoWorkSpineAuditV1.audit(
      spineRows: [row],
      goalRuns: [goal(status: .running, revision: 1)],
      plgReferences: [.init(goalID: "g1", contractID: "c1")],
      loopsReferences: [.init(goalID: "g1", contractID: "c1", loopsSessionID: "l1")])
    XCTAssertTrue(report.entries[0].idsAgree)
    XCTAssertFalse(report.migratedLegacyData)
  }

  func testPartialWriteFailsClosed() throws {
    let root = temporaryRoot()
    let store = TatwoWorkSpineStoreV1(directoryURL: root)
    try FileManager.default.createDirectory(at: store.rowsDirectoryURL, withIntermediateDirectories: true)
    try Data("{\"schema\":\"WorkSpineV1\"".utf8).write(to: store.rowURL(goalID: "g1"))
    XCTAssertThrowsError(try store.locator().byGoalID("g1"))
  }

  func testG32CollisionInsertFailsClosed() throws {
    let store = TatwoWorkSpineStoreV1(directoryURL: temporaryRoot())
    _ = try store.create(
      .init(
        goalID: "g1",
        contractID: "c1",
        cycleEpoch: 1,
        threadID: "t1"))

    XCTAssertThrowsError(
      try store.create(
        .init(
          goalID: "g1",
          contractID: "c2",
          cycleEpoch: 2,
          threadID: "t2"))
    ) { error in
      XCTAssertEqual(error as? TatwoWorkSpineErrorV1, .collision("g1"))
    }
  }

  func testG32PLGWithoutGoalFailsAudit() throws {
    let row = try TatwoWorkSpineV1(
      goalID: "g1",
      contractID: "c1",
      cycleEpoch: 1,
      threadID: "t1"
    ).sealedForTesting()
    let report = TatwoWorkSpineAuditV1.audit(
      spineRows: [row],
      goalRuns: [],
      plgReferences: [.init(goalID: "g1", contractID: "c1")],
      loopsReferences: [])

    XCTAssertFalse(report.isConsistent)
    XCTAssertFalse(try XCTUnwrap(report.entries.first).goalRunPresent)
  }

  func testG32IdleChatWithoutGoalPassesAudit() {
    let report = TatwoWorkSpineAuditV1.audit(
      spineRows: [],
      goalRuns: [],
      plgReferences: [],
      loopsReferences: [])

    XCTAssertTrue(report.isConsistent)
    XCTAssertTrue(report.entries.isEmpty)
  }

  func testG32LiveFourStoreDumpHasOneExactIdentityRow() throws {
    let row = try TatwoWorkSpineV1(
      goalID: "g1",
      contractID: "c1",
      cycleEpoch: 1,
      agentRunID: "a1",
      threadID: "t1",
      loopsSessionID: "l1"
    ).sealedForTesting()
    let report = TatwoWorkSpineAuditV1.audit(
      spineRows: [row],
      goalRuns: [goal(status: .running, revision: 1)],
      plgReferences: [.init(goalID: "g1", contractID: "c1")],
      loopsReferences: [
        .init(goalID: "g1", contractID: "c1", loopsSessionID: "l1")
      ])
    let dump = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(
      TatwoWorkSpineAuditReportV1.self,
      from: dump)

    XCTAssertTrue(decoded.isConsistent)
    XCTAssertEqual(
      [
        decoded.spineRowCount,
        decoded.goalRunCount,
        decoded.plgReferenceCount,
        decoded.loopsReferenceCount,
      ],
      [1, 1, 1, 1])
    XCTAssertEqual(try XCTUnwrap(decoded.entries.first).goalID, "g1")
  }

  private func goal(status: GoalRunStatus, revision: UInt64) -> TatwoStoredGoalRun {
    .init(goalID: "g1", contractID: "c1", mode: .s, scenario: "code", objective: "test", status: status, revision: revision)
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("work-spine-\(UUID().uuidString)", isDirectory: true)
  }
}
