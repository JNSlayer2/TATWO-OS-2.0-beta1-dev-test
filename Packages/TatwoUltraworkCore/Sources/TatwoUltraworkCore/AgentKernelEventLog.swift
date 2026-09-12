import Foundation

public enum AgentKernelStoreError: Error, Equatable {
  case leaseHeld
  case corrupt
  case sequenceMismatch
  case schemaMismatch
}

public final class AgentKernelEventLog: @unchecked Sendable {
  private let root: URL
  private let fileManager = FileManager.default
  private let lock = NSLock()
  private var lastEventCache: [String: (signature: FileSignature, event: AgentKernelEvent?)] = [:]

  public init(root: URL) {
    self.root = root.standardizedFileURL
  }

  public func acquireLease(runID: String) throws {
    try lock.withLock {
      let leaseURL = runDirectory(runID)
        .appendingPathComponent("run.lease")
      try TatwoCreateOnlyFile.write(
        Data(UUID().uuidString.utf8),
        to: leaseURL,
        onDuplicate: {
          throw AgentKernelStoreError.leaseHeld
        })
    }
  }

  public func releaseLease(runID: String) throws {
    try lock.withLock {
      let leaseURL = runDirectory(runID)
        .appendingPathComponent("run.lease")
      if fileManager.fileExists(atPath: leaseURL.path) {
        try fileManager.removeItem(at: leaseURL)
      }
    }
  }

  public func append(_ event: AgentKernelEvent) throws {
    try lock.withLock {
      guard event.schemaVersion == AgentKernelSchema.version else {
        throw AgentKernelStoreError.schemaMismatch
      }

      let previous = try lastEventUnlocked(runID: event.runID)
      guard event.eventSequence == (previous?.eventSequence ?? 0) + 1,
            event.runSequence == (previous?.runSequence ?? 0) + 1
      else {
        throw AgentKernelStoreError.sequenceMismatch
      }

      let logURL = eventsURL(event.runID)
      try fileManager.createDirectory(
        at: logURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      let storedEvent = event.sealed(after: previous)
      var data = try Self.encoder.encode(storedEvent)
      data.append(0x0A)

      if !fileManager.fileExists(atPath: logURL.path) {
        guard fileManager.createFile(atPath: logURL.path, contents: nil) else {
          throw CocoaError(.fileWriteUnknown)
        }
      }
      let handle = try FileHandle(forWritingTo: logURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.synchronize()
      lastEventCache[event.runID] = (
        signature: try fileSignature(logURL),
        event: storedEvent)
    }
  }

  public func read(runID: String) throws -> [AgentKernelEvent] {
    try lock.withLock {
      try readUnlocked(runID)
    }
  }

  public func lastEvent(runID: String) throws -> AgentKernelEvent? {
    try lock.withLock {
      try lastEventUnlocked(runID: runID)
    }
  }

  public func readRecoverablePrefix(runID: String) throws -> [AgentKernelEvent] {
    try lock.withLock {
      let url = eventsURL(runID)
      guard fileManager.fileExists(atPath: url.path) else { return [] }
      let data = try Data(contentsOf: url)
      let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
      var valid: [AgentKernelEvent] = []
      for line in lines {
        if line.isEmpty { continue }
        guard let event = try? Self.decoder.decode(
          AgentKernelEvent.self,
          from: Data(line)),
          (try? validate(valid + [event], runID: runID)) != nil
        else {
          break
        }
        valid.append(event)
      }
      return valid
    }
  }

  public func saveSnapshot(_ snapshot: AgentKernelSnapshot) throws {
    try lock.withLock {
      guard snapshot.schemaVersion == AgentKernelSchema.version else {
        throw AgentKernelStoreError.schemaMismatch
      }
      let lastEvent = try lastEventUnlocked(runID: snapshot.runID)
      guard (lastEvent?.eventSequence ?? 0) == snapshot.lastEventSequence else {
        throw AgentKernelStoreError.sequenceMismatch
      }
      try writeAtomically(
        snapshot,
        to: runDirectory(snapshot.runID)
          .appendingPathComponent("snapshot.json"))
    }
  }

  public func loadSnapshot(runID: String) throws -> AgentKernelSnapshot? {
    try lock.withLock {
      let url = runDirectory(runID)
        .appendingPathComponent("snapshot.json")
      guard fileManager.fileExists(atPath: url.path) else {
        return nil
      }
      do {
        let snapshot = try Self.decoder.decode(
          AgentKernelSnapshot.self,
          from: Data(contentsOf: url))
        guard snapshot.schemaVersion == AgentKernelSchema.version else {
          throw AgentKernelStoreError.schemaMismatch
        }
        guard snapshot.runID == runID,
              snapshot.lastEventSequence <= (try lastEventUnlocked(runID: runID)?.eventSequence ?? 0)
        else {
          throw AgentKernelStoreError.corrupt
        }
        return snapshot
      } catch let error as AgentKernelStoreError {
        throw error
      } catch {
        throw AgentKernelStoreError.corrupt
      }
    }
  }

  private func readUnlocked(_ runID: String) throws -> [AgentKernelEvent] {
    let url = eventsURL(runID)
    guard fileManager.fileExists(atPath: url.path) else {
      return []
    }

    do {
      let data = try Data(contentsOf: url)
      guard data.isEmpty || data.last == 0x0A else {
        throw AgentKernelStoreError.corrupt
      }
      let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
      var events: [AgentKernelEvent] = []
      for line in lines.dropLast() {
        guard !line.isEmpty else {
          throw AgentKernelStoreError.corrupt
        }
        events.append(try Self.decoder.decode(AgentKernelEvent.self, from: Data(line)))
      }
      try validate(events, runID: runID)
      lastEventCache[runID] = (
        signature: try fileSignature(url),
        event: events.last)
      return events
    } catch let error as AgentKernelStoreError {
      throw error
    } catch {
      throw AgentKernelStoreError.corrupt
    }
  }

  private func lastEventUnlocked(runID: String) throws -> AgentKernelEvent? {
    let url = eventsURL(runID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let signature = try fileSignature(url)
    if let cached = lastEventCache[runID],
       cached.signature == signature
    {
      return cached.event
    }
    return try readUnlocked(runID).last
  }

  private func validate(
    _ events: [AgentKernelEvent],
    runID: String
  ) throws {
    var previous: AgentKernelEvent?
    for (index, event) in events.enumerated() {
      guard event.schemaVersion == AgentKernelSchema.version else {
        throw AgentKernelStoreError.schemaMismatch
      }
      guard event.runID == runID else {
        throw AgentKernelStoreError.corrupt
      }
      let expected = index + 1
      guard event.eventSequence == expected,
            event.runSequence == expected
      else {
        throw AgentKernelStoreError.corrupt
      }
      guard event.previousEventHash == previous?.eventHash,
            event.hasValidHash()
      else {
        throw AgentKernelStoreError.corrupt
      }
      previous = event
    }
  }

  private func eventsURL(_ runID: String) -> URL {
    runDirectory(runID).appendingPathComponent("events.jsonl")
  }

  private struct FileSignature: Equatable {
    let size: UInt64
    let modifiedAt: Date
  }

  private func fileSignature(_ url: URL) throws -> FileSignature {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    return FileSignature(
      size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
      modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast)
  }

  private func runDirectory(_ runID: String) -> URL {
    root.appendingPathComponent(
      runID.replacingOccurrences(of: "/", with: "_"),
      isDirectory: true)
  }

  private func writeAtomically<T: Encodable>(
    _ value: T,
    to url: URL
  ) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Self.encoder.encode(value).write(to: url, options: .atomic)
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
