import CryptoKit
import Darwin
import Foundation

public enum TatwoChatRuntimeAdapter: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
  case unavailable
  case nativeAgent = "tatwo-native-agent"
  case codexExec = "codex-exec"
  case claudeCLI = "claude-cli-native"
  case grokCLI = "grok-cli-native"
  case minimaxDirect = "minimax-direct"
  /// Deprecated production transport. The D5 cutoff is scheduled for
  /// August 20, 2026; keep the adapter decodable for historical receipts
  /// and tests, but new Chat route decisions must not select it.
  case gatewayDirect = "gateway-direct"

  public var id: String { rawValue }
}

public enum TatwoChatRuntimeFallbackReason:
  String, Codable, Sendable, Equatable, Hashable
{
  case minimaxLocalCLIUnavailable = "dev_runtime_minimax_local_cli_unavailable"
  case codexExecutableUnavailable = "dev_runtime_codex_executable_unavailable"
  case claudeExecutableUnavailable = "dev_runtime_claude_executable_unavailable"
  case grokExecutableUnavailable = "dev_runtime_grok_executable_unavailable"
  case nativeGovernanceNotEngaged =
    "dev_runtime_native_governance_not_engaged"
}

public struct TatwoChatRuntimeRouteDecision:
  Codable, Sendable, Equatable, Hashable
{
  public let adapter: TatwoChatRuntimeAdapter
  public let fallbackReason: TatwoChatRuntimeFallbackReason?

  public init(
    adapter: TatwoChatRuntimeAdapter,
    fallbackReason: TatwoChatRuntimeFallbackReason? = nil
  ) {
    self.adapter = adapter
    self.fallbackReason = fallbackReason
  }
}
