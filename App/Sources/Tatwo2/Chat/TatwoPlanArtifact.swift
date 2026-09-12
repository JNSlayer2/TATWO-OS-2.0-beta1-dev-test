// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoPlanArtifact.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import Foundation

public struct TatwoPlanArtifactV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoPlanArtifactV1"

  public enum State: String, Codable, Sendable, Equatable {
    case discussing
    case confirmed
    case ready
  }

  public struct Section: Codable, Sendable, Equatable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
      self.title = title
      self.body = body
    }
  }

  public struct PlanFlowSelectionV1: Codable, Sendable, Equatable {
    public enum Destination: String, Codable, Sendable, Equatable {
      case plan
      case goal
      case plg
    }

    public enum Collaboration: String, Codable, Sendable, Equatable {
      case singleModel = "single_model"
      case multiModel = "multi_model"
    }

    public enum ModelAssignment: String, Codable, Sendable, Equatable {
      case single
      case primarySecondary = "primary_secondary"
      case explicitModels = "explicit_models"
    }

    public var destination: Destination?
    public var collaboration: Collaboration?
    public var modelAssignment: ModelAssignment?
    public var primaryModelID: String?
    public var secondaryModelID: String?
    /// Ultrawork 這一級實際有幾個輔助角色。S 只有主導、沒有副審，硬要一個
    /// `secondaryModelID` 會讓「已設定主導 terra」的 S 拓撲永遠卡在
    /// 「尚未指定輔模型」。`nil` 保留舊行為（必須有副審）。
    public var auxiliaryModelCount: Int?

    public init(
      destination: Destination? = nil,
      collaboration: Collaboration? = nil,
      modelAssignment: ModelAssignment? = nil,
      primaryModelID: String? = nil,
      secondaryModelID: String? = nil,
      auxiliaryModelCount: Int? = nil
    ) {
      self.destination = destination
      self.collaboration = collaboration
      self.modelAssignment = modelAssignment
      self.primaryModelID = primaryModelID
      self.secondaryModelID = secondaryModelID
      self.auxiliaryModelCount = auxiliaryModelCount
    }

    /// 這一級是否真的需要副審模型。
    public var requiresAuxiliaryModel: Bool {
      (auxiliaryModelCount ?? 1) > 0
    }

    public var missingSelections: [String] {
      var missing: [String] = []
      if destination == nil { missing.append("destination") }
      if collaboration == nil { missing.append("collaboration") }
      if destination == .plg, collaboration == .singleModel {
        missing.append("plgRequiresUltrawork")
      }
      if collaboration == .multiModel {
        if modelAssignment == nil { missing.append("modelAssignment") }
        if primaryModelID?.trimmingCharacters(
          in: .whitespacesAndNewlines).isEmpty != false
        { missing.append("primaryModelID") }
        if requiresAuxiliaryModel,
          secondaryModelID?.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty != false
        { missing.append("secondaryModelID") }
      }
      return missing
    }

    public var isComplete: Bool { missingSelections.isEmpty }

    public var executionBlocker: String? {
      if destination == nil { return "請先選擇 /goal 或 /plg" }
      if collaboration == nil { return "請先選擇 單模型 或 Ultrawork" }
      if destination == .plg, collaboration == .singleModel {
        return "PLG 需要 Ultrawork 協作；單模型請改選 /goal"
      }
      if collaboration == .multiModel {
        if primaryModelID?.trimmingCharacters(
          in: .whitespacesAndNewlines).isEmpty != false
        {
          return "Ultrawork 尚未指定主導模型"
        }
        if requiresAuxiliaryModel,
          secondaryModelID?.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty != false
        {
          return "Ultrawork 尚未指定輔模型"
        }
      }
      return nil
    }

    public var selectionSummary: String {
      let destinationLabel: String
      switch destination {
      case .goal: destinationLabel = "/goal"
      case .plg: destinationLabel = "/plg"
      case .plan: destinationLabel = "/plan"
      case nil: destinationLabel = "未選流程"
      }
      let collaborationLabel: String
      switch collaboration {
      case .singleModel: collaborationLabel = "單模型"
      case .multiModel: collaborationLabel = "Ultrawork"
      case nil: collaborationLabel = "未選拓撲"
      }
      return "已選：\(destinationLabel) · \(collaborationLabel)"
    }
  }

  public let schema: String
  public let planID: UUID
  public let threadID: UUID
  public var objective: String
  public var sections: [Section]
  public var sourceAssistantMessageID: String?
  public let createdAt: Date
  public var updatedAt: Date
  public var state: State
  public var planFlowSelection: PlanFlowSelectionV1?
  public var executionTurnID: String?
  public var kind: String?
  var prReview: PRPlanReview?
  var prMessage: String?

  public init(
    planID: UUID = UUID(),
    threadID: UUID,
    objective: String,
    sections: [Section] = [],
    sourceAssistantMessageID: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    state: State = .discussing,
    planFlowSelection: PlanFlowSelectionV1? = nil,
    kind: String? = nil
  ) {
    self.schema = Self.schemaName
    self.planID = planID
    self.threadID = threadID
    self.objective = objective
    self.sections = sections
    self.sourceAssistantMessageID = sourceAssistantMessageID
    // 2026-08-21 主導驗收修正：時間戳一律先降到毫秒精度再存。
    // 原本存 `Date()` 全精度，寫進 JSON 後再讀回會被截斷，於是
    // 「記憶體中的計劃書」與「從磁碟還原的同一份計劃書」在 Equatable
    // 下不相等——切換 thread 再切回來就對不上（sol 自己的測試抓到了，
    // 但他在 sandbox 裡跑不了測試所以沒發現）。
    self.createdAt = Self.storagePrecision(createdAt)
    self.updatedAt = Self.storagePrecision(updatedAt ?? createdAt)
    self.state = state
    self.planFlowSelection = planFlowSelection
    self.kind = kind
  }

  /// 與 JSON 往返後仍然相等的時間精度。
  ///
  /// 這裡是**整秒**，因為本型別的編碼策略是 `.iso8601`（不帶小數秒），
  /// 磁碟上本來就只留得住秒。精度若比落檔格式細，記憶體中的計劃書就
  /// 永遠不會等於自己讀回來的版本。
  static func storagePrecision(_ date: Date) -> Date {
    Date(timeIntervalSince1970:
      date.timeIntervalSince1970.rounded(.down))
  }

  /// 自動合成的 Decodable init **不會**經過上面的 designated init，所以
  /// 只在 init 裡正規化精度是修不掉往返不相等的——解碼這一路必須自己
  /// 正規化一次。這正是 sol 那支測試（切 thread 再切回來計劃書對不上）
  /// 真正踩到的地方。
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schema = try container.decode(String.self, forKey: .schema)
    self.planID = try container.decode(UUID.self, forKey: .planID)
    self.threadID = try container.decode(UUID.self, forKey: .threadID)
    self.objective = try container.decode(String.self, forKey: .objective)
    self.sections = try container.decode([Section].self, forKey: .sections)
    self.sourceAssistantMessageID = try container.decodeIfPresent(
      String.self,
      forKey: .sourceAssistantMessageID)
    self.createdAt = Self.storagePrecision(
      try container.decode(Date.self, forKey: .createdAt))
    self.updatedAt = Self.storagePrecision(
      try container.decode(Date.self, forKey: .updatedAt))
    self.state = try container.decode(State.self, forKey: .state)
    self.planFlowSelection = try container.decodeIfPresent(
      PlanFlowSelectionV1.self,
      forKey: .planFlowSelection)
    self.executionTurnID = try container.decodeIfPresent(String.self, forKey: .executionTurnID)
    self.kind = try container.decodeIfPresent(String.self, forKey: .kind)
    self.prReview = try container.decodeIfPresent(PRPlanReview.self, forKey: .prReview)
    self.prMessage = try container.decodeIfPresent(String.self, forKey: .prMessage)
  }

  public func canonicalJSONData() throws -> Data {
    try JSONEncoder.tatwoPlanArtifact.encode(self)
  }

  public mutating func updateDiscussion(
    objective: String,
    sections: [Section],
    at: Date = Date()
  ) {
    self.objective = objective
    self.sections = sections
    updatedAt = Self.storagePrecision(at)
    state = .discussing
    executionTurnID = nil
  }

  /// This API is intentionally separate from discussion updates so callers
  /// must wire it to an explicit human confirmation action.
  public mutating func confirm(at: Date = Date()) {
    updatedAt = Self.storagePrecision(at)
    state = .confirmed
  }

  /// 2026-08-21 使用者需求：畫布可直接編輯計劃書（鉛筆→修改→儲存）。
  /// 編輯用文本格式＝第一行 objective、空行、之後 `## 標題` 段落——
  /// 與 `sections(fromModelResponse:)` 解析規則對齊，往返穩定。
  public func editableText() -> String {
    var blocks = [objective]
    blocks.append(
      contentsOf: sections.map { "## \($0.title)\n\($0.body)" })
    return blocks.joined(separator: "\n\n")
  }

  /// 套用使用者手改的文本：首個非空且非標題行＝新 objective；其餘走
  /// 既有段落解析。任何內容修改都回到 discussing（沿用確認語義）。
  public mutating func applyEditedText(_ text: String, at: Date = Date()) {
    let normalized = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    var lines = normalized.split(
      separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var newObjective = objective
    if let first = lines.first(where: {
      !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }), !first.hasPrefix("## ") {
      newObjective = first.trimmingCharacters(in: .whitespaces)
      if let index = lines.firstIndex(of: first) {
        lines.remove(at: index)
      }
    }
    let remainder = lines.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let newSections = remainder.isEmpty
      ? [] : Self.markdownSections(remainder)
    updateDiscussion(
      objective: newObjective, sections: newSections, at: at)
  }

  public func markdownExport() -> String {
    var blocks = [
      kind == "pr" ? (state == .ready ? "# PR" : "# PR · Plan") : (kind == "feedback" ? "# 回報問題" : "# Plan"),
      "## Objective\n\n\(objective)",
    ]
    blocks.append(
      contentsOf: sections.map { section in
        "## \(section.title)\n\n\(section.body)"
      })
    return blocks.joined(separator: "\n\n")
  }

  /// Only complete, explicitly labelled fences update a canvas. Missing
  /// headings remain missing; never invent model output.
  public static func parseSections(fromReply reply: String, fenceName: String = "tatwo-plan") -> [Section]? {
    let lines = reply.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    var body: [String]? = nil
    var nestedFence: String?
    var outsideFence: String?
    var result: [Section]?
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if body == nil {
        if let fence = outsideFence {
          if trimmed == fence { outsideFence = nil }
        } else if trimmed == "```\(fenceName)" {
          body = []
        } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
          outsideFence = String(trimmed.prefix(while: { $0 == "`" || $0 == "~" }))
        }
      } else if let fence = nestedFence {
        body?.append(line)
        if trimmed == fence { nestedFence = nil }
      } else if trimmed == "```" {
        let sections = markdownSections(body!.joined(separator: "\n"))
        if !sections.isEmpty { result = sections }
        body = nil
      } else {
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
          nestedFence = String(trimmed.prefix(while: { $0 == "`" || $0 == "~" }))
        }
        body?.append(line)
      }
    }
    return result
  }

  static func markdownSections(_ text: String) -> [Section] {
    var result: [Section] = []
    var fence: String?
    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let current = fence {
        if trimmed == current { fence = nil }
      } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fence = String(trimmed.prefix(while: { $0 == "`" || $0 == "~" }))
      } else if line.hasPrefix("## ") {
        result.append(Section(title: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), body: ""))
        continue
      }
      if !result.isEmpty { result[result.count - 1].body += line + "\n" }
    }
    return result.map { Section(title: $0.title, body: $0.body.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  /// Converts one completed model response into stable plan-canvas sections.
  /// Supported section markers are Markdown headings, bold-only lines, and
  /// numbered heading lines. Unstructured prose remains visible as one plan.
  public static func sections(
    fromModelResponse response: String
  ) -> [Section] {
    let normalized = response
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }

    var result: [Section] = []
    var currentTitle: String?
    var currentBody: [String] = []

    func flush() {
      let body = currentBody.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else {
        currentBody = []
        return
      }
      result.append(Section(
        title: currentTitle ?? "計劃",
        body: body))
      currentBody = []
    }

    let lines = normalized.split(
      separator: "\n",
      omittingEmptySubsequences: false).map(String.init)

    for (index, line) in lines.enumerated() {
      let candidate = planSectionHeading(in: line)
      let isNumberedCandidate = line
        .trimmingCharacters(in: .whitespaces)
        .range(
          of: #"^\d+[.)、]\s+.+$"#,
          options: .regularExpression) != nil
      let nextMeaningfulLine = lines[(index + 1)...]
        .first(where: {
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
      let numberedCandidateHasBody =
        !isNumberedCandidate
        || nextMeaningfulLine.map { planSectionHeading(in: $0) == nil } == true

      if let heading = candidate, numberedCandidateHasBody {
        flush()
        currentTitle = heading
      } else {
        currentBody.append(line)
      }
    }
    flush()

    guard !result.isEmpty else {
      return [Section(title: "計劃", body: normalized)]
    }
    return result
  }

  static func planSectionHeading(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    if let range = trimmed.range(
      of: #"^#{1,6}\s+(.+?)\s*#*$"#,
      options: .regularExpression)
    {
      let matched = String(trimmed[range])
      return matched
        .replacingOccurrences(
          of: #"^#{1,6}\s+"#,
          with: "",
          options: .regularExpression)
        .replacingOccurrences(
          of: #"\s*#*$"#,
          with: "",
          options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }

    if trimmed.range(
      of: #"^\*\*[^*\n]+\*\*$"#,
      options: .regularExpression) != nil
    {
      return String(trimmed.dropFirst(2).dropLast(2))
        .trimmingCharacters(in: .whitespaces)
    }

    if trimmed.range(
      of: #"^\d+[.)、]\s+.+$"#,
      options: .regularExpression) != nil
    {
      return trimmed.replacingOccurrences(
        of: #"^\d+[.)、]\s+"#,
        with: "",
        options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }
    return nil
  }
}

public extension JSONEncoder {
  static var tatwoPlanArtifact: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

public extension JSONDecoder {
  static var tatwoPlanArtifact: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
