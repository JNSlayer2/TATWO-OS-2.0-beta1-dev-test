// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoCodexSandboxMode.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import CryptoKit
import Darwin
import Foundation

public enum TatwoCodexSandboxMode: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
  case readOnly = "read-only"
  case workspaceWrite = "workspace-write"
  case dangerFullAccess = "danger-full-access"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .readOnly: return "唯讀"
    case .workspaceWrite: return "工作區寫入"
    case .dangerFullAccess: return "完整存取"
    }
  }

  public var codexArguments: [String] {
    // 2026-08-23 codex 對齊：workspace-write 沙盒預設斷網＝sol 路由 curl 靜默
    // 無輸出的真兇；「代我核准」語義含網路（與 claude 路由 WebFetch/Bash curl 等價）。
    switch self {
    case .workspaceWrite:
      return ["-s", rawValue, "-c", "sandbox_workspace_write.network_access=true"]
    default:
      return ["-s", rawValue]
    }
  }
}
