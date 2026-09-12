import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ExternalVolumeReaderTests: XCTestCase {
  private struct FakeFileSystem: ExternalVolumeFileSystem {
    enum Mode: Sendable {
      case absent
      case denied
      case io
      case success
      case delayed
    }

    let mode: Mode

    func inspect(_ url: URL) throws -> ExternalVolumeFileInfo {
      try throwIfNeeded()
      return ExternalVolumeFileInfo(
        isDirectory: true,
        isRegularFile: false,
        isSymbolicLink: false)
    }

    func listDirectory(
      _ url: URL,
      maximumEntries: Int
    ) throws -> [ExternalVolumeDirectoryEntry] {
      try throwIfNeeded()
      return []
    }

    func readFile(_ url: URL, maximumBytes: Int) throws -> Data {
      try throwIfNeeded()
      return Data("ok".utf8)
    }

    private func throwIfNeeded() throws {
      switch mode {
      case .absent:
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
      case .denied:
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
      case .io:
        throw NSError(domain: "fixture", code: 77)
      case .success:
        break
      case .delayed:
        // Must lose the timeout race even under heavy scheduler contention:
        // keep the stub delay orders of magnitude above the 10ms test timeout.
        Thread.sleep(forTimeInterval: 0.75)
      }
    }
  }

  func testInjectedMissingVolumeIsClassifiedWithoutTouchingTheVolume() {
    let root = URL(
      fileURLWithPath: "/Volumes/F7-missing-\(UUID().uuidString)",
      isDirectory: true)
    let reader = ExternalVolumeReader(
      rootURL: root,
      fileSystem: FakeFileSystem(mode: .absent))

    let outcome = reader.inspectSync()

    XCTAssertEqual(outcome.state, .unavailable)
    XCTAssertEqual(outcome.failure, .volumeAbsent)
    XCTAssertNil(outcome.value)
    XCTAssertFalse(outcome.sourceKey.contains("F7-missing"))
    XCTAssertEqual(outcome.access, .enabled)
  }

  func testPermissionAndIOErrorsRemainDistinct() {
    let root = URL(fileURLWithPath: "/tmp/injected-volume", isDirectory: true)
    let denied = ExternalVolumeReader(
      rootURL: root,
      fileSystem: FakeFileSystem(mode: .denied)
    ).inspectSync()
    let io = ExternalVolumeReader(
      rootURL: root,
      fileSystem: FakeFileSystem(mode: .io)
    ).inspectSync()

    XCTAssertEqual(denied.failure, .permissionDenied)
    XCTAssertEqual(io.failure, .ioError)
    XCTAssertNotEqual(denied.failure, io.failure)
  }

  func testExternalVolumePolicyStopsBeforeFilesystemProbe() {
    let root = URL(fileURLWithPath: "/Volumes/F7-not-enabled", isDirectory: true)
    let reader = ExternalVolumeReader(
      rootURL: root,
      policy: ExternalReadPolicy(allowExternalVolumes: false),
      fileSystem: FakeFileSystem(mode: .success))

    let outcome = reader.inspectSync()

    XCTAssertEqual(outcome.access, .notEnabled)
    XCTAssertEqual(outcome.state, .unavailable)
    XCTAssertNil(outcome.failure)
    XCTAssertEqual(outcome.diagnosticCode, "external-volume-opt-in-required")
  }

  func testAsyncTimeoutIsBoundedAndClassifiedAsIOError() async {
    let root = URL(fileURLWithPath: "/tmp/slow-volume", isDirectory: true)
    let reader = ExternalVolumeReader(
      rootURL: root,
      policy: ExternalReadPolicy(
        allowExternalVolumes: true,
        timeout: .milliseconds(10)),
      fileSystem: FakeFileSystem(mode: .delayed))

    let outcome = await reader.readBoundedFile(
      root.appendingPathComponent("large.json"),
      maximumBytes: 128)

    XCTAssertEqual(outcome.state, .unavailable)
    XCTAssertEqual(outcome.failure, .ioError)
    XCTAssertEqual(outcome.diagnosticCode, "timed-out")

    let syncOutcome = reader.inspectSync()
    XCTAssertEqual(syncOutcome.state, .unavailable)
    XCTAssertEqual(syncOutcome.failure, .ioError)
    XCTAssertEqual(syncOutcome.diagnosticCode, "timed-out")
  }
}
