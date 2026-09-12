import Foundation

// MARK: - Observed native MCP servers (fixture paths only)

public enum TatwoPluginConfigSourceV1: String, Codable, Sendable, Equatable {
  case codexToml = "codex_config_toml"
  case claudeMcpJson = "claude_mcp_json"
}

public struct TatwoPluginObservedMcpServerV1: Codable, Sendable, Equatable, Identifiable {
  public var id: String { serverID }

  public let serverID: String
  public let source: TatwoPluginConfigSourceV1
  public let transport: String?
  public let command: String?
  public let args: [String]
  public let url: String?

  public init(
    serverID: String,
    source: TatwoPluginConfigSourceV1,
    transport: String? = nil,
    command: String? = nil,
    args: [String] = [],
    url: String? = nil
  ) {
    self.serverID = serverID
    self.source = source
    self.transport = transport
    self.command = command
    self.args = args
    self.url = url
  }
}

public enum TatwoPluginDriftKindV1: String, Codable, Sendable, Equatable, CaseIterable {
  /// Present in OS portable_mcp registry, missing from observed native config.
  case registryOnly = "registry_only"
  /// Present in native config, missing from OS portable_mcp registry.
  case configOnly = "config_only"
  /// Present in both registry and at least one observed config surface.
  case matched = "matched"
}

public struct TatwoPluginDriftItemV1: Codable, Sendable, Equatable, Identifiable {
  public var id: String { "\(kind.rawValue):\(serverID)" }

  public let serverID: String
  public let kind: TatwoPluginDriftKindV1
  public let registryEntryID: String?
  public let configSources: [TatwoPluginConfigSourceV1]

  public init(
    serverID: String,
    kind: TatwoPluginDriftKindV1,
    registryEntryID: String? = nil,
    configSources: [TatwoPluginConfigSourceV1] = []
  ) {
    self.serverID = serverID
    self.kind = kind
    self.registryEntryID = registryEntryID
    self.configSources = configSources
  }
}

public struct TatwoPluginConfigReadbackReportV1: Codable, Sendable, Equatable {
  public let schema: String
  public let registryRevision: String?
  public let codexPathInjected: String?
  public let claudePathInjected: String?
  public let codexServers: [TatwoPluginObservedMcpServerV1]
  public let claudeServers: [TatwoPluginObservedMcpServerV1]
  public let drift: [TatwoPluginDriftItemV1]
  public let notes: [String]

  public init(
    schema: String = "TatwoPluginConfigReadbackReportV1",
    registryRevision: String? = nil,
    codexPathInjected: String? = nil,
    claudePathInjected: String? = nil,
    codexServers: [TatwoPluginObservedMcpServerV1],
    claudeServers: [TatwoPluginObservedMcpServerV1],
    drift: [TatwoPluginDriftItemV1],
    notes: [String] = []
  ) {
    self.schema = schema
    self.registryRevision = registryRevision
    self.codexPathInjected = codexPathInjected
    self.claudePathInjected = claudePathInjected
    self.codexServers = codexServers
    self.claudeServers = claudeServers
    self.drift = drift
    self.notes = notes
  }

  public var registryOnlyIDs: [String] {
    drift.filter { $0.kind == .registryOnly }.map(\.serverID).sorted()
  }

  public var configOnlyIDs: [String] {
    drift.filter { $0.kind == .configOnly }.map(\.serverID).sorted()
  }

  public var matchedIDs: [String] {
    drift.filter { $0.kind == .matched }.map(\.serverID).sorted()
  }
}

public enum TatwoPluginConfigReadbackErrorV1: Error, LocalizedError, Sendable, Equatable {
  case pathNotProvided(String)
  case fileNotFound(String)
  case unreadable(String)
  case unparseable(String, String)
  case forbiddenHomePath(String)
  case inputTooLarge(path: String, bytes: Int, limit: Int)
  case invalidUTF8(String)
  case pathEscapesAllowedRoot(path: String, detail: String)
  case invalidConfigStructure(String, String)

  public var errorDescription: String? {
    switch self {
    case .pathNotProvided(let label):
      return "Plugin config readback path not provided: \(label)"
    case .fileNotFound(let path):
      return "Plugin config readback file not found: \(path)"
    case .unreadable(let path):
      return "Plugin config readback unreadable: \(path)"
    case .unparseable(let path, let detail):
      return "Plugin config readback unparseable at \(path): \(detail)"
    case .forbiddenHomePath(let path):
      return "Plugin config readback refuses default home path: \(path)"
    case .inputTooLarge(let path, let bytes, let limit):
      return "Plugin config readback input too large at \(path): \(bytes) bytes > limit \(limit)"
    case .invalidUTF8(let path):
      return "Plugin config readback invalid UTF-8 at \(path)"
    case .pathEscapesAllowedRoot(let path, let detail):
      return "Plugin config readback path escapes allowed root at \(path): \(detail)"
    case .invalidConfigStructure(let path, let detail):
      return "Plugin config readback invalid structure at \(path): \(detail)"
    }
  }
}

/// Read-only native MCP inventory for controller drift. Paths are always injected;
/// S1 never defaults to real `~/.codex` or `~/.claude`.
public enum TatwoPluginConfigReadback {
  /// Hard byte cap for fixture/native config reads (fail-closed; no silent truncate).
  public static let maxConfigBytes: Int = 2 * 1024 * 1024

  /// Refuse accidental home / escaped targets. Always runs realpath +
  /// optional fixture-root containment — no boolean bypass.
  /// (home `.codex` may itself be a symlink to an external volume).
  public static func assertNotDefaultHomePath(
    _ path: String,
    allowedRootURL: URL? = nil
  ) throws {
    let expanded = (path as NSString).expandingTildeInPath
    let candidate = URL(fileURLWithPath: expanded)
    let canonical = try canonicalPath(for: candidate)

    if let allowedRootURL {
      let allowedRoot = try canonicalDirectoryPath(for: allowedRootURL)
      // Containment uses realpath of both sides so symlink escape is rejected.
      if !pathIsInsideOrEqual(canonical, root: allowedRoot) {
        throw TatwoPluginConfigReadbackErrorV1.pathEscapesAllowedRoot(
          path: path,
          detail: "realpath \(canonical) not under allowed root \(allowedRoot)")
      }
    }

    let homeLexical = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
    let homeCanonical = try canonicalDirectoryPath(for: URL(fileURLWithPath: NSHomeDirectory()))

    let forbiddenRelatives = [
      ".codex/config.toml",
      ".claude/.mcp.json",
      ".claude/settings.json",
      ".claude.json",
    ]
    for relative in forbiddenRelatives {
      // Lexical home identity (pre-realpath).
      let lexicalForbidden =
        (homeLexical as NSString).appendingPathComponent(relative)
      if pathsEqual(expanded, lexicalForbidden)
        || pathsEqual(candidate.standardizedFileURL.path, lexicalForbidden)
      {
        throw TatwoPluginConfigReadbackErrorV1.forbiddenHomePath(path)
      }
      // Canonical identity: resolve BOTH sides (home `.codex` may symlink out of $HOME).
      let forbiddenURL = URL(fileURLWithPath: homeLexical).appendingPathComponent(relative)
      let forbiddenCanon = try canonicalPath(for: forbiddenURL)
      if pathsEqual(canonical, forbiddenCanon) {
        throw TatwoPluginConfigReadbackErrorV1.forbiddenHomePath(path)
      }
    }

    // Refuse any path under home agent config trees — lexical and realpath identities.
    let forbiddenDirRelatives = [".codex", ".claude"]
    for relative in forbiddenDirRelatives {
      let lexicalDir = (homeLexical as NSString).appendingPathComponent(relative)
      if pathIsInsideOrEqual(expanded, root: lexicalDir)
        || pathIsInsideOrEqual(candidate.standardizedFileURL.path, root: lexicalDir)
      {
        throw TatwoPluginConfigReadbackErrorV1.forbiddenHomePath(path)
      }
      let dirURL = URL(fileURLWithPath: homeLexical).appendingPathComponent(relative)
      // Directory may exist as symlink; resolve for containment.
      let dirCanon: String
      if FileManager.default.fileExists(atPath: dirURL.path) {
        dirCanon = dirURL.resolvingSymlinksInPath().standardizedFileURL.path
      } else {
        dirCanon = (homeCanonical as NSString).appendingPathComponent(relative)
      }
      if pathIsInsideOrEqual(canonical, root: dirCanon) {
        throw TatwoPluginConfigReadbackErrorV1.forbiddenHomePath(path)
      }
    }
  }

  public static func readCodexConfigTOML(
    at url: URL,
    allowedRootURL: URL? = nil
  ) throws -> [TatwoPluginObservedMcpServerV1] {
    try assertNotDefaultHomePath(
      url.path, allowedRootURL: allowedRootURL)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoPluginConfigReadbackErrorV1.fileNotFound(url.path)
    }
    let data = try readBoundedFileData(at: url)
    guard let text = String(data: data, encoding: .utf8) else {
      throw TatwoPluginConfigReadbackErrorV1.invalidUTF8(url.path)
    }
    do {
      return try parseCodexMcpServersTOML(text)
    } catch let typed as TatwoPluginConfigReadbackErrorV1 {
      throw typed
    } catch {
      throw TatwoPluginConfigReadbackErrorV1.unparseable(url.path, String(describing: error))
    }
  }

  public static func readClaudeMcpJSON(
    at url: URL,
    allowedRootURL: URL? = nil
  ) throws -> [TatwoPluginObservedMcpServerV1] {
    try assertNotDefaultHomePath(
      url.path, allowedRootURL: allowedRootURL)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoPluginConfigReadbackErrorV1.fileNotFound(url.path)
    }
    let data = try readBoundedFileData(at: url)
    // Reject invalid UTF-8 even though JSONSerialization may accept NSData bytes.
    if String(data: data, encoding: .utf8) == nil {
      throw TatwoPluginConfigReadbackErrorV1.invalidUTF8(url.path)
    }
    do {
      return try parseClaudeMcpJSON(data)
    } catch let typed as TatwoPluginConfigReadbackErrorV1 {
      // Re-home memory path to real path for structured errors.
      switch typed {
      case .unparseable(_, let detail):
        throw TatwoPluginConfigReadbackErrorV1.unparseable(url.path, detail)
      case .invalidConfigStructure(_, let detail):
        throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(url.path, detail)
      default:
        throw typed
      }
    } catch {
      throw TatwoPluginConfigReadbackErrorV1.unparseable(url.path, String(describing: error))
    }
  }

  /// Compare registry portable_mcp ids against union of observed native MCP server ids.
  public static func compareDrift(
    registry: TatwoPluginControllerRegistryDocumentV1,
    codexServers: [TatwoPluginObservedMcpServerV1],
    claudeServers: [TatwoPluginObservedMcpServerV1],
    codexPathInjected: String? = nil,
    claudePathInjected: String? = nil
  ) -> TatwoPluginConfigReadbackReportV1 {
    let registryIDs = Set(registry.portableMcpEntries.map(\.id))
    var configSourcesByID: [String: Set<TatwoPluginConfigSourceV1>] = [:]
    for server in codexServers {
      configSourcesByID[server.serverID, default: []].insert(.codexToml)
    }
    for server in claudeServers {
      configSourcesByID[server.serverID, default: []].insert(.claudeMcpJson)
    }
    let configIDs = Set(configSourcesByID.keys)

    var items: [TatwoPluginDriftItemV1] = []
    for id in registryIDs.intersection(configIDs).sorted() {
      items.append(
        TatwoPluginDriftItemV1(
          serverID: id,
          kind: .matched,
          registryEntryID: id,
          configSources: (configSourcesByID[id] ?? []).sorted { $0.rawValue < $1.rawValue }))
    }
    for id in registryIDs.subtracting(configIDs).sorted() {
      items.append(
        TatwoPluginDriftItemV1(
          serverID: id,
          kind: .registryOnly,
          registryEntryID: id,
          configSources: []))
    }
    for id in configIDs.subtracting(registryIDs).sorted() {
      items.append(
        TatwoPluginDriftItemV1(
          serverID: id,
          kind: .configOnly,
          registryEntryID: nil,
          configSources: (configSourcesByID[id] ?? []).sorted { $0.rawValue < $1.rawValue }))
    }

    return TatwoPluginConfigReadbackReportV1(
      registryRevision: registry.registryRevision,
      codexPathInjected: codexPathInjected,
      claudePathInjected: claudePathInjected,
      codexServers: codexServers.sorted { $0.serverID < $1.serverID },
      claudeServers: claudeServers.sorted { $0.serverID < $1.serverID },
      drift: items,
      notes: [
        "S1 read-only inventory; no staged apply",
        "Only portable_mcp entries participate in MCP config drift",
        "Paths must be injected; defaults do not target real home configs",
        "Config parse is fail-closed (size/UTF-8/structure); no silent skip of bad entries",
      ])
  }

  public static func readback(
    registry: TatwoPluginControllerRegistryDocumentV1,
    codexConfigURL: URL?,
    claudeMcpJSONURL: URL?,
    allowedRootURL: URL? = nil
  ) throws -> TatwoPluginConfigReadbackReportV1 {
    var codex: [TatwoPluginObservedMcpServerV1] = []
    var claude: [TatwoPluginObservedMcpServerV1] = []
    if let codexConfigURL {
      codex = try readCodexConfigTOML(
        at: codexConfigURL,
        allowedRootURL: allowedRootURL)
    }
    if let claudeMcpJSONURL {
      claude = try readClaudeMcpJSON(
        at: claudeMcpJSONURL,
        allowedRootURL: allowedRootURL)
    }
    return compareDrift(
      registry: registry,
      codexServers: codex,
      claudeServers: claude,
      codexPathInjected: codexConfigURL?.path,
      claudePathInjected: claudeMcpJSONURL?.path)
  }

  // MARK: - Bounded IO + path identity

  private static func readBoundedFileData(at url: URL) throws -> Data {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    } catch {
      throw TatwoPluginConfigReadbackErrorV1.unreadable(url.path)
    }
    if values.isRegularFile == false {
      throw TatwoPluginConfigReadbackErrorV1.unreadable(url.path)
    }
    if let size = values.fileSize, size > maxConfigBytes {
      throw TatwoPluginConfigReadbackErrorV1.inputTooLarge(
        path: url.path, bytes: size, limit: maxConfigBytes)
    }
    let data: Data
    do {
      data = try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
      throw TatwoPluginConfigReadbackErrorV1.unreadable(url.path)
    }
    if data.count > maxConfigBytes {
      throw TatwoPluginConfigReadbackErrorV1.inputTooLarge(
        path: url.path, bytes: data.count, limit: maxConfigBytes)
    }
    return data
  }

  private static func canonicalPath(for url: URL) throws -> String {
    let expanded = URL(fileURLWithPath: (url.path as NSString).expandingTildeInPath)
    if FileManager.default.fileExists(atPath: expanded.path) {
      return expanded.resolvingSymlinksInPath().standardizedFileURL.path
    }
    // Resolve existing parent, then append final component (symlink parent escape).
    let parent = expanded.deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: parent.path) {
      let parentCanon = parent.resolvingSymlinksInPath().standardizedFileURL.path
      return URL(fileURLWithPath: parentCanon)
        .appendingPathComponent(expanded.lastPathComponent)
        .standardizedFileURL.path
    }
    return expanded.standardizedFileURL.path
  }

  private static func canonicalDirectoryPath(for url: URL) throws -> String {
    let expanded = URL(fileURLWithPath: (url.path as NSString).expandingTildeInPath)
    if FileManager.default.fileExists(atPath: expanded.path) {
      return expanded.resolvingSymlinksInPath().standardizedFileURL.path
    }
    return expanded.standardizedFileURL.path
  }

  private static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
    URL(fileURLWithPath: lhs).standardizedFileURL.path
      == URL(fileURLWithPath: rhs).standardizedFileURL.path
  }

  private static func pathIsInsideOrEqual(_ path: String, root: String) -> Bool {
    let p = URL(fileURLWithPath: path).standardizedFileURL.path
    let r = URL(fileURLWithPath: root).standardizedFileURL.path
    if p == r { return true }
    let prefix = r.hasSuffix("/") ? r : r + "/"
    return p.hasPrefix(prefix)
  }

  // MARK: - Parsers (strict / fail-closed)

  /// Parse `[mcp_servers.<id>]` tables with simple keys: command, args, url, transport/type.
  /// Structural anomalies inside an mcp_servers table fail closed (no silent skip).
  public static func parseCodexMcpServersTOML(_ text: String) throws -> [TatwoPluginObservedMcpServerV1] {
    var servers: [String: [String: String]] = [:]
    var order: [String] = []
    var current: String?
    var lineNo = 0

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      lineNo += 1
      let line = stripTOMLComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }

      if line.hasPrefix("["), line.hasSuffix("]") {
        let body = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        current = nil
        if body.hasPrefix("mcp_servers.") {
          guard let serverID = mcpServerID(fromTableHeader: body) else {
            throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
              "<memory>",
              "line \(lineNo): unsupported mcp_servers table header [\(body)]")
          }
          current = serverID
          if servers[serverID] == nil {
            servers[serverID] = [:]
            order.append(serverID)
          }
        }
        continue
      }

      // Outside mcp_servers tables: ignore foreign keys (model = …, [plugins], …).
      guard let serverID = current else { continue }

      guard let eq = line.firstIndex(of: "=") else {
        throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
          "<memory>",
          "line \(lineNo): malformed assignment in mcp_servers.\(serverID)")
      }
      let key = line[..<eq].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty else {
        throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
          "<memory>",
          "line \(lineNo): empty key in mcp_servers.\(serverID)")
      }
      if key == "args" {
        // Validate array shape eagerly (fail closed; no empty-on-bad).
        _ = try parseTOMLStringArrayStrict(value, lineNo: lineNo)
      }
      servers[serverID, default: [:]][key] = value
    }

    return try order.map { serverID -> TatwoPluginObservedMcpServerV1 in
      guard let fields = servers[serverID] else {
        throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
          "<memory>", "missing fields for mcp_servers.\(serverID)")
      }
      let command = fields["command"].map(unquoteTOMLScalar)
      let url = fields["url"].map(unquoteTOMLScalar)
      let transport = (fields["transport"] ?? fields["type"]).map(unquoteTOMLScalar)
      let args: [String]
      if let rawArgs = fields["args"] {
        args = try parseTOMLStringArrayStrict(rawArgs, lineNo: 0)
      } else {
        args = []
      }
      return TatwoPluginObservedMcpServerV1(
        serverID: serverID,
        source: .codexToml,
        transport: transport,
        command: command,
        args: args,
        url: url)
    }
  }

  public static func parseClaudeMcpJSON(_ data: Data) throws -> [TatwoPluginObservedMcpServerV1] {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      throw TatwoPluginConfigReadbackErrorV1.unparseable(
        "<memory>", "JSON parse failed: \(error.localizedDescription)")
    }
    guard let root = object as? [String: Any] else {
      throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
        "<memory>", "root must be object")
    }

    let serversObject: [String: Any]
    if let raw = root["mcpServers"] {
      guard let direct = raw as? [String: Any] else {
        throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
          "<memory>", "mcpServers must be object")
      }
      serversObject = direct
    } else if let nested = root["mcp"] as? [String: Any] {
      if let raw = nested["servers"] {
        guard let servers = raw as? [String: Any] else {
          throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
            "<memory>", "mcp.servers must be object")
        }
        serversObject = servers
      } else if nested.isEmpty {
        serversObject = [:]
      } else {
        throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
          "<memory>", "mcp object missing servers")
      }
    } else if root.isEmpty {
      serversObject = [:]
    } else {
      // Non-empty root without mcpServers: fail closed (not silent empty inventory).
      throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
        "<memory>", "root missing mcpServers (or mcp.servers)")
    }

    var result: [TatwoPluginObservedMcpServerV1] = []
    for key in serversObject.keys.sorted() {
      guard let value = serversObject[key] else { continue }
      guard let object = value as? [String: Any] else {
        throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
          "<memory>", "server \(key) must be object")
      }
      if let command = object["command"], !(command is String), !(command is NSNull) {
        throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
          "<memory>", "server \(key).command must be string")
      }
      if let url = object["url"], !(url is String), !(url is NSNull) {
        throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
          "<memory>", "server \(key).url must be string")
      }
      let command = object["command"] as? String
      let url = object["url"] as? String
      let transport = (object["type"] as? String) ?? (object["transport"] as? String)
      let args = try parseJSONStringArray(object["args"], serverID: key)
      result.append(
        TatwoPluginObservedMcpServerV1(
          serverID: key,
          source: .claudeMcpJson,
          transport: transport,
          command: command,
          args: args,
          url: url))
    }
    return result
  }

  private static func parseJSONStringArray(_ raw: Any?, serverID: String) throws -> [String] {
    guard let raw else { return [] }
    if raw is NSNull { return [] }
    guard let list = raw as? [Any] else {
      throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
        "<memory>", "server \(serverID).args must be array")
    }
    var out: [String] = []
    out.reserveCapacity(list.count)
    for (index, item) in list.enumerated() {
      guard let s = item as? String else {
        throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
          "<memory>",
          "server \(serverID).args[\(index)] must be string (mixed types rejected)")
      }
      out.append(s)
    }
    return out
  }

  private static func mcpServerID(fromTableHeader body: String) -> String? {
    // mcp_servers.name  |  mcp_servers."name-with-dash"
    let prefix = "mcp_servers."
    guard body.hasPrefix(prefix) else { return nil }
    let rest = String(body.dropFirst(prefix.count))
    if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 {
      let id = String(rest.dropFirst().dropLast())
      return id.isEmpty ? nil : id
    }
    // Reject nested deeper tables like mcp_servers.name.env (fail closed if seen as mcp header)
    if rest.contains(".") { return nil }
    let id = rest.trimmingCharacters(in: .whitespaces)
    return id.isEmpty ? nil : id
  }

  private static func stripTOMLComment(_ line: String) -> String {
    var inQuote = false
    var result = ""
    for char in line {
      if char == "\"" {
        inQuote.toggle()
        result.append(char)
        continue
      }
      if char == "#", !inQuote {
        break
      }
      result.append(char)
    }
    return result
  }

  private static func unquoteTOMLScalar(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
      return String(trimmed.dropFirst().dropLast())
    }
    return trimmed
  }

  private static func parseTOMLStringArrayStrict(_ raw: String, lineNo: Int) throws -> [String] {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
      throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
        "<memory>",
        "line \(lineNo): args must be a TOML string array")
    }
    let inner = String(trimmed.dropFirst().dropLast())
    if inner.trimmingCharacters(in: .whitespaces).isEmpty {
      return []
    }
    var items: [String] = []
    var current = ""
    var inQuote = false
    var sawContentOutsideQuote = false
    for char in inner {
      if char == "\"" {
        inQuote.toggle()
        continue
      }
      if char == ",", !inQuote {
        let piece = current.trimmingCharacters(in: .whitespaces)
        if piece.isEmpty && !sawContentOutsideQuote {
          // empty slot between commas with no quotes → reject
          throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
            "<memory>",
            "line \(lineNo): empty args element")
        }
        // Unquoted tokens after quote-strip path: accept as scalar string
        if !piece.isEmpty {
          items.append(piece)
        }
        current = ""
        sawContentOutsideQuote = false
        continue
      }
      if !inQuote, !char.isWhitespace {
        sawContentOutsideQuote = true
      }
      current.append(char)
    }
    if inQuote {
      throw TatwoPluginConfigReadbackErrorV1.invalidConfigStructure(
        "<memory>",
        "line \(lineNo): unterminated string in args")
    }
    let last = current.trimmingCharacters(in: .whitespaces)
    if !last.isEmpty {
      items.append(last)
    }
    return items
  }
}
