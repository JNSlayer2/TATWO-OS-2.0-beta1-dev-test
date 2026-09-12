import CryptoKit
import Foundation

/// The three filesystem failure classes exposed to UI and receipts.
public enum ExternalVolumeFailure: String, Codable, Sendable, Equatable {
  case volumeAbsent = "volume-absent"
  case permissionDenied = "permission-denied"
  case ioError = "io-error"
}

/// A policy outcome is deliberately separate from an I/O failure. A source that
/// has not been opted into is not the same thing as a mounted volume that
/// failed to read.
public enum ExternalVolumeAccess: String, Codable, Sendable, Equatable {
  case enabled
  case notEnabled = "not-enabled"
}

public enum ExternalReadState: String, Codable, Sendable, Equatable {
  case fresh
  case stale
  case unavailable
}

public struct ExternalReadPolicy: Sendable, Equatable {
  public var allowExternalVolumes: Bool
  public var timeout: Duration
  public var maximumEntries: Int

  public init(
    allowExternalVolumes: Bool = true,
    timeout: Duration = .seconds(2),
    maximumEntries: Int = 512
  ) {
    self.allowExternalVolumes = allowExternalVolumes
    self.timeout = timeout
    self.maximumEntries = max(1, maximumEntries)
  }

  public static let standard = Self()
}

public struct ExternalReadOutcome<Value: Sendable>: Sendable {
  public let value: Value?
  public let state: ExternalReadState
  public let access: ExternalVolumeAccess
  public let failure: ExternalVolumeFailure?
  public let lastGoodAt: Date?
  /// A SHA-256 of the normalized source identity. Raw absolute paths never
  /// leave this type.
  public let sourceKey: String
  public let elapsedMs: Int
  public let diagnosticCode: String?

  public init(
    value: Value?,
    state: ExternalReadState,
    access: ExternalVolumeAccess = .enabled,
    failure: ExternalVolumeFailure? = nil,
    lastGoodAt: Date? = nil,
    sourceKey: String,
    elapsedMs: Int = 0,
    diagnosticCode: String? = nil
  ) {
    self.value = value
    self.state = state
    self.access = access
    self.failure = failure
    self.lastGoodAt = lastGoodAt
    self.sourceKey = sourceKey
    self.elapsedMs = max(0, elapsedMs)
    self.diagnosticCode = diagnosticCode
  }

  public var isUsable: Bool {
    value != nil && (state == .fresh || state == .stale)
  }
}

extension ExternalReadOutcome: Codable where Value: Codable {}

public struct ExternalVolumeFileInfo: Codable, Sendable, Equatable {
  public let isDirectory: Bool
  public let isRegularFile: Bool
  public let isSymbolicLink: Bool
  public let modifiedAt: Date?
  public let size: Int64?

  public init(
    isDirectory: Bool,
    isRegularFile: Bool,
    isSymbolicLink: Bool,
    modifiedAt: Date? = nil,
    size: Int64? = nil
  ) {
    self.isDirectory = isDirectory
    self.isRegularFile = isRegularFile
    self.isSymbolicLink = isSymbolicLink
    self.modifiedAt = modifiedAt
    self.size = size
  }
}

public struct ExternalVolumeDirectoryEntry: Codable, Sendable, Equatable {
  public let url: URL
  public let info: ExternalVolumeFileInfo

  public init(url: URL, info: ExternalVolumeFileInfo) {
    self.url = url
    self.info = info
  }
}

public protocol ExternalVolumeFileSystem: Sendable {
  func inspect(_ url: URL) throws -> ExternalVolumeFileInfo
  func listDirectory(_ url: URL, maximumEntries: Int) throws -> [ExternalVolumeDirectoryEntry]
  func readFile(_ url: URL, maximumBytes: Int) throws -> Data
  func readFileWindow(_ url: URL, offset: UInt64, length: Int) throws -> Data
}

public extension ExternalVolumeFileSystem {
  func readFileWindow(_ url: URL, offset: UInt64, length: Int) throws -> Data {
    let data = try readFile(
      url,
      maximumBytes: Int(min(UInt64(Int.max), offset + UInt64(max(0, length)))))
    guard offset < UInt64(data.count) else { return Data() }
    let start = Int(offset)
    let end = min(data.count, start + max(0, length))
    return Data(data[start..<end])
  }
}

public struct FileManagerExternalVolumeFileSystem: @unchecked Sendable, ExternalVolumeFileSystem {
  public let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func inspect(_ url: URL) throws -> ExternalVolumeFileInfo {
    let values = try url.resourceValues(forKeys: [
      .isDirectoryKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .contentModificationDateKey,
      .fileSizeKey,
    ])
    return ExternalVolumeFileInfo(
      isDirectory: values.isDirectory == true,
      isRegularFile: values.isRegularFile == true,
      isSymbolicLink: values.isSymbolicLink == true,
      modifiedAt: values.contentModificationDate,
      size: values.fileSize.map(Int64.init))
  }

  public func listDirectory(
    _ url: URL,
    maximumEntries: Int
  ) throws -> [ExternalVolumeDirectoryEntry] {
    let urls = try fileManager.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .contentModificationDateKey,
        .fileSizeKey,
      ],
      options: [.skipsHiddenFiles])
    return try urls.prefix(maximumEntries).map {
      ExternalVolumeDirectoryEntry(url: $0, info: try inspect($0))
    }
  }

  public func readFile(_ url: URL, maximumBytes: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try handle.read(upToCount: max(1, maximumBytes)) ?? Data()
  }

  public func readFileWindow(_ url: URL, offset: UInt64, length: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: offset)
    return try handle.read(upToCount: max(0, length)) ?? Data()
  }
}

/// One bounded, injectable entry point for data rooted at a configurable
/// filesystem location. The synchronous methods are intended for existing
/// utility readers; UI callers should use the async methods so no filesystem
/// operation runs on the main actor.
public struct ExternalVolumeReader: Sendable {
  public let rootURL: URL
  public let policy: ExternalReadPolicy
  public let fileSystem: any ExternalVolumeFileSystem
  private let now: @Sendable () -> Date

  public init(
    rootURL: URL,
    policy: ExternalReadPolicy = .standard,
    fileSystem: any ExternalVolumeFileSystem = FileManagerExternalVolumeFileSystem(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.policy = policy
    self.fileSystem = fileSystem
    self.now = now
  }

  public var sourceKey: String {
    Self.sourceKey(for: rootURL)
  }

  public static func sourceKey(for url: URL, logicalResource: String = "") -> String {
    let identity = "\(url.standardizedFileURL.path)|\(logicalResource)"
    return SHA256.hash(data: Data(identity.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  public static func isExternalVolumePath(_ url: URL) -> Bool {
    isExternalVolumePath(url.standardizedFileURL.path)
  }

  public static func isExternalVolumePath(_ path: String) -> Bool {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    let components = standardized.split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
    guard let first = components.first, first == "Volumes" else {
      return resolvesSymlinkToExternalVolume(components: components)
    }
    return true
  }

  /// readlink-only symlink walk. It never stats or opens a symlink destination.
  private static func resolvesSymlinkToExternalVolume(components: [String]) -> Bool {
    var prefix = ""
    for component in components {
      prefix += "/" + component
      var target = prefix
      var hops = 32
      while hops > 0,
            let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target) {
        hops -= 1
        if destination.hasPrefix("/") {
          target = destination
        } else {
          target = ((target as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(destination)
        }
        let targetComponents = URL(fileURLWithPath: target).standardizedFileURL.path
          .split(separator: "/", omittingEmptySubsequences: true)
          .map(String.init)
        if targetComponents.first == "Volumes" {
          return true
        }
      }
    }
    return false
  }

  public func inspectSync(_ url: URL? = nil) -> ExternalReadOutcome<ExternalVolumeFileInfo> {
    let target = (url ?? rootURL).standardizedFileURL
    return performSync(target: target, operation: "inspect") {
      try fileSystem.inspect(target)
    }
  }

  public func readDirectorySync(
    _ url: URL? = nil,
    maximumEntries: Int? = nil
  ) -> ExternalReadOutcome<[ExternalVolumeDirectoryEntry]> {
    let target = (url ?? rootURL).standardizedFileURL
    let limit = max(1, maximumEntries ?? policy.maximumEntries)
    return performSync(target: target, operation: "list") {
      try fileSystem.listDirectory(target, maximumEntries: limit)
    }
  }

  public func readBoundedFileSync(
    _ url: URL,
    maximumBytes: Int
  ) -> ExternalReadOutcome<Data> {
    let target = url.standardizedFileURL
    return performSync(target: target, operation: "read") {
      try fileSystem.readFile(target, maximumBytes: max(1, maximumBytes))
    }
  }

  public func readFileWindowSync(
    _ url: URL,
    offset: UInt64,
    length: Int
  ) -> ExternalReadOutcome<Data> {
    let target = url.standardizedFileURL
    return performSync(target: target, operation: "read-window") {
      try fileSystem.readFileWindow(target, offset: offset, length: length)
    }
  }

  public func inspect(_ url: URL? = nil) async -> ExternalReadOutcome<ExternalVolumeFileInfo> {
    await performAsync(target: (url ?? rootURL).standardizedFileURL, operation: "inspect") {
      try fileSystem.inspect((url ?? rootURL).standardizedFileURL)
    }
  }

  public func readDirectory(
    _ url: URL? = nil,
    maximumEntries: Int? = nil
  ) async -> ExternalReadOutcome<[ExternalVolumeDirectoryEntry]> {
    let target = (url ?? rootURL).standardizedFileURL
    let limit = max(1, maximumEntries ?? policy.maximumEntries)
    return await performAsync(target: target, operation: "list") {
      try fileSystem.listDirectory(target, maximumEntries: limit)
    }
  }

  public func readBoundedFile(_ url: URL, maximumBytes: Int) async -> ExternalReadOutcome<Data> {
    let target = url.standardizedFileURL
    return await performAsync(target: target, operation: "read") {
      try fileSystem.readFile(target, maximumBytes: max(1, maximumBytes))
    }
  }

  private func performSync<Value: Sendable>(
    target: URL,
    operation: String,
    work: @escaping @Sendable () throws -> Value
  ) -> ExternalReadOutcome<Value> {
    let start = now()
    guard policy.allowExternalVolumes || !Self.isExternalVolumePath(target) else {
      return outcome(
        value: nil,
        state: .unavailable,
        access: .notEnabled,
        target: target,
        start: start,
        operation: operation,
        diagnosticCode: "external-volume-opt-in-required")
    }
    let lock = NSLock()
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Value, Error>?
    DispatchQueue.global(qos: .utility).async {
      do {
        let value = try work()
        lock.lock()
        result = .success(value)
        lock.unlock()
      } catch {
        lock.lock()
        result = .failure(error)
        lock.unlock()
      }
      semaphore.signal()
    }

    let timeout = DispatchTime.now() + timeoutInterval
    guard semaphore.wait(timeout: timeout) == .success else {
      return failureOutcome(
        ExternalVolumeReaderTimeout(),
        target: target,
        start: start,
        operation: operation)
    }
    lock.lock()
    let resolved = result
    lock.unlock()
    switch resolved {
    case let .success(value):
      return outcome(
        value: value,
        state: .fresh,
        target: target,
        start: start,
        operation: operation)
    case let .failure(error):
      return failureOutcome(error, target: target, start: start, operation: operation)
    case nil:
      return failureOutcome(
        ExternalVolumeReaderTimeout(),
        target: target,
        start: start,
        operation: operation)
    }
  }

  private func performAsync<Value: Sendable>(
    target: URL,
    operation: String,
    work: @escaping @Sendable () throws -> Value
  ) async -> ExternalReadOutcome<Value> {
    let start = now()
    guard policy.allowExternalVolumes || !Self.isExternalVolumePath(target) else {
      return outcome(
        value: nil,
        state: .unavailable,
        access: .notEnabled,
        target: target,
        start: start,
        operation: operation,
        diagnosticCode: "external-volume-opt-in-required")
    }

    let timeout = policy.timeout
    do {
      let value = try await withCheckedThrowingContinuation { continuation in
        let gate = ExternalVolumeCompletionGate<Value>(continuation: continuation)
        Task.detached(priority: .utility) {
          do {
            gate.finish(.success(try work()))
          } catch {
            gate.finish(.failure(error))
          }
        }
        Task.detached(priority: .utility) {
          do {
            try await Task.sleep(for: timeout)
            gate.finish(.failure(ExternalVolumeReaderTimeout()))
          } catch {
            // Cancellation of the timeout task does not alter the read result.
          }
        }
      }
      return outcome(
        value: value,
        state: .fresh,
        target: target,
        start: start,
        operation: operation)
    } catch {
      return failureOutcome(error, target: target, start: start, operation: operation)
    }
  }

  private func outcome<Value: Sendable>(
    value: Value?,
    state: ExternalReadState,
    access: ExternalVolumeAccess = .enabled,
    failure: ExternalVolumeFailure? = nil,
    target: URL,
    start: Date,
    operation: String,
    diagnosticCode: String? = nil
  ) -> ExternalReadOutcome<Value> {
    let elapsed = max(0, Int(now().timeIntervalSince(start) * 1_000))
    return ExternalReadOutcome(
      value: value,
      state: state,
      access: access,
      failure: failure,
      sourceKey: Self.sourceKey(for: target, logicalResource: operation),
      elapsedMs: elapsed,
      diagnosticCode: diagnosticCode)
  }

  private func failureOutcome<Value>(
    _ error: Error,
    target: URL,
    start: Date,
    operation: String
  ) -> ExternalReadOutcome<Value> where Value: Sendable {
    let classification = Self.classify(error)
    return outcome(
      value: nil,
      state: .unavailable,
      failure: classification.failure,
      target: target,
      start: start,
      operation: operation,
      diagnosticCode: classification.code)
  }

  private var timeoutInterval: TimeInterval {
    let components = policy.timeout.components
    return max(
      0,
      TimeInterval(components.seconds)
        + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
  }

  public static func classify(_ error: Error) -> (failure: ExternalVolumeFailure, code: String) {
    if error is ExternalVolumeReaderTimeout {
      return (.ioError, "timed-out")
    }
    let nsError = error as NSError
    let code = nsError.code
    if nsError.domain == NSCocoaErrorDomain {
      if [
        CocoaError.fileReadNoSuchFile.rawValue,
        CocoaError.fileNoSuchFile.rawValue,
      ].contains(code) {
        return (.volumeAbsent, "no-such-file")
      }
      if [
        CocoaError.fileReadNoPermission.rawValue,
        CocoaError.fileWriteNoPermission.rawValue,
      ].contains(code) {
        return (.permissionDenied, "permission-denied")
      }
    }
    if nsError.domain == NSPOSIXErrorDomain {
      switch Int32(code) {
      case ENOENT, ENODEV, ENXIO:
        return (.volumeAbsent, "posix-\(code)")
      case EACCES, EPERM:
        return (.permissionDenied, "posix-\(code)")
      default:
        break
      }
    }
    return (.ioError, "\(nsError.domain)-\(code)")
  }
}

private final class ExternalVolumeCompletionGate<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var resolved = false

  init(continuation: CheckedContinuation<Value, Error>) {
    self.continuation = continuation
  }

  func finish(_ result: Result<Value, Error>) {
    lock.lock()
    guard !resolved, let continuation else {
      lock.unlock()
      return
    }
    resolved = true
    self.continuation = nil
    lock.unlock()
    continuation.resume(with: result)
  }
}

private struct ExternalVolumeReaderTimeout: Error {}
