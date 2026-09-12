// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoNativeChatEngine.swift；改動 4 行（原因：改接 Tatwo2 同名 Facade 假資料）
import CryptoKit
import Darwin
import Foundation

public enum TatwoNativeChatEngine: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
  case codex = "Codex"
  case claude = "Claude"

  public var id: String { rawValue }

}
