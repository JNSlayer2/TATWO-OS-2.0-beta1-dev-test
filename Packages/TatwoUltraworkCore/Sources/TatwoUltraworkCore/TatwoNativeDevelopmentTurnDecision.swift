import CryptoKit
import Darwin
import Foundation

public enum TatwoNativeDevelopmentAccess:
  String, Codable, Sendable, Equatable, Hashable
{
  case none
  case readOnly = "read_only"
  case mutation

  public var authorizesNativeRuntime: Bool { self != .none }
  public var isReadOnly: Bool { self != .mutation }
}

public struct TatwoNativeDevelopmentTurnDecision:
  Sendable, Equatable, Hashable
{
  public let requested: Bool
  public let access: TatwoNativeDevelopmentAccess

  public init(
    requested: Bool,
    access: TatwoNativeDevelopmentAccess
  ) {
    self.requested = requested
    self.access = access
  }
}
