import Foundation

public enum TatwoGBrainLayer: String, Codable, Sendable, CaseIterable, Equatable {
  case curated
  case truth
}

public enum TatwoGBrainReaderStatus: String, Codable, Sendable, Equatable {
  case available
  case rootMissing = "root_missing"
  case permissionDenied = "permission_denied"
  case ioError = "io_error"
  case unavailable
  case invalidPath = "invalid_path"
  case entryMissing = "entry_missing"
}

public struct TatwoGBrainEntry: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let relativePath: String
  public let fileName: String
  public let title: String
  public let layer: TatwoGBrainLayer
  public let modifiedAt: Date
  public let size: Int64

  public init(
    relativePath: String,
    fileName: String,
    title: String,
    layer: TatwoGBrainLayer,
    modifiedAt: Date,
    size: Int64
  ) {
    self.id = relativePath
    self.relativePath = relativePath
    self.fileName = fileName
    self.title = title
    self.layer = layer
    self.modifiedAt = modifiedAt
    self.size = size
  }
}

public struct TatwoGBrainListResult: Codable, Sendable, Equatable {
  public let entries: [TatwoGBrainEntry]
  public let status: TatwoGBrainReaderStatus

  public init(entries: [TatwoGBrainEntry], status: TatwoGBrainReaderStatus) {
    self.entries = entries
    self.status = status
  }
}

public struct TatwoGBrainReadResult: Codable, Sendable, Equatable {
  public let content: String
  public let truncated: Bool
  public let status: TatwoGBrainReaderStatus

  public init(content: String, truncated: Bool, status: TatwoGBrainReaderStatus) {
    self.content = content
    self.truncated = truncated
    self.status = status
  }
}

public struct TatwoGBrainReader {
  public static let defaultMaximumReadBytes = 200 * 1_024

  public let rootURL: URL
  public let maximumReadBytes: Int
  private let externalReader: ExternalVolumeReader

  public init(
    rootURL: URL,
    maximumReadBytes: Int = TatwoGBrainReader.defaultMaximumReadBytes,
    fileManager: FileManager = .default,
    externalReader: ExternalVolumeReader? = nil
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.maximumReadBytes = max(1, maximumReadBytes)
    self.externalReader = externalReader
      ?? ExternalVolumeReader(
        rootURL: rootURL,
        fileSystem: FileManagerExternalVolumeFileSystem(fileManager: fileManager)
      )
  }

  public func list() -> TatwoGBrainListResult {
    let result = listOutcome()
    return result.value ?? TatwoGBrainListResult(
      entries: [],
      status: status(from: result.failure, fallback: .unavailable)
    )
  }

  public func listOutcome() -> ExternalReadOutcome<TatwoGBrainListResult> {
    switch rootStatus() {
    case .available:
      break
    case let status:
      return ExternalReadOutcome(
        value: TatwoGBrainListResult(entries: [], status: status),
        state: .unavailable,
        failure: failure(from: status),
        sourceKey: externalReader.sourceKey,
        diagnosticCode: status.rawValue)
    }

    var entries: [TatwoGBrainEntry] = []
    var firstFailure: ExternalReadOutcome<[ExternalVolumeDirectoryEntry]>?
    for layer in TatwoGBrainLayer.allCases {
      let layerURL = rootURL.appendingPathComponent(layer.rawValue, isDirectory: true)
      let layerResult = externalReader.readDirectorySync(layerURL)
      guard let candidates = layerResult.value else {
        if layerResult.failure != .volumeAbsent, firstFailure == nil {
          firstFailure = layerResult
        }
        continue
      }

      for candidateEntry in candidates {
        let candidate = candidateEntry.url
        guard isSupportedEntry(candidateEntry, within: layerURL) else { continue }
        let values = candidateEntry.info
        guard values.isRegularFile else { continue }

        let relativePath = "\(layer.rawValue)/\(candidate.lastPathComponent)"
        entries.append(
          TatwoGBrainEntry(
            relativePath: relativePath,
            fileName: candidate.lastPathComponent,
            title: title(for: candidate),
            layer: layer,
            modifiedAt: values.modifiedAt ?? .distantPast,
            size: values.size ?? 0))
      }
    }

    if let firstFailure {
      return ExternalReadOutcome(
        value: TatwoGBrainListResult(
          entries: [],
          status: status(
            from: firstFailure.failure,
            fallback: .unavailable
          )
        ),
        state: .unavailable,
        access: firstFailure.access,
        failure: firstFailure.failure,
        sourceKey: firstFailure.sourceKey,
        elapsedMs: firstFailure.elapsedMs,
        diagnosticCode: firstFailure.diagnosticCode
      )
    }

    entries.sort {
      if $0.layer != $1.layer {
        return $0.layer == .curated
      }
      return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
    }
    return ExternalReadOutcome(
      value: TatwoGBrainListResult(entries: entries, status: .available),
      state: .fresh,
      sourceKey: externalReader.sourceKey)
  }

  public func read(entryPath: String) -> TatwoGBrainReadResult {
    readOutcome(entryPath: entryPath).value
      ?? TatwoGBrainReadResult(content: "", truncated: false, status: .unavailable)
  }

  public func readOutcome(entryPath: String) -> ExternalReadOutcome<TatwoGBrainReadResult> {
    switch rootStatus() {
    case .available:
      break
    case let status:
      return ExternalReadOutcome(
        value: TatwoGBrainReadResult(content: "", truncated: false, status: status),
        state: .unavailable,
        failure: failure(from: status),
        sourceKey: externalReader.sourceKey,
        diagnosticCode: status.rawValue)
    }

    guard let entryURL = validatedEntryURL(for: entryPath) else {
      return ExternalReadOutcome(
        value: TatwoGBrainReadResult(content: "", truncated: false, status: .invalidPath),
        state: .unavailable,
        failure: .ioError,
        sourceKey: ExternalVolumeReader.sourceKey(
          for: rootURL,
          logicalResource: "gbrain:\(entryPath)"
        ),
        diagnosticCode: "invalid-path")
    }
    let probe = externalReader.inspectSync(entryURL)
    guard probe.value?.isRegularFile == true else {
      return ExternalReadOutcome(
        value: TatwoGBrainReadResult(content: "", truncated: false, status: .entryMissing),
        state: .unavailable,
        failure: probe.failure,
        sourceKey: probe.sourceKey,
        diagnosticCode: "entry-missing")
    }

    let readResult = externalReader.readBoundedFileSync(
      entryURL,
      maximumBytes: maximumReadBytes + 1
    )
    guard let data = readResult.value else {
      return Self.mapOutcome(
        readResult,
        value: TatwoGBrainReadResult(
          content: "",
          truncated: false,
          status: status(from: readResult.failure, fallback: .unavailable)
        )
      )
    }
    let truncated = data.count > maximumReadBytes
    let visibleData = truncated ? data.prefix(maximumReadBytes) : data[...]
    return Self.mapOutcome(
      readResult,
      value: TatwoGBrainReadResult(
        content: String(decoding: visibleData, as: UTF8.self),
        truncated: truncated,
        status: .available
      )
    )
  }

  private func rootStatus() -> TatwoGBrainReaderStatus {
    let result = externalReader.inspectSync()
    guard let info = result.value else {
      return status(from: result.failure, fallback: .unavailable)
    }
    return info.isDirectory ? .available : .rootMissing
  }

  private func validatedEntryURL(for entryPath: String) -> URL? {
    guard !entryPath.isEmpty, !entryPath.hasPrefix("/") else { return nil }
    let components = NSString(string: entryPath).pathComponents
    guard components.count == 2,
      TatwoGBrainLayer(rawValue: components[0]) != nil,
      ["md", "json"].contains((components[1] as NSString).pathExtension.lowercased())
    else {
      return nil
    }

    let candidate = rootURL.appendingPathComponent(entryPath).standardizedFileURL
    let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolvedCandidate.hasPrefix(resolvedRoot + "/") else { return nil }
    return candidate
  }

  private func isSupportedEntry(
    _ candidate: ExternalVolumeDirectoryEntry,
    within layerURL: URL
  ) -> Bool {
    guard ["md", "json"].contains(candidate.url.pathExtension.lowercased()),
      candidate.info.isRegularFile
    else { return false }
    let resolvedLayer = layerURL.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedCandidate = candidate.url.resolvingSymlinksInPath().standardizedFileURL.path
    return resolvedCandidate.hasPrefix(resolvedLayer + "/")
  }

  private func title(for fileURL: URL) -> String {
    guard fileURL.pathExtension.lowercased() == "md" else {
      return fileURL.deletingPathExtension().lastPathComponent
    }
    guard let data = externalReader.readBoundedFileSync(fileURL, maximumBytes: 4_096).value,
      let firstLine = String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .first
    else {
      return fileURL.deletingPathExtension().lastPathComponent
    }

    let line = firstLine.trimmingCharacters(in: .whitespaces)
    guard line.hasPrefix("#") else {
      return fileURL.deletingPathExtension().lastPathComponent
    }
    let heading = line.drop(while: { $0 == "#" })
      .trimmingCharacters(in: .whitespaces)
    return heading.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : heading
  }

  private func status(from failure: ExternalVolumeFailure?, fallback: TatwoGBrainReaderStatus) -> TatwoGBrainReaderStatus {
    switch failure {
    case .volumeAbsent: return .rootMissing
    case .permissionDenied: return .permissionDenied
    case .ioError: return .ioError
    case nil: return fallback
    }
  }

  private func failure(from status: TatwoGBrainReaderStatus) -> ExternalVolumeFailure? {
    switch status {
    case .rootMissing, .entryMissing: return .volumeAbsent
    case .permissionDenied: return .permissionDenied
    case .ioError, .unavailable, .invalidPath: return .ioError
    case .available: return nil
    }
  }

  private static func mapOutcome<T>(
    _ outcome: ExternalReadOutcome<T>,
    value: TatwoGBrainReadResult
  ) -> ExternalReadOutcome<TatwoGBrainReadResult> where T: Sendable {
    ExternalReadOutcome(
      value: value,
      state: outcome.state,
      access: outcome.access,
      failure: outcome.failure,
      lastGoodAt: outcome.lastGoodAt,
      sourceKey: outcome.sourceKey,
      elapsedMs: outcome.elapsedMs,
      diagnosticCode: outcome.diagnosticCode
    )
  }
}
