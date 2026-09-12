import Foundation

public struct TatwoGatewayCooldownRecordV1: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let provider: String
  public let scope: String
  public let reason: String
  public let tripAtUTC: String
  public let resetAtUTC: String
  public let sourceEventID: String
  public let contractID: String
  public let probeAttemptedAtUTC: String?
  public let probeSucceededAtUTC: String?
  public let clearedAtUTC: String?

  public init(
    schemaVersion: Int = 1,
    provider: String,
    scope: String,
    reason: String,
    tripAtUTC: String,
    resetAtUTC: String,
    sourceEventID: String,
    contractID: String,
    probeAttemptedAtUTC: String? = nil,
    probeSucceededAtUTC: String? = nil,
    clearedAtUTC: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.provider = provider
    self.scope = scope
    self.reason = reason
    self.tripAtUTC = tripAtUTC
    self.resetAtUTC = resetAtUTC
    self.sourceEventID = sourceEventID
    self.contractID = contractID
    self.probeAttemptedAtUTC = probeAttemptedAtUTC
    self.probeSucceededAtUTC = probeSucceededAtUTC
    self.clearedAtUTC = clearedAtUTC
  }
}

public enum TatwoGatewayCooldownStateV1: String, Codable, Sendable, Equatable {
  case clear
  case blocked
  case requiresProbe = "requires_probe"
}

public struct TatwoGatewayCooldownProjectionV1: Sendable, Equatable {
  public let state: TatwoGatewayCooldownStateV1
  public let code: String
  public let record: TatwoGatewayCooldownRecordV1?
  public let retryAtUTC: String?

  public var dispatchAllowed: Bool { state == .clear }
}

public struct TatwoGatewayCooldownStore: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL) {
    self.directoryURL = directoryURL
  }

  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoGatewayCooldownStore {
    TatwoGatewayCooldownStore(
      directoryURL: TatwoGoalRunStore.default(environment: environment).directoryURL)
  }

  public func projection(
    modelID: String,
    now: Date = Date(),
    margin: TimeInterval = 60
  ) -> TatwoGatewayCooldownProjectionV1 {
    let providerKeys = Self.providerKeys(modelID)
    for record in records() where providerKeys.contains(record.provider) {
      guard
        let tripAt = Self.date(record.tripAtUTC),
        let resetAt = Self.date(record.resetAtUTC)
      else {
        return TatwoGatewayCooldownProjectionV1(
          state: .blocked,
          code: "cooldown_blocked_malformed",
          record: record,
          retryAtUTC: nil)
      }
      if now < tripAt {
        return TatwoGatewayCooldownProjectionV1(
          state: .blocked,
          code: "cooldown_blocked_clock_rollback",
          record: record,
          retryAtUTC: Self.string(tripAt))
      }
      let retryAt = resetAt.addingTimeInterval(margin)
      if now < retryAt {
        return TatwoGatewayCooldownProjectionV1(
          state: .blocked,
          code: "cooldown_blocked_before_reset_margin",
          record: record,
          retryAtUTC: Self.string(retryAt))
      }
      if let clearedAt = record.clearedAtUTC.flatMap(Self.date),
        let probeSucceededAt = record.probeSucceededAtUTC.flatMap(Self.date),
        clearedAt >= tripAt,
        probeSucceededAt >= retryAt
      {
        continue
      }
      return TatwoGatewayCooldownProjectionV1(
        state: record.probeAttemptedAtUTC == nil ? .requiresProbe : .blocked,
        code: record.probeAttemptedAtUTC == nil
          ? "cooldown_probe_required"
          : "cooldown_blocked_probe_exhausted",
        record: record,
        retryAtUTC: Self.string(retryAt))
    }
    return TatwoGatewayCooldownProjectionV1(
      state: .clear,
      code: "clear",
      record: nil,
      retryAtUTC: nil)
  }

  private func records() -> [TatwoGatewayCooldownRecordV1] {
    let directory = directoryURL.appendingPathComponent("cooldowns", isDirectory: true)
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil)) ?? []
    return files
      .filter { $0.pathExtension == "json" }
      .compactMap { try? Data(contentsOf: $0) }
      .compactMap { try? JSONDecoder().decode(TatwoGatewayCooldownRecordV1.self, from: $0) }
  }

  private static func providerKeys(_ modelID: String) -> Set<String> {
    let model = TatwoMCPRegistry.normalizeGatewayModel(modelID)
    var keys = Set([model])
    if model == "chatgpt-pro-consult" || model.hasPrefix("gpt-") || model.hasPrefix("codex-") {
      keys.insert("openai")
    }
    if model.hasPrefix("sonnet-") || model.hasPrefix("haiku-") || model.hasPrefix("opus-") {
      keys.insert("anthropic")
    }
    return keys
  }

  private static func date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  private static func string(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
