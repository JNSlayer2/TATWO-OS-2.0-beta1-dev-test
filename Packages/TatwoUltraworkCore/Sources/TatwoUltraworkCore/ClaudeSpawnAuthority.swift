import Foundation

public enum ClaudeSpawnPurpose: String, CaseIterable, Sendable, Codable {
  case chatTurn
  case devRunner
  case computerHostBridge
  case cliTab
  case smoke
}

public enum ClaudeSpawnNetworkPolicy: String, Sendable, Codable {
  case allowed
  case denied
  case reportUnavailable
}

public enum ClaudeSpawnNetworkEnvironment {
  /// Claude's Bash tool runs in the same child environment as the CLI. Keep
  /// network capability explicit and remove inherited variables that can
  /// silently redirect DNS/HTTP into a dead development proxy.
  public static func applying(
    _ policy: ClaudeSpawnNetworkPolicy,
    to environment: [String: String]
  ) -> [String: String] {
    var result = environment
    let proxyKeys = [
      "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
      "http_proxy", "https_proxy", "all_proxy", "no_proxy",
    ]
    switch policy {
    case .allowed:
      for key in proxyKeys { result.removeValue(forKey: key) }
      result["TATWO_CLAUDE_NETWORK_CAPABILITY"] = "direct"
    case .denied:
      for key in proxyKeys { result.removeValue(forKey: key) }
      result["TATWO_CLAUDE_NETWORK_CAPABILITY"] = "denied"
    case .reportUnavailable:
      result["TATWO_CLAUDE_NETWORK_CAPABILITY"] = "diagnostic_only"
    }
    return result
  }
}

public struct ClaudeSpawnToolPolicy: Sendable, Equatable, Codable {
  public var tools: [String]
  public var allowedTools: [String]

  public init(tools: [String], allowedTools: [String]) {
    self.tools = Self.normalized(tools)
    self.allowedTools = Self.normalized(allowedTools)
  }

  public static let none = ClaudeSpawnToolPolicy(tools: [], allowedTools: [])

  private static func normalized(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
      return trimmed
    }
  }
}

public struct ClaudeSpawnRequest: Sendable, Equatable {
  public var purpose: ClaudeSpawnPurpose
  public var canonicalModelSlug: String
  public var effort: String?
  public var toolPolicy: ClaudeSpawnToolPolicy
  public var networkPolicy: ClaudeSpawnNetworkPolicy
  public var workingDirectory: URL
  public var extraMCPConfig: String?
  public var additionalArguments: [String]

  public init(
    purpose: ClaudeSpawnPurpose,
    canonicalModelSlug: String,
    effort: String?,
    toolPolicy: ClaudeSpawnToolPolicy,
    networkPolicy: ClaudeSpawnNetworkPolicy,
    workingDirectory: URL,
    extraMCPConfig: String? = nil,
    additionalArguments: [String] = []
  ) {
    self.purpose = purpose
    self.canonicalModelSlug = canonicalModelSlug
    self.effort = effort
    self.toolPolicy = toolPolicy
    self.networkPolicy = networkPolicy
    self.workingDirectory = workingDirectory.standardizedFileURL
    self.extraMCPConfig = extraMCPConfig
    self.additionalArguments = additionalArguments
  }
}

public struct ClaudeSpawnPlan: Sendable, Equatable {
  public let executableURL: URL
  public let arguments: [String]
  public let environment: [String: String]
  public let currentDirectoryURL: URL
  public let vendorModelID: String
  public let profileHomeURL: URL
}

public enum ClaudeSpawnAuthorityError: Error, Sendable, Equatable {
  case executableUnavailable
  case unsupportedModel(String)
  case invalidWorkingDirectory
}

/// Single source of truth for every Claude CLI child identity.
///
/// This authority deliberately owns HOME, credential scrubbing/injection,
/// vendor model mapping and explicit tool arguments. Callers may add protocol
/// arguments, but must not rebuild those identity fields themselves.
public struct ClaudeSpawnAuthority: Sendable {
  public static let oauthTokenFilename = "claude-oauth-token"

  private static let forbiddenEnvironmentKeys: Set<String> = [
    "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_ACCESS_TOKEN",
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR",
    "GROK_API_KEY", "MINIMAX_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY",
    "XAI_API_KEY",
  ]

  public let executableURL: URL
  public let profileHomeURL: URL
  public let baseEnvironment: [String: String]

  public init(
    executableURL: URL,
    profileHomeURL: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.executableURL = executableURL.standardizedFileURL
    self.profileHomeURL = (profileHomeURL ?? Self.resolveProfileHome(environment: environment))
      .standardizedFileURL
    self.baseEnvironment = environment
  }

  public func plan(_ request: ClaudeSpawnRequest) throws -> ClaudeSpawnPlan {
    guard executableURL.path.hasPrefix("/") else {
      throw ClaudeSpawnAuthorityError.executableUnavailable
    }
    guard request.workingDirectory.path.hasPrefix("/") else {
      throw ClaudeSpawnAuthorityError.invalidWorkingDirectory
    }
    guard let vendorModelID = Self.vendorModelID(for: request.canonicalModelSlug) else {
      throw ClaudeSpawnAuthorityError.unsupportedModel(request.canonicalModelSlug)
    }

    var environment = ClaudeSpawnNetworkEnvironment.applying(
      request.networkPolicy,
      to: Self.scrubbedEnvironment(baseEnvironment))
    environment["HOME"] = profileHomeURL.path
    environment["TATWO_CLAUDE_SPAWN_PURPOSE"] = request.purpose.rawValue
    environment["TATWO_CLAUDE_NETWORK_POLICY"] = request.networkPolicy.rawValue
    Self.injectProfileToken(into: &environment, profileHomeURL: profileHomeURL)

    var arguments = ["--model", vendorModelID]
    if let effort = request.effort?.trimmingCharacters(in: .whitespacesAndNewlines), !effort.isEmpty {
      arguments += ["--effort", effort]
    }
    if let config = request.extraMCPConfig, !config.isEmpty {
      arguments += ["--strict-mcp-config", "--mcp-config", config]
    }
    // Always explicit, including the empty set: never inherit settings.json.
    arguments += ["--tools", request.toolPolicy.tools.joined(separator: ",")]
    arguments += ["--allowedTools", request.toolPolicy.allowedTools.joined(separator: ",")]
    arguments += request.additionalArguments

    return ClaudeSpawnPlan(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      currentDirectoryURL: request.workingDirectory,
      vendorModelID: vendorModelID,
      profileHomeURL: profileHomeURL)
  }

  public static func vendorModelID(for canonicalModelSlug: String) -> String? {
    switch canonicalModelSlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "fable-5", "fable5", "claude-fable-5": "claude-fable-5"
    case "opus-5", "opus5", "opus", "claude-opus-5": "claude-opus-5"
    case "sonnet-5", "sonnet5", "sonnet", "claude-sonnet-5": "sonnet"
    case "haiku-4-5", "haiku45", "haiku", "claude-haiku-4-5": "haiku"
    // 救援/舊版路由（沿用原 alias 語義，fable5 驗收 2026-08-23）。
    case "sonnet-4-6", "claude-sonnet-4-6": "sonnet"
    case "haiku-4-6", "claude-haiku-4-6": "haiku"
    default: nil
    }
  }

  public static func resolveProfileHome(environment: [String: String]) -> URL {
    if let injected = absoluteDirectory(environment["TATWO_NATIVE_CLAUDE_SUBSCRIPTION_HOME"]) {
      return injected
    }
    if let appSupport = absoluteDirectory(environment["TATWO_ULTRAWORK_APP_SUPPORT"]) {
      return appSupport.appendingPathComponent("model-subscriptions/claude", isDirectory: true)
    }
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    return applicationSupport.appendingPathComponent(
      "Tatwo Ultrawork/model-subscriptions/claude", isDirectory: true)
  }

  public static func scrubbedEnvironment(_ environment: [String: String]) -> [String: String] {
    var result = environment
    for key in forbiddenEnvironmentKeys { result.removeValue(forKey: key) }
    return result
  }

  public static func injectProfileToken(
    into environment: inout [String: String],
    profileHomeURL: URL
  ) {
    let tokenURL = profileHomeURL.appendingPathComponent(oauthTokenFilename)
    guard let raw = try? String(contentsOf: tokenURL, encoding: .utf8) else { return }
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return }
    environment["CLAUDE_CODE_OAUTH_TOKEN"] = token
  }

  private static func absoluteDirectory(_ value: String?) -> URL? {
    guard let value, value.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
  }
}
