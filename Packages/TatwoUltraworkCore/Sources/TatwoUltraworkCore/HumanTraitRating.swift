import Foundation

/// 人工評分獨立持久層：不改寫考場/評測刻錄，僅以疊加來源存在。
public struct TatwoHumanTraitRatingV1: Codable, Sendable, Equatable, Identifiable {
  public var id: String { "\(modelID)#\(dimensionID)" }
  public let modelID: String
  public let dimensionID: String
  public let value0To10: Double
  public let ratedAt: String
  public let note: String

  public init(modelID: String, dimensionID: String, value0To10: Double, ratedAt: String, note: String = "") {
    self.modelID = modelID
    self.dimensionID = dimensionID
    self.value0To10 = min(max(value0To10, 0), 10)
    self.ratedAt = ratedAt
    self.note = note
  }
}

public struct TatwoHumanCollabRatingV1: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let comboLabel: String
  /// 質性判定：勝 / 持平 / 負（原樣保存，不轉數字）
  public let verdict: String
  /// positive / flat / negative
  public let deltaDirection: String
  public let note: String
  public let ratedAt: String

  public init(id: String, comboLabel: String, verdict: String, deltaDirection: String, note: String, ratedAt: String) {
    self.id = id
    self.comboLabel = comboLabel
    self.verdict = verdict
    self.deltaDirection = deltaDirection
    self.note = note
    self.ratedAt = ratedAt
  }
}

public struct TatwoHumanTraitRatingStore: Sendable {
  public let fileURL: URL

  public init(directoryURL: URL) {
    self.fileURL = directoryURL.appendingPathComponent("human-trait-ratings.json", isDirectory: false)
  }

  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoHumanTraitRatingStore {
    TatwoHumanTraitRatingStore(
      directoryURL: TatwoGoalRunStore.default(environment: environment).directoryURL)
  }

  public func all() -> [TatwoHumanTraitRatingV1] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return (try? JSONDecoder().decode([TatwoHumanTraitRatingV1].self, from: data)) ?? []
  }

  public func rating(modelID: String, dimensionID: String) -> TatwoHumanTraitRatingV1? {
    all().first { $0.modelID == modelID && $0.dimensionID == dimensionID }
  }

  @discardableResult
  public func upsert(_ rating: TatwoHumanTraitRatingV1) throws -> URL {
    var items = all().filter { $0.id != rating.id }
    items.append(rating)
    try persist(items)
    return fileURL
  }

  @discardableResult
  public func remove(modelID: String, dimensionID: String) throws -> URL {
    let items = all().filter { !($0.modelID == modelID && $0.dimensionID == dimensionID) }
    try persist(items)
    return fileURL
  }

  private func persist(_ items: [TatwoHumanTraitRatingV1]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(items.sorted { $0.id < $1.id }).write(to: fileURL, options: .atomic)
  }
}

public struct TatwoHumanCollabRatingStore: Sendable {
  public let fileURL: URL

  public init(directoryURL: URL) {
    self.fileURL = directoryURL.appendingPathComponent("human-collab-ratings.json", isDirectory: false)
  }

  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoHumanCollabRatingStore {
    TatwoHumanCollabRatingStore(
      directoryURL: TatwoGoalRunStore.default(environment: environment).directoryURL)
  }

  public func all() -> [TatwoHumanCollabRatingV1] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return (try? JSONDecoder().decode([TatwoHumanCollabRatingV1].self, from: data)) ?? []
  }

  @discardableResult
  public func upsert(_ rating: TatwoHumanCollabRatingV1) throws -> URL {
    var items = all().filter { $0.id != rating.id }
    items.append(rating)
    try persist(items)
    return fileURL
  }

  @discardableResult
  public func remove(id: String) throws -> URL {
    try persist(all().filter { $0.id != id })
    return fileURL
  }

  private func persist(_ items: [TatwoHumanCollabRatingV1]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(items.sorted { $0.ratedAt < $1.ratedAt }).write(to: fileURL, options: .atomic)
  }
}
