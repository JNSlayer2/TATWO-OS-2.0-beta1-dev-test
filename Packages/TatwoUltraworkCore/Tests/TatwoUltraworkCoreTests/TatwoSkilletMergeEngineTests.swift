import CryptoKit
import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoSkilletMergeEngineTests: XCTestCase {
    func testMergesNonOverlappingTextEditsDeterministically() {
        let base = data("one\ntwo\nthree\nfour\n")
        let result = merge(
            base: ["SKILL.md": base],
            canonical: ["SKILL.md": data("ONE\ntwo\nthree\nfour\n")],
            proposed: ["SKILL.md": data("one\ntwo\nthree\nFOUR\n")]
        )

        XCTAssertTrue(result.isClean)
        XCTAssertEqual(
            String(data: result.mergedFiles["SKILL.md"]!, encoding: .utf8),
            "ONE\ntwo\nthree\nFOUR\n"
        )
    }

    func testCollapsesIdenticalEdit() {
        let result = merge(
            base: ["SKILL.md": data("base\n")],
            canonical: ["SKILL.md": data("same\n")],
            proposed: ["SKILL.md": data("same\n")]
        )

        XCTAssertTrue(result.isClean)
        XCTAssertEqual(result.mergedFiles["SKILL.md"], data("same\n"))
    }

    func testMergesIndependentAdditionAndDeletion() {
        let result = merge(
            base: [
                "SKILL.md": data("manifest\n"),
                "remove.txt": data("old\n"),
            ],
            canonical: [
                "SKILL.md": data("manifest\n"),
                "canonical.txt": data("canonical\n"),
            ],
            proposed: [
                "SKILL.md": data("manifest\n"),
                "remove.txt": data("old\n"),
                "proposed.txt": data("proposed\n"),
            ]
        )

        XCTAssertTrue(result.isClean)
        XCTAssertNil(result.mergedFiles["remove.txt"])
        XCTAssertEqual(result.mergedFiles["canonical.txt"], data("canonical\n"))
        XCTAssertEqual(result.mergedFiles["proposed.txt"], data("proposed\n"))
    }

    func testProducesConflictForOverlappingTextEditsWithoutMarkers() {
        let result = merge(
            base: ["SKILL.md": data("one\ntwo\nthree\n")],
            canonical: ["SKILL.md": data("one\nCANONICAL\nthree\n")],
            proposed: ["SKILL.md": data("one\nPROPOSED\nthree\n")]
        )

        XCTAssertFalse(result.isClean)
        XCTAssertEqual(result.conflicts.map(\.kind), [.overlappingTextEdits])
        XCTAssertNil(result.mergedFiles["SKILL.md"])
    }

    func testProducesConflictForDifferingBinaryChanges() {
        let result = merge(
            base: ["SKILL.md": Data([0, 1, 2])],
            canonical: ["SKILL.md": Data([0, 1, 3])],
            proposed: ["SKILL.md": Data([0, 1, 4])]
        )

        XCTAssertEqual(result.conflicts.map(\.kind), [.binaryChange])
    }

    func testDeleteModifyConflictPreservesDeletedSideProvenance() {
        let base = data("base\n")
        let canonical = data("canonical\n")

        let proposedDeletion = merge(
            base: [
                "SKILL.md": data("manifest\n"),
                "note.txt": base,
            ],
            canonical: [
                "SKILL.md": data("manifest\n"),
                "note.txt": canonical,
            ],
            proposed: [
                "SKILL.md": data("manifest\n"),
            ]
        )
        let proposedDeletionConflict = proposedDeletion.conflicts.first {
            $0.relativePath == "note.txt"
        }
        XCTAssertEqual(proposedDeletionConflict?.kind, .deleteModify)
        XCTAssertEqual(
            proposedDeletionConflict?.canonicalContentDigest,
            digest(canonical)
        )
        XCTAssertNil(proposedDeletionConflict?.proposedContentDigest)

        let canonicalDeletion = merge(
            base: [
                "SKILL.md": data("manifest\n"),
                "note.txt": base,
            ],
            canonical: [
                "SKILL.md": data("manifest\n"),
            ],
            proposed: [
                "SKILL.md": data("manifest\n"),
                "note.txt": canonical,
            ]
        )
        let canonicalDeletionConflict = canonicalDeletion.conflicts.first {
            $0.relativePath == "note.txt"
        }
        XCTAssertEqual(canonicalDeletionConflict?.kind, .deleteModify)
        XCTAssertNil(canonicalDeletionConflict?.canonicalContentDigest)
        XCTAssertEqual(
            canonicalDeletionConflict?.proposedContentDigest,
            digest(canonical)
        )
    }

    func testLargeLineCountFailsClosedWithoutBuildingQuadraticLCSTable() {
        let lineCount = 50_000
        let baseLines = (0..<lineCount).map { "line-\($0)" }
        var canonicalLines = baseLines
        var proposedLines = baseLines
        canonicalLines[0] = "canonical"
        proposedLines[lineCount - 1] = "proposed"

        let result = merge(
            base: ["SKILL.md": data(baseLines.joined(separator: "\n"))],
            canonical: ["SKILL.md": data(canonicalLines.joined(separator: "\n"))],
            proposed: ["SKILL.md": data(proposedLines.joined(separator: "\n"))]
        )

        XCTAssertFalse(result.isClean)
        XCTAssertEqual(result.conflicts.map(\.kind), [.mergeComplexityExceeded])
        XCTAssertNil(result.mergedFiles["SKILL.md"])
    }

    func testPathPrefixCollisionFailsClosedAsDeterministicConflict() {
        let result = merge(
            base: [
                "SKILL.md": data("manifest\n"),
            ],
            canonical: [
                "SKILL.md": data("manifest\n"),
                "notes": data("canonical file\n"),
            ],
            proposed: [
                "SKILL.md": data("manifest\n"),
                "notes/extra.txt": data("proposed nested file\n"),
            ]
        )

        XCTAssertFalse(result.isClean)
        XCTAssertEqual(
            result.conflicts.filter { $0.kind == .renameCollision }
                .map(\.relativePath),
            ["notes", "notes/extra.txt"]
        )
        XCTAssertNil(result.mergedFiles["notes"])
        XCTAssertNil(result.mergedFiles["notes/extra.txt"])
    }

    func testMissingBaseFailsClosedAsUnrelatedHistory() {
        let result = TatwoSkilletMergeEngine.merge(
            repositoryID: "skill",
            sourceDeviceID: "macbook",
            baseRevisionID: nil,
            canonicalRevisionID: revision("canonical"),
            proposedRevisionID: revision("proposed"),
            baseFiles: nil,
            canonicalFiles: ["SKILL.md": data("canonical")],
            proposedFiles: ["SKILL.md": data("proposed")]
        )

        XCTAssertEqual(result.conflicts.map(\.kind), [.unrelatedHistory])
        XCTAssertTrue(result.mergedFiles.isEmpty)
    }

    func testResultDoesNotDependOnDictionaryInsertionOrder() {
        let baseA = [
            "SKILL.md": data("one\ntwo\nthree\n"),
            "a.txt": data("a"),
        ]
        let baseB = Dictionary(uniqueKeysWithValues: baseA.reversed())
        let canonicalA = [
            "SKILL.md": data("ONE\ntwo\nthree\n"),
            "a.txt": data("a"),
        ]
        let canonicalB = Dictionary(uniqueKeysWithValues: canonicalA.reversed())
        let proposedA = [
            "SKILL.md": data("one\ntwo\nTHREE\n"),
            "a.txt": data("a"),
        ]
        let proposedB = Dictionary(uniqueKeysWithValues: proposedA.reversed())

        XCTAssertEqual(
            merge(base: baseA, canonical: canonicalA, proposed: proposedA),
            merge(base: baseB, canonical: canonicalB, proposed: proposedB)
        )
    }

    func testMergesExactRenameWithModificationOntoRenamedPath() {
        let result = merge(
            base: [
                "SKILL.md": data("manifest\n"),
                "old.txt": data("base\n"),
            ],
            canonical: [
                "SKILL.md": data("manifest\n"),
                "new.txt": data("base\n"),
            ],
            proposed: [
                "SKILL.md": data("manifest\n"),
                "old.txt": data("modified\n"),
            ]
        )

        XCTAssertTrue(result.isClean)
        XCTAssertNil(result.mergedFiles["old.txt"])
        XCTAssertEqual(result.mergedFiles["new.txt"], data("modified\n"))
    }

    private func merge(
        base: [String: Data],
        canonical: [String: Data],
        proposed: [String: Data]
    ) -> TatwoSkilletMergeResultV1 {
        TatwoSkilletMergeEngine.merge(
            repositoryID: "skill",
            sourceDeviceID: "macbook",
            baseRevisionID: revision("base"),
            canonicalRevisionID: revision("canonical"),
            proposedRevisionID: revision("proposed"),
            baseFiles: base,
            canonicalFiles: canonical,
            proposedFiles: proposed
        )
    }

    private func data(_ value: String) -> Data {
        Data(value.utf8)
    }

    private func revision(_ seed: String) -> String {
        "rev-\(digest(Data(seed.utf8)))"
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
