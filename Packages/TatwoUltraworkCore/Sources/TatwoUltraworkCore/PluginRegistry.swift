import Foundation

public struct TatwoPluginRegistryBookV1: Codable, Sendable, Equatable {
  public let schema: String
  public var entries: [PluginRegistryEntry]
  public var removedDefaultIDs: [String]
  public var updatedAt: Date

  public init(
    schema: String = "TatwoPluginRegistryBookV1",
    entries: [PluginRegistryEntry] = TatwoCatalog.defaults.plugins,
    removedDefaultIDs: [String] = [],
    updatedAt: Date = Date()
  ) {
    self.schema = schema
    self.entries = entries
    self.removedDefaultIDs = removedDefaultIDs.sorted()
    self.updatedAt = updatedAt
  }

  public var sortedEntries: [PluginRegistryEntry] {
    entries.sorted {
      if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
      return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  public func entry(id: String) -> PluginRegistryEntry? {
    entries.first { $0.id == id }
  }

  public func normalizedForCurrentDefaults() -> TatwoPluginRegistryBookV1 {
    let removed = Set(removedDefaultIDs)
    var mergedByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    for entry in TatwoCatalog.defaults.plugins where !removed.contains(entry.id) {
      mergedByID[entry.id] = entry
    }
    var copy = self
    copy.removedDefaultIDs = Array(removed).sorted()
    copy.entries = Array(mergedByID.values).sortedEntriesForRegistry()
    return copy
  }
}

public struct TatwoPluginRegistryMutationResult: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let stage: String
  public let message: String
  public let entry: PluginRegistryEntry?
  public let book: TatwoPluginRegistryBookV1

  public init(
    schema: String = "TatwoPluginRegistryMutationResultV1",
    ok: Bool,
    stage: String = "staging",
    message: String,
    entry: PluginRegistryEntry?,
    book: TatwoPluginRegistryBookV1
  ) {
    self.schema = schema
    self.ok = ok
    self.stage = stage
    self.message = message
    self.entry = entry
    self.book = book
  }
}

public struct TatwoClaudeMCPServerConfigV1: Codable, Sendable, Equatable {
  public let type: String
  public let command: String?
  public let args: [String]?
  public let url: String?
  public let env: [String: String]?

  public init(
    type: String,
    command: String? = nil,
    args: [String]? = nil,
    url: String? = nil,
    env: [String: String]? = nil
  ) {
    self.type = type
    self.command = command
    self.args = args
    self.url = url
    self.env = env
  }
}

public struct TatwoClaudeMCPConfigV1: Codable, Sendable, Equatable {
  public let mcpServers: [String: TatwoClaudeMCPServerConfigV1]

  public init(mcpServers: [String: TatwoClaudeMCPServerConfigV1]) {
    self.mcpServers = mcpServers
  }
}

public struct TatwoClaudeMCPSyncReceiptV1: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let stage: String
  public let wrotePath: String
  public let backupPath: String?
  public let serverNames: [String]
  public let manualInstallHint: String
  public let config: TatwoClaudeMCPConfigV1

  public init(
    schema: String = "TatwoClaudeMCPSyncReceiptV1",
    ok: Bool,
    stage: String,
    wrotePath: String,
    backupPath: String?,
    serverNames: [String],
    manualInstallHint: String,
    config: TatwoClaudeMCPConfigV1
  ) {
    self.schema = schema
    self.ok = ok
    self.stage = stage
    self.wrotePath = wrotePath
    self.backupPath = backupPath
    self.serverNames = serverNames
    self.manualInstallHint = manualInstallHint
    self.config = config
  }
}

public enum TatwoPluginRegistryError: Error, LocalizedError, Sendable, Equatable {
  case unsupportedKind(String)
  case invalidPath
  case invalidPurpose
  case unknownEntry(String)
  case invalidClaudeMCPEntry(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedKind(let kind):
      return "unsupported_registry_kind:\(kind)"
    case .invalidPath:
      return "invalid_plugin_registry_path"
    case .invalidPurpose:
      return "invalid_plugin_registry_plain_purpose"
    case .unknownEntry(let id):
      return "unknown_plugin_registry_entry:\(id)"
    case .invalidClaudeMCPEntry(let id):
      return "invalid_claude_mcp_entry:\(id)"
    }
  }
}

public struct TatwoPluginRegistryStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public static func defaultFileURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let explicit = environmentValue("TATWO_ULTRAWORK_PLUGIN_REGISTRY_PATH", environment: environment)
      ?? environmentValue("TATWO_ULTRAWORK_PLUGIN_REGISTRY", environment: environment),
      !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return URL(fileURLWithPath: explicit)
    }
    return TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
      .appendingPathComponent("plugin-registry.json")
  }

  public static func defaultStore(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoPluginRegistryStore {
    TatwoPluginRegistryStore(fileURL: defaultFileURL(environment: environment))
  }

  public static func loadDefaultStaging(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoPluginRegistryBookV1 {
    (try? defaultStore(environment: environment).load())
      ?? TatwoPluginRegistryBookV1().normalizedForCurrentDefaults()
  }

  public static func loadDefaultEntries(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [PluginRegistryEntry] {
    loadDefaultStaging(environment: environment).sortedEntries
  }

  public static func defaultClaudeConfigURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let explicit = environmentValue("TATWO_CLAUDE_CONFIG_PATH", environment: environment)
      ?? environmentValue("TATWO_CLAUDE_MCP_CONFIG_PATH", environment: environment),
      !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return URL(fileURLWithPath: explicit)
    }
    if let home = environmentValue("HOME", environment: environment),
      !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".claude.json")
    }
    return defaultClaudeStagingURL(environment: environment)
  }

  public static func defaultClaudeStagingURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let explicit = environmentValue("TATWO_CLAUDE_MCP_STAGING_PATH", environment: environment),
      !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return URL(fileURLWithPath: explicit)
    }
    return TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
      .appendingPathComponent("claude-mcp-staging.json")
  }

  public func load() throws -> TatwoPluginRegistryBookV1 {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return TatwoPluginRegistryBookV1().normalizedForCurrentDefaults()
    }
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TatwoPluginRegistryBookV1.self, from: data).normalizedForCurrentDefaults()
  }

  public func exportClaudeMCPConfig() throws -> TatwoClaudeMCPConfigV1 {
    let entries = try load().sortedEntries.filter { $0.kind == .mcp }
    var servers: [String: TatwoClaudeMCPServerConfigV1] = [:]
    for entry in entries {
      let serverName = Self.claudeMCPServerName(for: entry)
      servers[serverName] = try Self.claudeMCPServerConfig(for: entry)
    }
    return TatwoClaudeMCPConfigV1(mcpServers: servers)
  }

  @discardableResult
  public func writeClaudeMCPStaging(
    to targetURL: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> TatwoClaudeMCPSyncReceiptV1 {
    let config = try exportClaudeMCPConfig()
    let destination = targetURL ?? Self.defaultClaudeStagingURL(environment: environment)
    try Self.writeEncodable(config, to: destination)
    return TatwoClaudeMCPSyncReceiptV1(
      ok: true,
      stage: "staging",
      wrotePath: destination.path,
      backupPath: nil,
      serverNames: config.mcpServers.keys.sorted(),
      manualInstallHint:
        "Manual fallback: copy this file's top-level mcpServers object into the official Claude user config ~/.claude.json.",
      config: config)
  }

  @discardableResult
  public func syncClaudeMCPConfig(
    targetURL: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> TatwoClaudeMCPSyncReceiptV1 {
    let config = try exportClaudeMCPConfig()
    let destination = targetURL ?? Self.defaultClaudeConfigURL(environment: environment)
    let backup = try Self.backupIfNeeded(destination)
    let merged = try Self.mergedClaudeConfig(existingAt: destination, exported: config)
    try Self.writeJSONValue(merged, to: destination)
    return TatwoClaudeMCPSyncReceiptV1(
      ok: true,
      stage: "claude-user-config",
      wrotePath: destination.path,
      backupPath: backup?.path,
      serverNames: config.mcpServers.keys.sorted(),
      manualInstallHint:
        "Synced by merging exported mcpServers into Claude's user config. Existing file was backed up before write when present.",
      config: config)
  }

  public func save(_ book: TatwoPluginRegistryBookV1) throws {
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var copy = book.normalizedForCurrentDefaults()
    copy.updatedAt = Date()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(copy).write(to: fileURL, options: [.atomic])
  }

  @discardableResult
  public func register(
    kind: RegistryKind,
    path rawPath: String,
    plainPurpose rawPurpose: String,
    name rawName: String? = nil
  ) throws -> TatwoPluginRegistryMutationResult {
    guard kind == .skill || kind == .mcp else {
      throw TatwoPluginRegistryError.unsupportedKind(kind.rawValue)
    }
    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { throw TatwoPluginRegistryError.invalidPath }
    let purpose = rawPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !purpose.isEmpty else { throw TatwoPluginRegistryError.invalidPurpose }

    var book = try load()
    let name = Self.deriveName(rawName: rawName, path: path, kind: kind)
    let id = Self.uniqueID(kind: kind, name: name, existingIDs: Set(book.entries.map(\.id)))
    let entry = PluginRegistryEntry(
      id: id,
      name: name,
      kind: kind,
      purpose: purpose,
      path: path,
      trigger: "人工在 Plugins 分頁登記；由情境編輯器與工作筐按需選用。",
      safetyLevel: kind == .mcp ? .high : .medium,
      requiredForModes: [.m, .l, .xl],
      installState: .unknown,
      publicInstallHint: "staging registry entry; smoke/doctor 尚未驗證")
    book.entries.append(entry)
    book.entries = book.entries.sortedEntriesForRegistry()
    try save(book)
    let saved = try load()
    return TatwoPluginRegistryMutationResult(
      ok: true,
      message: "已登記 \(kind.rawValue) 到 Plugins staging registry。",
      entry: saved.entry(id: entry.id),
      book: saved)
  }

  @discardableResult
  public func remove(id rawID: String) throws -> TatwoPluginRegistryMutationResult {
    let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    var book = try load()
    guard let existing = book.entry(id: id) else {
      throw TatwoPluginRegistryError.unknownEntry(id)
    }
    book.entries.removeAll { $0.id == id }
    if TatwoCatalog.defaults.plugins.contains(where: { $0.id == id }),
      !book.removedDefaultIDs.contains(id)
    {
      book.removedDefaultIDs.append(id)
    }
    book.removedDefaultIDs.sort()
    try save(book)
    return TatwoPluginRegistryMutationResult(
      ok: true,
      message: "已從 Plugins staging registry 移除 \(existing.name)。",
      entry: existing,
      book: try load())
  }

  private static func deriveName(rawName: String?, path: String, kind: RegistryKind) -> String {
    if let rawName {
      let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    let lastPathComponent: String
    if path.contains("/") {
      lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
    } else if let colon = path.lastIndex(of: ":") {
      lastPathComponent = String(path[path.index(after: colon)...])
    } else {
      lastPathComponent = path
    }
    let stripped = lastPathComponent.replacingOccurrences(of: ".md", with: "")
      .replacingOccurrences(of: ".json", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return stripped.isEmpty ? "New \(kind.rawValue.uppercased())" : stripped
  }

  private static func uniqueID(kind: RegistryKind, name: String, existingIDs: Set<String>) -> String {
    let slug = slug(name)
    let base = "\(kind.rawValue)-\(slug.isEmpty ? "entry" : slug)"
    if !existingIDs.contains(base) { return base }
    var counter = 2
    while existingIDs.contains("\(base)-\(counter)") { counter += 1 }
    return "\(base)-\(counter)"
  }

  private static func slug(_ raw: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    let lower = raw.lowercased()
    var result = ""
    var previousWasDash = false
    for scalar in lower.unicodeScalars {
      let char = Character(scalar)
      if allowed.contains(char) {
        result.append(char)
        previousWasDash = false
      } else if !previousWasDash {
        result.append("-")
        previousWasDash = true
      }
    }
    return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private static func claudeMCPServerName(for entry: PluginRegistryEntry) -> String {
    let candidate = slug(entry.id).isEmpty ? slug(entry.name) : slug(entry.id)
    return candidate.isEmpty ? "tatwo-mcp-server" : candidate
  }

  private static func claudeMCPServerConfig(
    for entry: PluginRegistryEntry
  ) throws -> TatwoClaudeMCPServerConfigV1 {
    guard entry.kind == .mcp else {
      throw TatwoPluginRegistryError.invalidClaudeMCPEntry(entry.id)
    }
    let rawPath = (entry.path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawPath.isEmpty else {
      throw TatwoPluginRegistryError.invalidClaudeMCPEntry(entry.id)
    }

    if rawPath.hasPrefix("http://") || rawPath.hasPrefix("https://") {
      return TatwoClaudeMCPServerConfigV1(type: "http", url: rawPath)
    }

    let commandAndArgs: (String, [String])
    if rawPath.hasPrefix("mcp:") {
      let command = String(rawPath.dropFirst("mcp:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !command.isEmpty else { throw TatwoPluginRegistryError.invalidClaudeMCPEntry(entry.id) }
      commandAndArgs = (command, [])
    } else if rawPath.hasPrefix("stdio:") {
      let spec = String(rawPath.dropFirst("stdio:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
      commandAndArgs = splitCommandSpec(spec, entryID: entry.id)
    } else if rawPath.hasPrefix("/") || rawPath.contains("://") {
      commandAndArgs = (rawPath, [])
    } else {
      commandAndArgs = splitCommandSpec(rawPath, entryID: entry.id)
    }

    return TatwoClaudeMCPServerConfigV1(
      type: "stdio",
      command: commandAndArgs.0,
      args: commandAndArgs.1,
      env: [:])
  }

  private static func splitCommandSpec(_ spec: String, entryID: String) -> (String, [String]) {
    let parts = spec.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard let command = parts.first, !command.isEmpty else {
      return ("invalid-\(slug(entryID))", [])
    }
    return (command, Array(parts.dropFirst()))
  }

  private static func mergedClaudeConfig(
    existingAt targetURL: URL,
    exported: TatwoClaudeMCPConfigV1
  ) throws -> JSONValue {
    let exportedValue = try JSONValue.fromEncodable(exported)
    guard FileManager.default.fileExists(atPath: targetURL.path) else {
      return exportedValue
    }
    let data = try Data(contentsOf: targetURL)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case .object(var root) = decoded else {
      return exportedValue
    }
    let existingServers: [String: JSONValue]
    if case .object(let servers) = root["mcpServers"] {
      existingServers = servers
    } else {
      existingServers = [:]
    }
    guard case .object(let exportedRoot) = exportedValue,
      case .object(let exportedServers) = exportedRoot["mcpServers"]
    else {
      return decoded
    }
    root["mcpServers"] = .object(existingServers.merging(exportedServers) { _, new in new })
    return .object(root)
  }

  private static func backupIfNeeded(_ targetURL: URL) throws -> URL? {
    guard FileManager.default.fileExists(atPath: targetURL.path) else { return nil }
    var backupURL = URL(fileURLWithPath: targetURL.path + ".bak")
    if FileManager.default.fileExists(atPath: backupURL.path) {
      let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
      backupURL = URL(fileURLWithPath: targetURL.path + ".bak.\(stamp)")
    }
    try FileManager.default.copyItem(at: targetURL, to: backupURL)
    return backupURL
  }

  private static func writeEncodable<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic])
  }

  private static func writeJSONValue(_ value: JSONValue, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic])
  }

  private static func environmentValue(
    _ key: String,
    environment: [String: String]
  ) -> String? {
    if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
      return value
    }
    if let raw = getenv(key) {
      let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty {
        return value
      }
    }
    return nil
  }
}

private extension Array where Element == PluginRegistryEntry {
  func sortedEntriesForRegistry() -> [PluginRegistryEntry] {
    sorted {
      if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
      return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }
}
