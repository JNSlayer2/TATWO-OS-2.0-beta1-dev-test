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
