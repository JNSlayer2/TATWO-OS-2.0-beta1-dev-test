import CryptoKit
import Darwin
import Foundation

public enum TatwoNativeChatSkin: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
  case codex = "Codex 皮"
  case claude = "Claude 皮"

  public var id: String { rawValue }
}

public struct TatwoNativePaneBindingMatrix: Codable, Sendable, Equatable, Hashable {
  public let skin: TatwoNativeChatSkin
  public let engine: TatwoNativeChatEngine

  public init(skin: TatwoNativeChatSkin, engine: TatwoNativeChatEngine) {
    self.skin = skin
    self.engine = engine
  }

  public static let allCases: [TatwoNativePaneBindingMatrix] = TatwoNativeChatSkin.allCases.flatMap { skin in
    TatwoNativeChatEngine.allCases.map { engine in
      TatwoNativePaneBindingMatrix(skin: skin, engine: engine)
    }
  }
}
