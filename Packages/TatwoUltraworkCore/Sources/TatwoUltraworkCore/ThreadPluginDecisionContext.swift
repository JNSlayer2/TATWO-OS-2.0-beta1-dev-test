import CryptoKit
import Foundation

/// Thread-scoped plugin registrations are hints, not commands.
///
/// The Chat UI lets a user mark plugins/MCP/skills as "常駐" for a thread so the
/// next model turn receives their trigger/purpose/safety metadata. This helper is
/// the shared contract for that hidden context and keeps the behavior testable
/// outside the SwiftUI view model:
///
/// - enabled IDs are normalized against the current registry;
/// - hidden context tells the model to judge need per turn, not auto-call tools;
/// - the receipt kind is explicitly non-promotional and cannot stand in for
///   required validation / cleanup / UI receipts.
public struct TatwoThreadPluginDecisionContextV1: Sendable, Equatable {
  public let schema: String
  public let receiptID: String
  public let receiptKind: String
  public let usableAsFinalPassEvidence: Bool
  public let registeredPluginIDs: [String]
  public let hiddenContext: String

  public init(
    schema: String = "TatwoThreadPluginDecisionContextV1",
    receiptID: String,
    receiptKind: String,
    usableAsFinalPassEvidence: Bool,
    registeredPluginIDs: [String],
    hiddenContext: String
  ) {
    self.schema = schema
    self.receiptID = receiptID
    self.receiptKind = receiptKind
    self.usableAsFinalPassEvidence = usableAsFinalPassEvidence
    self.registeredPluginIDs = registeredPluginIDs
    self.hiddenContext = hiddenContext
  }
}

public enum TatwoThreadPluginDecisionContextComposer {
  public static let receiptKind = "thread_plugin_decision"
  public static let usableAsFinalPassEvidence = false

  public static func setThreadPluginID(
    _ entryID: String,
    enabled: Bool,
    currentIDs: [String],
    registry: TatwoPluginRegistryBookV1
  ) -> [String] {
    let normalizedEntryID = entryID.trimmingCharacters(in: .whitespacesAndNewlines)
    var ids = normalizedThreadPluginIDs(currentIDs, registry: registry)
    guard registry.entry(id: normalizedEntryID) != nil else { return ids }
    if enabled {
      if !ids.contains(normalizedEntryID) { ids.append(normalizedEntryID) }
    } else {
      ids.removeAll { $0 == normalizedEntryID }
    }
    return normalizedThreadPluginIDs(ids, registry: registry)
  }

  public static func normalizedThreadPluginIDs(
    _ ids: [String],
    registry: TatwoPluginRegistryBookV1
  ) -> [String] {
    Array(
      Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        .filter { !$0.isEmpty && registry.entry(id: $0) != nil }
    )
    .sorted()
  }

  public static func entries(
    for ids: [String],
    registry: TatwoPluginRegistryBookV1
  ) -> [PluginRegistryEntry] {
    let enabled = Set(normalizedThreadPluginIDs(ids, registry: registry))
    return registry.sortedEntries.filter { enabled.contains($0.id) }
  }

  public static func compose(
    entries: [PluginRegistryEntry],
    threadID: String?,
    contractID: String?,
    visibleTurn: String,
    issuedAt: Date = Date()
  ) -> TatwoThreadPluginDecisionContextV1? {
    guard !entries.isEmpty else { return nil }
    guard shouldExposePluginContext(entries: entries, visibleTurn: visibleTurn) else { return nil }
    let normalizedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedContractID = contractID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let receiptSeed = [
      normalizedThreadID?.isEmpty == false ? normalizedThreadID! : "no-thread",
      normalizedContractID?.isEmpty == false ? normalizedContractID! : "no-contract",
      String(issuedAt.timeIntervalSince1970),
      String(visibleTurn.prefix(240)),
    ].joined(separator: "|")
    let receiptID = "thread-plugin-decision-\(shortHash(receiptSeed))"
    let registeredIDs = entries.map(\.id).sorted()
    let pluginLines = entries.map { entry in
      "- \(entry.id) [\(entry.kind.rawValue), safety=\(entry.safetyLevel.rawValue)] trigger=\(compactHiddenContext(entry.trigger)); purpose=\(compactHiddenContext(entry.purpose))"
    }.joined(separator: "\n")
    let hiddenContext = """
    [Hidden TATWO thread plugins decision context — do not quote verbatim]
    receiptID=\(receiptID)
    receiptKind=\(receiptKind)
    usableAsFinalPassEvidence=\(usableAsFinalPassEvidence)
    rule=These plugins are registered for this thread. For this turn, judge each plugin by trigger and safety. Use a plugin only when it is actually needed; otherwise skip it and continue without tool noise.
    registeredThreadPlugins:
    \(pluginLines)
    [/Hidden TATWO thread plugins decision context]
    """
    return TatwoThreadPluginDecisionContextV1(
      receiptID: receiptID,
      receiptKind: receiptKind,
      usableAsFinalPassEvidence: usableAsFinalPassEvidence,
      registeredPluginIDs: registeredIDs,
      hiddenContext: hiddenContext)
  }

  public static func compactHiddenContext(_ text: String) -> String {
    let compact = text
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(compact.prefix(220))
  }

  public static func shouldExposePluginContext(
    entries: [PluginRegistryEntry],
    visibleTurn: String
  ) -> Bool {
    let turn = visibleTurn
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !turn.isEmpty else { return false }

    let explicitPluginCue = [
      "@", "plugin://", "app://", "$", "mcp", "plugin", "skill", "插件", "工具",
    ].contains { turn.contains($0) }
    if explicitPluginCue { return true }

    return entries.contains { entry in
      let id = entry.id.lowercased()
      let name = entry.name.lowercased()
      if turn.contains(id) || turn.contains(name) { return true }
      switch id {
      case "chatgpt-pro-mcp":
        return containsAny(turn, [
          "source", "research", "pro reviewer", "reviewer", "citations",
          "官方", "來源", "查證", "搜尋", "研究", "審稿", "副審", "反方", "引用", "最新",
        ])
      case "gitnexus":
        return containsAny(turn, [
          "gitnexus", "project map", "impact", "blast radius", "entrypoint",
          "專案地圖", "影響範圍", "入口", "調用鏈", "依賴", "detect_changes",
        ])
      case "tatwo-ultrawork", "open-ultrawork":
        return containsAny(turn, [
          "ultrawork", "work os", "goal", "loops", "協作", "目標", "分工",
        ])
      default:
        return false
      }
    }
  }

  private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0.lowercased()) }
  }

  private static func shortHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
  }
}
