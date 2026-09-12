import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

enum TatwoAtomicFileFaultPoint: String, Sendable, Equatable {
  case beforeFileSync
  case beforeRename
  case beforeDirectorySync
}

final class TatwoAtomicFileFaultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var failAt: TatwoAtomicFileFaultPoint?

  init(failAt: TatwoAtomicFileFaultPoint? = nil) {
    self.failAt = failAt
  }

  func setFailAt(_ point: TatwoAtomicFileFaultPoint?) {
    lock.lock()
    failAt = point
    lock.unlock()
  }

  func check(_ point: TatwoAtomicFileFaultPoint) throws {
    lock.lock()
    let shouldFail = failAt == point
    lock.unlock()
    if shouldFail {
      throw POSIXError(.EIO)
    }
  }
}

/// Atomic replacement for the sandboxed remote-loop channel and its registry projection.
///
/// Foundation's nested `.atomic` write can be rejected by the managed workspace when the
/// destination itself is already a temporary file. A plain temp write followed by POSIX
/// `rename(2)` keeps the required temp+rename semantics without that extra staging layer.
///
/// Durability order is explicit: write all bytes, sync the temporary file, rename, then sync
/// the parent directory. An error after rename is an intentionally ambiguous outcome: callers
/// must reopen and reconcile the durable truth rather than assuming rollback.
enum TatwoAtomicFile {
  static func write(
    _ data: Data,
    to url: URL,
    faultBox: TatwoAtomicFileFaultBox? = nil
  ) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    let temporary = parent
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    var renamed = false
    do {
      try writeAndSync(data, to: temporary, faultBox: faultBox)
      try faultBox?.check(.beforeRename)
      let result = temporary.path.withCString { source in
        url.path.withCString { destination in
          rename(source, destination)
        }
      }
      guard result == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      renamed = true
      try faultBox?.check(.beforeDirectorySync)
      try syncDirectory(parent)
    } catch {
      if !renamed {
        try? FileManager.default.removeItem(at: temporary)
      }
      throw error
    }
  }

  static func syncDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { _ = close(descriptor) }
    while fsync(descriptor) != 0 {
      if errno == EINTR { continue }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  fileprivate static func writeAndSync(
    _ data: Data,
    to url: URL,
    faultBox: TatwoAtomicFileFaultBox?
  ) throws {
    let descriptor = open(
      url.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
      S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var isOpen = true
    defer {
      if isOpen { _ = close(descriptor) }
    }
    try writeAll(data, descriptor: descriptor)
    try faultBox?.check(.beforeFileSync)
    try syncRegularFile(descriptor)
    isOpen = false
    guard close(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  /// macOS `F_FULLFSYNC` is the strongest regular-file flush request available
  /// through this API. Failure is fail-closed, but even a successful request is
  /// not an absolute guarantee against every hardware power-loss mode.
  /// Directory-entry durability remains a separate parent-directory `fsync(2)`.
  private static func syncRegularFile(_ descriptor: Int32) throws {
    #if canImport(Darwin)
    while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
      if errno == EINTR { continue }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    #elseif canImport(Glibc)
    while Glibc.fsync(descriptor) != 0 {
      if errno == EINTR { continue }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    #endif
  }

  private static func writeAll(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else {
        if raw.count == 0 { return }
        throw POSIXError(.EIO)
      }
      var offset = 0
      while offset < raw.count {
        #if canImport(Darwin)
        let count = Darwin.write(
          descriptor,
          base.advanced(by: offset),
          raw.count - offset)
        #elseif canImport(Glibc)
        let count = Glibc.write(
          descriptor,
          base.advanced(by: offset),
          raw.count - offset)
        #endif
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        offset += count
      }
    }
  }
}

/// Create-only durable write (`O_CREAT|O_EXCL`). Atomic fence for test/file stores.
/// On EEXIST, `onDuplicate` decides accept (load-and-compare) vs reject.
public enum TatwoCreateOnlyFile {
  public static func write(
    _ data: Data,
    to url: URL,
    onDuplicate: () throws -> Void
  ) throws {
    try write(
      data,
      to: url,
      onDuplicate: onDuplicate,
      publishFence: nil,
      faultBox: nil)
  }

  /// Result of the single create-only publication syscall.
  enum PublishResult: Sendable, Equatable {
    case created
    case duplicate
  }

  /// Create-only write with an optional synchronous publication fence.
  ///
  /// The fence is called after the temporary payload has been fully written and
  /// file-synced, and it receives a `publish()` closure that performs the single
  /// `link(2)` create-only publication point. Callers that own a separate
  /// liveness/authority cell can therefore make the final pathname visible only
  /// while that authority is still current, without holding that authority across
  /// payload write/fsync or parent-directory fsync.
  static func write(
    _ data: Data,
    to url: URL,
    onDuplicate: () throws -> Void,
    publishFence: ((_ publish: () throws -> PublishResult) throws -> PublishResult)? = nil,
    faultBox: TatwoAtomicFileFaultBox?
  ) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])

    // Never stream bytes into the final pathname. A duplicate must observe either
    // no entry or a fully written, fully file-synced inode. `link(2)` supplies the
    // create-if-absent publication fence without replace semantics.
    let temporary = parent
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    var temporaryExists = true
    defer {
      if temporaryExists {
        #if canImport(Darwin)
        _ = Darwin.unlink(temporary.path)
        #elseif canImport(Glibc)
        _ = Glibc.unlink(temporary.path)
        #endif
      }
    }

    try TatwoAtomicFile.writeAndSync(data, to: temporary, faultBox: faultBox)
    let publish: () throws -> PublishResult = {
      let publishResult = temporary.path.withCString { source in
        url.path.withCString { destination in
          #if canImport(Darwin)
          Darwin.link(source, destination)
          #elseif canImport(Glibc)
          Glibc.link(source, destination)
          #endif
        }
      }
      if publishResult != 0 {
        let publishErrno = errno
        if publishErrno == EEXIST {
          return .duplicate
        }
        throw POSIXError(POSIXErrorCode(rawValue: publishErrno) ?? .EIO)
      }
      return .created
    }

    let publishResult: PublishResult
    if let publishFence {
      publishResult = try publishFence(publish)
    } else {
      publishResult = try publish()
    }

    switch publishResult {
    case .duplicate:
      // The winner published a closed, file-synced inode. Validate it, then
      // sync the shared directory so an in-flight winner's entry is durable
      // before accepting this duplicate as committed.
      try onDuplicate()
      try TatwoAtomicFile.syncDirectory(parent)
      return
    case .created:
      break
    }

    #if canImport(Darwin)
    let unlinkResult = Darwin.unlink(temporary.path)
    #elseif canImport(Glibc)
    let unlinkResult = Glibc.unlink(temporary.path)
    #endif
    guard unlinkResult == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    temporaryExists = false

    // Failure from here is an ambiguous outcome: the fully synced payload is
    // already visible at the final create-only path and must be reconciled.
    try faultBox?.check(.beforeDirectorySync)
    try TatwoAtomicFile.syncDirectory(parent)
  }
}
