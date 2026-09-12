import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoArtifactReviewCoreTests: XCTestCase {
  func testOriginalRenderedAndExportValuesHashOnlyPassedContent() {
    let original = TatwoArtifactReviewOriginalFileV1(
      artifactID: "artifact-1",
      sourceRelativePath: "Docs/brief.md",
      content: "hello")
    let rendered = TatwoArtifactReviewRenderedContentV1(
      renderID: "render-1",
      artifactID: original.artifactID,
      renderer: "markdown",
      content: "<p>hello</p>",
      pageCount: 1)
    let exported = TatwoArtifactReviewExportHashV1(
      exportID: "export-1",
      artifactID: original.artifactID,
      mediaType: "text/markdown",
      content: Data("hello".utf8))

    XCTAssertEqual(
      original.contentSHA256,
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    XCTAssertEqual(rendered.contentSHA256, TatwoArtifactReviewHasher.sha256("<p>hello</p>"))
    XCTAssertEqual(exported.sha256, original.contentSHA256)
    XCTAssertEqual(exported.byteCount, 5)
  }

  func testDiffOfEqualContentHasNoHunks() {
    let diff = TatwoArtifactReviewDiffAggregator.diff(
      original: "alpha\nbeta\n",
      modified: "alpha\nbeta\n")

    XCTAssertTrue(diff.hunks.isEmpty)
    XCTAssertEqual(
      diff.summary,
      TatwoArtifactReviewDiffSummaryV1(
        hunkCount: 0,
        insertedLineCount: 0,
        deletedLineCount: 0,
        replacementHunkCount: 0))
    XCTAssertEqual(diff.originalSHA256, diff.modifiedSHA256)
  }

  func testDiffAggregatesAdjacentDeleteAndInsertAsReplacementHunk() throws {
    let diff = TatwoArtifactReviewDiffAggregator.diff(
      original: "alpha\nold one\nold two\nomega\n",
      modified: "alpha\nnew one\nnew two\nnew three\nomega\n")

    let hunk = try XCTUnwrap(diff.hunks.first)
    XCTAssertEqual(diff.hunks.count, 1)
    XCTAssertEqual(hunk.kind, .replace)
    XCTAssertEqual(hunk.originalRange, .init(startLine: 2, lineCount: 2))
    XCTAssertEqual(hunk.modifiedRange, .init(startLine: 2, lineCount: 3))
    XCTAssertEqual(hunk.beforeContent, "old one\nold two\n")
    XCTAssertEqual(hunk.afterContent, "new one\nnew two\nnew three\n")
    XCTAssertEqual(diff.summary.insertedLineCount, 3)
    XCTAssertEqual(diff.summary.deletedLineCount, 2)
    XCTAssertEqual(diff.summary.replacementHunkCount, 1)
  }

  func testDiffSeparatesNonAdjacentInsertionAndDeletion() {
    let diff = TatwoArtifactReviewDiffAggregator.diff(
      original: "one\ntwo\nthree\n",
      modified: "zero\none\nthree\n")

    XCTAssertEqual(diff.hunks.map(\.kind), [.insert, .delete])
    XCTAssertEqual(diff.hunks[0].originalRange, .init(startLine: 1, lineCount: 0))
    XCTAssertEqual(diff.hunks[0].modifiedRange, .init(startLine: 1, lineCount: 1))
    XCTAssertEqual(diff.hunks[1].originalRange, .init(startLine: 2, lineCount: 1))
    XCTAssertEqual(diff.hunks[1].modifiedRange, .init(startLine: 3, lineCount: 0))
  }

  func testDiffDetectsOnlyTerminalNewlineChange() throws {
    let diff = TatwoArtifactReviewDiffAggregator.diff(
      original: "line",
      modified: "line\n")

    let hunk = try XCTUnwrap(diff.hunks.first)
    XCTAssertEqual(hunk.kind, .replace)
    XCTAssertEqual(hunk.beforeContent, "line")
    XCTAssertEqual(hunk.afterContent, "line\n")
    XCTAssertNotEqual(diff.originalSHA256, diff.modifiedSHA256)
  }

  func testEmptyToContentProducesSingleInsertionHunk() throws {
    let diff = TatwoArtifactReviewDiffAggregator.diff(
      original: "",
      modified: "first\nsecond")

    let hunk = try XCTUnwrap(diff.hunks.first)
    XCTAssertEqual(hunk.kind, .insert)
    XCTAssertEqual(hunk.originalRange, .init(startLine: 1, lineCount: 0))
    XCTAssertEqual(hunk.modifiedRange, .init(startLine: 1, lineCount: 2))
    XCTAssertEqual(hunk.afterContent, "first\nsecond")
  }

  func testAnnotationAggregationGroupsAndSortsWithOpenBlockingCounts() {
    let diff = TatwoArtifactReviewDiffAggregator.diff(
      original: "old\n",
      modified: "new\n")
    let hunkID = diff.hunks[0].id
    let annotations = [
      annotation(
        id: "later",
        targetKind: .diffHunk,
        targetID: hunkID,
        severity: .note,
        state: .resolved,
        at: 20),
      annotation(
        id: "blocking",
        targetKind: .diffHunk,
        targetID: hunkID,
        severity: .blocking,
        state: .open,
        at: 10),
      annotation(
        id: "original-note",
        targetKind: .original,
        targetID: "artifact-1",
        severity: .suggestion,
        state: .open,
        at: 5),
    ]

    let aggregate = TatwoArtifactReviewAnnotationAggregator.aggregate(
      annotations: annotations,
      diff: diff)

    XCTAssertEqual(aggregate.totalCount, 3)
    XCTAssertEqual(aggregate.openCount, 2)
    XCTAssertEqual(aggregate.resolvedCount, 1)
    XCTAssertEqual(aggregate.openBlockingCount, 1)
    XCTAssertEqual(aggregate.groups.count, 2)
    XCTAssertEqual(
      aggregate.groups.first { $0.targetID == hunkID }?.annotations.map(\.id),
      ["blocking", "later"])
    XCTAssertTrue(aggregate.orphanedDiffAnnotationIDs.isEmpty)
  }

  func testAnnotationAggregationReportsUnknownDiffTargetsWithoutDroppingThem() {
    let diff = TatwoArtifactReviewDiffAggregator.diff(
      original: "same\n",
      modified: "same\n")
    let orphan = annotation(
      id: "orphan",
      targetKind: .diffHunk,
      targetID: "missing-hunk",
      severity: .blocking,
      state: .open,
      at: 1)

    let aggregate = TatwoArtifactReviewAnnotationAggregator.aggregate(
      annotations: [orphan],
      diff: diff)

    XCTAssertEqual(aggregate.totalCount, 1)
    XCTAssertEqual(aggregate.groups.first?.annotations, [orphan])
    XCTAssertEqual(aggregate.orphanedDiffAnnotationIDs, ["orphan"])
  }

  func testArtifactReviewValuesRoundTripCodableAndAreSendable() throws {
    let original = TatwoArtifactReviewOriginalFileV1(
      artifactID: "artifact",
      sourceRelativePath: "relative.md",
      content: "before\n")
    let rendered = TatwoArtifactReviewRenderedContentV1(
      renderID: "render",
      artifactID: original.artifactID,
      renderer: "plain-text",
      content: "before\n")
    let diff = TatwoArtifactReviewDiffAggregator.diff(
      original: original.content,
      modified: "after\n")
    let aggregate = TatwoArtifactReviewAnnotationAggregator.aggregate(
      annotations: [
        annotation(
          id: "review",
          targetKind: .diffHunk,
          targetID: diff.hunks[0].id,
          severity: .suggestion,
          state: .open,
          at: 1)
      ],
      diff: diff)

    XCTAssertEqual(try roundTrip(original), original)
    XCTAssertEqual(try roundTrip(rendered), rendered)
    XCTAssertEqual(try roundTrip(diff), diff)
    XCTAssertEqual(try roundTrip(aggregate), aggregate)
    assertSendable(original)
    assertSendable(rendered)
    assertSendable(diff)
    assertSendable(aggregate)
  }

  private func annotation(
    id: String,
    targetKind: TatwoArtifactReviewAnnotationTargetKindV1,
    targetID: String,
    severity: TatwoArtifactReviewAnnotationSeverityV1,
    state: TatwoArtifactReviewAnnotationStateV1,
    at time: TimeInterval
  ) -> TatwoArtifactReviewAnnotationV1 {
    TatwoArtifactReviewAnnotationV1(
      id: id,
      targetKind: targetKind,
      targetID: targetID,
      authorIdentity: "reviewer",
      body: "note-\(id)",
      severity: severity,
      state: state,
      createdAt: Date(timeIntervalSince1970: time))
  }

  private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
  }

  private func assertSendable<T: Sendable>(_ value: T) {
    _ = value
  }
}
