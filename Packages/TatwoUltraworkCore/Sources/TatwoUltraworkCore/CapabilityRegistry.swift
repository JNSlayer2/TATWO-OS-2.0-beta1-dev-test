import Foundation

public struct TatwoCapabilityRootsV1: Codable, Sendable, Equatable {
  public let schema: String
  public let canonicalSkillRoot: String
  public let canonicalPluginRoot: String
  public let importSkillRoots: [String]
  public let importPluginRoots: [String]

  public init(
    schema: String = "TatwoCapabilityRootsV1",
    canonicalSkillRoot: String,
    canonicalPluginRoot: String,
    importSkillRoots: [String],
    importPluginRoots: [String]
  ) {
    self.schema = schema
    self.canonicalSkillRoot = canonicalSkillRoot
    self.canonicalPluginRoot = canonicalPluginRoot
    self.importSkillRoots = importSkillRoots
    self.importPluginRoots = importPluginRoots
  }

  public static func current(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    let support = TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
    let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
    let explicitSkillRoots = (environment["TATWO_CAPABILITY_IMPORT_SKILL_ROOTS"] ?? "")
      .split(separator: ":").map(String.init)
    let codexHome = environment["CODEX_HOME"].map {
      URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("skills").path
    }
    let importSkillRoots = explicitSkillRoots + [
      codexHome,
      home.appendingPathComponent(".codex/skills").path,
      home.appendingPathComponent(".claude/skills").path,
      home.appendingPathComponent("AI/codex/home/skills").path,
    ].compactMap { $0 }
    let explicitPluginRoots = (environment["TATWO_CAPABILITY_IMPORT_PLUGIN_ROOTS"] ?? "")
      .split(separator: ":").map(String.init)
    return Self(
      canonicalSkillRoot: support.appendingPathComponent("capabilities/skills", isDirectory: true).path,
      canonicalPluginRoot: support.appendingPathComponent("capabilities/plugins", isDirectory: true).path,
      importSkillRoots: Array(NSOrderedSet(array: importSkillRoots)).compactMap { $0 as? String },
      importPluginRoots: Array(NSOrderedSet(array:
        explicitPluginRoots + [
          home.appendingPathComponent(".codex/plugins").path,
          home.appendingPathComponent("AI/codex/home/plugins").path,
        ])).compactMap { $0 as? String })
  }
}

public struct TatwoCapabilityBootstrapReceiptV1: Codable, Sendable, Equatable {
  public let schema: String
  public let canonicalRoot: String
  public let imported: [String]
  public let skipped: [String]
  public let available: [String]

  public init(
    schema: String = "TatwoCapabilityBootstrapReceiptV1",
    canonicalRoot: String,
    imported: [String],
    skipped: [String],
    available: [String]
  ) {
    self.schema = schema
    self.canonicalRoot = canonicalRoot
    self.imported = imported
    self.skipped = skipped
    self.available = available
  }
}

public struct TatwoCapabilityStatusV1: Codable, Sendable, Equatable {
  public let schema: String
  public let roots: TatwoCapabilityRootsV1
  public let availableSkills: [String]
  public let importedProviders: [String]

  public init(
    schema: String = "TatwoCapabilityStatusV1",
    roots: TatwoCapabilityRootsV1,
    availableSkills: [String],
    importedProviders: [String]
  ) {
    self.schema = schema
    self.roots = roots
    self.availableSkills = availableSkills
    self.importedProviders = importedProviders
  }
}

public enum TatwoCapabilityRegistry {
  public static func status(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoCapabilityStatusV1 {
    let roots = TatwoCapabilityRootsV1.current(environment: environment)
    let canonical = URL(fileURLWithPath: roots.canonicalSkillRoot, isDirectory: true)
    let available = ((try? FileManager.default.contentsOfDirectory(
      at: canonical, includingPropertiesForKeys: nil)) ?? [])
      .filter {
        FileManager.default.fileExists(
          atPath: $0.appendingPathComponent("SKILL.md").path)
      }
      .map(\.lastPathComponent)
      .sorted()
    let providers = roots.importSkillRoots.filter {
      FileManager.default.fileExists(atPath: $0)
    }
    return TatwoCapabilityStatusV1(
      roots: roots, availableSkills: available, importedProviders: providers)
  }

  @discardableResult
  public static func bootstrap(
    names: [String] = ["tatwo-ultrawork"],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> TatwoCapabilityBootstrapReceiptV1 {
    let roots = TatwoCapabilityRootsV1.current(environment: environment)
    let canonical = URL(fileURLWithPath: roots.canonicalSkillRoot, isDirectory: true)
    try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: roots.canonicalPluginRoot, isDirectory: true),
      withIntermediateDirectories: true)
    var imported: [String] = []
    var skipped: [String] = []
    var available: [String] = []
    for rawName in names {
      let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
        skipped.append(rawName)
        continue
      }
      let destination = canonical.appendingPathComponent(name, isDirectory: true)
      if FileManager.default.fileExists(atPath: destination.appendingPathComponent("SKILL.md").path) {
        skipped.append(name)
        available.append(name)
        continue
      }
      guard let source = roots.importSkillRoots.lazy.map({
        URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name, isDirectory: true)
      }).first(where: {
        FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path)
      }) else {
        skipped.append(name)
        continue
      }
      try FileManager.default.copyItem(at: source, to: destination)
      imported.append(name)
      available.append(name)
    }
    return TatwoCapabilityBootstrapReceiptV1(
      canonicalRoot: canonical.path, imported: imported.sorted(), skipped: skipped.sorted(),
      available: available.sorted())
  }
}
