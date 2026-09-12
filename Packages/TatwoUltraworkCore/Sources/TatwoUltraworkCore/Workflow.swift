import Foundation

public enum TatwoParseError: Error, LocalizedError, Sendable {
  case unknownMode(String)
  case unknownScenario(String)

  public var errorDescription: String? {
    switch self {
    case .unknownMode(let value): return "Unknown mode: \(value)"
    case .unknownScenario(let value): return "Unknown scenario: \(value)"
    }
  }
}

extension WorkModeID {
  public static func parse(_ value: String) throws -> WorkModeID {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if let mode = WorkModeID(rawValue: normalized) { return mode }
    throw TatwoParseError.unknownMode(value)
  }
}

extension ScenarioID {
  public static func parse(_ value: String) throws -> ScenarioID {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "daily", "default", "general", "通用", "日常": return .daily
    case "design", "ui", "ux", "設計": return .design
    case "coding", "code", "dev", "寫代碼", "程式": return .coding
    case "trading", "trade", "交易": return .trading
    case "modeling", "model", "research", "建模": return .modeling
    default: throw TatwoParseError.unknownScenario(value)
    }
  }
}

public enum WorkflowFactory {
  public static func make(mode: WorkModeID, scenario: ScenarioID) -> WorkflowTemplate {
    let needsHuman = mode >= .xl
    let nodes: [WorkflowNode] = [
      WorkflowNode(
        id: "user-task", title: "使用者任務", kind: .userTask, ownerRole: "Human",
        plainDescription: "把目標、不要做什麼、完成定義先寫清楚。", mustProduceEvidence: false),
      WorkflowNode(
        id: "project-map", title: "GitNexus 專案地圖", kind: .projectMap, ownerRole: "GitNexus + lead identity",
        plainDescription: mode == .s ? "S 小修可跳過；若影響範圍不明再手動查。" : "M/L/XL 每次協作先查入口與影響範圍，避免盲改。",
        mustProduceEvidence: mode >= .m),
      WorkflowNode(
        id: "sandbox", title: "沙盒", kind: .sandbox, ownerRole: "Host executor + optional verifier",
        plainDescription: mode >= .l
          ? "先用臨時 workspace；Colima 可當 L/XL 可選乾淨容器驗證器，但缺少時只降級，不自動安裝或啟動。"
          : "需要時用隔離工作區降低風險；S/M 不預設開 Colima。", mustProduceEvidence: mode >= .xl),
      WorkflowNode(
        id: "scout", title: "Sub / 消息探索", kind: .scout, ownerRole: "sub + news identity",
        plainDescription: "找候選、反例、缺口；只回短證據，不直接寫檔。", mustProduceEvidence: true),
      WorkflowNode(
        id: "builder", title: "主導落地", kind: .builder, ownerRole: "lead identity / safe host",
        plainDescription: "只有具備安全 host capability 的引擎能套用 patch、跑 shell、改檔；目前預設 Codex。", mustProduceEvidence: true),
      WorkflowNode(
        id: "reviewer", title: "監督審稿", kind: .reviewer, ownerRole: "supervisor identity",
        plainDescription: "找 bug、漏測、UI/UX 明顯問題；不能 final pass。", mustProduceEvidence: true),
      WorkflowNode(
        id: "verifier", title: "Verifier 驗證", kind: .verifier,
        ownerRole: "verifier identity + deterministic checks / optional Colima",
        plainDescription: "用測試、CLI、截圖、hash 或 Colima dry-run/執行收據證明，不靠文字感覺。",
        mustProduceEvidence: true),
      WorkflowNode(
        id: "judge", title: "驗收裁決", kind: .judge, ownerRole: "verifier / human gate",
        plainDescription: "處理 blocking findings；沒證據就 fail closed。", mustProduceEvidence: true),
      WorkflowNode(
        id: "tests", title: "測試", kind: .tests, ownerRole: "safe host executor",
        plainDescription: "swift test、CLI smoke、redaction scan、必要時 GUI 截圖。",
        mustProduceEvidence: true),
      WorkflowNode(
        id: "rollback", title: "回滾 / 不實裝", kind: .rollback, ownerRole: "safe host executor",
        plainDescription: "任何 gate 失敗就保存 checkpoint，不硬上主機。", mustProduceEvidence: true),
      WorkflowNode(
        id: "install", title: needsHuman ? "人工授權後實裝" : "可選實裝", kind: .hostInstall,
        ownerRole: "Human + safe host", plainDescription: "備份後才動主機 config、session 或 LaunchAgent。",
        mustProduceEvidence: true),
      WorkflowNode(
        id: "receipt", title: "收據", kind: .receipt, ownerRole: "Tatwo Ultrawork",
        plainDescription: "只記結果、偏好、失敗模式，不記 raw log/token/私密路徑。", mustProduceEvidence: true),
    ]

    let edges: [WorkflowEdge] = [
      WorkflowEdge(
        id: "e1", from: "user-task", to: "project-map", label: mode == .s ? "S 可跳過" : "M+ 固定查影響範圍"),
      WorkflowEdge(id: "e2", from: "project-map", to: "sandbox", label: "入口/影響範圍收據"),
      WorkflowEdge(id: "e3", from: "sandbox", to: "scout", label: "安全探索"),
      WorkflowEdge(id: "e4", from: "scout", to: "builder", label: "收斂成 patch"),
      WorkflowEdge(id: "e5", from: "builder", to: "reviewer", label: "分離審稿"),
      WorkflowEdge(id: "e6", from: "reviewer", to: "verifier", label: "證據驗證"),
      WorkflowEdge(id: "e7", from: "verifier", to: "judge", label: "裁決 gate"),
      WorkflowEdge(id: "e8", from: "judge", to: "tests", label: "允許才測完整"),
      WorkflowEdge(id: "e9", from: "judge", to: "rollback", label: "P0/P1 或證據不足"),
      WorkflowEdge(id: "e10", from: "tests", to: "install", label: "沙盒通過"),
      WorkflowEdge(id: "e11", from: "install", to: "receipt", label: "留下可回朔收據"),
      WorkflowEdge(id: "e12", from: "rollback", to: "receipt", label: "記錄失敗模式"),
    ]

    let policy =
      mode >= .xl
      ? "XL：沙盒必過且人工授權後才可 host install；不得改 signed app bundle、不得偷寫真實 LaunchAgent。"
      : "先用最小可驗證修改；host mutation 需可回滾。"
    return WorkflowTemplate(
      id: "\(mode.rawValue.lowercased())-\(scenario.rawValue)-default", mode: mode,
      scenario: scenario, title: "Tatwo Ultrawork \(mode.rawValue) / \(scenario.rawValue)",
      nodes: nodes, edges: edges, hostMutationPolicy: policy)
  }

  public static func mermaid(_ workflow: WorkflowTemplate) -> String {
    var lines = ["flowchart LR"]
    for node in workflow.nodes {
      let safeTitle = node.title.replacingOccurrences(of: "\"", with: "'")
      lines.append("  \(node.id.replacingOccurrences(of: "-", with: "_"))[\"\(safeTitle)\"]")
    }
    for edge in workflow.edges {
      let from = edge.from.replacingOccurrences(of: "-", with: "_")
      let to = edge.to.replacingOccurrences(of: "-", with: "_")
      let label = edge.label.replacingOccurrences(of: "\"", with: "'")
      lines.append("  \(from) -- \"\(label)\" --> \(to)")
    }
    return lines.joined(separator: "\n")
  }
}
