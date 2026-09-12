// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoModelSpeedTier.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import CryptoKit
import Darwin
import Foundation

public enum TatwoModelSpeedTier: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
  case fast
  case standard

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .fast: return "fast"
    case .standard: return "standard"
    }
  }

  public var compactDisplayName: String { displayName }

  public var serviceTierValue: String { rawValue }

  /// app-server uses the model catalog's service-tier ID, not the CLI's
  /// legacy speed label. Explicit "default" also resets a prior Fast turn.
  public var appServerValue: String {
    switch self {
    case .fast: return "priority"
    case .standard: return "default"
    }
  }

  /// `standard` is the account/CLI default tier, and the Codex runtime does
  /// not advertise it as an override target: passing
  /// `-c service_tier="standard"` makes every turn start with a
  /// "not advertised, ignoring" warning while behaving identically to the
  /// no-argument path. Keep the UI selection persisted and shown, but only send
  /// argv for the tier that actually changes runtime behaviour.
  public var codexArguments: [String] {
    switch self {
    case .fast:
      return ["-c", "service_tier=\"\(serviceTierValue)\""]
    case .standard:
      return []
    }
  }
}
