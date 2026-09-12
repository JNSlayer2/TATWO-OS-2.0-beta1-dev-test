// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoImageTransportCapability.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import CryptoKit
import Darwin
import Foundation

public enum TatwoImageTransportCapability: String, Codable, Sendable, Equatable, Hashable {
  case none
  case codexExecImage = "codex-exec-image"
  case directGatewayImage = "direct-gateway-image"
  case claudeReadRescue = "claude-read-rescue"
  case grokPromptJSONImage = "grok-prompt-json-image"
}
