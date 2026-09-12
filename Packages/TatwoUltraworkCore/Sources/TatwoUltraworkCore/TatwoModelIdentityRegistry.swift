import Foundation

public enum TatwoModelCurrentHealth: String, Codable, Sendable, Equatable {
  case managedExternally = "MANAGED_EXTERNALLY"
  case deferUntilRouteHealthV2 = "DEFER_UNTIL_ROUTE_HEALTH_V2"
  case verifiedHealthy = "VERIFIED_HEALTHY"
  case unavailable = "UNAVAILABLE"
}

public struct TatwoModelIdentityRecord: Codable, Sendable, Equatable, Identifiable {
  public var id: String { canonicalModelID }

  public let canonicalModelID: String
  public let aliases: [String]
  public let currentHealth: TatwoModelCurrentHealth
  public let datedHistoricalEvidenceIDs: [String]

  public init(
    canonicalModelID: String,
    aliases: [String] = [],
    currentHealth: TatwoModelCurrentHealth = .managedExternally,
    datedHistoricalEvidenceIDs: [String] = []
  ) {
    self.canonicalModelID = canonicalModelID
    self.aliases = aliases
    self.currentHealth = currentHealth
    self.datedHistoricalEvidenceIDs = datedHistoricalEvidenceIDs
  }
}

private struct TatwoModelIdentityRegistryDocument: Codable {
  let schema: String
  let canonicalAsOf: String
  let records: [TatwoModelIdentityRecord]
}

/// Shared Node/Swift source for active model IDs and compatibility aliases.
///
/// Both runtimes load `TatwoModelIdentityRegistryV1.json`. If the resource is
/// missing or malformed, the registry becomes empty and dispatch fails closed.
/// Historical evidence IDs are intentionally stored in a separate field and
/// never participate in normalization or dispatch eligibility.
public enum TatwoModelIdentityRegistry {
  private static let document: TatwoModelIdentityRegistryDocument? = {
    guard
      let url = Bundle.module.url(
        forResource: "TatwoModelIdentityRegistryV1",
        withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let document = try? JSONDecoder().decode(
        TatwoModelIdentityRegistryDocument.self,
        from: data),
      document.schema == "TatwoModelIdentityRegistryV1",
      !document.records.isEmpty
    else {
      return nil
    }
    return document
  }()

  public static let records: [TatwoModelIdentityRecord] = document?.records ?? []

  public static let canonicalAsOf: String? = document?.canonicalAsOf

  public static let canonicalModelIDs: Set<String> = Set(records.map(\.canonicalModelID))

  public static let aliases: [String: String] = {
    var result: [String: String] = [:]
    for record in records {
      result[record.canonicalModelID.lowercased()] = record.canonicalModelID
      for alias in record.aliases {
        result[alias.lowercased()] = record.canonicalModelID
      }
    }
    return result
  }()

  public static let datedHistoricalEvidenceIDs: Set<String> = Set(
    records.flatMap(\.datedHistoricalEvidenceIDs))

  public static func record(for value: String?) -> TatwoModelIdentityRecord? {
    guard let canonical = canonicalModelID(for: value) else { return nil }
    return records.first { $0.canonicalModelID == canonical }
  }

  public static func canonicalModelID(for value: String?) -> String? {
    let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty, !datedHistoricalEvidenceIDs.contains(raw) else { return nil }
    return aliases[raw.lowercased()]
  }

  public static func normalize(_ value: String?) -> String {
    let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return "" }
    return canonicalModelID(for: raw) ?? raw
  }

  public static func isActiveDispatchEligible(_ value: String?) -> Bool {
    guard let record = record(for: value) else { return false }
    return record.currentHealth != .deferUntilRouteHealthV2
      && record.currentHealth != .unavailable
  }
}
