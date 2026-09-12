import Foundation

public struct TatwoCoworkTicketTemplate: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let displayName: String
  public let category: String
  public let mode: WorkModeID
  public let scenarioID: String
  public let baseScenario: ScenarioID?
  public let identityBindings: [TatwoScenarioIdentityBinding]
  public let tokenBudget: String
  public let agentsMarkdown: String

  public init(
    id: String,
    displayName: String,
    category: String,
    mode: WorkModeID,
    scenarioID: String,
    baseScenario: ScenarioID?,
    identityBindings: [TatwoScenarioIdentityBinding],
    tokenBudget: String,
    agentsMarkdown: String
  ) {
    self.id = id
    self.displayName = displayName
    self.category = category
    self.mode = mode
    self.scenarioID = scenarioID
    self.baseScenario = baseScenario
    self.identityBindings = identityBindings
    self.tokenBudget = tokenBudget
    self.agentsMarkdown = agentsMarkdown
  }

  public var shortLabel: String {
    displayName.replacingOccurrences(of: " · ", with: " ")
  }

  public var identitySummaryLines: [String] {
    identityBindings.map { binding in
      let models = binding.boundModelIDs.isEmpty ? "未綁定" : binding.boundModelIDs.joined(separator: ", ")
      return "- \(binding.phase.chineseName) \(binding.identity): \(models) — \(binding.responsibility)"
    }
  }

  public func prefixedTicket(userText: String) -> String {
    let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
    [TATWO Ultrawork 情境模板]
    template=\(displayName)
    scenarioID=\(scenarioID)
    mode=\(mode.rawValue)
    baseScenario=\(baseScenario?.rawValue ?? "custom")
    tokenBudget=\(tokenBudget)
    Plan/Loops/Goal 身份組:
    \(identitySummaryLines.joined(separator: "\n"))

    agentsContext:
    \(agentsMarkdown)

    [工單]
    \(trimmed)
    """
  }
}

public enum TatwoCoworkTemplateFactory {
  public static func templates(from book: TatwoScenarioConfigBookV1) -> [TatwoCoworkTicketTemplate] {
    let normalized = book.normalizedForCurrentDefaults()
    let canonicalOrder = Dictionary(
      uniqueKeysWithValues:
        TatwoScenarioConfigDefaults.round13SeedScenarios.enumerated().map {
          ($0.element.id, $0.offset)
        })
    return normalized.scenarios
      .filter { canonicalOrder[$0.id] != nil }
      .sorted {
        (canonicalOrder[$0.id] ?? Int.max)
          < (canonicalOrder[$1.id] ?? Int.max)
      }
      .compactMap(template(from:))
  }

  private static func template(from scenario: TatwoCustomScenarioConfig) -> TatwoCoworkTicketTemplate? {
    guard let mode = declaredMode(displayName: scenario.displayName),
          let modeConfig = scenario.modeConfigs[mode] ?? scenario.modeConfigs.values.sorted(by: { $0.mode < $1.mode }).first
    else { return nil }
    return TatwoCoworkTicketTemplate(
      id: scenario.id,
      displayName: scenario.displayName,
      category: scenario.displayCategory,
      mode: mode,
      scenarioID: scenario.id,
      baseScenario: scenario.baseScenario,
      identityBindings: modeConfig.bindings,
      tokenBudget: modeConfig.tokenBudget,
      agentsMarkdown: modeConfig.agentsMarkdown)
  }

  private static func declaredMode(displayName: String) -> WorkModeID? {
    let parts = displayName.components(separatedBy: " · ")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    for part in parts {
      if part == "S" { return .s }
      if part == "M" { return .m }
      if part == "L" { return .l }
      if part == "XXL" { return .xxl }
      if part == "XL" { return .xl }
    }
    return nil
  }
}

public struct TatwoCoworkRunStats: Codable, Sendable, Equatable {
  public let logByteCount: Int
  public let changedFiles: [String]
  public let receiptFiles: [String]
  public let measuredAt: Date

  public init(logByteCount: Int, changedFiles: [String], receiptFiles: [String], measuredAt: Date) {
    self.logByteCount = logByteCount
    self.changedFiles = changedFiles
    self.receiptFiles = receiptFiles
    self.measuredAt = measuredAt
  }

  public var changedFileCount: Int { changedFiles.count }
}

public enum TatwoCoworkSupervisorPhase: String, Codable, Sendable, Equatable {
  case startup
  case patrol
  case completion
  case stopped
  case failure
}

public enum TatwoCoworkCardSeverity: String, Codable, Sendable, Equatable {
  case ok
  case warning
  case danger
}

public struct TatwoCoworkSupervisorCard: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let phase: TatwoCoworkSupervisorPhase
  public let severity: TatwoCoworkCardSeverity
  public let title: String
  public let body: String
  public let stats: TatwoCoworkRunStats

  public init(
    id: String = UUID().uuidString,
    phase: TatwoCoworkSupervisorPhase,
    severity: TatwoCoworkCardSeverity,
    title: String,
    body: String,
    stats: TatwoCoworkRunStats
  ) {
    self.id = id
    self.phase = phase
    self.severity = severity
    self.title = title
    self.body = body
    self.stats = stats
  }
}

public enum TatwoCoworkProgressInspector {
  public static func card(
    phase: TatwoCoworkSupervisorPhase,
    stats: TatwoCoworkRunStats,
    previousGrowthStats: TatwoCoworkRunStats?,
    runStartedAt: Date,
    allowedRelativeRoots: [String]
  ) -> TatwoCoworkSupervisorCard {
    let elapsed = max(0, Int(stats.measuredAt.timeIntervalSince(runStartedAt)))
    let scopeDrift = pathsOutsideAllowedRoots(stats.changedFiles, allowedRelativeRoots: allowedRelativeRoots)
    let noGrowthSeconds: Int = {
      guard let previousGrowthStats,
            stats.logByteCount <= previousGrowthStats.logByteCount,
            stats.changedFiles == previousGrowthStats.changedFiles
      else { return 0 }
      return max(0, Int(stats.measuredAt.timeIntervalSince(previousGrowthStats.measuredAt)))
    }()
    let stalled = noGrowthSeconds >= 600
    let severity: TatwoCoworkCardSeverity = stalled ? .danger : (scopeDrift.isEmpty ? .ok : .warning)
    let title: String
    switch (phase, stalled, scopeDrift.isEmpty) {
    case (_, true, _): title = "🔴 卡死警報 · 10分鐘零成長"
    case (_, _, false): title = "🟠 範圍警報 · scope drift"
    case (.startup, _, _): title = "✅ 起跑確認 · Ultrawork job 已啟動"
    case (.completion, _, _): title = "🧾 收據卡 · Ultrawork job 完成"
    case (.stopped, _, _): title = "⏹ 停止卡 · 已終止"
    case (.failure, _, _): title = "⚠️ 失敗卡 · 啟動或執行失敗"
    case (.patrol, _, _): title = "🟢 監工卡 · 2分鐘進度"
    }
    var rows = [
      "elapsed=\(formatDuration(elapsed))",
      "log=\(formatBytes(stats.logByteCount))",
      "改檔=\(stats.changedFileCount)",
      "收據=\(stats.receiptFiles.count)",
      scopeDrift.isEmpty ? "範圍=OK" : "範圍警報=\(scopeDrift.joined(separator: ", "))",
    ]
    if stalled { rows.append("10分鐘零成長：log 與改檔數未增加，請停止或檢查子進程") }
    if !stats.changedFiles.isEmpty { rows.append("改檔清單：\(stats.changedFiles.prefix(8).joined(separator: ", "))") }
    if !stats.receiptFiles.isEmpty { rows.append("收據檔：\(stats.receiptFiles.prefix(5).joined(separator: ", "))") }
    return TatwoCoworkSupervisorCard(phase: phase, severity: severity, title: title, body: rows.joined(separator: "\n"), stats: stats)
  }

  public static func pathsOutsideAllowedRoots(_ paths: [String], allowedRelativeRoots: [String]) -> [String] {
    let roots = allowedRelativeRoots.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
    guard !roots.isEmpty else { return [] }
    return paths.filter { path in
      let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      return !roots.contains { root in normalized == root || normalized.hasPrefix(root + "/") }
    }
  }

  public static func formatBytes(_ count: Int) -> String {
    if count < 1_024 { return "\(count) B" }
    if count < 1_048_576 { return String(format: "%.1f KB", Double(count) / 1_024.0) }
    return String(format: "%.1f MB", Double(count) / 1_048_576.0)
  }

  public static func formatDuration(_ seconds: Int) -> String {
    let minutes = seconds / 60
    let remainder = seconds % 60
    if minutes == 0 { return "\(remainder)s" }
    return "\(minutes)m\(String(format: "%02d", remainder))s"
  }
}

public enum TatwoCoworkGitStatusParser {
  public static func changedPaths(fromPorcelain output: String) -> [String] {
    output.split(whereSeparator: \ .isNewline).compactMap { rawLine in
      let line = String(rawLine)
      guard line.count >= 3 else { return nil }
      let payload = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !payload.isEmpty else { return nil }
      if let range = payload.range(of: " -> ") {
        return String(payload[range.upperBound...])
      }
      return payload
    }
  }
}

public enum TatwoCoworkReceiptLocator {
  public static func receiptFiles(in workdir: URL, since: Date) -> [String] {
    let candidates = [
      workdir.appendingPathComponent("docs/plans/receipts"),
      workdir.appendingPathComponent(".tatwo-ultrawork"),
    ]
    let allowedExtensions = Set(["md", "json"])
    let fm = FileManager.default
    var results: [String] = []
    for root in candidates where fm.fileExists(atPath: root.path) {
      guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
      for case let url as URL in enumerator {
        guard allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard values?.isRegularFile == true,
              let modified = values?.contentModificationDate,
              modified >= since
        else { continue }
        results.append(relativePath(url, from: workdir))
      }
    }
    return results.sorted()
  }

  private static func relativePath(_ url: URL, from root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return path }
    return String(path.dropFirst(rootPath.count + 1))
  }
}
