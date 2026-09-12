import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

enum TatwoFileLockError: Error, LocalizedError, Sendable, Equatable {
  case directoryCreationFailed(String)
  case openFailed(path: String, code: Int32)
  case acquireFailed(path: String, code: Int32)
  case timedOut(path: String, waited: TimeInterval)

  var errorDescription: String? {
    switch self {
    case .directoryCreationFailed(let path):
      return "Could not create lock directory: \(path)"
    case let .openFailed(path, code):
      return "Could not open lock file \(path): errno \(code)"
    case let .acquireFailed(path, code):
      return "Could not acquire lock file \(path): errno \(code)"
    case let .timedOut(path, waited):
      return "Timed out acquiring lock file \(path) after \(waited) seconds"
    }
  }
}

/// Cross-process **advisory** lock for cooperative writer serialization.
///
/// Security-critical fences (execution claims, install seals, per-job high-water) MUST use
/// create-only primitives (`SecItemAdd` / `O_CREAT|O_EXCL`) as the truth. This flock helper
/// may reduce lost cooperative updates for non-security RMW, but lock pathnames are
/// unlink/replaceable — never treat the lock inode as an atomic authority.
///
/// The stores write `.atomic`, which makes each individual write all-or-nothing, but does NOT
/// serialize a read → mutate → write across processes: two concurrent `begin`s could both read
/// the same run, both pass the helper cap, and one overwrite the other. This wraps that critical
/// section in a `flock(2)` exclusive lock on a per-file `.lock` sibling so the section runs one
/// at a time. Lock setup/acquisition failures are fail-closed: the protected mutation never runs.
enum TatwoFileLock {
  static func withExclusiveLock<T>(
    for url: URL,
    timeout: TimeInterval = 8,
    _ body: () throws -> T
  ) throws -> T {
    let lockURL = url.appendingPathExtension("lock")
    do {
      try FileManager.default.createDirectory(
        at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      throw TatwoFileLockError.directoryCreationFailed(
        lockURL.deletingLastPathComponent().path)
    }
    let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
    guard fd >= 0 else {
      throw TatwoFileLockError.openFailed(path: lockURL.path, code: errno)
    }
    defer { close(fd) }
    let startedAt = ProcessInfo.processInfo.systemUptime
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      if code == EINTR { continue }
      guard code == EWOULDBLOCK || code == EAGAIN else {
        throw TatwoFileLockError.acquireFailed(path: lockURL.path, code: code)
      }
      let waited = ProcessInfo.processInfo.systemUptime - startedAt
      guard waited < timeout else {
        throw TatwoFileLockError.timedOut(path: lockURL.path, waited: waited)
      }
      Thread.sleep(forTimeInterval: min(0.02, max(0, timeout - waited)))
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }
}
