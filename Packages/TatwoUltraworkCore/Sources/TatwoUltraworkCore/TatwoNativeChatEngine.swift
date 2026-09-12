import CryptoKit
import Darwin
import Foundation

public enum TatwoNativeChatEngine: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
  case codex = "Codex"
  case claude = "Claude"

  public var id: String { rawValue }
}
