import CryptoKit
import Darwin
import Foundation

public enum TatwoPermissionPreset: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
  case askFirst
  case approveForMe
  case fullAccess
  case configFile

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .askFirst: return "要求核准"
    case .approveForMe: return "代我核准"
    case .fullAccess: return "完整存取權"
    case .configFile: return "自訂 config.toml"
    }
  }

  public var shortDisplayName: String {
    switch self {
    case .askFirst: return "核准"
    case .approveForMe: return "代核"
    case .fullAccess: return "全權"
    case .configFile: return "自訂"
    }
  }

  public var subtitle: String {
    switch self {
    case .askFirst: return "先停在安全邊界，外部寫入需人類決定"
    case .approveForMe: return "允許工作區寫入，仍保留 OS receipts"
    case .fullAccess: return "可存取網路與電腦檔案；僅限明確授權任務"
    case .configFile: return "使用 config.toml 內定義的權限"
    }
  }

  public var codexSandboxMode: TatwoCodexSandboxMode? {
    switch self {
    case .askFirst: return .readOnly
    case .approveForMe: return .workspaceWrite
    case .fullAccess: return .dangerFullAccess
    case .configFile: return nil
    }
  }

  public var codexArguments: [String] {
    codexSandboxMode?.codexArguments ?? []
  }

  public var claudeArguments: [String] {
    switch self {
    case .askFirst: return ["--permission-mode", "manual"]
    case .approveForMe: return ["--permission-mode", "acceptEdits"]
    case .fullAccess: return ["--permission-mode", "bypassPermissions"]
    case .configFile: return []
    }
  }

  public var grokArguments: [String] {
    // 2026-08-20 A-D headless tests on the bundled Grok CLI showed that
    // acceptEdits/auto cancel write tools immediately; only --always-approve
    // completed the write and EndTurn. Re-test this mapping after Grok CLI upgrades.
    switch self {
    case .askFirst: return ["--permission-mode", "default"]
    case .approveForMe: return ["--always-approve"]
    case .fullAccess: return ["--always-approve"]
    case .configFile: return []
    }
  }

  public var mappingSummary: String {
    let codex = codexArguments.isEmpty ? "Codex: config.toml" : "Codex: \(codexArguments.joined(separator: " "))"
    let claude = claudeArguments.isEmpty ? "Claude: default/config" : "Claude: \(claudeArguments.joined(separator: " "))"
    return "\(codex) · \(claude)"
  }
}
