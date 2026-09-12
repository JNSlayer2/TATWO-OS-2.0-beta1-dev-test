import CryptoKit
import Foundation

public struct TatwoObjectiveIdentity: Codable, Sendable, Equatable, Hashable {
  public let schemaVersion: Int
  public let normalizedObjective: String
  public let objectiveHash: String
  public let objectiveID: String
  public let previewPrefix96: String
  public let normalizedLength: Int

  public init(
    schemaVersion: Int = 2,
    normalizedObjective: String,
    objectiveHash: String,
    objectiveID: String,
    previewPrefix96: String,
    normalizedLength: Int
  ) {
    self.schemaVersion = schemaVersion
    self.normalizedObjective = normalizedObjective
    self.objectiveHash = objectiveHash
    self.objectiveID = objectiveID
    self.previewPrefix96 = previewPrefix96
    self.normalizedLength = normalizedLength
  }

  public static func make(_ raw: String) -> TatwoObjectiveIdentity {
    let normalized = normalize(raw)
    let hash = SHA256.hash(data: Data(normalized.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return TatwoObjectiveIdentity(
      normalizedObjective: normalized,
      objectiveHash: hash,
      objectiveID: "obj-\(hash)",
      previewPrefix96: String(normalized.prefix(96)),
      normalizedLength: normalized.count)
  }

  public static func normalize(_ raw: String) -> String {
    raw
      .precomposedStringWithCanonicalMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  public var preview: String {
    "\(previewPrefix96)…#\(objectiveHash.prefix(8))"
  }
}

public struct TatwoStoredObjectiveContextV2: Codable, Sendable, Equatable, Hashable {
  public let schemaVersion: Int
  public let objectiveHash: String
  public let previewPrefix96: String
  public let normalizedLength: Int

  public init(
    schemaVersion: Int = 2,
    objectiveHash: String,
    previewPrefix96: String,
    normalizedLength: Int
  ) {
    self.schemaVersion = schemaVersion
    self.objectiveHash = objectiveHash
    self.previewPrefix96 = previewPrefix96
    self.normalizedLength = normalizedLength
  }

  public init(identity: TatwoObjectiveIdentity) {
    self.init(
      objectiveHash: identity.objectiveHash,
      previewPrefix96: identity.previewPrefix96,
      normalizedLength: identity.normalizedLength)
  }

  public func matches(_ identity: TatwoObjectiveIdentity) -> Bool {
    schemaVersion >= 2
      && objectiveHash == identity.objectiveHash
      && previewPrefix96 == identity.previewPrefix96
      && normalizedLength == identity.normalizedLength
  }

  public var preview: String {
    "\(previewPrefix96)…#\(objectiveHash.prefix(8))"
  }
}
