import Foundation

public enum TatwoActivitySourceKind: String, Codable, Sendable, Equatable {
  case dispatchRegistry
  case codexSessionJSONL
}

public enum TatwoActivityModelConfidence: String, Codable, Sendable, Equatable {
  case explicitTurnContext
  case providerOnly
}

public struct TatwoRecentActivityRecord: Identifiable, Sendable, Equatable, Codable {
  public let id: String
  public let modelID: String
  public let modelProvider: String
  public let originator: String
  public let workdirSummary: String
  public let statusText: String
  public let startedAt: Date
  public let updatedAt: Date
  public let sourceKind: TatwoActivitySourceKind
  public let modelConfidence: TatwoActivityModelConfidence

  public init(
    id: String,
    modelID: String,
    modelProvider: String,
    originator: String,
    workdirSummary: String,
    statusText: String,
    startedAt: Date,
    updatedAt: Date,
    sourceKind: TatwoActivitySourceKind,
    modelConfidence: TatwoActivityModelConfidence
  ) {
    self.id = id
    self.modelID = modelID
    self.modelProvider = modelProvider
    self.originator = originator
    self.workdirSummary = workdirSummary
    self.statusText = statusText
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.sourceKind = sourceKind
    self.modelConfidence = modelConfidence
  }
}

/// Read-only bridge from Codex CLI/Desktop rollout JSONL into the App activity foldout.
///
/// This does not write to `TatwoDispatchRegistry` and does not invent dispatch records. It
/// projects observed Codex session metadata (model/provider/time/cwd/originator) as local UI
/// activity so the quota page can show real gateway work even when the Work OS dispatch
/// registry was not the caller that created the session.
public enum TatwoCodexSessionActivitySource {
  private static let maxRolloutFilesPerHome = 220
  private static let maxRolloutHeaderLines = 80
  private static let maxRolloutHeaderBytes = 512 * 1024

  public static func defaultCodexHomeCandidates(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    allowExternalVolumes: Bool = false
  ) -> [URL] {
    let home = environment["HOME"] ?? NSHomeDirectory()
    var paths: [String] = []
    if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
      paths.append(codexHome)
    }
    paths.append("\(home)/.codex")
    var seen = Set<String>()
    return paths.compactMap { raw in
      let url = URL(fileURLWithPath: raw, isDirectory: true)
      let key = url.standardizedFileURL.path
      // Skip candidates that resolve onto an external volume unless the caller
      // explicitly opted in. The lexical/readlink gate runs before the bounded
      // reader so launch-time activity refresh cannot trigger a TCC prompt.
      if !allowExternalVolumes, ExternalVolumeReader.isExternalVolumePath(key) { return nil }
      guard !seen.contains(key),
        ExternalVolumeReader(
          rootURL: url,
          policy: ExternalReadPolicy(allowExternalVolumes: allowExternalVolumes)
        ).inspectSync().value?.isDirectory == true
      else { return nil }
      seen.insert(key)
      return url
    }
  }

  /// Candidate paths for the bounded reader. This intentionally performs no
  /// filesystem probe, so an external path can be classified as not-enabled
  /// by `ExternalVolumeReader` without triggering a removable-volume prompt.
  public static func readerCandidateURLs(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [URL] {
    let home = environment["HOME"] ?? NSHomeDirectory()
    var paths: [String] = []
    if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
      paths.append(codexHome)
    }
    paths.append("\(home)/.codex")
    var seen = Set<String>()
    return paths.compactMap { raw in
      let url = URL(fileURLWithPath: raw, isDirectory: true)
      let key = url.standardizedFileURL.path
      guard seen.insert(key).inserted else { return nil }
      return url
    }
  }

  /// Dialog-safe external-volume probe: lexical mount-component check plus
  /// component-wise symlink resolution via `destinationOfSymbolicLink` (readlink,
  /// which reads the link itself and never accesses the link target). Mirrors
  /// `TatwoCodexAppStateBridge.SourcePaths`'s gate; kept local to avoid touching
  /// that type (dedup tracked in the code-health inventory).
  static func resolvesOntoExternalVolume(_ path: String) -> Bool {
    ExternalVolumeReader.isExternalVolumePath(path)
  }

  public static func loadRecentOutcome(
    codexHomeCandidates: [URL] = readerCandidateURLs(),
    since cutoff: Date,
    now: Date = Date(),
    limit: Int = 60,
    allowExternalVolumes: Bool = false,
    cacheRootURL: URL? = defaultActivityCacheRoot()
  ) -> ExternalReadOutcome<[TatwoRecentActivityRecord]> {
    let start = Date()
    var records: [TatwoRecentActivityRecord] = []
    var seenIDs = Set<String>()
    var firstFailure: (
      failure: ExternalVolumeFailure?,
      access: ExternalVolumeAccess,
      sourceKey: String,
      diagnosticCode: String
    )?

    for home in codexHomeCandidates {
      let reader = ExternalVolumeReader(
        rootURL: home,
        policy: ExternalReadPolicy(allowExternalVolumes: allowExternalVolumes)
      )
      let probe = reader.inspectSync()
      guard probe.value?.isDirectory == true else {
        if firstFailure == nil {
          firstFailure = (
            probe.failure,
            probe.access,
            probe.sourceKey,
            probe.diagnosticCode ?? "probe-failed"
          )
        }
        continue
      }
      let filesResult = rolloutFiles(
        in: home,
        reader: reader,
        since: cutoff,
        now: now
      )
      if firstFailure == nil, filesResult.value == nil {
        firstFailure = (
          filesResult.failure,
          filesResult.access,
          filesResult.sourceKey,
          filesResult.diagnosticCode ?? "list-failed"
        )
      }
      for file in filesResult.value ?? [] {
        guard let record = parseRollout(
          file,
          reader: reader,
          cutoff: cutoff,
          now: now
        ) else { continue }
        guard !seenIDs.contains(record.id) else { continue }
        seenIDs.insert(record.id)
        records.append(record)
      }
    }

    let value = Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    let elapsed = max(0, Int(Date().timeIntervalSince(start) * 1_000))
    let defaultSourceKey = ExternalVolumeReader.sourceKey(
      for: codexHomeCandidates.first ?? URL(fileURLWithPath: NSHomeDirectory()),
      logicalResource: "codex-session-activity"
    )
    if !value.isEmpty {
      let lastGoodAt = now
      writeActivityCache(
        value,
        lastGoodAt: lastGoodAt,
        sourceKey: defaultSourceKey,
        cacheRootURL: cacheRootURL)
      return ExternalReadOutcome(
        value: value,
        state: .fresh,
        lastGoodAt: lastGoodAt,
        sourceKey: defaultSourceKey,
        elapsedMs: elapsed)
    }
    if let firstFailure {
      if let cached = readActivityCache(
        sourceKey: defaultSourceKey,
        cacheRootURL: cacheRootURL
      ), let failure = firstFailure.failure {
        return ExternalReadOutcome(
          value: cached.records,
          state: .stale,
          access: firstFailure.access,
          failure: failure,
          lastGoodAt: cached.lastGoodAt,
          sourceKey: defaultSourceKey,
          elapsedMs: elapsed,
          diagnosticCode: firstFailure.diagnosticCode)
      }
      return ExternalReadOutcome(
        value: nil,
        state: .unavailable,
        access: firstFailure.access,
        failure: firstFailure.failure,
        sourceKey: firstFailure.sourceKey,
        elapsedMs: elapsed,
        diagnosticCode: firstFailure.diagnosticCode)
    }
    return ExternalReadOutcome(
      value: value,
      state: .fresh,
      sourceKey: defaultSourceKey,
      elapsedMs: elapsed)
  }

  public static func loadRecent(
    codexHomeCandidates: [URL] = readerCandidateURLs(),
    since cutoff: Date,
    now: Date = Date(),
    limit: Int = 60,
    allowExternalVolumes: Bool = false,
    cacheRootURL: URL? = defaultActivityCacheRoot()
  ) -> [TatwoRecentActivityRecord] {
    loadRecentOutcome(
      codexHomeCandidates: codexHomeCandidates,
      since: cutoff,
      now: now,
      limit: limit,
      allowExternalVolumes: allowExternalVolumes,
      cacheRootURL: cacheRootURL
    ).value ?? []
  }

  public static func defaultActivityCacheRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
      .appendingPathComponent("ExternalVolumeCache", isDirectory: true)
  }

  private struct ActivityCache: Codable {
    let schema: String
    let lastGoodAt: Date
    let records: [TatwoRecentActivityRecord]
  }

  private static func cacheURL(
    sourceKey: String,
    cacheRootURL: URL?
  ) -> URL? {
    guard let cacheRootURL else { return nil }
    return cacheRootURL.appendingPathComponent(
      "\(sourceKey)-codex-activity.json",
      isDirectory: false)
  }

  private static func writeActivityCache(
    _ records: [TatwoRecentActivityRecord],
    lastGoodAt: Date,
    sourceKey: String,
    cacheRootURL: URL?
  ) {
    guard let url = cacheURL(sourceKey: sourceKey, cacheRootURL: cacheRootURL) else { return }
    let envelope = ActivityCache(
      schema: "TatwoExternalVolumeActivityCacheV1",
      lastGoodAt: lastGoodAt,
      records: records)
    guard let data = try? JSONEncoder().encode(envelope) else { return }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try data.write(to: url, options: [.atomic])
    } catch {
      // Cache is an optimization; a cache write must never change fresh data.
    }
  }

  private static func readActivityCache(
    sourceKey: String,
    cacheRootURL: URL?
  ) -> ActivityCache? {
    guard let url = cacheURL(sourceKey: sourceKey, cacheRootURL: cacheRootURL),
      let data = try? Data(contentsOf: url),
      let envelope = try? JSONDecoder().decode(ActivityCache.self, from: data),
      envelope.schema == "TatwoExternalVolumeActivityCacheV1"
    else {
      return nil
    }
    return envelope
  }

  private static func rolloutFiles(
    in codexHome: URL,
    reader: ExternalVolumeReader,
    since cutoff: Date,
    now: Date
  ) -> ExternalReadOutcome<[URL]> {
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    let sessionsProbe = reader.inspectSync(sessions)
    if sessionsProbe.value?.isDirectory != true,
       sessionsProbe.failure != nil,
       sessionsProbe.failure != .volumeAbsent {
      return ExternalReadOutcome(
        value: nil,
        state: sessionsProbe.state,
        access: sessionsProbe.access,
        failure: sessionsProbe.failure,
        sourceKey: sessionsProbe.sourceKey,
        elapsedMs: sessionsProbe.elapsedMs,
        diagnosticCode: sessionsProbe.diagnosticCode)
    }
    if sessionsProbe.value?.isDirectory != true {
      return ExternalReadOutcome(
        value: [],
        state: .fresh,
        access: sessionsProbe.access,
        sourceKey: sessionsProbe.sourceKey,
        elapsedMs: sessionsProbe.elapsedMs)
    }
    let dayDirs = sessionDayDirs(sessionsRoot: sessions, since: cutoff, now: now)
    var files: [URL] = []
    for dir in dayDirs {
      let result = reader.readDirectorySync(dir)
      files.append(contentsOf: (result.value ?? []).map(\.url).filter {
        $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl"
      })
    }
    let datedFiles = files.map { ($0, rolloutSortDate($0, reader: reader)) }
    let sorted = Array(datedFiles.sorted { $0.1 > $1.1 }.prefix(maxRolloutFilesPerHome).map(\.0))
    return ExternalReadOutcome(
      value: sorted,
      state: .fresh,
      access: sessionsProbe.access,
      sourceKey: reader.sourceKey,
      elapsedMs: sessionsProbe.elapsedMs)
  }

  private static func rolloutSortDate(_ url: URL, reader: ExternalVolumeReader) -> Date {
    reader.inspectSync(url).value?.modifiedAt ?? .distantPast
  }

  private static func sessionDayDirs(sessionsRoot: URL, since cutoff: Date, now: Date) -> [URL] {
    let calendar = Calendar(identifier: .gregorian)
    let start = calendar.startOfDay(for: cutoff)
    let end = calendar.startOfDay(for: now)
    let days = max(0, calendar.dateComponents([.day], from: start, to: end).day ?? 0)
    return (0...days).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
      let parts = calendar.dateComponents([.year, .month, .day], from: date)
      guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
      return sessionsRoot
        .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
    }
  }

  private static func parseRollout(
    _ url: URL,
    reader: ExternalVolumeReader,
    cutoff: Date,
    now: Date
  ) -> TatwoRecentActivityRecord? {
    guard let data = reader.readBoundedFileSync(
      url,
      maximumBytes: maxRolloutHeaderBytes
    ).value else { return nil }
    guard let text = readRolloutHeader(data) else { return nil }

    var sessionID = url.deletingPathExtension().lastPathComponent
    var timestamp: Date?
    var cwd: String?
    var originator = ""
    var modelProvider = ""
    var model: String?

    for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(80) {
      guard
        let lineData = String(line).data(using: .utf8),
        let object = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
        let type = object["type"] as? String,
        let payload = object["payload"] as? [String: Any]
      else { continue }

      if type == "session_meta" {
        sessionID = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? sessionID
        if let rawTimestamp = payload["timestamp"] as? String {
          timestamp = parseDate(rawTimestamp)
        }
        cwd = payload["cwd"] as? String
        originator = (payload["originator"] as? String) ?? originator
        modelProvider = (payload["model_provider"] as? String) ?? modelProvider
      } else if type == "turn_context", model == nil {
        model = payload["model"] as? String
        cwd = cwd ?? (payload["cwd"] as? String)
      }

      if timestamp != nil, cwd != nil, !originator.isEmpty, !modelProvider.isEmpty, model != nil {
        break
      }
    }

    guard let observedAt = timestamp, observedAt >= cutoff, observedAt <= now.addingTimeInterval(60) else {
      return nil
    }
    guard originator == "codex_exec" || modelProvider == "model_gateway" else { return nil }

    let explicitModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelID: String
    let confidence: TatwoActivityModelConfidence
    if let explicitModel, !explicitModel.isEmpty {
      modelID = explicitModel
      confidence = .explicitTurnContext
    } else {
      modelID = modelProvider.isEmpty ? "codex-session" : modelProvider
      confidence = .providerOnly
    }

    return TatwoRecentActivityRecord(
      id: "codex-session-\(sessionID)",
      modelID: modelID,
      modelProvider: modelProvider.isEmpty ? "unknown-provider" : modelProvider,
      originator: originator.isEmpty ? "unknown-originator" : originator,
      workdirSummary: summarizeWorkdir(cwd ?? ""),
      statusText: "observed",
      startedAt: observedAt,
      updatedAt: observedAt,
      sourceKind: .codexSessionJSONL,
      modelConfidence: confidence)
  }

  private static func readRolloutHeader(_ data: Data) -> String? {
    guard !data.isEmpty else { return nil }
    let newlineCount = data.reduce(0) { partial, byte in
      partial + (byte == 10 ? 1 : 0)
    }
    let reachedEOF = data.count < maxRolloutHeaderBytes
    guard !data.isEmpty else { return nil }
    let completeData: Data
    if !reachedEOF, newlineCount >= maxRolloutHeaderLines,
       let lastNewline = data.lastIndex(of: 10),
       lastNewline < data.index(before: data.endIndex) {
      completeData = Data(data.prefix(through: lastNewline))
    } else {
      completeData = data
    }
    return String(decoding: completeData, as: UTF8.self)
  }

  private static func parseDate(_ raw: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }
    return ISO8601DateFormatter().date(from: raw)
  }

  static func summarizeWorkdir(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "unknown cwd" }
    let components = trimmed.split(separator: "/").map(String.init)
    guard let last = components.last else { return trimmed }
    if components.count >= 2 {
      return "\(components[components.count - 2])/\(last)"
    }
    return last
  }
}
