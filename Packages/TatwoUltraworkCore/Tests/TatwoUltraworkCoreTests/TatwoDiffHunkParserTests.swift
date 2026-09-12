import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoDiffHunkParserTests: XCTestCase {
  func testParsesModifiedFileWithCorrectLineNumbersAndCounts() {
    let diff = """
      diff --git a/Sources/Example.swift b/Sources/Example.swift
      index 1111111..2222222 100644
      --- a/Sources/Example.swift
      +++ b/Sources/Example.swift
      @@ -10,3 +10,4 @@ struct Example {
       unchanged
      -old value
      +new value
      +extra value
       tail
      """

    let parsed = TatwoDiffHunkParser.parse(unifiedDiff: diff)

    XCTAssertEqual(parsed.files.count, 1)
    XCTAssertEqual(
      parsed.files[0],
      TatwoDiffFile(
        oldPath: "Sources/Example.swift",
        newPath: "Sources/Example.swift",
        changeKind: .modified,
        hunks: [
          TatwoDiffHunk(
            header: "@@ -10,3 +10,4 @@ struct Example {",
            lines: [
              TatwoDiffLine(
                kind: .context,
                oldLineNumber: 10,
                newLineNumber: 10,
                text: "unchanged"),
              TatwoDiffLine(
                kind: .removed,
                oldLineNumber: 11,
                newLineNumber: nil,
                text: "old value"),
              TatwoDiffLine(
                kind: .added,
                oldLineNumber: nil,
                newLineNumber: 11,
                text: "new value"),
              TatwoDiffLine(
                kind: .added,
                oldLineNumber: nil,
                newLineNumber: 12,
                text: "extra value"),
              TatwoDiffLine(
                kind: .context,
                oldLineNumber: 12,
                newLineNumber: 13,
                text: "tail"),
            ])
        ],
        addedCount: 2,
        removedCount: 1,
        isBinary: false))
  }

  func testParsesNewFile() {
    let diff = """
      diff --git a/Sources/New.swift b/Sources/New.swift
      new file mode 100644
      --- /dev/null
      +++ b/Sources/New.swift
      @@ -0,0 +1,2 @@
      +first
      +second
      """

    let file = TatwoDiffHunkParser.parse(unifiedDiff: diff).files[0]

    XCTAssertEqual(file.oldPath, "/dev/null")
    XCTAssertEqual(file.newPath, "Sources/New.swift")
    XCTAssertEqual(file.changeKind, .added)
    XCTAssertEqual(file.addedCount, 2)
    XCTAssertEqual(file.removedCount, 0)
    XCTAssertEqual(file.hunks[0].lines.map(\.newLineNumber), [1, 2])
    XCTAssertEqual(file.hunks[0].lines.map(\.oldLineNumber), [nil, nil])
  }

  func testParsesDeletedFile() {
    let diff = """
      diff --git a/Sources/Old.swift b/Sources/Old.swift
      deleted file mode 100644
      --- a/Sources/Old.swift
      +++ /dev/null
      @@ -7,2 +0,0 @@
      -first
      -second
      """

    let file = TatwoDiffHunkParser.parse(unifiedDiff: diff).files[0]

    XCTAssertEqual(file.oldPath, "Sources/Old.swift")
    XCTAssertEqual(file.newPath, "/dev/null")
    XCTAssertEqual(file.changeKind, .deleted)
    XCTAssertEqual(file.addedCount, 0)
    XCTAssertEqual(file.removedCount, 2)
    XCTAssertEqual(file.hunks[0].lines.map(\.oldLineNumber), [7, 8])
    XCTAssertEqual(file.hunks[0].lines.map(\.newLineNumber), [nil, nil])
  }

  func testParsesRenameMetadataWithoutHunks() {
    let diff = """
      diff --git a/Sources/Old Name.swift b/Sources/New Name.swift
      similarity index 100%
      rename from Sources/Old Name.swift
      rename to Sources/New Name.swift
      """

    let file = TatwoDiffHunkParser.parse(unifiedDiff: diff).files[0]

    XCTAssertEqual(file.oldPath, "Sources/Old Name.swift")
    XCTAssertEqual(file.newPath, "Sources/New Name.swift")
    XCTAssertEqual(file.changeKind, .renamed)
    XCTAssertEqual(file.hunks, [])
    XCTAssertEqual(file.addedCount, 0)
    XCTAssertEqual(file.removedCount, 0)
  }

  func testParsesMultipleFilesInInputOrder() {
    let diff = """
      diff --git a/A.swift b/A.swift
      --- a/A.swift
      +++ b/A.swift
      @@ -1 +1 @@
      -old
      +new
      diff --git a/B.swift b/B.swift
      new file mode 100644
      --- /dev/null
      +++ b/B.swift
      @@ -0,0 +1 @@
      +created
      """

    let parsed = TatwoDiffHunkParser.parse(unifiedDiff: diff)

    XCTAssertEqual(parsed.files.map(\.newPath), ["A.swift", "B.swift"])
    XCTAssertEqual(parsed.files.map(\.changeKind), [.modified, .added])
    XCTAssertEqual(parsed.files.map(\.addedCount), [1, 1])
    XCTAssertEqual(parsed.files.map(\.removedCount), [1, 0])
  }

  func testMarksBinaryFileAndSkipsBinaryPayload() {
    let diff = """
      diff --git a/Assets/icon.png b/Assets/icon.png
      index 1111111..2222222 100644
      GIT binary patch
      literal 3
      abc
      """

    let file = TatwoDiffHunkParser.parse(unifiedDiff: diff).files[0]

    XCTAssertEqual(file.oldPath, "Assets/icon.png")
    XCTAssertEqual(file.newPath, "Assets/icon.png")
    XCTAssertEqual(file.changeKind, .modified)
    XCTAssertTrue(file.isBinary)
    XCTAssertEqual(file.hunks, [])
    XCTAssertEqual(file.addedCount, 0)
    XCTAssertEqual(file.removedCount, 0)
  }

  func testIgnoresNoNewlineMarkerAndSupportsImplicitHunkCounts() {
    let diff = """
      diff --git a/File.txt b/File.txt
      --- a/File.txt
      +++ b/File.txt
      @@ -3 +3 @@
      -before
      \\ No newline at end of file
      +after
      \\ No newline at end of file
      """

    let lines = TatwoDiffHunkParser.parse(unifiedDiff: diff).files[0].hunks[0].lines

    XCTAssertEqual(lines.count, 2)
    XCTAssertEqual(lines[0].oldLineNumber, 3)
    XCTAssertEqual(lines[1].newLineNumber, 3)
  }

  func testDoesNotMistakeHunkContentForFilePathHeaders() {
    let diff = """
      diff --git a/File.txt b/File.txt
      --- a/File.txt
      +++ b/File.txt
      @@ -1 +1 @@
      --- old marker
      +++ new marker
      """

    let file = TatwoDiffHunkParser.parse(unifiedDiff: diff).files[0]

    XCTAssertEqual(file.oldPath, "File.txt")
    XCTAssertEqual(file.newPath, "File.txt")
    XCTAssertEqual(file.hunks[0].lines.map(\.text), ["-- old marker", "++ new marker"])
    XCTAssertEqual(file.removedCount, 1)
    XCTAssertEqual(file.addedCount, 1)
  }

  func testModelsRoundTripCodableAndAreSendable() throws {
    let parsed = TatwoDiffHunkParser.parse(
      unifiedDiff: """
        diff --git a/File.swift b/File.swift
        --- a/File.swift
        +++ b/File.swift
        @@ -1 +1 @@
        -before
        +after
        """)

    let decoded = try JSONDecoder().decode(
      TatwoParsedDiff.self,
      from: JSONEncoder().encode(parsed))

    XCTAssertEqual(decoded, parsed)
    assertSendable(decoded)
    assertSendable(decoded.files[0])
    assertSendable(decoded.files[0].hunks[0])
    assertSendable(decoded.files[0].hunks[0].lines[0])
  }

  private func assertSendable<T: Sendable>(_ value: T) {
    _ = value
  }
}
