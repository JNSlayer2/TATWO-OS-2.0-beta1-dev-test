import XCTest

@testable import TatwoUltraworkCore

final class WorkOSPersistenceBoundaryTests: XCTestCase {
  func testBeginWithNoPersistenceArgumentsIsPureProjection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "pure WorkOS projection")

    XCTAssertFalse(contract.contractID.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testCanonicalBeginRequiresTypedOwnerAndCompleteStores() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true)
    let projected = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "canonical typed WorkOS begin")
    _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
      goalStoreRoot: root,
      contractID: projected.contractID)

    let attachment = try WorkOSFactory.beginCanonical(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "canonical typed WorkOS begin",
      store: TatwoGoalRunStore(directoryURL: root),
      registry: TatwoDispatchRegistry(directoryURL: root),
      sessionStore: TatwoSessionStore(directoryURL: root),
      owner: TatwoCanonicalSessionOwnerV1(
        provider: "codex",
        locator: .thread("thread-authority"),
        workspacePath: "/tmp/tatwo-workos-boundary"))

    XCTAssertEqual(attachment.contract, projected)
    XCTAssertEqual(
      attachment.pointer.ownerBinding?.sessionID,
      "thread-authority")
  }
}
