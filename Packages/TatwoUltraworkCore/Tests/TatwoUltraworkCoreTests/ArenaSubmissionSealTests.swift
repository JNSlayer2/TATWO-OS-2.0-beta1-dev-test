import XCTest

@testable import TatwoUltraworkCore

/// Phase 3: prove the submission seal is trust-on-verify — tampering, additions, and
/// removals are all detected, and the arena's `runSummary` only counts a report as evidence
/// when its submission seal still verifies.
final class ArenaSubmissionSealTests: XCTestCase {
  private func makeDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "arena-seal-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  func testSealThenVerifyPasses() throws {
    let dir = makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("index", to: dir.appendingPathComponent("index.html"))
    try write("body{}", to: dir.appendingPathComponent("css/site.css"))

    let seal = try TatwoArenaSubmissionSealer.seal(directory: dir)
    XCTAssertTrue(seal.sealed)
    XCTAssertEqual(seal.fileHashes.count, 2)

    let verification = try TatwoArenaSubmissionSealer.verify(directory: dir, against: seal)
    XCTAssertTrue(verification.verified)
    XCTAssertEqual(verification.reason, "ok")
  }

  func testSignedSealVerifiesOnlyWithCorrectGraderKey() throws {
    let dir = makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("index", to: dir.appendingPathComponent("index.html"))

    let key = "grader-secret-123"
    let seal = try TatwoArenaSubmissionSealer.seal(directory: dir, signingKey: key)
    XCTAssertNotNil(seal.signature)

    // Correct key → provenance + tamper check pass.
    XCTAssertTrue(
      try TatwoArenaSubmissionSealer.verify(directory: dir, against: seal, signingKey: key).verified)
    // Wrong key → rejected as unauthorized even though the files are unchanged.
    let wrong = try TatwoArenaSubmissionSealer.verify(
      directory: dir, against: seal, signingKey: "attacker-key")
    XCTAssertFalse(wrong.verified)
    XCTAssertEqual(wrong.reason, "signature_mismatch")
  }

  func testSelfSealedSubmissionFailsProvenanceWhenKeyRequired() throws {
    let dir = makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("<h1>forged</h1>", to: dir.appendingPathComponent("index.html"))

    // A model self-seals its own project WITHOUT the grader key (signature nil).
    let selfSeal = try TatwoArenaSubmissionSealer.seal(directory: dir)
    XCTAssertNil(selfSeal.signature)

    // Tamper-only verify (no key) still passes — files match.
    XCTAssertTrue(try TatwoArenaSubmissionSealer.verify(directory: dir, against: selfSeal).verified)
    // But when a grader key is required, the unsigned self-seal is rejected.
    let gated = try TatwoArenaSubmissionSealer.verify(
      directory: dir, against: selfSeal, signingKey: "grader-secret-123")
    XCTAssertFalse(gated.verified)
    XCTAssertEqual(gated.reason, "unsigned")
  }

  func testTamperedFileFailsVerification() throws {
    let dir = makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("index.html")
    try write("original", to: file)
    let seal = try TatwoArenaSubmissionSealer.seal(directory: dir)

    try write("tampered", to: file)
    let verification = try TatwoArenaSubmissionSealer.verify(directory: dir, against: seal)
    XCTAssertFalse(verification.verified)
    XCTAssertEqual(verification.changed, ["index.html"])
  }

  func testAddedAndRemovedFilesFailVerification() throws {
    let dir = makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("a", to: dir.appendingPathComponent("a.txt"))
    let seal = try TatwoArenaSubmissionSealer.seal(directory: dir)

    try write("b", to: dir.appendingPathComponent("b.txt"))
    var verification = try TatwoArenaSubmissionSealer.verify(directory: dir, against: seal)
    XCTAssertFalse(verification.verified)
    XCTAssertEqual(verification.added, ["b.txt"])

    try FileManager.default.removeItem(at: dir.appendingPathComponent("a.txt"))
    try FileManager.default.removeItem(at: dir.appendingPathComponent("b.txt"))
    verification = try TatwoArenaSubmissionSealer.verify(directory: dir, against: seal)
    XCTAssertFalse(verification.verified)
    XCTAssertEqual(verification.removed, ["a.txt"])
  }

  func testUnsealedSealNeverVerifies() throws {
    let dir = makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let unsealed = TatwoArenaSubmissionSeal(sealed: false, fileHashes: [:])
    let verification = try TatwoArenaSubmissionSealer.verify(directory: dir, against: unsealed)
    XCTAssertFalse(verification.verified)
    XCTAssertEqual(verification.reason, "seal_not_sealed")
  }

  func testScaffoldStyleSealJSONDecodesLeniently() throws {
    // The arena scaffold writes a superset with no `algorithm` and sealed:false.
    let json = """
      {
        "schema": "TatwoArenaSubmissionSealV1",
        "caseID": "01-tattoo",
        "modelSlug": "fable-5",
        "sealed": false,
        "editable": true,
        "fileHashes": {}
      }
      """
    let seal = try JSONDecoder().decode(
      TatwoArenaSubmissionSeal.self, from: Data(json.utf8))
    XCTAssertFalse(seal.sealed)
    XCTAssertEqual(seal.algorithm, "sha256")
    XCTAssertTrue(seal.fileHashes.isEmpty)
  }

  // MARK: runSummary gate logic (the forged-report defense)

  func testRunSummaryCountsOnlyVerifiedSeals() throws {
    let modelFolder = makeDir()
    defer { try? FileManager.default.removeItem(at: modelFolder) }
    let generated = modelFolder.appendingPathComponent("generated-project", isDirectory: true)
    try write("<html>", to: generated.appendingPathComponent("index.html"))
    let sealURL = modelFolder.appendingPathComponent("final-submission/seal.json")
    let decoder = JSONDecoder()

    // A model-written report with an UNSEALED seal is not verified.
    try write(
      #"{"schema":"TatwoArenaSubmissionSealV1","sealed":false,"fileHashes":{}}"#, to: sealURL)
    XCTAssertFalse(
      TatwoWebArenaFactory.isReportSealVerified(modelFolder: modelFolder, decoder: decoder))

    // A real sealed seal over the current generated-project verifies.
    let seal = try TatwoArenaSubmissionSealer.seal(directory: generated)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try FileManager.default.createDirectory(
      at: sealURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(seal).write(to: sealURL)
    XCTAssertTrue(
      TatwoWebArenaFactory.isReportSealVerified(modelFolder: modelFolder, decoder: decoder))

    // Tampering the deliverable after sealing breaks verification.
    try write("<html> tampered", to: generated.appendingPathComponent("index.html"))
    XCTAssertFalse(
      TatwoWebArenaFactory.isReportSealVerified(modelFolder: modelFolder, decoder: decoder))
  }
}
