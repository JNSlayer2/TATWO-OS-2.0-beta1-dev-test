import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoOfflineCopyMergeV1Tests: XCTestCase {
  private let projectID = "shared-m2"
  private let writer = "writer-device"
  private let replicaDevice = "offline-device"

  private func manifest(
    head: TatwoSharedProjectVersionAnchorV1 = .git(
      commit: "head-1",
      tree: "tree-1")
  ) throws -> TatwoSharedProjectManifestV1 {
    try TatwoSharedProjectManifestV1.build(
      projectID: projectID,
      displayName: "M2 shared project",
      dataKinds: [.gitBacked],
      formalHead: head,
      writer: TatwoProjectWriterLeaseV1(
        projectID: projectID,
        writerDeviceID: writer,
        projectEpoch: 1,
        projectFencingToken: "project-token",
        since: Date(timeIntervalSince1970: 1_900_000_000)),
      members: [
        TatwoSharedProjectMemberV1(deviceID: writer, role: .writer),
        TatwoSharedProjectMemberV1(deviceID: replicaDevice, role: .offlineCopy, provisional: true)
      ],
      versionFloor: TatwoSharedProjectVersionFloorV1(
        minSchemaVersion: 1,
        minProtocolVersion: 1),
      createdAt: Date(timeIntervalSince1970: 1_900_000_000))
  }

  private func replica(
    base: TatwoSharedProjectVersionAnchorV1 = .git(
      commit: "head-1",
      tree: "tree-1"),
    path: String = "Sources/Feature.swift"
  ) -> TatwoOfflineCopyStateV1 {
    TatwoOfflineCopyStateV1(
      replicaID: "replica-m2",
      deviceID: replicaDevice,
      baseVersionAnchor: base,
      provisionalChanges: [
        TatwoOfflineCopyProvisionalChangeV1(
          path: path,
          sha256: "sha256:change-1")
      ])
  }

  func testFourMergeDecisions() throws {
    let fixture = try manifest()

    let fastForward = TatwoOfflineCopyMergeV1.plan(
      manifest: fixture,
      replica: replica(),
      canonicalHead: TatwoOfflineCopyCanonicalHeadV1(
        anchor: fixture.formalHead))
    XCTAssertEqual(fastForward.decision, .fastForward)
    XCTAssertEqual(fastForward.applicableBy, writer)
    XCTAssertTrue(fastForward.provisional)
    XCTAssertEqual(fastForward.gitInstruction?.requiresCanonicalWriter, true)
    XCTAssertTrue(fastForward.gitInstruction?.wipBranch.contains("replica-m2") == true)

    let needsRebase = TatwoOfflineCopyMergeV1.plan(
      manifest: fixture,
      replica: replica(),
      canonicalHead: TatwoOfflineCopyCanonicalHeadV1(
        anchor: .git(commit: "head-2", tree: "tree-2"),
        changedPaths: ["Sources/Other.swift"]))
    XCTAssertEqual(needsRebase.decision, .needsRebase)

    let conflict = TatwoOfflineCopyMergeV1.plan(
      manifest: fixture,
      replica: replica(),
      canonicalHead: TatwoOfflineCopyCanonicalHeadV1(
        anchor: .git(commit: "head-2", tree: "tree-2"),
        changedPaths: ["Sources/Feature.swift", "README.md"]))
    XCTAssertEqual(conflict.decision, .conflict(paths: ["Sources/Feature.swift"]))

    let rejected = TatwoOfflineCopyMergeV1.plan(
      manifest: fixture,
      replica: TatwoOfflineCopyStateV1(
        replicaID: "replica-m2",
        deviceID: replicaDevice,
        baseVersionAnchor: fixture.formalHead,
        provisionalChanges: [],
        state: .provisionalDirty,
        provisional: true),
      canonicalHead: TatwoOfflineCopyCanonicalHeadV1(anchor: fixture.formalHead))
    guard case let .rejected(reason) = rejected.decision else {
      return XCTFail("expected rejected plan")
    }
    XCTAssertTrue(reason.contains("no provisional changes"))
  }

  func testOnlyCanonicalWriterMayApplyAndPromotionClearsProvisional() throws {
    let fixture = try manifest()
    let plan = TatwoOfflineCopyMergeV1.plan(
      manifest: fixture,
      replica: replica(),
      canonicalHead: TatwoOfflineCopyCanonicalHeadV1(anchor: fixture.formalHead))

    XCTAssertThrowsError(
      try plan.apply(
        manifest: fixture,
        byDeviceID: replicaDevice,
        promotedVersionAnchor: .git(commit: "head-2", tree: "tree-2"))
    ) { error in
      XCTAssertEqual(
        error as? TatwoOfflineCopyMergeErrorV1,
        .notCanonicalWriter(expected: writer, actual: replicaDevice))
    }

    let applied = try plan.apply(
      manifest: fixture,
      byDeviceID: writer,
      promotedVersionAnchor: .git(commit: "head-2", tree: "tree-2"))
    XCTAssertFalse(applied.provisional)
    XCTAssertEqual(applied.replicaState, .cleanMirror)
    XCTAssertEqual(applied.promotedCanonicalHead, .git(commit: "head-2", tree: "tree-2"))
  }

  func testBaseAnchorExpirationNeedsRebaseAndSamePathConflict() throws {
    let fixture = try manifest()
    let oldBase = replica(
      base: .journal(sequence: 1, digest: "digest-1"),
      path: "state.json")
    let current = TatwoOfflineCopyCanonicalHeadV1(
      anchor: .journal(sequence: 2, digest: "digest-2"),
      changedPaths: [])
    let rebase = TatwoOfflineCopyMergeV1.plan(
      manifest: try manifest(
        head: .journal(sequence: 2, digest: "digest-2")),
      replica: oldBase,
      canonicalHead: current)
    XCTAssertEqual(rebase.decision, .needsRebase)

    let conflict = TatwoOfflineCopyMergeV1.plan(
      manifest: try manifest(
        head: .journal(sequence: 2, digest: "digest-2")),
      replica: oldBase,
      canonicalHead: TatwoOfflineCopyCanonicalHeadV1(
        anchor: current.anchor,
        changedPaths: ["state.json"]))
    XCTAssertEqual(conflict.decision, .conflict(paths: ["state.json"]))
    XCTAssertEqual(fixture.projectID, projectID)
  }
}

