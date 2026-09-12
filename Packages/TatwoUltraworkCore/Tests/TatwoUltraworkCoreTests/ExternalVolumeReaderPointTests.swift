import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ExternalVolumeReaderPointTests: XCTestCase {
  private struct FailureFileSystem: ExternalVolumeFileSystem {
    enum Mode: Sendable {
      case absent
      case denied
      case io
    }

    let mode: Mode

    func inspect(_ url: URL) throws -> ExternalVolumeFileInfo {
      throw error()
    }

    func listDirectory(
      _ url: URL,
      maximumEntries: Int
    ) throws -> [ExternalVolumeDirectoryEntry] {
      throw error()
    }

    func readFile(_ url: URL, maximumBytes: Int) throws -> Data {
      throw error()
    }

    private func error() -> NSError {
      switch mode {
      case .absent:
        return NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
      case .denied:
        return NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
      case .io:
        return NSError(domain: "fixture", code: 77)
      }
    }
  }

  func testSandboxPointPreservesVolumeAbsentOutcome() {
    let root = URL(
      fileURLWithPath: "/Volumes/F7-sandbox-missing-\(UUID().uuidString)",
      isDirectory: true)
    let reader = ExternalVolumeReader(
      rootURL: root,
      fileSystem: FailureFileSystem(mode: .absent))

    let outcome = TatwoSandboxRunReader(
      rootURL: root,
      externalReader: reader
    ).listRunsOutcome()

    XCTAssertEqual(outcome.failure, .volumeAbsent)
    XCTAssertEqual(outcome.state, .unavailable)
    XCTAssertNil(outcome.value)
  }

  func testGBrainPointPreservesPermissionDeniedOutcome() {
    let root = URL(fileURLWithPath: "/tmp/F7-gbrain-denied", isDirectory: true)
    let reader = ExternalVolumeReader(
      rootURL: root,
      fileSystem: FailureFileSystem(mode: .denied))

    let outcome = TatwoGBrainReader(
      rootURL: root,
      externalReader: reader
    ).listOutcome()

    XCTAssertEqual(outcome.failure, .permissionDenied)
    XCTAssertEqual(outcome.state, .unavailable)
    XCTAssertEqual(outcome.value?.status, .permissionDenied)
  }

  func testGBrainDetailPointPreservesEntryMissingOutcome() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("F7-gbrain-detail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let outcome = TatwoGBrainReader(rootURL: root).readOutcome(
      entryPath: "curated/missing.md")

    XCTAssertEqual(outcome.failure, .volumeAbsent)
    XCTAssertEqual(outcome.state, .unavailable)
    XCTAssertEqual(outcome.value?.status, .entryMissing)
  }

  func testSkillsPointPreservesIOOutcome() {
    let root = URL(fileURLWithPath: "/tmp/F7-skills-io", isDirectory: true)
    let reader = ExternalVolumeReader(
      rootURL: root,
      fileSystem: FailureFileSystem(mode: .io))

    let outcome = TatwoSkillsDirectoryCatalog(rootURL: root).scanOutcome(
      registeredPaths: [],
      reader: reader)

    XCTAssertEqual(outcome.failure, .ioError)
    XCTAssertEqual(outcome.state, .unavailable)
    XCTAssertNil(outcome.value)
  }

  func testSkillsDetailPointPreservesMissingOutcome() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("F7-skills-detail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let outcome = TatwoSkillsDirectoryCatalog(rootURL: root).loadDetailOutcome(
      id: "missing")

    XCTAssertEqual(outcome.failure, .volumeAbsent)
    XCTAssertEqual(outcome.state, .unavailable)
    XCTAssertNil(outcome.value)
  }
}
