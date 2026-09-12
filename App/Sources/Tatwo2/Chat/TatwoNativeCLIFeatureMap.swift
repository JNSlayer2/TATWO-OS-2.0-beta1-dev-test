// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoNativeCLIFeatureMap.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import CryptoKit
import Darwin
import Foundation

public enum TatwoNativeCLIFeature: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
  case jsonStream = "JSON stream"
  case resumeSession = "resume session"
  case model = "model"
  case workingDirectory = "working directory"
  case sandbox = "sandbox"
  case imageAttachment = "image attachment"
  case approvalBar = "approval bar"
  case permissionMode = "permission mode"
  case thinkingFold = "thinking fold"
  case toolUseBlock = "tool-use block"
  case diffView = "diff view"
  case taskSidebar = "task sidebar"

  public var id: String { rawValue }
}

public enum TatwoNativeCLIMappingStatus: String, Codable, Sendable, Equatable, Hashable {
  case mapped
  case unmapped
  case uiOnly
}

public struct TatwoNativeCLIFeatureMapping: Codable, Sendable, Equatable, Hashable {
  public let feature: TatwoNativeCLIFeature
  public let status: TatwoNativeCLIMappingStatus
  public let flag: String?
  public let note: String

  public init(feature: TatwoNativeCLIFeature, status: TatwoNativeCLIMappingStatus, flag: String?, note: String) {
    self.feature = feature
    self.status = status
    self.flag = flag
    self.note = note
  }
}

public enum TatwoNativeCLIFeatureMap {
  public static func mapping(engine: TatwoNativeChatEngine) -> [TatwoNativeCLIFeature: TatwoNativeCLIFeatureMapping] {
    switch engine {
    case .codex:
      return dictionary([
        .init(feature: .jsonStream, status: .mapped, flag: "--json", note: "codex exec emits JSONL"),
        .init(feature: .resumeSession, status: .mapped, flag: "exec resume <session_id>", note: "resume previous Codex session"),
        .init(feature: .model, status: .mapped, flag: "--model <model>", note: "Codex CLI model override"),
        .init(feature: .workingDirectory, status: .mapped, flag: "--cd", note: "set work root; UI supplies <dir> value"),
        .init(feature: .sandbox, status: .mapped, flag: "--sandbox workspace-write", note: "workspace-write cowork ticket"),
        .init(feature: .imageAttachment, status: .mapped, flag: "--image <file>", note: "initial prompt image attachment"),
        .init(feature: .approvalBar, status: .unmapped, flag: nil, note: "no stable codex exec approval flag in current help"),
        .init(feature: .permissionMode, status: .unmapped, flag: nil, note: "Codex exec exposes sandbox, not Claude-style permission modes"),
        .init(feature: .thinkingFold, status: .uiOnly, flag: nil, note: "fold normalized thinking events when present"),
        .init(feature: .toolUseBlock, status: .uiOnly, flag: nil, note: "render normalized tool-use events"),
        .init(feature: .diffView, status: .mapped, flag: "exec review", note: "review command can produce code-review context; not a chat-turn flag"),
        .init(feature: .taskSidebar, status: .uiOnly, flag: nil, note: "session metadata projection")
      ])
    case .claude:
      return dictionary([
        .init(feature: .jsonStream, status: .mapped, flag: "--output-format stream-json --verbose", note: "Claude print stream JSON currently requires --verbose"),
        .init(feature: .resumeSession, status: .mapped, flag: "--resume <session_id> / --continue", note: "resume by id or current directory"),
        .init(feature: .model, status: .mapped, flag: "--model <model>", note: "Claude model alias/name"),
        .init(feature: .workingDirectory, status: .mapped, flag: "--add-dir <dir>", note: "allow additional project directory; process cwd still set by host"),
        .init(feature: .sandbox, status: .unmapped, flag: nil, note: "Claude help exposes permissions, not Codex sandbox modes"),
        .init(feature: .imageAttachment, status: .mapped, flag: "@<repo-relative-image-path>", note: "App appends dragged image path as a Claude Code file mention in the turn; round18 vision e2e verifies native image understanding"),
        .init(feature: .approvalBar, status: .mapped, flag: "--permission-mode manual", note: "manual permission prompts"),
        .init(feature: .permissionMode, status: .mapped, flag: "--permission-mode <mode>", note: "manual/auto/plan/etc."),
        .init(feature: .thinkingFold, status: .mapped, flag: "stream-json thinking events", note: "render normalized thinking events when emitted"),
        .init(feature: .toolUseBlock, status: .mapped, flag: "stream-json tool events", note: "render normalized tool-use events"),
        .init(feature: .diffView, status: .uiOnly, flag: nil, note: "render diff blocks from CLI output; no dedicated print flag"),
        .init(feature: .taskSidebar, status: .mapped, flag: "--bg / claude agents", note: "background agent/task surface")
      ])
    }
  }

  public static func receiptMarkdown(engine: TatwoNativeChatEngine) -> String {
    let mappings = mapping(engine: engine)
    // 防禦：若日後新增 feature 沒同步 mapping，用 "—" 佔位而非 force-unwrap crash。
    return TatwoNativeCLIFeature.allCases.map { feature in
      guard let item = mappings[feature] else {
        return "| \(engine.rawValue) | \(feature.rawValue) | — | — | (未對映) |"
      }
      return "| \(engine.rawValue) | \(feature.rawValue) | \(item.status.rawValue) | \(item.flag ?? "—") | \(item.note) |"
    }.joined(separator: "\n")
  }

  private static func dictionary(_ rows: [TatwoNativeCLIFeatureMapping]) -> [TatwoNativeCLIFeature: TatwoNativeCLIFeatureMapping] {
    Dictionary(uniqueKeysWithValues: rows.map { ($0.feature, $0) })
  }
}
