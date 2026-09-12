import Foundation

// MARK: - Entry type (§9.1)

/// Work OS §9.1 plugin controller entry type. Legacy `RegistryKind` must not infer this.
public enum TatwoPluginEntryTypeV1: String, Codable, Sendable, CaseIterable, Equatable {
  case portableMcp = "portable_mcp"
  case vendorNative = "vendor_native"
  case appNative = "app_native"
}

public enum TatwoPluginMcpTransportV1: String, Codable, Sendable, CaseIterable, Equatable {
  case stdio
  case http
  case sse
}

public enum TatwoPluginDesiredStateV1: String, Codable, Sendable, CaseIterable, Equatable {
  case enabled
  case disabled
}

// MARK: - Type-specific payloads

/// ① portable_mcp canonical MCP definition (OS truth; brands only project fragments).
public struct TatwoPluginCanonicalMcpDefinitionV1: Codable, Sendable, Equatable {
  public let protocolName: String
  public let transport: TatwoPluginMcpTransportV1
  public let command: String?
  public let args: [String]
  public let url: String?
  public let envRefs: [String]
  public let toolNamespace: String?
  public let healthCheckProbeID: String?

  public init(
    protocolName: String = "mcp",
    transport: TatwoPluginMcpTransportV1,
    command: String? = nil,
    args: [String] = [],
    url: String? = nil,
    envRefs: [String] = [],
    toolNamespace: String? = nil,
    healthCheckProbeID: String? = nil
  ) {
    self.protocolName = protocolName
    self.transport = transport
    self.command = command
    self.args = args
    self.url = url
    self.envRefs = envRefs
    self.toolNamespace = toolNamespace
    self.healthCheckProbeID = healthCheckProbeID
  }

  private enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case transport
    case command
    case args
    case url
    case envRefs
    case toolNamespace
    case healthCheck
  }

  private struct HealthCheckDTO: Codable, Sendable, Equatable {
    let probeID: String?
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolName = try container.decodeIfPresent(String.self, forKey: .protocolName) ?? "mcp"
    transport = try container.decode(TatwoPluginMcpTransportV1.self, forKey: .transport)
    command = try container.decodeIfPresent(String.self, forKey: .command)
    args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
    url = try container.decodeIfPresent(String.self, forKey: .url)
    envRefs = try container.decodeIfPresent([String].self, forKey: .envRefs) ?? []
    toolNamespace = try container.decodeIfPresent(String.self, forKey: .toolNamespace)
    let health = try container.decodeIfPresent(HealthCheckDTO.self, forKey: .healthCheck)
    healthCheckProbeID = health?.probeID
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolName, forKey: .protocolName)
    try container.encode(transport, forKey: .transport)
    try container.encodeIfPresent(command, forKey: .command)
    if !args.isEmpty {
      try container.encode(args, forKey: .args)
    }
    try container.encodeIfPresent(url, forKey: .url)
    if !envRefs.isEmpty {
      try container.encode(envRefs, forKey: .envRefs)
    }
    try container.encodeIfPresent(toolNamespace, forKey: .toolNamespace)
    if let healthCheckProbeID {
      try container.encode(HealthCheckDTO(probeID: healthCheckProbeID), forKey: .healthCheck)
    }
  }
}

/// Per-brand projection template reference (S2 will expand; S1 only stores ids).
public struct TatwoPluginProjectionTemplateRefV1: Codable, Sendable, Equatable {
  public let templateID: String

  public init(templateID: String) {
    self.templateID = templateID
  }
}

/// ② vendor_native implementation candidate (not portable MCP config).
public struct TatwoPluginVendorImplementationV1: Codable, Sendable, Equatable {
  public let implementationID: String
  public let provider: String
  public let capabilityID: String
  public let entrypoint: String
  public let availabilityProbe: String?
  public let riskClass: String?
  public let priority: Int

  public init(
    implementationID: String,
    provider: String,
    capabilityID: String,
    entrypoint: String,
    availabilityProbe: String? = nil,
    riskClass: String? = nil,
    priority: Int
  ) {
    self.implementationID = implementationID
    self.provider = provider
    self.capabilityID = capabilityID
    self.entrypoint = entrypoint
    self.availabilityProbe = availabilityProbe
    self.riskClass = riskClass
    self.priority = priority
  }
}

/// Routing hook into D12 capability lanes (`docs/protocol/CAPABILITY_LANE_ROUTING_DESIGN.md`).
public struct TatwoPluginVendorRoutingV1: Codable, Sendable, Equatable {
  public let laneRef: String
  public let selection: String
  public let fallback: String
  public let highRiskPolicy: String?

  public init(
    laneRef: String,
    selection: String,
    fallback: String,
    highRiskPolicy: String? = nil
  ) {
    self.laneRef = laneRef
    self.selection = selection
    self.fallback = fallback
    self.highRiskPolicy = highRiskPolicy
  }
}

/// ③ app_native feature descriptor (no external MCP projection).
public struct TatwoPluginAppFeatureV1: Codable, Sendable, Equatable {
  public let moduleID: String
  public let builtIn: Bool
  public let externalProjection: String
  public let statusSource: String?

  public init(
    moduleID: String,
    builtIn: Bool = true,
    externalProjection: String = "none",
    statusSource: String? = "app_runtime"
  ) {
    self.moduleID = moduleID
    self.builtIn = builtIn
    self.externalProjection = externalProjection
    self.statusSource = statusSource
  }
}

// MARK: - Registry entry

/// S1 controller registry entry. Discriminated by `type`; wrong payload for type fails closed.
public struct TatwoPluginRegistryEntryV1: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let type: TatwoPluginEntryTypeV1
  public let displayName: String?
  public let legacyKind: String?
  public let purpose: String?
  public let trigger: String?
  public let desiredState: TatwoPluginDesiredStateV1
  public let canonicalDefinition: TatwoPluginCanonicalMcpDefinitionV1?
  public let projectionTemplates: [String: TatwoPluginProjectionTemplateRefV1]?
  public let implementations: [TatwoPluginVendorImplementationV1]?
  public let routing: TatwoPluginVendorRoutingV1?
  public let appFeature: TatwoPluginAppFeatureV1?

  public init(
    id: String,
    type: TatwoPluginEntryTypeV1,
    displayName: String? = nil,
    legacyKind: String? = nil,
    purpose: String? = nil,
    trigger: String? = nil,
    desiredState: TatwoPluginDesiredStateV1 = .enabled,
    canonicalDefinition: TatwoPluginCanonicalMcpDefinitionV1? = nil,
    projectionTemplates: [String: TatwoPluginProjectionTemplateRefV1]? = nil,
    implementations: [TatwoPluginVendorImplementationV1]? = nil,
    routing: TatwoPluginVendorRoutingV1? = nil,
    appFeature: TatwoPluginAppFeatureV1? = nil
  ) {
    self.id = id
    self.type = type
    self.displayName = displayName
    self.legacyKind = legacyKind
    self.purpose = purpose
    self.trigger = trigger
    self.desiredState = desiredState
    self.canonicalDefinition = canonicalDefinition
    self.projectionTemplates = projectionTemplates
    self.implementations = implementations
    self.routing = routing
    self.appFeature = appFeature
  }
}

// MARK: - Document

public struct TatwoPluginControllerRegistryDocumentV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoPluginControllerRegistryV1"

  public let schema: String
  public let registryRevision: String
  public let activeRevision: String?
  public let entries: [TatwoPluginRegistryEntryV1]
  public let updatedAt: String?
  public let source: String

  public init(
    schema: String = TatwoPluginControllerRegistryDocumentV1.schemaName,
    registryRevision: String,
    activeRevision: String? = nil,
    entries: [TatwoPluginRegistryEntryV1],
    updatedAt: String? = nil,
    source: String = "os_registry"
  ) {
    self.schema = schema
    self.registryRevision = registryRevision
    self.activeRevision = activeRevision
    self.entries = entries
    self.updatedAt = updatedAt
    self.source = source
  }

  public var portableMcpEntries: [TatwoPluginRegistryEntryV1] {
    entries.filter { $0.type == .portableMcp }
  }
}

// MARK: - Errors

public enum TatwoPluginControllerRegistryErrorV1: Error, LocalizedError, Sendable, Equatable {
  case fileNotFound(String)
  case unreadableData(String)
  case invalidJSON(String)
  case unsupportedSchema(String)
  case emptyRegistryRevision
  case emptyEntries
  case duplicateEntryID(String)
  case invalidEntryID(String)
  case unknownType(String)
  case missingCanonicalDefinition(String)
  case missingProjectionTemplates(String)
  case invalidCanonicalDefinition(String, String)
  case missingImplementations(String)
  case missingRouting(String)
  case invalidLaneRef(String)
  case missingAppFeature(String)
  case typePayloadMismatch(String, String)
  case forbiddenFieldPresent(String)
  case secretLiteralRejected(String)

  public var errorDescription: String? {
    switch self {
    case .fileNotFound(let path):
      return "Plugin controller registry file not found: \(path)"
    case .unreadableData(let path):
      return "Plugin controller registry unreadable: \(path)"
    case .invalidJSON(let detail):
      return "Plugin controller registry JSON invalid: \(detail)"
    case .unsupportedSchema(let schema):
      return "Unsupported plugin controller registry schema: \(schema)"
    case .emptyRegistryRevision:
      return "registryRevision must be non-empty"
    case .emptyEntries:
      return "Plugin controller registry entries must not be empty"
    case .duplicateEntryID(let id):
      return "Duplicate plugin registry entry id: \(id)"
    case .invalidEntryID(let id):
      return "Invalid plugin registry entry id: \(id)"
    case .unknownType(let raw):
      return "Unknown plugin entry type (fail-closed): \(raw)"
    case .missingCanonicalDefinition(let id):
      return "portable_mcp entry missing canonicalDefinition: \(id)"
    case .missingProjectionTemplates(let id):
      return "portable_mcp entry missing projectionTemplates: \(id)"
    case .invalidCanonicalDefinition(let id, let reason):
      return "portable_mcp canonicalDefinition invalid for \(id): \(reason)"
    case .missingImplementations(let id):
      return "vendor_native entry missing implementations: \(id)"
    case .missingRouting(let id):
      return "vendor_native entry missing routing: \(id)"
    case .invalidLaneRef(let id):
      return "vendor_native routing.laneRef invalid for \(id)"
    case .missingAppFeature(let id):
      return "app_native entry missing appFeature: \(id)"
    case .typePayloadMismatch(let id, let detail):
      return "Entry \(id) payload does not match type: \(detail)"
    case .forbiddenFieldPresent(let field):
      return "Forbidden field present in plugin registry (fail-closed): \(field)"
    case .secretLiteralRejected(let field):
      return "Secret-like literal rejected in plugin registry: \(field)"
    }
  }
}

// MARK: - Loader (fail-closed)

public enum TatwoPluginControllerRegistryLoaderV1 {
  /// Forbidden key fragments; presence anywhere in the raw JSON object graph fails closed.
  public static let forbiddenKeyFragments: [String] = [
    "auth", "token", "apikey", "api_key", "cookie", "credential", "secret", "password",
  ]

  public static func load(from url: URL) throws -> TatwoPluginControllerRegistryDocumentV1 {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoPluginControllerRegistryErrorV1.fileNotFound(url.path)
    }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw TatwoPluginControllerRegistryErrorV1.unreadableData(url.path)
    }
    return try load(data: data)
  }

  public static func load(data: Data) throws -> TatwoPluginControllerRegistryDocumentV1 {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw TatwoPluginControllerRegistryErrorV1.invalidJSON(error.localizedDescription)
    }
    try scanForbiddenKeys(object)

    let decoder = JSONDecoder()
    let document: TatwoPluginControllerRegistryDocumentV1
    do {
      document = try decoder.decode(TatwoPluginControllerRegistryDocumentV1.self, from: data)
    } catch let decoding as DecodingError {
      throw TatwoPluginControllerRegistryErrorV1.invalidJSON(describeDecodingError(decoding))
    } catch {
      throw TatwoPluginControllerRegistryErrorV1.invalidJSON(String(describing: error))
    }
    try validate(document)
    return document
  }

  public static func validate(_ document: TatwoPluginControllerRegistryDocumentV1) throws {
    guard document.schema == TatwoPluginControllerRegistryDocumentV1.schemaName else {
      throw TatwoPluginControllerRegistryErrorV1.unsupportedSchema(document.schema)
    }
    guard !document.registryRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TatwoPluginControllerRegistryErrorV1.emptyRegistryRevision
    }
    guard document.source == "os_registry" else {
      throw TatwoPluginControllerRegistryErrorV1.invalidJSON(
        "source must be os_registry (native config is never truth)")
    }
    guard !document.entries.isEmpty else {
      throw TatwoPluginControllerRegistryErrorV1.emptyEntries
    }

    var seen = Set<String>()
    for entry in document.entries {
      try validate(entry: entry, seen: &seen)
    }
  }

  private static func validate(entry: TatwoPluginRegistryEntryV1, seen: inout Set<String>) throws {
    let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty, id == entry.id, !id.contains("/"), !id.contains(".."), !id.contains("\\") else {
      throw TatwoPluginControllerRegistryErrorV1.invalidEntryID(entry.id)
    }
    guard seen.insert(id).inserted else {
      throw TatwoPluginControllerRegistryErrorV1.duplicateEntryID(id)
    }

    switch entry.type {
    case .portableMcp:
      guard let canonical = entry.canonicalDefinition else {
        throw TatwoPluginControllerRegistryErrorV1.missingCanonicalDefinition(id)
      }
      guard let templates = entry.projectionTemplates, !templates.isEmpty else {
        throw TatwoPluginControllerRegistryErrorV1.missingProjectionTemplates(id)
      }
      try validateCanonical(canonical, entryID: id)
      if entry.implementations != nil || entry.routing != nil || entry.appFeature != nil {
        throw TatwoPluginControllerRegistryErrorV1.typePayloadMismatch(
          id, "portable_mcp must not carry implementations/routing/appFeature")
      }

    case .vendorNative:
      guard let implementations = entry.implementations, !implementations.isEmpty else {
        throw TatwoPluginControllerRegistryErrorV1.missingImplementations(id)
      }
      guard let routing = entry.routing else {
        throw TatwoPluginControllerRegistryErrorV1.missingRouting(id)
      }
      let lane = routing.laneRef.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !lane.isEmpty, lane.contains(":") else {
        throw TatwoPluginControllerRegistryErrorV1.invalidLaneRef(id)
      }
      if entry.canonicalDefinition != nil || entry.projectionTemplates != nil || entry.appFeature != nil {
        throw TatwoPluginControllerRegistryErrorV1.typePayloadMismatch(
          id, "vendor_native must not carry canonicalDefinition/projectionTemplates/appFeature")
      }
      for impl in implementations {
        guard !impl.implementationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw TatwoPluginControllerRegistryErrorV1.typePayloadMismatch(
            id, "implementationID empty")
        }
      }

    case .appNative:
      guard let feature = entry.appFeature else {
        throw TatwoPluginControllerRegistryErrorV1.missingAppFeature(id)
      }
      guard !feature.moduleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TatwoPluginControllerRegistryErrorV1.typePayloadMismatch(id, "moduleID empty")
      }
      if entry.canonicalDefinition != nil || entry.projectionTemplates != nil
        || entry.implementations != nil || entry.routing != nil
      {
        throw TatwoPluginControllerRegistryErrorV1.typePayloadMismatch(
          id, "app_native must not carry MCP or vendor payloads")
      }
    }
  }

  private static func validateCanonical(
    _ canonical: TatwoPluginCanonicalMcpDefinitionV1,
    entryID: String
  ) throws {
    guard canonical.protocolName == "mcp" else {
      throw TatwoPluginControllerRegistryErrorV1.invalidCanonicalDefinition(
        entryID, "protocol must be mcp")
    }
    switch canonical.transport {
    case .stdio:
      let command = (canonical.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !command.isEmpty else {
        throw TatwoPluginControllerRegistryErrorV1.invalidCanonicalDefinition(
          entryID, "stdio requires command")
      }
      if let url = canonical.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw TatwoPluginControllerRegistryErrorV1.invalidCanonicalDefinition(
          entryID, "stdio must not set url")
      }
    case .http, .sse:
      let url = (canonical.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !url.isEmpty else {
        throw TatwoPluginControllerRegistryErrorV1.invalidCanonicalDefinition(
          entryID, "\(canonical.transport.rawValue) requires url")
      }
      guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
        throw TatwoPluginControllerRegistryErrorV1.invalidCanonicalDefinition(
          entryID, "url must be http(s)")
      }
      if url.contains("?") {
        throw TatwoPluginControllerRegistryErrorV1.invalidCanonicalDefinition(
          entryID, "url must not include query tokens")
      }
    }
    for ref in canonical.envRefs {
      let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed == ref, !trimmed.contains("=") else {
        throw TatwoPluginControllerRegistryErrorV1.invalidCanonicalDefinition(
          entryID, "envRefs must be names only")
      }
    }
  }

  private static func scanForbiddenKeys(_ value: Any) throws {
    if let dict = value as? [String: Any] {
      for (key, child) in dict {
        let lower = key.lowercased()
        for fragment in forbiddenKeyFragments where lower.contains(fragment) {
          // envRefs / secretRef as *names* are allowed only as exact known non-literal keys.
          if lower == "envrefs" || lower == "secretref" || lower == "healthcheck" {
            continue
          }
          throw TatwoPluginControllerRegistryErrorV1.forbiddenFieldPresent(key)
        }
        if let string = child as? String, looksLikeSecretLiteral(key: lower, value: string) {
          throw TatwoPluginControllerRegistryErrorV1.secretLiteralRejected(key)
        }
        try scanForbiddenKeys(child)
      }
    } else if let array = value as? [Any] {
      for child in array {
        try scanForbiddenKeys(child)
      }
    }
  }

  private static func looksLikeSecretLiteral(key: String, value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if key.contains("token") || key.contains("secret") || key.contains("password")
      || key.contains("apikey") || key.contains("api_key") || key.contains("cookie")
      || key.contains("credential")
    {
      return true
    }
    return false
  }

  private static func describeDecodingError(_ error: DecodingError) -> String {
    switch error {
    case .typeMismatch(_, let context):
      return "typeMismatch at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
    case .valueNotFound(_, let context):
      return "valueNotFound at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
    case .keyNotFound(let key, let context):
      return "keyNotFound \(key.stringValue) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
    case .dataCorrupted(let context):
      return "dataCorrupted at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
    @unknown default:
      return String(describing: error)
    }
  }
}

// MARK: - S2 staged projection interface (contract only; S1 does not project)

/// S2 will render brand fragments into application-support staging. S1 only defines the seam.
public struct TatwoPluginStagedProjectionTargetV1: Codable, Sendable, Equatable {
  public let brand: String
  public let logicalPath: String
  public let templateID: String

  public init(brand: String, logicalPath: String, templateID: String) {
    self.brand = brand
    self.logicalPath = logicalPath
    self.templateID = templateID
  }
}

public struct TatwoPluginStagedProjectionPlanV1: Codable, Sendable, Equatable {
  public let schema: String
  public let registryRevision: String
  public let entryID: String
  public let targets: [TatwoPluginStagedProjectionTargetV1]
  public let writesNativeConfig: Bool

  public init(
    schema: String = "TatwoPluginStagedProjectionPlanV1",
    registryRevision: String,
    entryID: String,
    targets: [TatwoPluginStagedProjectionTargetV1],
    writesNativeConfig: Bool = false
  ) {
    self.schema = schema
    self.registryRevision = registryRevision
    self.entryID = entryID
    self.targets = targets
    self.writesNativeConfig = writesNativeConfig
  }
}

/// S2 implementers plan projections; S1 does not call host writers.
public protocol TatwoPluginStagedProjectionPlanningV1: Sendable {
  func planProjection(
    registry: TatwoPluginControllerRegistryDocumentV1,
    entryID: String
  ) throws -> TatwoPluginStagedProjectionPlanV1
}
