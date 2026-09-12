import CryptoKit
import Darwin
import Foundation

/// The one loopback MCP endpoint owned by the currently running App instance.
///
/// Keeping this as a validated value (rather than passing an arbitrary string)
/// prevents a Chat turn from accidentally targeting another installed/staging
/// App or an off-device MCP server. The HTTP server binds only to 127.0.0.1,
/// so the planner accepts only that exact origin and a non-zero port.
public struct TatwoAppMCPEndpoint: Sendable, Equatable, Hashable {
  public let url: URL

  public init?(url: URL) {
    guard let components = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "http",
      components.host == "127.0.0.1",
      let port = components.port,
      (1...Int(UInt16.max)).contains(port),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else {
      return nil
    }
    guard let canonicalURL = URL(string: "http://127.0.0.1:\(port)") else {
      return nil
    }
    self.url = canonicalURL
  }

  public init?(urlString: String) {
    guard let url = URL(string: urlString) else { return nil }
    self.init(url: url)
  }

  public static func loopback(port: UInt16) -> TatwoAppMCPEndpoint? {
    guard port != 0 else { return nil }
    return TatwoAppMCPEndpoint(urlString: "http://127.0.0.1:\(port)")
  }
}

/// Process-local readiness published by the App delegate and consumed by Chat.
///
/// Chat must see `.ready` before it constructs a Claude computer-use command.
/// A configured port is not evidence that the listener successfully bound it.
public enum TatwoAppMCPRuntimeState: Sendable, Equatable {
  case notStarted
  case ready(TatwoAppMCPEndpoint)
  case failed(String)

  public var endpoint: TatwoAppMCPEndpoint? {
    guard case .ready(let endpoint) = self else { return nil }
    return endpoint
  }

  public var failureReason: String? {
    guard case .failed(let reason) = self else { return nil }
    return reason
  }
}

public enum TatwoChatAppMCPToolCatalog {
  public static let readOnly = [
    "mcp__tatwo-app__tatwo_app_read_os_state",
    "mcp__tatwo-app__tatwo_app_list_loops",
  ]
  public static let mutations = [
    "mcp__tatwo-app__tatwo_app_switch_tab",
    "mcp__tatwo-app__tatwo_app_set_sidebar_pinned",
    "mcp__tatwo-app__tatwo_app_set_tab_setting",
  ]

  public static func allowedTools(
    permissionPreset: TatwoPermissionPreset,
    perThreadAllowlist: [String]
  ) -> [String] {
    let approved = Set(perThreadAllowlist)
    let mutationTools =
      permissionPreset == .approveForMe || permissionPreset == .fullAccess
      ? mutations
      : mutations.filter { approved.contains($0) }
    return readOnly + mutationTools
  }
}

public struct TatwoChatMCPApprovalRequest: Sendable, Equatable {
  public let toolName: String

  public init?(diagnosticText: String) {
    let patterns = [
      #"(?i)(?:permission|approval).{0,80}(mcp__[A-Za-z0-9_-]+__[A-Za-z0-9_-]+)"#,
      #"(?i)(mcp__[A-Za-z0-9_-]+__[A-Za-z0-9_-]+).{0,80}(?:permission|approval)"#,
    ]
    for pattern in patterns {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(diagnosticText.startIndex..., in: diagnosticText)
      guard let match = expression.firstMatch(in: diagnosticText, range: range),
        match.numberOfRanges >= 2,
        let toolRange = Range(match.range(at: 1), in: diagnosticText)
      else { continue }
      self.toolName = String(diagnosticText[toolRange])
      return
    }
    // 2026-08-23 使用者「先問我」實測：內建工具的權限請求長這樣——
    // "Claude requested permissions to write to <path>" / "to use <Tool>"，
    // 沒有 mcp__ 字樣；原版只認 mcp__ ＝授權鈕永遠不出現。
    if let builtin = Self.builtinToolName(in: diagnosticText) {
      self.toolName = builtin
      return
    }
    return nil
  }

  public static func builtinToolName(in text: String) -> String? {
    guard text.range(
      of: #"(?i)requested permissions"#, options: .regularExpression) != nil
    else { return nil }
    if text.range(
      of: #"(?i)requested permissions to (write to|edit)"#,
      options: .regularExpression) != nil {
      return "Write"
    }
    if let match = text.range(
      of: #"(?i)(?<=requested permissions to use )[A-Za-z][A-Za-z0-9_]*"#,
      options: .regularExpression) {
      return String(text[match])
    }
    return nil
  }

  public var userMessage: String {
    "工具 \(toolName) 需要授權；請在本討論串允許此工具後重試。"
  }
}
