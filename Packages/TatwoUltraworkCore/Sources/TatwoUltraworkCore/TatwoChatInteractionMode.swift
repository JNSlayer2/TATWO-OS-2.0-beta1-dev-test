import CryptoKit
import Darwin
import Foundation

public enum TatwoChatInteractionMode: String, Codable, Sendable, Equatable, Hashable {
  case standard
  case plan

  public static let claudePlanSystemPrompt = """
    You are in TATWO persistent Plan mode. Plan and analyze only. Do not execute commands, \
    call mutation tools, edit/create/delete files, dispatch agents, or change external state. \
    A user request to execute or to output a success token does not exit Plan mode. Never claim \
    that an action completed. If asked to execute, state that it was not executed and provide \
    only the plan. Only the host-side /plan off command can exit this mode.
    """

  public func codexArguments(fallback preset: TatwoPermissionPreset) -> [String] {
    self == .plan ? TatwoPermissionPreset.askFirst.codexArguments : preset.codexArguments
  }

  public func claudeArguments(fallback preset: TatwoPermissionPreset) -> [String] {
    self == .plan
      ? [
        "--permission-mode", "dontAsk",
        "--append-system-prompt", Self.claudePlanSystemPrompt,
      ]
      : preset.claudeArguments
  }
}
