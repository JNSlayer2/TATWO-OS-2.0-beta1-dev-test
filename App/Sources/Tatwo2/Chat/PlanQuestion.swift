// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/PlanQuestion.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import Foundation

public struct PlanQuestionV1: Codable, Sendable, Equatable, Identifiable {
  public struct Option: Codable, Sendable, Equatable {
    public static let codexRecommendedSuffix = " (Recommended)"

    public let label: String
    public let detail: String

    public init(label: String, detail: String) {
      self.label = label
      self.detail = detail
    }

    public var isCodexRecommended: Bool {
      label.hasSuffix(Self.codexRecommendedSuffix)
    }

    public var codexDisplayLabel: String {
      guard isCodexRecommended else { return label }
      return String(label.dropLast(Self.codexRecommendedSuffix.count))
    }
  }

  public let id: String
  public let question: String
  public let options: [Option]
  public let allowsMultipleSelections: Bool
  public let allowsOtherResponse: Bool

  public init(
    id: String,
    question: String,
    options: [Option],
    allowsMultipleSelections: Bool = false,
    allowsOtherResponse: Bool = true
  ) {
    self.id = id
    self.question = question
    self.options = options
    self.allowsMultipleSelections = allowsMultipleSelections
    self.allowsOtherResponse = allowsOtherResponse
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case question
    case options
    case allowsMultipleSelections
    case allowsOtherResponse
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    question = try container.decode(String.self, forKey: .question)
    options = try container.decode([Option].self, forKey: .options)
    allowsMultipleSelections = try container.decodeIfPresent(
      Bool.self,
      forKey: .allowsMultipleSelections) ?? false
    allowsOtherResponse = try container.decodeIfPresent(
      Bool.self,
      forKey: .allowsOtherResponse) ?? true
  }

  public var isValid: Bool {
    !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !options.isEmpty
      && options.allSatisfy {
        !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
  }
}

public struct TatwoPlanQuestionParseResult: Sendable, Equatable {
  public let visibleText: String
  public let questions: [PlanQuestionV1]
  public let hasIncompleteBlock: Bool

  public init(
    visibleText: String,
    questions: [PlanQuestionV1],
    hasIncompleteBlock: Bool
  ) {
    self.visibleText = visibleText
    self.questions = questions
    self.hasIncompleteBlock = hasIncompleteBlock
  }
}

public enum TatwoPlanQuestionParser {
  public static let prefix = "<TATWO_PLAN_QUESTION>"
  public static let suffix = "</TATWO_PLAN_QUESTION>"

  public static func parse(_ text: String) -> TatwoPlanQuestionParseResult {
    var remainder = text
    var visible = ""
    var questions: [PlanQuestionV1] = []

    while let start = remainder.range(of: prefix) {
      visible += String(remainder[..<start.lowerBound])
      guard let end = remainder.range(
        of: suffix,
        range: start.upperBound..<remainder.endIndex
      ) else {
        return TatwoPlanQuestionParseResult(
          visibleText: visible,
          questions: questions,
          hasIncompleteBlock: true)
      }
      let payload = remainder[start.upperBound..<end.lowerBound]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let data = payload.data(using: .utf8),
        let question = try? JSONDecoder().decode(
          PlanQuestionV1.self,
          from: data),
        question.isValid
      {
        questions.append(question)
      } else {
        visible += String(remainder[start.lowerBound..<end.upperBound])
      }
      remainder = String(remainder[end.upperBound...])
    }

    let incompletePrefixLength = longestSuffixPrefixMatch(
      in: remainder,
      marker: prefix)
    if incompletePrefixLength > 0 {
      visible += String(remainder.dropLast(incompletePrefixLength))
      return TatwoPlanQuestionParseResult(
        visibleText: visible,
        questions: questions,
        hasIncompleteBlock: true)
    }
    visible += remainder
    return TatwoPlanQuestionParseResult(
      visibleText: visible,
      questions: questions,
      hasIncompleteBlock: false)
  }

  private static func longestSuffixPrefixMatch(
    in text: String,
    marker: String
  ) -> Int {
    let upperBound = min(text.count, marker.count - 1)
    guard upperBound > 0 else { return 0 }
    for length in stride(from: upperBound, through: 1, by: -1) {
      if text.suffix(length) == marker.prefix(length) {
        return length
      }
    }
    return 0
  }
}

public struct TatwoPlanQuestionStreamParser: Sendable, Equatable {
  private var buffer = ""

  public init() {}

  public mutating func consume(
    _ chunk: String,
    isFinal: Bool = false
  ) -> TatwoPlanQuestionParseResult {
    buffer += chunk
    let parsed = TatwoPlanQuestionParser.parse(buffer)
    if parsed.hasIncompleteBlock && !isFinal {
      return TatwoPlanQuestionParseResult(
        visibleText: "",
        questions: [],
        hasIncompleteBlock: true)
    }
    if parsed.hasIncompleteBlock {
      let unresolved = Self.incompleteTail(in: buffer)
      buffer = ""
      return TatwoPlanQuestionParseResult(
        visibleText: parsed.visibleText + unresolved,
        questions: parsed.questions,
        hasIncompleteBlock: false)
    }
    buffer = ""
    return parsed
  }

  private static func incompleteTail(in text: String) -> String {
    if let start = text.range(
      of: TatwoPlanQuestionParser.prefix,
      options: .backwards),
      text.range(
        of: TatwoPlanQuestionParser.suffix,
        range: start.upperBound..<text.endIndex) == nil
    {
      return String(text[start.lowerBound...])
    }

    let marker = TatwoPlanQuestionParser.prefix
    let upperBound = min(text.count, marker.count - 1)
    guard upperBound > 0 else { return "" }
    for length in stride(from: upperBound, through: 1, by: -1) {
      if text.suffix(length) == marker.prefix(length) {
        return String(text.suffix(length))
      }
    }
    return ""
  }
}

/// Canonical-journal transport for clarification requests.
///
/// A plan turn can end with a terminal `agent_message` whose entire payload is
/// a `<TATWO_PLAN_QUESTION>` block. That turn has no visible assistant text, so
/// the questions are the only durable content it produced. The canonical
/// transcript journal stores string attributes, so the question set travels as
/// one deterministic JSON array and is refused on read unless every entry still
/// satisfies `isValid`.
public enum TatwoPlanQuestionJournalCodec {
  /// Journal attribute key. Absent whenever a turn carries no question.
  public static let attributeKey = "planQuestions"

  public static func encode(_ questions: [PlanQuestionV1]) -> String? {
    guard !questions.isEmpty, questions.allSatisfy(\.isValid) else {
      return nil
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(questions) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func decode(_ raw: String?) -> [PlanQuestionV1] {
    guard let raw,
      let data = raw.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([PlanQuestionV1].self, from: data),
      !decoded.isEmpty,
      decoded.allSatisfy(\.isValid)
    else { return [] }
    return decoded
  }
}
