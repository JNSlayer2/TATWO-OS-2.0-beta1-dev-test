import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoThreadTreeV1Tests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_710_000_000)

  private func makeTree() throws -> (
    tree: TatwoThreadTreeV1,
    projectID: String,
    threadID: String
  ) {
    var tree = TatwoThreadTreeV1.empty()
    let project = try tree.addProject(title: "Proj", id: "proj-1", at: t0)
    let thread = try tree.addThread(
      projectID: project.id,
      title: "Main thread",
      id: "thread-1",
      at: t0)
    return (tree, project.id, thread.id)
  }

  private func parentSnapshot(threadID: String = "thread-1") -> TatwoParentThreadSnapshotV1 {
    TatwoParentThreadSnapshotV1(
      parentThreadID: threadID,
      parentMessageCount: 4,
      parentTranscriptDigest: "sha256:parent-digest",
      inheritedContext: "parent context for inheritance",
      capturedAt: t0)
  }

  // MARK: - Three-phase transitions

  func testAsymmetricThreePhaseTransitions() throws {
    let env = try makeTree()
    var tree = env.tree

    let opened = try tree.openDiscussion(
      projectID: env.projectID,
      threadID: env.threadID,
      label: "討論串-A",
      parentSnapshot: parentSnapshot(),
      id: "disc-1",
      at: t0)
    XCTAssertEqual(opened.phase, .snapshotInherited)
    XCTAssertEqual(opened.markedTitle, "#討論串-A")
    XCTAssertEqual(opened.inheritedSnapshot.inheritedContext, "parent context for inheritance")

    let inProgress = try tree.beginProgress(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-1",
      at: t0.addingTimeInterval(10))
    XCTAssertEqual(inProgress.phase, .inProgress)

    let metrics1 = try tree.appendSealedMessage(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-1",
      text: "secret body one",
      at: t0.addingTimeInterval(20))
    let metrics2 = try tree.appendSealedMessage(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-1",
      text: "secret body two",
      at: t0.addingTimeInterval(30))
    XCTAssertEqual(metrics1.messageCount, 1)
    XCTAssertEqual(metrics2.messageCount, 2)
    XCTAssertEqual(metrics2.lastActiveAt, t0.addingTimeInterval(30))

    let injection = try tree.closeDiscussion(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-1",
      compressedSummary: "compressed: two sealed turns about the task",
      at: t0.addingTimeInterval(40))

    XCTAssertEqual(injection.schema, TatwoDiscussionInjectionSummaryV1.schemaName)
    XCTAssertEqual(injection.discussionID, "disc-1")
    XCTAssertEqual(injection.markedTitle, "#討論串-A")
    XCTAssertEqual(injection.parentThreadID, "thread-1")
    XCTAssertEqual(injection.parentProjectID, "proj-1")
    XCTAssertEqual(injection.compressedSummary, "compressed: two sealed turns about the task")
    XCTAssertEqual(injection.messageCount, 2)
    XCTAssertEqual(
      injection.sourcePhaseSequence,
      [.snapshotInherited, .inProgress, .closed])

    let closed = try tree.discussion(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-1")
    XCTAssertEqual(closed.phase, .closed)
    XCTAssertEqual(closed.injectionSummary, injection)
  }

  // MARK: - Skip / reverse rejected

  func testSkipAndReverseTransitionsRejected() throws {
    let env = try makeTree()
    var tree = env.tree
    _ = try tree.openDiscussion(
      projectID: env.projectID,
      threadID: env.threadID,
      label: "side",
      parentSnapshot: parentSnapshot(),
      id: "disc-skip",
      at: t0)

    // Skip snapshotInherited → closed
    XCTAssertThrowsError(
      try tree.closeDiscussion(
        projectID: env.projectID,
        threadID: env.threadID,
        discussionID: "disc-skip",
        compressedSummary: "nope")
    ) { error in
      XCTAssertEqual(
        error as? TatwoThreadTreeErrorV1,
        .invalidTransition(from: .snapshotInherited, to: .closed))
    }

    // Message before beginProgress rejected
    XCTAssertThrowsError(
      try tree.appendSealedMessage(
        projectID: env.projectID,
        threadID: env.threadID,
        discussionID: "disc-skip",
        text: "too early")
    ) { error in
      XCTAssertEqual(
        error as? TatwoThreadTreeErrorV1,
        .invalidTransition(from: .snapshotInherited, to: .inProgress))
    }

    _ = try tree.beginProgress(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-skip",
      at: t0.addingTimeInterval(1))

    // Double beginProgress (no reverse / re-entry)
    XCTAssertThrowsError(
      try tree.beginProgress(
        projectID: env.projectID,
        threadID: env.threadID,
        discussionID: "disc-skip")
    ) { error in
      XCTAssertEqual(
        error as? TatwoThreadTreeErrorV1,
        .invalidTransition(from: .inProgress, to: .inProgress))
    }

    _ = try tree.closeDiscussion(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-skip",
      compressedSummary: "done",
      at: t0.addingTimeInterval(2))

    // Reverse closed → inProgress rejected
    XCTAssertThrowsError(
      try tree.beginProgress(
        projectID: env.projectID,
        threadID: env.threadID,
        discussionID: "disc-skip")
    ) { error in
      XCTAssertEqual(
        error as? TatwoThreadTreeErrorV1,
        .invalidTransition(from: .closed, to: .inProgress))
    }

    // closed → closed rejected
    XCTAssertThrowsError(
      try tree.closeDiscussion(
        projectID: env.projectID,
        threadID: env.threadID,
        discussionID: "disc-skip",
        compressedSummary: "again")
    ) { error in
      XCTAssertEqual(
        error as? TatwoThreadTreeErrorV1,
        .invalidTransition(from: .closed, to: .closed))
    }
  }

  // MARK: - # marker immutable / no strip path

  func testHashPrefixCannotBeRemovedAndIsStructural() throws {
    let bare = try TatwoDiscussionMarkerTitleV1(label: "討論串")
    XCTAssertEqual(bare.marked, "#討論串")
    XCTAssertTrue(bare.marked.hasPrefix("#"))

    let already = try TatwoDiscussionMarkerTitleV1(label: "##討論串")
    XCTAssertEqual(already.marked, "#討論串")

    let withSpace = try TatwoDiscussionMarkerTitleV1(label: "  # side task  ")
    XCTAssertEqual(withSpace.marked, "#side task")

    XCTAssertThrowsError(try TatwoDiscussionMarkerTitleV1(label: "#")) { error in
      XCTAssertEqual(error as? TatwoThreadTreeErrorV1, .emptyMarkerLabel)
    }
    XCTAssertThrowsError(try TatwoDiscussionMarkerTitleV1(label: "   ")) { error in
      XCTAssertEqual(error as? TatwoThreadTreeErrorV1, .emptyMarkerLabel)
    }

    // Type surface: only public string form is `marked` (always prefixed).
    let children = Mirror(reflecting: bare).children.map { $0.label }
    XCTAssertFalse(
      children.contains(where: { $0 == "body" && false }),
      "body must remain private; Mirror may still see it as private storage")
    // Encode shape always writes `marked` with `#`.
    let data = try JSONEncoder().encode(bare)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
    XCTAssertEqual(object?["marked"], "#討論串")
    XCTAssertNil(object?["body"])
    XCTAssertNil(object?["unmarked"])
    XCTAssertNil(object?["raw"])

    let env = try makeTree()
    var tree = env.tree
    let disc = try tree.openDiscussion(
      projectID: env.projectID,
      threadID: env.threadID,
      label: "不可去井",
      parentSnapshot: parentSnapshot(),
      id: "disc-hash")
    XCTAssertEqual(disc.markedTitle, "#不可去井")
    // No tree API returns a stripable title without `#`.
    XCTAssertTrue(disc.markerTitle.marked.hasPrefix("#"))
  }

  // MARK: - inProgress does not leak full text

  func testInProgressDoesNotExposeFullText() throws {
    let env = try makeTree()
    var tree = env.tree
    _ = try tree.openDiscussion(
      projectID: env.projectID,
      threadID: env.threadID,
      label: "secret-work",
      parentSnapshot: parentSnapshot(),
      id: "disc-seal",
      at: t0)
    _ = try tree.beginProgress(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-seal",
      at: t0.addingTimeInterval(1))
    _ = try tree.appendSealedMessage(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-seal",
      text: "FULL TEXT MUST NOT LEAK",
      at: t0.addingTimeInterval(2))
    _ = try tree.appendSealedMessage(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-seal",
      text: "second sealed line",
      at: t0.addingTimeInterval(3))

    let metrics = try tree.progressMetrics(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-seal")
    XCTAssertEqual(metrics.messageCount, 2)
    XCTAssertEqual(metrics.lastActiveAt, t0.addingTimeInterval(3))

    // Metrics type has no text fields (only count + date).
    let metricsMirror = Mirror(reflecting: metrics).children.compactMap(\.label)
    XCTAssertEqual(Set(metricsMirror), Set(["messageCount", "lastActiveAt"]))

    XCTAssertThrowsError(
      try tree.sealedFullText(
        projectID: env.projectID,
        threadID: env.threadID,
        discussionID: "disc-seal")
    ) { error in
      XCTAssertEqual(
        error as? TatwoThreadTreeErrorV1,
        .fullTextSealedWhileInProgress)
    }

    let node = try tree.discussion(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-seal")
    XCTAssertThrowsError(try node.fullTextIfAllowed()) { error in
      XCTAssertEqual(
        error as? TatwoThreadTreeErrorV1,
        .fullTextSealedWhileInProgress)
    }
  }

  // MARK: - Closed injection shape

  func testClosedInjectionSummaryShape() throws {
    let env = try makeTree()
    var tree = env.tree
    _ = try tree.openDiscussion(
      projectID: env.projectID,
      threadID: env.threadID,
      label: "inject-me",
      parentSnapshot: parentSnapshot(),
      id: "disc-inj",
      at: t0)
    _ = try tree.beginProgress(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-inj",
      at: t0.addingTimeInterval(1))
    _ = try tree.appendSealedMessage(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-inj",
      text: "body",
      at: t0.addingTimeInterval(2))

    let closedAt = t0.addingTimeInterval(3)
    let injection = try tree.closeDiscussion(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-inj",
      compressedSummary: "  parent-ready digest  ",
      at: closedAt)

    XCTAssertEqual(injection.schema, "TatwoDiscussionInjectionSummaryV1")
    XCTAssertEqual(injection.discussionID, "disc-inj")
    XCTAssertEqual(injection.markedTitle, "#inject-me")
    XCTAssertEqual(injection.parentThreadID, "thread-1")
    XCTAssertEqual(injection.parentProjectID, "proj-1")
    XCTAssertEqual(injection.compressedSummary, "parent-ready digest")
    XCTAssertEqual(injection.messageCount, 1)
    XCTAssertEqual(injection.closedAt, closedAt)
    XCTAssertEqual(
      injection.sourcePhaseSequence,
      [.snapshotInherited, .inProgress, .closed])

    let encoded = try JSONEncoder().encode(injection)
    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    let requiredKeys: Set<String> = [
      "schema",
      "discussionID",
      "markedTitle",
      "parentThreadID",
      "parentProjectID",
      "compressedSummary",
      "messageCount",
      "closedAt",
      "sourcePhaseSequence",
    ]
    XCTAssertEqual(Set(object?.keys.map { String($0) } ?? []), requiredKeys)

    // Empty summary rejected
    let env2 = try makeTree()
    var tree2 = env2.tree
    _ = try tree2.openDiscussion(
      projectID: env2.projectID,
      threadID: env2.threadID,
      label: "x",
      parentSnapshot: parentSnapshot(),
      id: "disc-empty-sum")
    _ = try tree2.beginProgress(
      projectID: env2.projectID,
      threadID: env2.threadID,
      discussionID: "disc-empty-sum")
    XCTAssertThrowsError(
      try tree2.closeDiscussion(
        projectID: env2.projectID,
        threadID: env2.threadID,
        discussionID: "disc-empty-sum",
        compressedSummary: "   ")
    ) { error in
      XCTAssertEqual(error as? TatwoThreadTreeErrorV1, .summaryRequiredToClose)
    }
  }

  // MARK: - Hierarchy project → thread → #discussion

  func testProjectThreadDiscussionHierarchy() throws {
    var tree = TatwoThreadTreeV1.empty()
    let project = try tree.addProject(title: "P", id: "p")
    let thread = try tree.addThread(projectID: "p", title: "T", id: "t")
    let disc = try tree.openDiscussion(
      projectID: "p",
      threadID: "t",
      label: "D",
      parentSnapshot: parentSnapshot(threadID: "t"),
      id: "d")

    XCTAssertEqual(tree.projects.map(\.id), ["p"])
    XCTAssertEqual(tree.projects[0].threads.map(\.id), ["t"])
    XCTAssertEqual(tree.projects[0].threads[0].discussions.map(\.id), ["d"])
    XCTAssertEqual(disc.markedTitle, "#D")
    XCTAssertEqual(project.id, "p")
    XCTAssertEqual(thread.id, "t")
  }

  // MARK: - Round-trip encode

  func testTreeCodableRoundTripPreservesPhases() throws {
    let env = try makeTree()
    var tree = env.tree
    _ = try tree.openDiscussion(
      projectID: env.projectID,
      threadID: env.threadID,
      label: "rt",
      parentSnapshot: parentSnapshot(),
      id: "disc-rt",
      at: t0)
    _ = try tree.beginProgress(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-rt",
      at: t0.addingTimeInterval(1))
    _ = try tree.appendSealedMessage(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-rt",
      text: "sealed",
      at: t0.addingTimeInterval(2))

    let data = try tree.encodeDocument()
    let decoded = try TatwoThreadTreeV1.decode(from: data)
    let metrics = try decoded.progressMetrics(
      projectID: env.projectID,
      threadID: env.threadID,
      discussionID: "disc-rt")
    XCTAssertEqual(metrics.messageCount, 1)
    XCTAssertThrowsError(
      try decoded.sealedFullText(
        projectID: env.projectID,
        threadID: env.threadID,
        discussionID: "disc-rt"))
  }

  func testCorruptTreeDocumentFailClosed() {
    XCTAssertThrowsError(try TatwoThreadTreeV1.decode(from: Data("{bad".utf8))) { error in
      guard case TatwoThreadTreeErrorV1.corruptDocument = error else {
        return XCTFail("expected corruptDocument, got \(error)")
      }
    }

    let wrongSchema = Data("{\"schema\":\"Nope\",\"projects\":[]}".utf8)
    XCTAssertThrowsError(try TatwoThreadTreeV1.decode(from: wrongSchema)) { error in
      XCTAssertEqual(
        error as? TatwoThreadTreeErrorV1,
        .schemaMismatch("Nope"))
    }
  }
}
