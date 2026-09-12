import XCTest

@testable import TatwoUltraworkCore

final class TatwoChangeReceiptCoreTests: XCTestCase {
  func testParsesUnifiedDiffIntoFileCountsAndHunkSummary() {
    let diff = """
      diff --git a/Sources/Parser.swift b/Sources/Parser.swift
      index 1111111..2222222 100644
      --- a/Sources/Parser.swift
      +++ b/Sources/Parser.swift
      @@ -10,3 +10,4 @@ public struct Parser {
       unchanged
      -old line
      +new line
      +another line
       tail
      """

    let receipt = TatwoChangeReceiptParser.parse(diff: diff)

    XCTAssertEqual(receipt.schema, "TatwoChangeReceiptV1")
    XCTAssertEqual(receipt.summary.fileCount, 1)
    XCTAssertEqual(receipt.summary.additions, 2)
    XCTAssertEqual(receipt.summary.deletions, 1)
    XCTAssertEqual(receipt.files.first?.relativePath, "Sources/Parser.swift")
    XCTAssertEqual(receipt.files.first?.status, .modified)
    XCTAssertEqual(receipt.files.first?.additions, 2)
    XCTAssertEqual(receipt.files.first?.deletions, 1)
    XCTAssertEqual(
      receipt.files.first?.hunks,
      [
        TatwoChangeReceiptHunkSummary(
          oldStart: 10,
          oldLineCount: 3,
          newStart: 10,
          newLineCount: 4,
          heading: "public struct Parser {",
          additions: 2,
          deletions: 1)
      ])
  }

  func testPorcelainStatusSuppliesStagedAndUnstagedState() {
    let status = """
      M  Sources/Staged.swift
       M Sources/Unstaged.swift
      AM Sources/Both.swift
      """

    let receipt = TatwoChangeReceiptParser.parse(diff: "", status: status)
    let files = Dictionary(uniqueKeysWithValues: receipt.files.map { ($0.relativePath, $0) })

    XCTAssertEqual(files["Sources/Staged.swift"]?.status, .modified)
    XCTAssertEqual(files["Sources/Staged.swift"]?.staged, true)
    XCTAssertEqual(files["Sources/Staged.swift"]?.unstaged, false)
    XCTAssertEqual(files["Sources/Unstaged.swift"]?.staged, false)
    XCTAssertEqual(files["Sources/Unstaged.swift"]?.unstaged, true)
    XCTAssertEqual(files["Sources/Both.swift"]?.status, .added)
    XCTAssertEqual(files["Sources/Both.swift"]?.staged, true)
    XCTAssertEqual(files["Sources/Both.swift"]?.unstaged, true)
  }

  func testParsesNulDelimitedRenameCopyUnicodeAndSpaces() {
    let status = "R  Sources/New Name.swift\u{0}Sources/舊 名稱.swift\u{0}C  Copy.swift\u{0}Original.swift\u{0}?? 新增 檔.swift\u{0}"

    let receipt = TatwoChangeReceiptParser.parse(diff: "", status: status)

    XCTAssertEqual(receipt.files.map(\.relativePath), [
      "Copy.swift",
      "Sources/New Name.swift",
      "新增 檔.swift",
    ])
    XCTAssertEqual(receipt.files[0].previousRelativePath, "Original.swift")
    XCTAssertEqual(receipt.files[0].status, .copied)
    XCTAssertEqual(receipt.files[1].previousRelativePath, "Sources/舊 名稱.swift")
    XCTAssertEqual(receipt.files[1].status, .renamed)
    XCTAssertEqual(receipt.files[2].status, .untracked)
  }

  func testDiffMetadataParsesRenameWithoutHunks() {
    let diff = """
      diff --git a/Old.swift b/New.swift
      similarity index 100%
      rename from Old.swift
      rename to New.swift
      """

    let file = TatwoChangeReceiptParser.parse(diff: diff).files.first

    XCTAssertEqual(file?.relativePath, "New.swift")
    XCTAssertEqual(file?.previousRelativePath, "Old.swift")
    XCTAssertEqual(file?.status, .renamed)
    XCTAssertEqual(file?.additions, 0)
    XCTAssertEqual(file?.deletions, 0)
    XCTAssertEqual(file?.hunks, [])
  }

  func testBinaryDiffUsesUnknownLineCountsWithoutCrashing() {
    let diff = """
      diff --git a/Assets/image.png b/Assets/image.png
      index 1111111..2222222 100644
      Binary files a/Assets/image.png and b/Assets/image.png differ
      """

    let receipt = TatwoChangeReceiptParser.parse(diff: diff)

    XCTAssertEqual(receipt.summary.binaryCount, 1)
    XCTAssertTrue(receipt.files[0].isBinary)
    XCTAssertNil(receipt.files[0].additions)
    XCTAssertNil(receipt.files[0].deletions)
  }

  func testConflictAndTypeChangeStatusesArePreserved() {
    let status = """
      UU Sources/Conflict.swift
      T  Sources/ModeChanged.swift
      D  Sources/Deleted.swift
      """

    let files = Dictionary(
      uniqueKeysWithValues: TatwoChangeReceiptParser.parse(diff: "", status: status)
        .files.map { ($0.relativePath, $0.status) })

    XCTAssertEqual(files["Sources/Conflict.swift"], .conflicted)
    XCTAssertEqual(files["Sources/ModeChanged.swift"], .typeChanged)
    XCTAssertEqual(files["Sources/Deleted.swift"], .deleted)
  }

  func testMultipleFilesAreSortedAndSummaryTotalsKnownCountsOnly() {
    let diff = """
      diff --git a/Z.swift b/Z.swift
      --- a/Z.swift
      +++ b/Z.swift
      @@ -1 +1 @@
      -old
      +new
      diff --git a/A.swift b/A.swift
      --- a/A.swift
      +++ b/A.swift
      @@ -0,0 +1,2 @@
      +one
      +two
      """

    let receipt = TatwoChangeReceiptParser.parse(diff: diff)

    XCTAssertEqual(receipt.files.map(\.relativePath), ["A.swift", "Z.swift"])
    XCTAssertEqual(receipt.summary.fileCount, 2)
    XCTAssertEqual(receipt.summary.additions, 3)
    XCTAssertEqual(receipt.summary.deletions, 1)
  }

  func testDuplicateFileSectionsMergeWithoutCrashing() {
    let diff = """
      diff --git a/File.swift b/File.swift
      --- a/File.swift
      +++ b/File.swift
      @@ -1 +1 @@
      -one
      +two
      diff --git a/File.swift b/File.swift
      --- a/File.swift
      +++ b/File.swift
      @@ -3,0 +4 @@
      +three
      """

    let receipt = TatwoChangeReceiptParser.parse(diff: diff)

    XCTAssertEqual(receipt.files.count, 1)
    XCTAssertEqual(receipt.files[0].additions, 2)
    XCTAssertEqual(receipt.files[0].deletions, 1)
    XCTAssertEqual(receipt.files[0].hunks.count, 2)
  }

  func testMalformedAndMissingInputReturnsWarningsInsteadOfCrashing() {
    let malformed = """
      diff --git
      @@ not-a-hunk @@
      +orphan
      """

    let receipt = TatwoChangeReceiptParser.parse(diff: malformed, status: "X")

    XCTAssertEqual(receipt.files, [])
    XCTAssertFalse(receipt.warnings.isEmpty)
    XCTAssertEqual(TatwoChangeReceiptParser.parse(diff: "").files, [])
  }

  func testUnsafePathsAreRejected() {
    let status = " M ../Secrets.swift\n?? /tmp/Absolute.swift\n M Sources/Safe.swift\n"

    let receipt = TatwoChangeReceiptParser.parse(diff: "", status: status)

    XCTAssertEqual(receipt.files.map(\.relativePath), ["Sources/Safe.swift"])
    XCTAssertTrue(receipt.warnings.contains { $0.contains("unsafe_path") })
  }

  func testReceiptModelsRoundTripCodableAndAreSendableValues() throws {
    let receipt = TatwoChangeReceiptParser.parse(
      diff: """
        diff --git a/File.swift b/File.swift
        --- a/File.swift
        +++ b/File.swift
        @@ -1 +1 @@ heading
        -before
        +after
        """,
      status: " M File.swift\n")

    let decoded = try JSONDecoder().decode(
      TatwoChangeReceiptV1.self,
      from: JSONEncoder().encode(receipt))

    XCTAssertEqual(decoded, receipt)
    assertSendable(decoded)
    assertSendable(decoded.summary)
    assertSendable(decoded.files[0])
    assertSendable(decoded.files[0].hunks[0])
  }

  private func assertSendable<T: Sendable>(_ value: T) {
    _ = value
  }
}
