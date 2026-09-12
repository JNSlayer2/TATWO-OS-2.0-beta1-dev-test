import CryptoKit
import Darwin
import Foundation

public enum TatwoChatCommandMode: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
  case chat
  case cowork
  case cli

  public var id: String { rawValue }
}

public struct TatwoChatCommandPlan: Codable, Sendable, Equatable, Hashable {
  public let routeID: String
  public let engine: TatwoNativeChatEngine
  public let runtimeAdapter: TatwoChatRuntimeAdapter
  public let canonicalModelSlug: String
  public let executable: String
  public let arguments: [String]
  public let workingDirectoryPath: String
  public let expectsJSON: Bool
  public let capturesSessionID: Bool
  public let logFilePath: String?
  public let standardInputFromDevNull: Bool
  /// UTF-8 prompt bytes delivered through a closed stdin pipe. This avoids
  /// the Codex CLI's ambiguous "argv prompt plus non-TTY stdin" path, which
  /// can wait indefinitely before producing its first JSONL event.
  public let standardInputUTF8: String?
  public let requiresForegroundScheduling: Bool
  public let nativeDevelopmentAccess: TatwoNativeDevelopmentAccess
  /// Machine-readable reason that the requested development runtime was
  /// downgraded to the resilient gateway chat path.
  public let runtimeFallbackReason: TatwoChatRuntimeFallbackReason?
  /// Per-command environment overrides. The launcher applies these only
  /// after constructing its small terminal-like allowlist.
  public let environmentOverrides: [String: String]
  /// Immutable conversation-continuation request for this physical turn.
  /// The opaque handle itself is transported through a mode-0600 file, never
  /// through argv or environment variables.
  public let gatewayContinuationRequest: TatwoGatewayContinuationRequestV1?
  /// Ephemeral files created by the planner but owned by the production
  /// launcher until the child has either consumed them or failed to launch.
  ///
  /// The device/inode binding lets the launcher refuse to unlink a path that
  /// was replaced after planning.
  public let ownedTemporaryFiles: [TatwoChatOwnedTemporaryFile]

  public init(
    routeID: String,
    engine: TatwoNativeChatEngine,
    runtimeAdapter: TatwoChatRuntimeAdapter,
    canonicalModelSlug: String,
    executable: String,
    arguments: [String],
    workingDirectoryPath: String,
    expectsJSON: Bool,
    capturesSessionID: Bool,
    logFilePath: String? = nil,
    standardInputFromDevNull: Bool = false,
    standardInputUTF8: String? = nil,
    requiresForegroundScheduling: Bool = false,
    nativeDevelopmentAccess: TatwoNativeDevelopmentAccess = .none,
    runtimeFallbackReason: TatwoChatRuntimeFallbackReason? = nil,
    environmentOverrides: [String: String] = [:],
    gatewayContinuationRequest: TatwoGatewayContinuationRequestV1? = nil,
    ownedTemporaryFiles: [TatwoChatOwnedTemporaryFile] = []
  ) {
    self.routeID = routeID
    self.engine = engine
    self.runtimeAdapter = runtimeAdapter
    self.canonicalModelSlug = canonicalModelSlug
    self.executable = executable
    self.arguments = arguments
    self.workingDirectoryPath = workingDirectoryPath
    self.expectsJSON = expectsJSON
    self.capturesSessionID = capturesSessionID
    self.logFilePath = logFilePath
    self.standardInputFromDevNull = standardInputFromDevNull
    self.standardInputUTF8 = standardInputUTF8
    self.requiresForegroundScheduling = requiresForegroundScheduling
    self.nativeDevelopmentAccess = nativeDevelopmentAccess
    self.runtimeFallbackReason = runtimeFallbackReason
    self.environmentOverrides = environmentOverrides
    self.gatewayContinuationRequest = gatewayContinuationRequest
    self.ownedTemporaryFiles = ownedTemporaryFiles
  }

  private enum CodingKeys: String, CodingKey {
    case routeID
    case engine
    case runtimeAdapter
    case canonicalModelSlug
    case executable
    case arguments
    case workingDirectoryPath
    case expectsJSON
    case capturesSessionID
    case logFilePath
    case standardInputFromDevNull
    case standardInputUTF8
    case requiresForegroundScheduling
    case nativeDevelopmentAccess
    case runtimeFallbackReason
    case environmentOverrides
    case gatewayContinuationRequest
    case ownedTemporaryFiles
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    routeID = try container.decode(String.self, forKey: .routeID)
    engine = try container.decode(TatwoNativeChatEngine.self, forKey: .engine)
    runtimeAdapter = try container.decode(
      TatwoChatRuntimeAdapter.self,
      forKey: .runtimeAdapter)
    canonicalModelSlug = try container.decode(
      String.self,
      forKey: .canonicalModelSlug)
    executable = try container.decode(String.self, forKey: .executable)
    arguments = try container.decode([String].self, forKey: .arguments)
    workingDirectoryPath = try container.decode(
      String.self,
      forKey: .workingDirectoryPath)
    expectsJSON = try container.decode(Bool.self, forKey: .expectsJSON)
    capturesSessionID = try container.decode(
      Bool.self,
      forKey: .capturesSessionID)
    logFilePath = try container.decodeIfPresent(
      String.self,
      forKey: .logFilePath)
    standardInputFromDevNull = try container.decodeIfPresent(
      Bool.self,
      forKey: .standardInputFromDevNull) ?? false
    standardInputUTF8 = try container.decodeIfPresent(
      String.self,
      forKey: .standardInputUTF8)
    requiresForegroundScheduling = try container.decodeIfPresent(
      Bool.self,
      forKey: .requiresForegroundScheduling) ?? false
    nativeDevelopmentAccess = try container.decodeIfPresent(
      TatwoNativeDevelopmentAccess.self,
      forKey: .nativeDevelopmentAccess) ?? .none
    runtimeFallbackReason = try container.decodeIfPresent(
      TatwoChatRuntimeFallbackReason.self,
      forKey: .runtimeFallbackReason)
    environmentOverrides = try container.decodeIfPresent(
      [String: String].self,
      forKey: .environmentOverrides) ?? [:]
    gatewayContinuationRequest = try container.decodeIfPresent(
      TatwoGatewayContinuationRequestV1.self,
      forKey: .gatewayContinuationRequest)
    ownedTemporaryFiles = try container.decodeIfPresent(
      [TatwoChatOwnedTemporaryFile].self,
      forKey: .ownedTemporaryFiles) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(routeID, forKey: .routeID)
    try container.encode(engine, forKey: .engine)
    try container.encode(runtimeAdapter, forKey: .runtimeAdapter)
    try container.encode(canonicalModelSlug, forKey: .canonicalModelSlug)
    try container.encode(executable, forKey: .executable)
    try container.encode(arguments, forKey: .arguments)
    try container.encode(workingDirectoryPath, forKey: .workingDirectoryPath)
    try container.encode(expectsJSON, forKey: .expectsJSON)
    try container.encode(capturesSessionID, forKey: .capturesSessionID)
    try container.encodeIfPresent(logFilePath, forKey: .logFilePath)
    try container.encode(
      standardInputFromDevNull,
      forKey: .standardInputFromDevNull)
    try container.encodeIfPresent(
      standardInputUTF8,
      forKey: .standardInputUTF8)
    try container.encode(
      requiresForegroundScheduling,
      forKey: .requiresForegroundScheduling)
    if nativeDevelopmentAccess != .none {
      try container.encode(
        nativeDevelopmentAccess,
        forKey: .nativeDevelopmentAccess)
    }
    try container.encodeIfPresent(
      runtimeFallbackReason,
      forKey: .runtimeFallbackReason)
    if !environmentOverrides.isEmpty {
      try container.encode(environmentOverrides, forKey: .environmentOverrides)
    }
    try container.encodeIfPresent(
      gatewayContinuationRequest,
      forKey: .gatewayContinuationRequest)
    if !ownedTemporaryFiles.isEmpty {
      try container.encode(ownedTemporaryFiles, forKey: .ownedTemporaryFiles)
    }
  }

  public var display: String {
    TatwoChatCommandPlanner.redacted(
      ([executable] + arguments).joined(separator: " ")
        + (standardInputFromDevNull
          ? " < /dev/null"
          : standardInputUTF8 == nil ? "" : " < <stdin-prompt>"))
  }
}

public struct TatwoChatOwnedTemporaryFile: Codable, Sendable, Equatable, Hashable {
  public let path: String
  public let deviceID: UInt64
  public let inode: UInt64

  public init(path: String, deviceID: UInt64, inode: UInt64) {
    self.path = path
    self.deviceID = deviceID
    self.inode = inode
  }
}
