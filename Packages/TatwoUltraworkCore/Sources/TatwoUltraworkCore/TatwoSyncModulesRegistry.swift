import Foundation

// MARK: - Errors

public enum TatwoSyncModulesRegistryError: Error, Equatable, LocalizedError {
  case unsupportedSchema(String)
  case bundledRegistryUnavailable(String)
  case emptyModules
  case duplicateModuleID(String)
  case unknownModuleID(String)
  case missingRequiredModuleIDs([String])
  case unexpectedModuleIDs([String])
  case invalidModuleID(String)
  case invalidSection(String)
  case invalidTransport(String)
  case emptyTitle(String)
  case emptyPlainZh(String)
  case multilinePlainZh(String)
  case threadsMustBeExcluded
  case cannotMutateExcludedModule(String)
  case failedStateRequiresReason(String)
  case multilineFailureReason(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let schema):
      return "Unsupported sync-modules registry schema: \(schema)"
    case .bundledRegistryUnavailable(let resource):
      return "Bundled sync-modules registry is unavailable: \(resource)"
    case .emptyModules:
      return "Sync-modules registry must declare modules"
    case .duplicateModuleID(let id):
      return "Duplicate sync module id: \(id)"
    case .unknownModuleID(let id):
      return "Unknown sync module id: \(id)"
    case .missingRequiredModuleIDs(let ids):
      return "Sync-modules registry missing required ids: \(ids.joined(separator: ","))"
    case .unexpectedModuleIDs(let ids):
      return "Sync-modules registry has unexpected ids: \(ids.joined(separator: ","))"
    case .invalidModuleID(let id):
      return "Invalid sync module id: \(id)"
    case .invalidSection(let value):
      return "Invalid sync module section: \(value)"
    case .invalidTransport(let value):
      return "Invalid sync module transport: \(value)"
    case .emptyTitle(let id):
      return "Sync module titleZh must not be empty: \(id)"
    case .emptyPlainZh(let id):
      return "Sync module plainZh must not be empty: \(id)"
    case .multilinePlainZh(let id):
      return "Sync module plainZh must be a single line: \(id)"
    case .threadsMustBeExcluded:
      return "threads module must set excluded=true (2026-07-23)"
    case .cannotMutateExcludedModule(let id):
      return "Excluded sync module cannot be enabled or marked syncing: \(id)"
    case .failedStateRequiresReason(let id):
      return "failed sync-module state requires a one-line reason: \(id)"
    case .multilineFailureReason(let id):
      return "failed sync-module reason must be a single line: \(id)"
    }
  }
}

// MARK: - Definition enums

public enum TatwoSyncModuleSectionV1: String, Codable, Sendable, Equatable, CaseIterable {
  case version
  case data
  case compute
}

public enum TatwoSyncModuleTransportV1: String, Codable, Sendable, Equatable, CaseIterable {
  case githubRelease = "github-release"
  case deviceSyncChannel = "device-sync-channel"
  case loopChannel = "loop-channel"
  case manual
}

public enum TatwoSyncModuleRunStateV1: String, Codable, Sendable, Equatable, CaseIterable {
  case idle
  case syncing
  case failed
}

// MARK: - Registry document

public struct TatwoSyncModuleDefinitionV1: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let section: TatwoSyncModuleSectionV1
  public let titleZh: String
  public let plainZh: String
  public let transport: TatwoSyncModuleTransportV1
  public let enabled: Bool
  public let statusProbe: String?
  public let owningPaths: [String]
  public let excluded: Bool
  public let notes: String

  public init(
    id: String,
    section: TatwoSyncModuleSectionV1,
    titleZh: String,
    plainZh: String,
    transport: TatwoSyncModuleTransportV1,
    enabled: Bool,
    statusProbe: String? = nil,
    owningPaths: [String],
    excluded: Bool = false,
    notes: String = ""
  ) {
    self.id = id
    self.section = section
    self.titleZh = titleZh
    self.plainZh = plainZh
    self.transport = transport
    self.enabled = enabled
    self.statusProbe = Self.normalizedOptional(statusProbe)
    self.owningPaths = owningPaths
    self.excluded = excluded
    self.notes = notes
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try values.decode(String.self, forKey: .id),
      section: try values.decode(TatwoSyncModuleSectionV1.self, forKey: .section),
      titleZh: try values.decode(String.self, forKey: .titleZh),
      plainZh: try values.decode(String.self, forKey: .plainZh),
      transport: try values.decode(TatwoSyncModuleTransportV1.self, forKey: .transport),
      enabled: try values.decode(Bool.self, forKey: .enabled),
      statusProbe: try values.decodeIfPresent(String.self, forKey: .statusProbe),
      owningPaths: try values.decodeIfPresent([String].self, forKey: .owningPaths) ?? [],
      excluded: try values.decodeIfPresent(Bool.self, forKey: .excluded) ?? false,
      notes: try values.decodeIfPresent(String.self, forKey: .notes) ?? "")
  }

  private static func normalizedOptional(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

public struct TatwoSyncModulesRegistry: Codable, Hashable, Sendable {
  public static let schemaName = "TatwoSyncModulesRegistryV1"
  public static let bundledResourceName = "sync-modules.v1"
  public static let requiredModuleIDs: [String] = [
    "os-app-version",
    "cli-version",
    "skillet-bundle-lane",
    "os-skillet-md",
    "mcp-plugin-registry",
    "memory-sync",
    "model-collab-presets",
    "governance-docs",
    "goal-state",
    "threads",
    "remote-loops-dispatch",
    "device-pressure",
    "device-trust",
  ]

  public let schema: String
  public let modules: [TatwoSyncModuleDefinitionV1]

  public init(
    schema: String = TatwoSyncModulesRegistry.schemaName,
    modules: [TatwoSyncModuleDefinitionV1]
  ) {
    self.schema = schema
    self.modules = modules
  }

  public var modulesByID: [String: TatwoSyncModuleDefinitionV1] {
    Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0) })
  }

  public func module(id: String) -> TatwoSyncModuleDefinitionV1? {
    modulesByID[id]
  }

  public func modules(in section: TatwoSyncModuleSectionV1) -> [TatwoSyncModuleDefinitionV1] {
    modules.filter { $0.section == section }
  }

  public func validate() throws {
    guard schema == Self.schemaName else {
      throw TatwoSyncModulesRegistryError.unsupportedSchema(schema)
    }
    guard !modules.isEmpty else {
      throw TatwoSyncModulesRegistryError.emptyModules
    }

    var seen = Set<String>()
    for module in modules {
      let trimmed = module.id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed == module.id, !trimmed.contains("/") else {
        throw TatwoSyncModulesRegistryError.invalidModuleID(module.id)
      }
      guard seen.insert(module.id).inserted else {
        throw TatwoSyncModulesRegistryError.duplicateModuleID(module.id)
      }
      if module.titleZh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw TatwoSyncModulesRegistryError.emptyTitle(module.id)
      }
      let plain = module.plainZh.trimmingCharacters(in: .whitespacesAndNewlines)
      if plain.isEmpty {
        throw TatwoSyncModulesRegistryError.emptyPlainZh(module.id)
      }
      if module.plainZh.contains(where: \.isNewline) {
        throw TatwoSyncModulesRegistryError.multilinePlainZh(module.id)
      }
    }

    let declared = Set(modules.map(\.id))
    let required = Set(Self.requiredModuleIDs)
    let missing = required.subtracting(declared).sorted()
    if !missing.isEmpty {
      throw TatwoSyncModulesRegistryError.missingRequiredModuleIDs(missing)
    }
    let unexpected = declared.subtracting(required).sorted()
    if !unexpected.isEmpty {
      throw TatwoSyncModulesRegistryError.unexpectedModuleIDs(unexpected)
    }
    guard let threads = module(id: "threads"), threads.excluded else {
      throw TatwoSyncModulesRegistryError.threadsMustBeExcluded
    }
  }

  public static func load(
    from url: URL,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> TatwoSyncModulesRegistry {
    let document = try decoder.decode(TatwoSyncModulesRegistry.self, from: Data(contentsOf: url))
    try document.validate()
    return document
  }

  /// Registry JSON lives in the Core resource bundle (`config/sync-modules.v1.json`).
  /// App Support is only for enablement/runtime overlays — never the definition.
  public static func bundledRegistryURL(
    fileManager: FileManager = .default
  ) -> URL? {
    var candidates: [URL] = []
    if let url = Bundle.module.url(
      forResource: bundledResourceName,
      withExtension: "json")
    {
      candidates.append(url)
    }
    if let url = Bundle.main.url(
      forResource: bundledResourceName,
      withExtension: "json")
    {
      candidates.append(url)
    }

    let executableDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
    let resourceBundleNames = [
      "TatwoUltrawork_TatwoUltraworkCore.bundle",
      "TatwoUltraworkCore_TatwoUltraworkCore.bundle",
    ]
    for name in resourceBundleNames {
      let bundleURL = executableDirectory.appendingPathComponent(name)
      if let bundle = Bundle(url: bundleURL),
        let url = bundle.url(
          forResource: bundledResourceName,
          withExtension: "json")
      {
        candidates.append(url)
      }
      candidates.append(
        bundleURL.appendingPathComponent("\(bundledResourceName).json"))
    }

    // Debug / snapshot executables may run after CWD is moved off /Volumes.
    // Walk from this source file to repo `config/`, never Application Support.
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<10 {
      candidates.append(
        directory
          .appendingPathComponent("config", isDirectory: true)
          .appendingPathComponent("\(bundledResourceName).json"))
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { break }
      directory = parent
    }

    return candidates.first { url in
      guard fileManager.fileExists(atPath: url.path) else { return false }
      let path = url.path.lowercased()
      return !path.contains("/application support/")
        && !path.contains("/containers/data/library/application support/")
    }
  }

  public static func loadBundled(
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> TatwoSyncModulesRegistry {
    guard let url = bundledRegistryURL() else {
      throw TatwoSyncModulesRegistryError.bundledRegistryUnavailable(
        "\(bundledResourceName).json")
    }
    return try load(from: url, decoder: decoder)
  }

  public func resolvedModules(
    enablement: TatwoSyncModuleEnablementStore,
    runtime: TatwoSyncModuleRuntimeStateStore
  ) throws -> [TatwoSyncModuleResolvedV1] {
    let enabledByID = try enablement.load()
    let runtimeByID = try runtime.load()
    return modules.map { definition in
      TatwoSyncModuleResolvedV1(
        definition: definition,
        enabled: Self.effectiveEnabled(definition, overlay: enabledByID[definition.id]),
        runtime: runtimeByID[definition.id] ?? TatwoSyncModuleRuntimeRecordV1(moduleID: definition.id))
    }
  }

  public static func effectiveEnabled(
    _ definition: TatwoSyncModuleDefinitionV1,
    overlay: Bool?
  ) -> Bool {
    if definition.excluded { return false }
    return overlay ?? definition.enabled
  }
}

/// Visual-round read model: registry definition + device-local enablement + last-sync state.
public struct TatwoSyncModuleResolvedV1: Sendable, Equatable, Identifiable {
  public var id: String { definition.id }
  public let definition: TatwoSyncModuleDefinitionV1
  public let enabled: Bool
  public let runtime: TatwoSyncModuleRuntimeRecordV1

  public var lastSyncAt: Date? { runtime.lastSyncAt }
  public var runState: TatwoSyncModuleRunStateV1 { runtime.state }
  public var reason: String? { runtime.reason }

  public init(
    definition: TatwoSyncModuleDefinitionV1,
    enabled: Bool,
    runtime: TatwoSyncModuleRuntimeRecordV1
  ) {
    self.definition = definition
    self.enabled = definition.excluded ? false : enabled
    self.runtime = runtime
  }
}

// MARK: - Device-local enablement (not the registry JSON)

public struct TatwoSyncModuleEnablementDocumentV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoSyncModuleEnablementV1"
  public static let fileName = "sync-modules.enablement.v1.json"

  public var schema: String
  public var updatedAt: Date
  public var enabled: [String: Bool]

  public init(
    schema: String = TatwoSyncModuleEnablementDocumentV1.schemaName,
    updatedAt: Date = Date(),
    enabled: [String: Bool] = [:]
  ) {
    self.schema = schema
    self.updatedAt = updatedAt
    self.enabled = enabled
  }
}

public struct TatwoSyncModuleEnablementStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public static func defaultStore(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default
  ) -> Self {
    let root = TatwoRuntimeLayout.applicationSupportRoot(
      environment: environment,
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager)
    return Self(fileURL: root.appendingPathComponent(
      TatwoSyncModuleEnablementDocumentV1.fileName))
  }

  public func load() throws -> [String: Bool] {
    try loadDocument().enabled
  }

  public func loadDocument() throws -> TatwoSyncModuleEnablementDocumentV1 {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return TatwoSyncModuleEnablementDocumentV1()
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(
      TatwoSyncModuleEnablementDocumentV1.self,
      from: Data(contentsOf: fileURL))
    if document.schema != TatwoSyncModuleEnablementDocumentV1.schemaName {
      throw TatwoSyncModulesRegistryError.unsupportedSchema(document.schema)
    }
    return document
  }

  public func isEnabled(
    moduleID: String,
    registry: TatwoSyncModulesRegistry
  ) throws -> Bool {
    guard let definition = registry.module(id: moduleID) else {
      throw TatwoSyncModulesRegistryError.unknownModuleID(moduleID)
    }
    return TatwoSyncModulesRegistry.effectiveEnabled(
      definition,
      overlay: try load()[moduleID])
  }

  public func setEnabled(
    _ enabled: Bool,
    moduleID: String,
    registry: TatwoSyncModulesRegistry,
    now: Date = Date()
  ) throws {
    guard let definition = registry.module(id: moduleID) else {
      throw TatwoSyncModulesRegistryError.unknownModuleID(moduleID)
    }
    if definition.excluded {
      throw TatwoSyncModulesRegistryError.cannotMutateExcludedModule(moduleID)
    }
    var document = try loadDocument()
    document.enabled[moduleID] = enabled
    document.updatedAt = now
    try persist(document)
  }

  private func persist(_ document: TatwoSyncModuleEnablementDocumentV1) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    var copy = document
    copy.schema = TatwoSyncModuleEnablementDocumentV1.schemaName
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(copy).write(to: fileURL, options: [.atomic])
  }
}

// MARK: - Per-module last-sync + run state (sync legs write here)

public struct TatwoSyncModuleRuntimeRecordV1: Codable, Sendable, Equatable {
  public var moduleID: String
  public var state: TatwoSyncModuleRunStateV1
  public var lastSyncAt: Date?
  public var reason: String?
  public var updatedAt: Date

  public init(
    moduleID: String,
    state: TatwoSyncModuleRunStateV1 = .idle,
    lastSyncAt: Date? = nil,
    reason: String? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 0)
  ) {
    self.moduleID = moduleID
    self.state = state
    self.lastSyncAt = lastSyncAt
    self.reason = reason
    self.updatedAt = updatedAt
  }
}

public struct TatwoSyncModuleRuntimeDocumentV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoSyncModuleRuntimeStateV1"
  public static let fileName = "sync-modules.runtime.v1.json"

  public var schema: String
  public var updatedAt: Date
  public var modules: [String: TatwoSyncModuleRuntimeRecordV1]

  public init(
    schema: String = TatwoSyncModuleRuntimeDocumentV1.schemaName,
    updatedAt: Date = Date(),
    modules: [String: TatwoSyncModuleRuntimeRecordV1] = [:]
  ) {
    self.schema = schema
    self.updatedAt = updatedAt
    self.modules = modules
  }
}

/// Persisted last-sync timestamp + idle/syncing/failed(reason) for each module.
/// Sync legs should call `markSyncing` / `markIdle` / `markFailed` — they must
/// not write the registry JSON.
public struct TatwoSyncModuleRuntimeStateStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public static func defaultStore(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default
  ) -> Self {
    let root = TatwoRuntimeLayout.applicationSupportRoot(
      environment: environment,
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager)
    return Self(fileURL: root.appendingPathComponent(
      TatwoSyncModuleRuntimeDocumentV1.fileName))
  }

  public func load() throws -> [String: TatwoSyncModuleRuntimeRecordV1] {
    try loadDocument().modules
  }

  public func record(for moduleID: String) throws -> TatwoSyncModuleRuntimeRecordV1 {
    try load()[moduleID] ?? TatwoSyncModuleRuntimeRecordV1(moduleID: moduleID)
  }

  public func markSyncing(
    moduleID: String,
    registry: TatwoSyncModulesRegistry,
    now: Date = Date()
  ) throws {
    try upsert(
      moduleID: moduleID,
      registry: registry,
      now: now
    ) { record in
      record.state = .syncing
      record.reason = nil
    }
  }

  public func markIdle(
    moduleID: String,
    lastSyncAt: Date? = nil,
    registry: TatwoSyncModulesRegistry,
    now: Date = Date()
  ) throws {
    try upsert(
      moduleID: moduleID,
      registry: registry,
      now: now
    ) { record in
      record.state = .idle
      record.lastSyncAt = lastSyncAt ?? now
      record.reason = nil
    }
  }

  public func markFailed(
    moduleID: String,
    reason: String,
    lastSyncAt: Date? = nil,
    registry: TatwoSyncModulesRegistry,
    now: Date = Date()
  ) throws {
    try upsert(
      moduleID: moduleID,
      registry: registry,
      now: now
    ) { record in
      record.state = .failed
      record.reason = reason
      if let lastSyncAt {
        record.lastSyncAt = lastSyncAt
      }
    }
  }

  public func loadDocument() throws -> TatwoSyncModuleRuntimeDocumentV1 {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return TatwoSyncModuleRuntimeDocumentV1()
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(
      TatwoSyncModuleRuntimeDocumentV1.self,
      from: Data(contentsOf: fileURL))
    if document.schema != TatwoSyncModuleRuntimeDocumentV1.schemaName {
      throw TatwoSyncModulesRegistryError.unsupportedSchema(document.schema)
    }
    return document
  }

  private func upsert(
    moduleID: String,
    registry: TatwoSyncModulesRegistry,
    now: Date,
    mutate: (inout TatwoSyncModuleRuntimeRecordV1) -> Void
  ) throws {
    guard let definition = registry.module(id: moduleID) else {
      throw TatwoSyncModulesRegistryError.unknownModuleID(moduleID)
    }
    if definition.excluded {
      throw TatwoSyncModulesRegistryError.cannotMutateExcludedModule(moduleID)
    }
    var document = try loadDocument()
    var record = document.modules[moduleID] ?? TatwoSyncModuleRuntimeRecordV1(moduleID: moduleID)
    mutate(&record)
    record.moduleID = moduleID
    record.updatedAt = now
    if record.state == .failed {
      let reason = record.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if reason.isEmpty {
        throw TatwoSyncModulesRegistryError.failedStateRequiresReason(moduleID)
      }
      if reason.contains(where: \.isNewline) {
        throw TatwoSyncModulesRegistryError.multilineFailureReason(moduleID)
      }
      record.reason = reason
    } else {
      record.reason = nil
    }
    document.modules[moduleID] = record
    document.updatedAt = now
    try persist(document)
  }

  private func persist(_ document: TatwoSyncModuleRuntimeDocumentV1) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    var copy = document
    copy.schema = TatwoSyncModuleRuntimeDocumentV1.schemaName
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(copy).write(to: fileURL, options: [.atomic])
  }
}
