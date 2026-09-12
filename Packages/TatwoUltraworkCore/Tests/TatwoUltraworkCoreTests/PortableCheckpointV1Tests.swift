import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class PortableCheckpointV1Tests: XCTestCase {
  func testContentHashIsCanonicalAndExcludesItself() throws {
    let checkpoint = try PortableCheckpointV1(
      goals: ["ship K1"],
      decisions: ["fail closed"],
      facts: ["schema is frozen"],
      toolSummaries: ["read boundary"],
      pending: ["restore validation"],
      artifactRefs: [
        PortableCheckpointArtifactRef(path: "artifacts/a.txt", digest: sha256("a"))
      ],
      parentCheckpointHash: sha256("parent"),
      sourceEventRange: PortableCheckpointEventRange(first: 1, last: 4),
      lossLedger: [
        PortableCheckpointLoss(item: "old transcript", classification: .omitted)
      ])

    let encoded = try JSONEncoder.sorted.encode(checkpoint)
    let decoded = try JSONDecoder().decode(PortableCheckpointV1.self, from: encoded)

    XCTAssertEqual(decoded.contentHash, checkpoint.contentHash)
    XCTAssertEqual(try decoded.recomputedContentHash(), checkpoint.contentHash)
    XCTAssertEqual(checkpoint.contentHash.count, 64)
  }

  func testUnknownMajorSchemaVersionIsRejected() throws {
    let checkpoint = try fixture()
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.sorted.encode(checkpoint))
        as? [String: Any])
    object["schemaVersion"] = 2
    let tampered = try JSONSerialization.data(withJSONObject: object)

    XCTAssertThrowsError(
      try PortableCheckpointV1.decodeAndValidate(tampered)
    ) { error in
      XCTAssertEqual(
        error as? PortableCheckpointValidationError,
        .unsupportedMajorVersion(2))
    }
  }

  func testRequiredMissingBlocksRestore() throws {
    let checkpoint = try PortableCheckpointV1(
      goals: [],
      decisions: [],
      facts: [],
      toolSummaries: [],
      pending: [],
      artifactRefs: [],
      parentCheckpointHash: nil,
      sourceEventRange: PortableCheckpointEventRange(first: 0, last: 0),
      lossLedger: [
        PortableCheckpointLoss(
          item: "approval receipt",
          classification: .requiredMissing)
      ])

    XCTAssertThrowsError(try checkpoint.validateForRestore()) { error in
      XCTAssertEqual(
        error as? PortableCheckpointValidationError,
        .restoreBlocked(reason: .missingDependency))
    }
  }

  func testRestoreValidatorChecksContentHashAndArtifactDigest() throws {
    let root = temporaryDirectory()
    let artifactURL = root.appendingPathComponent("artifacts/a.txt")
    try FileManager.default.createDirectory(
      at: artifactURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data("original".utf8).write(to: artifactURL)
    let checkpoint = try PortableCheckpointV1(
      goals: ["g"],
      decisions: [],
      facts: [],
      toolSummaries: [],
      pending: [],
      artifactRefs: [
        .init(path: "artifacts/a.txt", digest: sha256("original"))
      ],
      parentCheckpointHash: nil,
      sourceEventRange: .init(first: 1, last: 1),
      lossLedger: [])

    XCTAssertNoThrow(try checkpoint.validateForRestore(artifactRoot: root))

    try Data("tampered".utf8).write(to: artifactURL)
    XCTAssertThrowsError(
      try checkpoint.validateForRestore(artifactRoot: root)
    ) { error in
      XCTAssertEqual(
        error as? PortableCheckpointValidationError,
        .artifactDigestMismatch(path: "artifacts/a.txt"))
    }
  }

  func testRestoreValidatorRejectsMissingOrEscapingArtifact() throws {
    let root = temporaryDirectory()
    for path in ["missing.txt", "../escape.txt"] {
      let checkpoint = try PortableCheckpointV1(
        goals: [],
        decisions: [],
        facts: [],
        toolSummaries: [],
        pending: [],
        artifactRefs: [.init(path: path, digest: sha256("x"))],
        parentCheckpointHash: nil,
        sourceEventRange: .init(first: 0, last: 0),
        lossLedger: [])
      XCTAssertThrowsError(
        try checkpoint.validateForRestore(artifactRoot: root)
      ) { error in
        XCTAssertEqual(
          error as? PortableCheckpointValidationError,
          .artifactUnavailable(path: path))
      }
    }
  }

  private func fixture() throws -> PortableCheckpointV1 {
    try PortableCheckpointV1(
      goals: ["g"],
      decisions: ["d"],
      facts: ["f"],
      toolSummaries: ["t"],
      pending: ["p"],
      artifactRefs: [],
      parentCheckpointHash: nil,
      sourceEventRange: PortableCheckpointEventRange(first: 1, last: 1),
      lossLedger: [])
  }

  private func sha256(_ value: String) -> String {
    AgentKernelDigest.sha256Hex(Data(value.utf8))
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}

private extension JSONEncoder {
  static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}
