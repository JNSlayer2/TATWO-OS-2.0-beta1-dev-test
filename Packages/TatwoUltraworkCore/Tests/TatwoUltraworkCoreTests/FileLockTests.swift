import XCTest

@testable import TatwoUltraworkCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

final class FileLockTests: XCTestCase {
  func testLockSetupFailureDoesNotExecuteProtectedMutation() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-file-lock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blockingFile = root.appendingPathComponent("not-a-directory")
    try Data("x".utf8).write(to: blockingFile)
    let target = blockingFile.appendingPathComponent("state.json")
    var executed = false

    XCTAssertThrowsError(
      try TatwoFileLock.withExclusiveLock(for: target) {
        executed = true
      })
    XCTAssertFalse(executed)
  }

  func testLockTimeoutDoesNotExecuteProtectedMutation() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-file-lock-timeout-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("state.json")
    let lockURL = target.appendingPathExtension("lock")
    let descriptor = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
    defer { flock(descriptor, LOCK_UN) }
    var executed = false

    XCTAssertThrowsError(
      try TatwoFileLock.withExclusiveLock(for: target, timeout: 0.05) {
        executed = true
      }
    ) { error in
      guard case let TatwoFileLockError.timedOut(path, waited) = error else {
        return XCTFail("Expected timedOut, got \(error)")
      }
      XCTAssertEqual(path, lockURL.path)
      XCTAssertGreaterThanOrEqual(waited, 0.05)
    }
    XCTAssertFalse(executed)
  }
}
