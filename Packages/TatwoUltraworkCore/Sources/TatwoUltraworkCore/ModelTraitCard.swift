import Foundation

/// T5 特質卡 — 每模型一張，白話長短板 + 每條掛考試收據（docs/tatwo/TRAIT_CARD_DESIGN.md）。
/// 分數維持進度條可比；特質敘述沒有 evidenceRefs 不得上卡；無證據標待測試。
public struct TatwoModelTraitClaim: Codable, Sendable, Equatable, Identifiable {
  public let label: String
  public let plainClaim: String
  public let evidenceRefs: [String]
  /// `measured`（人工覆核過）/ `observed`（主考官觀測）/ `provisional`（方向性，待加測）
  public let confidence: String

  public var id: String { label }

  public init(label: String, plainClaim: String, evidenceRefs: [String], confidence: String) {
    self.label = label
    self.plainClaim = plainClaim
    self.evidenceRefs = evidenceRefs
    self.confidence = confidence
  }
}

public struct TatwoModelTraitDimensionScore: Codable, Sendable, Equatable, Identifiable {
  public let dimensionID: String
  public let value0To10: Double
  /// `measured` / `pending-mapping` / `untested`
  public let status: String

  public var id: String { dimensionID }

  public init(dimensionID: String, value0To10: Double, status: String) {
    self.dimensionID = dimensionID
    self.value0To10 = value0To10
    self.status = status
  }
}

public struct TatwoModelTraitPairing: Codable, Sendable, Equatable, Identifiable {
  public let modelID: String
  public let why: String

  public var id: String { modelID }

  public init(modelID: String, why: String) {
    self.modelID = modelID
    self.why = why
  }
}

public struct TatwoModelTraitCardV1: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let modelID: String
  public let generatedAt: Date
  public let evidenceRunIDs: [String]
  public let oneLiner: String
  public let strengths: [TatwoModelTraitClaim]
  public let weaknesses: [TatwoModelTraitClaim]
  public let dimensionScores: [TatwoModelTraitDimensionScore]
  public let bestRoles: [String]
  public let avoidRoles: [String]
  public let pairsWellWith: [TatwoModelTraitPairing]
  public let notes: String

  public var id: String { modelID }

  public init(
    schema: String = "TatwoModelTraitCardV1",
    modelID: String,
    generatedAt: Date = Date(),
    evidenceRunIDs: [String],
    oneLiner: String,
    strengths: [TatwoModelTraitClaim],
    weaknesses: [TatwoModelTraitClaim],
    dimensionScores: [TatwoModelTraitDimensionScore],
    bestRoles: [String],
    avoidRoles: [String],
    pairsWellWith: [TatwoModelTraitPairing],
    notes: String = ""
  ) {
    self.schema = schema
    self.modelID = modelID
    self.generatedAt = generatedAt
    self.evidenceRunIDs = evidenceRunIDs
    self.oneLiner = oneLiner
    self.strengths = strengths
    self.weaknesses = weaknesses
    self.dimensionScores = dimensionScores
    self.bestRoles = bestRoles
    self.avoidRoles = avoidRoles
    self.pairsWellWith = pairsWellWith
    self.notes = notes
  }
}

/// Reads trait cards from `<state>/trait-cards/*.json`（與 GoalRunStore 同一 state 目錄，
/// App / CLI / MCP 讀同一份）。Unreadable files skip 不炸——特質板是投影不是 gate。
public struct TatwoModelTraitCardStore: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL) {
    self.directoryURL = directoryURL.appendingPathComponent("trait-cards", isDirectory: true)
  }

  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoModelTraitCardStore {
    TatwoModelTraitCardStore(
      directoryURL: TatwoGoalRunStore.default(environment: environment).directoryURL)
  }

  public func allCards() -> [TatwoModelTraitCardV1] {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directoryURL, includingPropertiesForKeys: nil)) ?? []
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return files
      .filter { $0.pathExtension == "json" }
      .compactMap { url in
        (try? Data(contentsOf: url)).flatMap {
          try? decoder.decode(TatwoModelTraitCardV1.self, from: $0)
        }
      }
      .sorted { $0.modelID < $1.modelID }
  }

  @discardableResult
  public func save(_ card: TatwoModelTraitCardV1) throws -> URL {
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let url = directoryURL.appendingPathComponent("\(card.modelID).json", isDirectory: false)
    try encoder.encode(card).write(to: url, options: [.atomic])
    return url
  }
}
