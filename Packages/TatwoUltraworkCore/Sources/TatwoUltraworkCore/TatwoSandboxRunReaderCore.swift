import Foundation

public struct TatwoSandboxRun: Codable, Sendable, Identifiable, Equatable {
  public var id: String { "\(sandboxType)/\(runID)" }

  public let runID: String
  public let sandboxType: String
  public let modifiedAt: Date
  public let hasSummary: Bool
  public let hasSeal: Bool
  public let hasScoreReport: Bool

  public init(
    runID: String,
    sandboxType: String,
    modifiedAt: Date,
    hasSummary: Bool,
    hasSeal: Bool,
    hasScoreReport: Bool
  ) {
    self.runID = runID
    self.sandboxType = sandboxType
    self.modifiedAt = modifiedAt
    self.hasSummary = hasSummary
    self.hasSeal = hasSeal
    self.hasScoreReport = hasScoreReport
  }
}

public struct TatwoSandboxRunReader {
  public let rootURL: URL
  private let externalReader: ExternalVolumeReader

  public init(
    rootURL: URL,
    fileManager: FileManager = .default,
    externalReader: ExternalVolumeReader? = nil
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.externalReader = externalReader
      ?? ExternalVolumeReader(
        rootURL: rootURL,
        fileSystem: FileManagerExternalVolumeFileSystem(fileManager: fileManager)
      )
  }

  public func listRuns() -> [TatwoSandboxRun] {
    listRunsOutcome().value ?? []
  }

  public func listRunsOutcome() -> ExternalReadOutcome<[TatwoSandboxRun]> {
    let rootProbe = externalReader.inspectSync()
    guard rootProbe.value?.isDirectory == true else {
      return Self.mapOutcome(rootProbe, value: nil)
    }
    let rootList = externalReader.readDirectorySync()
    guard rootList.value != nil else {
      return Self.mapOutcome(rootList, value: nil)
    }

    var runs: [TatwoSandboxRun] = []
    var firstFailure: ExternalReadOutcome<[ExternalVolumeDirectoryEntry]>?
    for sandboxType in sandboxTypes(topLevel: rootList.value ?? []) {
      let typeURL = rootURL.appendingPathComponent(sandboxType, isDirectory: true)
      let typeResult = externalReader.readDirectorySync(typeURL)
      if typeResult.value == nil, firstFailure == nil {
        firstFailure = typeResult
      }
      let candidates = typeResult.value ?? []

      for candidate in candidates {
        let runURL = candidate.url
        guard candidate.info.isDirectory,
          !candidate.info.isSymbolicLink,
          isContained(runURL, by: typeURL)
        else {
          continue
        }

        let receipts = receiptPresence(in: runURL)
        runs.append(
          TatwoSandboxRun(
            runID: runURL.lastPathComponent,
            sandboxType: sandboxType,
            modifiedAt: candidate.info.modifiedAt ?? .distantPast,
            hasSummary: externalReader.inspectSync(
              runURL.appendingPathComponent("summary.json")
            ).value?.isRegularFile == true,
            hasSeal: receipts.hasSeal,
            hasScoreReport: receipts.hasScoreReport))
      }
    }

    let sorted = runs.sorted {
      if $0.modifiedAt != $1.modifiedAt {
        return $0.modifiedAt > $1.modifiedAt
      }
      if $0.sandboxType != $1.sandboxType {
        return $0.sandboxType.localizedStandardCompare($1.sandboxType) == .orderedAscending
      }
      return $0.runID.localizedStandardCompare($1.runID) == .orderedAscending
    }
    if runs.isEmpty, let firstFailure {
      return Self.mapOutcome(firstFailure, value: nil)
    }
    return ExternalReadOutcome(
      value: sorted,
      state: .fresh,
      access: rootProbe.access,
      sourceKey: externalReader.sourceKey,
      elapsedMs: rootProbe.elapsedMs)
  }

  public func readSummary(for run: TatwoSandboxRun) -> String? {
    readSummary(sandboxType: run.sandboxType, runID: run.runID)
  }

  public func readSummary(sandboxType: String, runID: String) -> String? {
    readSummaryOutcome(sandboxType: sandboxType, runID: runID).value
  }

  public func readSummaryOutcome(
    sandboxType: String,
    runID: String
  ) -> ExternalReadOutcome<String> {
    guard sandboxTypes(
      topLevel: externalReader.readDirectorySync().value ?? []
    ).contains(sandboxType),
      isSinglePathComponent(runID)
    else {
      return ExternalReadOutcome(
        value: nil,
        state: .unavailable,
        failure: .ioError,
        sourceKey: ExternalVolumeReader.sourceKey(
          for: rootURL,
          logicalResource: "summary:\(sandboxType)/\(runID)"
        ),
        diagnosticCode: "invalid-run-path")
    }

    let typeURL = rootURL.appendingPathComponent(sandboxType, isDirectory: true)
    let runURL = typeURL.appendingPathComponent(runID, isDirectory: true)
    guard isReadableDirectory(runURL), isContained(runURL, by: typeURL) else {
      let result = externalReader.inspectSync(runURL)
      return Self.mapOutcome(result, value: nil)
    }

    let summaryURL = runURL.appendingPathComponent("summary.json")
    let probe = externalReader.inspectSync(summaryURL)
    guard let values = probe.value,
      values.isRegularFile,
      !values.isSymbolicLink,
      isContained(summaryURL, by: runURL)
    else {
      return Self.mapOutcome(probe, value: nil)
    }
    let result = externalReader.readBoundedFileSync(summaryURL, maximumBytes: 512 * 1_024)
    guard let data = result.value, let text = String(data: data, encoding: .utf8) else {
      return Self.mapOutcome(result, value: nil, diagnosticCode: "invalid-utf8")
    }
    return Self.mapOutcome(result, value: text)
  }

  private func sandboxTypes(
    topLevel: [ExternalVolumeDirectoryEntry]
  ) -> [String] {
    var types = topLevel.compactMap { entry -> String? in
      let url = entry.url
      guard url.lastPathComponent.hasSuffix("沙盒"),
        entry.info.isDirectory,
        !entry.info.isSymbolicLink
      else {
        return nil
      }
      return url.lastPathComponent
    }

    let modeling3D = rootURL.appendingPathComponent("3D測試/模型", isDirectory: true)
    if isReadableDirectory(modeling3D) {
      types.append("3D測試/模型")
    }
    return types.sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
  }

  private func receiptPresence(in runURL: URL) -> (hasSeal: Bool, hasScoreReport: Bool) {
    var hasSeal = false
    var hasScoreReport = false
    var pending: [(url: URL, depth: Int)] = [(runURL, 0)]

    while let current = pending.popLast() {
      guard current.depth < 4 else { continue }
      let result = externalReader.readDirectorySync(current.url)
      guard let entries = result.value else { continue }

      for entry in entries {
        let candidate = entry.url
        let info = entry.info
        guard !info.isSymbolicLink else { continue }

        if info.isDirectory {
          guard !["generated-project", "generated-artifacts"]
            .contains(candidate.lastPathComponent)
          else { continue }
          pending.append((candidate, current.depth + 1))
          continue
        }

        guard info.isRegularFile else { continue }
        switch candidate.lastPathComponent {
        case "seal.json":
          hasSeal = true
        case "評分報告.json":
          hasScoreReport = true
        default:
          break
        }
        if hasSeal && hasScoreReport { return (true, true) }
      }
    }
    return (hasSeal, hasScoreReport)
  }

  private func isReadableDirectory(_ url: URL) -> Bool {
    guard let values = externalReader.inspectSync(url).value else { return false }
    return values.isDirectory && !values.isSymbolicLink
  }

  private func isContained(_ candidate: URL, by parent: URL) -> Bool {
    let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
    return resolvedCandidate.hasPrefix(resolvedParent + "/")
  }

  private func isSinglePathComponent(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/") else { return false }
    let components = NSString(string: value).pathComponents
    return components.count == 1 && components[0] != "." && components[0] != ".."
  }

  private static func mapOutcome<T, V>(
    _ outcome: ExternalReadOutcome<T>,
    value: V?,
    diagnosticCode: String? = nil
  ) -> ExternalReadOutcome<V> where T: Sendable, V: Sendable {
    ExternalReadOutcome(
      value: value,
      state: outcome.state,
      access: outcome.access,
      failure: outcome.failure,
      lastGoodAt: outcome.lastGoodAt,
      sourceKey: outcome.sourceKey,
      elapsedMs: outcome.elapsedMs,
      diagnosticCode: diagnosticCode ?? outcome.diagnosticCode
    )
  }
}
