import Foundation
import Darwin

public struct TatwoUltraworkTopologyPresetV1: Codable, Sendable, Equatable {
  public static let currentSchema = "tatwo.ultrawork.topology-preset.v1"

  public var schema: String
  public var presetID: String
  public var displayName: String
  public var scenarioID: String
  public var mode: WorkModeID
  public var primaryModelID: String?
  public var subModelIDs: [String]
  public var tokenBudget: String
  public var updatedAt: Date
  public var identitySummary: String

  public init(
    schema: String = Self.currentSchema,
    presetID: String,
    displayName: String,
    scenarioID: String,
    mode: WorkModeID,
    primaryModelID: String?,
    subModelIDs: [String],
    tokenBudget: String,
    updatedAt: Date,
    identitySummary: String = ""
  ) {
    self.schema = schema
    self.presetID = presetID
    self.displayName = displayName
    self.scenarioID = scenarioID
    self.mode = mode
    self.primaryModelID = primaryModelID
    self.subModelIDs = subModelIDs
    self.tokenBudget = tokenBudget
    self.updatedAt = updatedAt
    self.identitySummary = identitySummary
  }

  public init(
    from config: TatwoNativeThreadLoopsConfig,
    presetID: String,
    displayName: String,
    updatedAt: Date
  ) {
    self.init(
      presetID: presetID,
      displayName: displayName,
      scenarioID: config.scenarioID,
      mode: config.mode,
      primaryModelID: config.primaryModelID,
      subModelIDs: config.secondaryModelID.map { [$0] } ?? [],
      tokenBudget: config.tokenBudget,
      updatedAt: updatedAt,
      identitySummary: config.identitySummary)
  }

  public func loopsConfig() -> TatwoNativeThreadLoopsConfig {
    TatwoNativeThreadLoopsConfig(
      scenarioID: scenarioID,
      mode: mode,
      identitySummary: identitySummary,
      tokenBudget: tokenBudget,
      primaryModelID: primaryModelID,
      secondaryModelID: subModelIDs.first)
  }

  public func canonicalData() throws -> Data {
    try JSONEncoder.tatwoTopologyPreset.encode(self)
  }
}

public enum TatwoUltraworkTopologyPreset {
  public static func resolveForNewThread(
    default defaultPreset: TatwoUltraworkTopologyPresetV1?,
    lastUsed: TatwoUltraworkTopologyPresetV1?
  ) -> TatwoNativeThreadLoopsConfig? {
    (defaultPreset ?? lastUsed)?.loopsConfig()
  }
}

extension JSONEncoder {
  static var tatwoTopologyPreset: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }
}

extension JSONDecoder {
  static var tatwoTopologyPreset: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}

public enum TatwoUltraworkTopologyPresetStoreError: Error, Equatable {
  case presetNotFound(String)
}

public final class TatwoUltraworkTopologyPresetStore: @unchecked Sendable {
  private struct Document: Codable, Sendable, Equatable {
    static let currentSchema = "tatwo.ultrawork.topology-presets.v1"

    var schema = currentSchema
    var defaultPresetID: String?
    var presets: [TatwoUltraworkTopologyPresetV1]
  }

  public let directoryURL: URL
  public let fileURL: URL
  private let lock = NSLock()

  public init(directoryURL: URL) {
    self.directoryURL = directoryURL
    self.fileURL = directoryURL.appendingPathComponent(
      "ultrawork-topology-presets.json",
      isDirectory: false)
  }

  public convenience init(goalStore: TatwoGoalRunStore) {
    self.init(directoryURL: goalStore.directoryURL)
  }

  public func list() -> [TatwoUltraworkTopologyPresetV1] {
    lock.withLock {
      load().presets.sorted { lhs, rhs in
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.presetID < rhs.presetID
      }
    }
  }

  public func save(_ preset: TatwoUltraworkTopologyPresetV1) throws {
    try lock.withLock {
      var document = load()
      document.presets.removeAll { $0.presetID == preset.presetID }
      document.presets.append(preset)
      document.presets.sort { $0.presetID < $1.presetID }
      try persist(document)
    }
  }

  public func delete(id: String) throws {
    try lock.withLock {
      var document = load()
      document.presets.removeAll { $0.presetID == id }
      if document.defaultPresetID == id {
        document.defaultPresetID = nil
      }
      try persist(document)
    }
  }

  public func defaultPreset() -> TatwoUltraworkTopologyPresetV1? {
    lock.withLock {
      let document = load()
      guard let id = document.defaultPresetID else { return nil }
      return document.presets.first { $0.presetID == id }
    }
  }

  public func setDefault(id: String) throws {
    try lock.withLock {
      var document = load()
      guard document.presets.contains(where: { $0.presetID == id }) else {
        throw TatwoUltraworkTopologyPresetStoreError.presetNotFound(id)
      }
      document.defaultPresetID = id
      try persist(document)
    }
  }

  private func load() -> Document {
    guard
      let data = try? Data(contentsOf: fileURL),
      let document = try? JSONDecoder.tatwoTopologyPreset.decode(Document.self, from: data),
      document.schema == Document.currentSchema
    else {
      return Document(defaultPresetID: nil, presets: [])
    }
    return document
  }

  private func persist(_ document: Document) throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true)
    let data = try JSONEncoder.tatwoTopologyPreset.encode(document)
    let temporaryURL = directoryURL.appendingPathComponent(
      ".ultrawork-topology-presets.\(UUID().uuidString).tmp",
      isDirectory: false)
    do {
      try data.write(to: temporaryURL, options: [])
      guard rename(temporaryURL.path, fileURL.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }
}
