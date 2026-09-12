import CryptoKit
import Foundation

// MARK: - Brand + known templates

/// Brands that S2 can project portable_mcp entries into.
public enum TatwoPluginProjectionBrandV1: String, Codable, Sendable, CaseIterable, Equatable {
  case codex
  case claude
}

public enum TatwoPluginProjectionTemplateIDV1: String, Codable, Sendable, CaseIterable, Equatable {
  case codexMcpServerV1 = "codex.mcp-server.v1"
  case claudeMcpServerV1 = "claude.mcp-server.v1"

  public var brand: TatwoPluginProjectionBrandV1 {
    switch self {
    case .codexMcpServerV1: return .codex
    case .claudeMcpServerV1: return .claude
    }
  }
}

// MARK: - Result

public enum TatwoPluginProjectionOutcomeV1: Codable, Sendable, Equatable {
  case projected(TatwoPluginProjectedFragmentV1)
  case notProjectable(reason: String)

  public var isProjected: Bool {
    if case .projected = self { return true }
    return false
  }

  public var fragment: TatwoPluginProjectedFragmentV1? {
    if case .projected(let fragment) = self { return fragment }
    return nil
  }

  public var notProjectableReason: String? {
    if case .notProjectable(let reason) = self { return reason }
    return nil
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case fragment
    case reason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "projected":
      self = .projected(try container.decode(TatwoPluginProjectedFragmentV1.self, forKey: .fragment))
    case "notProjectable":
      self = .notProjectable(reason: try container.decode(String.self, forKey: .reason))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container, debugDescription: "unknown projection outcome kind: \(kind)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .projected(let fragment):
      try container.encode("projected", forKey: .kind)
      try container.encode(fragment, forKey: .fragment)
    case .notProjectable(let reason):
      try container.encode("notProjectable", forKey: .kind)
      try container.encode(reason, forKey: .reason)
    }
  }
}

/// Brand-specific projected config fragment (staging only; never applied by S2).
public struct TatwoPluginProjectedFragmentV1: Codable, Sendable, Equatable {
  public let schema: String
  public let entryID: String
  public let brand: TatwoPluginProjectionBrandV1
  public let templateID: String
  public let logicalPath: String
  /// Human-readable fragment body (TOML table for codex; pretty JSON object for claude server).
  public let body: String
  /// Managed-field view used for equality / plan classification.
  public let managed: TatwoPluginManagedMcpFieldsV1
  public let writesNativeConfig: Bool

  public init(
    schema: String = "TatwoPluginProjectedFragmentV1",
    entryID: String,
    brand: TatwoPluginProjectionBrandV1,
    templateID: String,
    logicalPath: String,
    body: String,
    managed: TatwoPluginManagedMcpFieldsV1,
    writesNativeConfig: Bool = false
  ) {
    self.schema = schema
    self.entryID = entryID
    self.brand = brand
    self.templateID = templateID
    self.logicalPath = logicalPath
    self.body = body
    self.managed = managed
    self.writesNativeConfig = writesNativeConfig
  }
}

/// Managed MCP fields the controller may stage (no secrets).
public struct TatwoPluginManagedMcpFieldsV1: Codable, Sendable, Equatable {
  public let serverID: String
  public let transport: String?
  public let command: String?
  public let args: [String]
  public let url: String?

  public init(
    serverID: String,
    transport: String? = nil,
    command: String? = nil,
    args: [String] = [],
    url: String? = nil
  ) {
    self.serverID = serverID
    self.transport = transport
    self.command = command
    self.args = args
    self.url = url
  }

  public static func fromObserved(_ server: TatwoPluginObservedMcpServerV1) -> TatwoPluginManagedMcpFieldsV1 {
    TatwoPluginManagedMcpFieldsV1(
      serverID: server.serverID,
      transport: server.transport,
      command: server.command,
      args: server.args,
      url: server.url)
  }

  /// Stable equality for plan classification (transport normalized).
  public func managedEquals(_ other: TatwoPluginManagedMcpFieldsV1) -> Bool {
    serverID == other.serverID
      && normalizeTransport(transport) == normalizeTransport(other.transport)
      && (command ?? "") == (other.command ?? "")
      && args == other.args
      && (url ?? "") == (other.url ?? "")
  }

  /// Canonical text for unified diff of managed fields only.
  public func stableManagedText() -> String {
    var lines: [String] = []
    lines.append("serverID=\(TatwoPluginProjectionV1.sanitizedIdentifier(serverID))")
    if let transport = normalizeTransport(transport) {
      lines.append("transport=\(transport)")
    }
    if let command, !command.isEmpty {
      lines.append("command=\(Self.escapedManagedValue(command))")
    }
    if !args.isEmpty {
      let encoded = args.map { Self.quote($0) }.joined(separator: ", ")
      lines.append("args=[\(encoded)]")
    }
    if let url, !url.isEmpty {
      lines.append("url=\(Self.escapedManagedValue(url))")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func normalizeTransport(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return t.isEmpty ? nil : t
  }

  private static func quote(_ value: String) -> String {
    TatwoPluginProjectionV1.tomlString(value)
  }

  private static func escapedManagedValue(_ value: String) -> String {
    let quoted = TatwoPluginProjectionV1.tomlString(value)
    return String(quoted.dropFirst().dropLast())
  }
}

// MARK: - Errors

public enum TatwoPluginProjectionErrorV1: Error, LocalizedError, Sendable, Equatable {
  case missingCanonicalDefinition(String)
  case missingProjectionTemplates(String)
  case missingBrandTemplate(entryID: String, brand: String)
  case unknownTemplateID(entryID: String, brand: String, templateID: String)
  case invalidCanonical(entryID: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .missingCanonicalDefinition(let id):
      return "Projection requires canonicalDefinition for portable_mcp: \(id)"
    case .missingProjectionTemplates(let id):
      return "Projection requires projectionTemplates for portable_mcp: \(id)"
    case .missingBrandTemplate(let id, let brand):
      return "Projection template missing for entry \(id) brand \(brand) (fail-closed)"
    case .unknownTemplateID(let id, let brand, let templateID):
      return "Unknown projection templateID \(templateID) for \(id)/\(brand) (fail-closed)"
    case .invalidCanonical(let id, let reason):
      return "Invalid canonicalDefinition for \(id): \(reason)"
    }
  }
}

// MARK: - Projector

/// S2 portable_mcp → brand fragment renderer. Never writes host config.
public enum TatwoPluginProjectionV1 {
  public static let rendererVersion = "s2-projection-v1"

  public static func knownTemplateIDs(for brand: TatwoPluginProjectionBrandV1) -> Set<String> {
    switch brand {
    case .codex: return [TatwoPluginProjectionTemplateIDV1.codexMcpServerV1.rawValue]
    case .claude: return [TatwoPluginProjectionTemplateIDV1.claudeMcpServerV1.rawValue]
    }
  }

  /// Project one registry entry for one brand. Types ②③ return `notProjectable`.
  /// Missing/unknown templates fail closed via `TatwoPluginProjectionErrorV1` for portable_mcp.
  public static func project(
    entry: TatwoPluginRegistryEntryV1,
    brand: TatwoPluginProjectionBrandV1
  ) throws -> TatwoPluginProjectionOutcomeV1 {
    switch entry.type {
    case .vendorNative:
      return .notProjectable(
        reason:
          "vendor_native does not project MCP config fragments; route via D12 capability lane (S2 fail-closed)")
    case .appNative:
      return .notProjectable(
        reason: "app_native has externalProjection=none; no external MCP fragment")
    case .portableMcp:
      return try projectPortable(entry: entry, brand: brand)
    }
  }

  public static func projectPortable(
    entry: TatwoPluginRegistryEntryV1,
    brand: TatwoPluginProjectionBrandV1
  ) throws -> TatwoPluginProjectionOutcomeV1 {
    guard entry.type == .portableMcp else {
      return try project(entry: entry, brand: brand)
    }
    guard let canonical = entry.canonicalDefinition else {
      throw TatwoPluginProjectionErrorV1.missingCanonicalDefinition(entry.id)
    }
    guard let templates = entry.projectionTemplates, !templates.isEmpty else {
      throw TatwoPluginProjectionErrorV1.missingProjectionTemplates(entry.id)
    }
    guard let templateRef = templates[brand.rawValue] else {
      throw TatwoPluginProjectionErrorV1.missingBrandTemplate(
        entryID: entry.id, brand: brand.rawValue)
    }
    let templateID = templateRef.templateID
    guard knownTemplateIDs(for: brand).contains(templateID) else {
      throw TatwoPluginProjectionErrorV1.unknownTemplateID(
        entryID: entry.id, brand: brand.rawValue, templateID: templateID)
    }

    let managed = try managedFields(entryID: entry.id, canonical: canonical)
    let body: String
    let logicalPath: String
    switch brand {
    case .codex:
      guard templateID == TatwoPluginProjectionTemplateIDV1.codexMcpServerV1.rawValue else {
        throw TatwoPluginProjectionErrorV1.unknownTemplateID(
          entryID: entry.id, brand: brand.rawValue, templateID: templateID)
      }
      body = renderCodexTOMLFragment(managed: managed)
      logicalPath = "~/.codex/config.toml#mcp_servers.\(sanitizedIdentifier(entry.id))"
    case .claude:
      guard templateID == TatwoPluginProjectionTemplateIDV1.claudeMcpServerV1.rawValue else {
        throw TatwoPluginProjectionErrorV1.unknownTemplateID(
          entryID: entry.id, brand: brand.rawValue, templateID: templateID)
      }
      body = try renderClaudeServerJSONObject(managed: managed)
      logicalPath = "~/.claude/.mcp.json#mcpServers.\(sanitizedIdentifier(entry.id))"
    }

    return .projected(
      TatwoPluginProjectedFragmentV1(
        entryID: entry.id,
        brand: brand,
        templateID: templateID,
        logicalPath: logicalPath,
        body: body,
        managed: managed,
        writesNativeConfig: false))
  }

  // MARK: - Managed fields from canonical

  public static func managedFields(
    entryID: String,
    canonical: TatwoPluginCanonicalMcpDefinitionV1
  ) throws -> TatwoPluginManagedMcpFieldsV1 {
    switch canonical.transport {
    case .stdio:
      let command = (canonical.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !command.isEmpty else {
        throw TatwoPluginProjectionErrorV1.invalidCanonical(entryID: entryID, reason: "stdio requires command")
      }
      if let url = canonical.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw TatwoPluginProjectionErrorV1.invalidCanonical(entryID: entryID, reason: "stdio must not set url")
      }
      return TatwoPluginManagedMcpFieldsV1(
        serverID: entryID,
        transport: "stdio",
        command: command,
        args: canonical.args,
        url: nil)
    case .http, .sse:
      let url = (canonical.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !url.isEmpty else {
        throw TatwoPluginProjectionErrorV1.invalidCanonical(
          entryID: entryID, reason: "\(canonical.transport.rawValue) requires url")
      }
      return TatwoPluginManagedMcpFieldsV1(
        serverID: entryID,
        transport: canonical.transport.rawValue,
        command: nil,
        args: [],
        url: url)
    }
  }

  // MARK: - Renderers (deterministic)

  /// Sanitized identifier for logical paths and diff headers.  The raw ID is
  /// still retained in the projected fragment and TOML key, but never enters a
  /// path/header where CR/LF or path punctuation could alter structure.
  public static func sanitizedIdentifier(_ value: String) -> String {
    var output = ""
    for scalar in value.unicodeScalars {
      let allowed =
        (scalar.value >= 0x41 && scalar.value <= 0x5A)
          || (scalar.value >= 0x61 && scalar.value <= 0x7A)
          || (scalar.value >= 0x30 && scalar.value <= 0x39)
          || scalar == "_" || scalar == "-" || scalar == "."
      if allowed {
        output.append(String(scalar))
      } else if scalar.value <= 0xFFFF {
        output += String(format: "_%04X_", scalar.value)
      } else {
        output += String(format: "_%08X_", scalar.value)
      }
    }
    return output.isEmpty ? "_empty_" : output
  }

  /// SHA-256 of the exact brand fragment used by an S3 apply receipt.
  public static func fragmentSHA256(
    managed: TatwoPluginManagedMcpFieldsV1,
    brand: TatwoPluginProjectionBrandV1
  ) throws -> String {
    let body: String
    switch brand {
    case .codex:
      body = renderCodexTOMLFragment(managed: managed)
    case .claude:
      body = try renderClaudeServerJSONObject(managed: managed)
    }
    return SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public static func renderCodexTOMLFragment(managed: TatwoPluginManagedMcpFieldsV1) -> String {
    let headerKey = codexTableHeader(serverID: managed.serverID)
    var lines: [String] = []
    lines.append(headerKey)
    if let command = managed.command {
      lines.append("command = \(tomlString(command))")
    }
    if !managed.args.isEmpty {
      let args = managed.args.map(tomlString).joined(separator: ", ")
      lines.append("args = [\(args)]")
    }
    if let url = managed.url, !url.isEmpty {
      lines.append("url = \(tomlString(url))")
    }
    if let transport = managed.transport, !transport.isEmpty {
      lines.append("transport = \(tomlString(transport))")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Single Claude mcpServers.<id> object (not the full file).
  public static func renderClaudeServerJSONObject(managed: TatwoPluginManagedMcpFieldsV1) throws -> String {
    var object: [String: Any] = [:]
    if let transport = managed.transport, !transport.isEmpty {
      object["type"] = transport
    }
    if let command = managed.command {
      object["command"] = command
    }
    if !managed.args.isEmpty {
      object["args"] = managed.args
    }
    if let url = managed.url, !url.isEmpty {
      object["url"] = url
    }
    // Stable key order: type, command, args, url
    let ordered = orderedClaudeObject(object)
    let data = try JSONSerialization.data(withJSONObject: ordered, options: [.prettyPrinted, .sortedKeys])
    guard var text = String(data: data, encoding: .utf8) else {
      throw TatwoPluginProjectionErrorV1.invalidCanonical(
        entryID: managed.serverID, reason: "failed to encode claude JSON")
    }
    // JSONSerialization prettyPrinted uses non-stable spacing on some platforms; normalize newlines.
    if !text.hasSuffix("\n") {
      text += "\n"
    }
    return text
  }

  private static func orderedClaudeObject(_ object: [String: Any]) -> [String: Any] {
    // sortedKeys on serialization handles order; return as-is.
    object
  }

  private static func codexTableHeader(serverID: String) -> String {
    // Quote when not a bare TOML key (dash, etc.).
    if serverID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) {
      return "[mcp_servers.\(serverID)]"
    }
    return "[mcp_servers.\(tomlString(serverID))]"
  }

  static func tomlString(_ value: String) -> String {
    var escaped = ""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x08: escaped += "\\b"
      case 0x09: escaped += "\\t"
      case 0x0A: escaped += "\\n"
      case 0x0C: escaped += "\\f"
      case 0x0D: escaped += "\\r"
      case 0x22: escaped += "\\\""
      case 0x5C: escaped += "\\\\"
      case 0x00...0x1F, 0x7F...0x9F:
        if scalar.value <= 0xFFFF {
          escaped += String(format: "\\u%04X", scalar.value)
        } else {
          escaped += String(format: "\\U%08X", scalar.value)
        }
      default:
        escaped.append(String(scalar))
      }
    }
    return "\"\(escaped)\""
  }
}
