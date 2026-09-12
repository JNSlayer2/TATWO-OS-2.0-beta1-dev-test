import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoSyncModulesRegistryTests: XCTestCase {
  func testRepositoryRegistryLoadsAndValidatesAllThirteenModules() throws {
    let registry = try TatwoSyncModulesRegistry.load(
      from: repositoryRoot().appendingPathComponent("config/sync-modules.v1.json"))

    XCTAssertEqual(registry.schema, TatwoSyncModulesRegistry.schemaName)
    XCTAssertEqual(registry.modules.count, 13)
    XCTAssertEqual(TatwoSyncModulesRegistry.requiredModuleIDs.count, 13)
    XCTAssertEqual(registry.modules.map(\.id), TatwoSyncModulesRegistry.requiredModuleIDs)
    XCTAssertEqual(registry.modules(in: .version).map(\.id), ["os-app-version", "cli-version"])
    XCTAssertEqual(
      registry.modules(in: .data).map(\.id),
      [
        "skillet-bundle-lane",
        "os-skillet-md",
        "mcp-plugin-registry",
        "memory-sync",
        "model-collab-presets",
        "governance-docs",
        "goal-state",
        "threads",
      ])
    XCTAssertEqual(
      registry.modules(in: .compute).map(\.id),
      ["remote-loops-dispatch", "device-pressure", "device-trust"])
    XCTAssertEqual(try XCTUnwrap(registry.module(id: "threads")).excluded, true)
    XCTAssertEqual(try XCTUnwrap(registry.module(id: "cli-version")).transport, .manual)
    XCTAssertTrue(
      try XCTUnwrap(registry.module(id: "cli-version")).notes.contains("Keychain"))
    XCTAssertTrue(
      try XCTUnwrap(registry.module(id: "governance-docs")).notes.contains("device-sync-channel"))
    XCTAssertTrue(
      try XCTUnwrap(registry.module(id: "threads")).notes.contains("2026-07-23"))
    XCTAssertEqual(try XCTUnwrap(registry.module(id: "skillet-bundle-lane")).transport, .loopChannel)
    XCTAssertFalse(try XCTUnwrap(registry.module(id: "threads")).enabled)
    let skilletMD = try XCTUnwrap(registry.module(id: "os-skillet-md"))
    XCTAssertEqual(skilletMD.section, .data)
    XCTAssertEqual(skilletMD.transport, .manual)
    XCTAssertFalse(skilletMD.excluded)
    XCTAssertTrue(skilletMD.enabled)
    XCTAssertTrue(skilletMD.notes.contains("Unify archives"))
    let modelCollab = try XCTUnwrap(registry.module(id: "model-collab-presets"))
    XCTAssertEqual(modelCollab.transport, .deviceSyncChannel)
    XCTAssertTrue(modelCollab.enabled)
    XCTAssertFalse(modelCollab.excluded)
    XCTAssertTrue(modelCollab.notes.contains("credential-looking"))
    XCTAssertTrue(modelCollab.notes.contains("rides app version"))
    try registry.validate()
  }

  func testBundledRegistryMatchesRepositoryFile() throws {
    let repositoryURL = repositoryRoot().appendingPathComponent("config/sync-modules.v1.json")
    let repository = try TatwoSyncModulesRegistry.load(from: repositoryURL)
    let bundled = try TatwoSyncModulesRegistry.loadBundled()
    XCTAssertEqual(bundled, repository)
    XCTAssertEqual(bundled.modules.count, 13)
    XCTAssertNotNil(bundled.module(id: "os-skillet-md"))
    let url = try XCTUnwrap(TatwoSyncModulesRegistry.bundledRegistryURL())
    XCTAssertFalse(url.path.lowercased().contains("/application support/"))
    XCTAssertTrue(url.lastPathComponent.hasPrefix("sync-modules.v1"))
    XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: repositoryURL))
  }

  func testOwningPathsExistInRepository() throws {
    let registry = try TatwoSyncModulesRegistry.load(
      from: repositoryRoot().appendingPathComponent("config/sync-modules.v1.json"))
    let root = repositoryRoot()
    for module in registry.modules {
      XCTAssertFalse(module.owningPaths.isEmpty, module.id)
      for relative in module.owningPaths {
        let url = root.appendingPathComponent(relative)
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: url.path),
          "\(module.id) missing owning path \(relative)")
      }
    }
  }

  func testValidateRejectsWrongSchemaDuplicateAndNonExcludedThreads() {
    let valid = sampleModule(id: "os-app-version", section: .version)
    XCTAssertThrowsError(
      try TatwoSyncModulesRegistry(schema: "Other", modules: [valid]).validate()
    ) { error in
      XCTAssertEqual(
        error as? TatwoSyncModulesRegistryError,
        .unsupportedSchema("Other"))
    }

    var duplicated = requiredModules(replacing: [])
    duplicated.append(sampleModule(id: "os-app-version", section: .version, titleZh: "B"))
    XCTAssertThrowsError(try TatwoSyncModulesRegistry(modules: duplicated).validate()) { error in
      XCTAssertEqual(
        error as? TatwoSyncModulesRegistryError,
        .duplicateModuleID("os-app-version"))
    }

    let notExcluded = TatwoSyncModulesRegistry(
      modules: requiredModules(replacing: [
        sampleModule(id: "threads", section: .data, excluded: false),
      ]))
    XCTAssertThrowsError(try notExcluded.validate()) { error in
      XCTAssertEqual(
        error as? TatwoSyncModulesRegistryError,
        .threadsMustBeExcluded)
    }
  }

  func testValidateRejectsMultilinePlainZhAndMissingRequiredIDs() {
    let multiline = TatwoSyncModulesRegistry(
      modules: requiredModules(replacing: [
        sampleModule(id: "goal-state", section: .data, plainZh: "一行\n第二行"),
      ]))
    XCTAssertThrowsError(try multiline.validate()) { error in
      XCTAssertEqual(
        error as? TatwoSyncModulesRegistryError,
        .multilinePlainZh("goal-state"))
    }

    let incomplete = TatwoSyncModulesRegistry(modules: [
      sampleModule(id: "os-app-version", section: .version),
    ])
    XCTAssertThrowsError(try incomplete.validate()) { error in
      guard case .missingRequiredModuleIDs(let ids) = error as? TatwoSyncModulesRegistryError else {
        return XCTFail("expected missingRequiredModuleIDs, got \(error)")
      }
      XCTAssertTrue(ids.contains("threads"))
    }
  }

  func testEnablementTogglePersistsWithoutRewritingRegistry() throws {
    let registry = try TatwoSyncModulesRegistry.load(
      from: repositoryRoot().appendingPathComponent("config/sync-modules.v1.json"))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-sync-modules-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let enablement = TatwoSyncModuleEnablementStore(
      fileURL: directory.appendingPathComponent("sync-modules.enablement.v1.json"))
    XCTAssertEqual(try enablement.isEnabled(moduleID: "skillet-bundle-lane", registry: registry), true)
    try enablement.setEnabled(false, moduleID: "skillet-bundle-lane", registry: registry)
    XCTAssertEqual(try enablement.isEnabled(moduleID: "skillet-bundle-lane", registry: registry), false)

    let reloaded = TatwoSyncModuleEnablementStore(fileURL: enablement.fileURL)
    XCTAssertEqual(try reloaded.isEnabled(moduleID: "skillet-bundle-lane", registry: registry), false)
    XCTAssertEqual(try reloaded.isEnabled(moduleID: "governance-docs", registry: registry), true)

    let registryOnDisk = try String(
      contentsOf: repositoryRoot().appendingPathComponent("config/sync-modules.v1.json"),
      encoding: .utf8)
    XCTAssertTrue(registryOnDisk.contains("\"id\": \"skillet-bundle-lane\""))
    XCTAssertFalse(try String(contentsOf: enablement.fileURL, encoding: .utf8).contains("plainZh"))
  }

  func testExcludedThreadsCannotBeEnabledOrMarkedSyncing() throws {
    let registry = try TatwoSyncModulesRegistry.load(
      from: repositoryRoot().appendingPathComponent("config/sync-modules.v1.json"))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-sync-modules-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let enablement = TatwoSyncModuleEnablementStore(
      fileURL: directory.appendingPathComponent("enablement.json"))
    let runtime = TatwoSyncModuleRuntimeStateStore(
      fileURL: directory.appendingPathComponent("runtime.json"))

    XCTAssertThrowsError(try enablement.setEnabled(true, moduleID: "threads", registry: registry)) {
      error in
      XCTAssertEqual(
        error as? TatwoSyncModulesRegistryError,
        .cannotMutateExcludedModule("threads"))
    }
    XCTAssertThrowsError(try runtime.markSyncing(moduleID: "threads", registry: registry)) { error in
      XCTAssertEqual(
        error as? TatwoSyncModulesRegistryError,
        .cannotMutateExcludedModule("threads"))
    }
    XCTAssertEqual(try enablement.isEnabled(moduleID: "threads", registry: registry), false)
  }

  func testRuntimeStatePersistsIdleSyncingFailedWithOneLineReason() throws {
    let registry = try TatwoSyncModulesRegistry.load(
      from: repositoryRoot().appendingPathComponent("config/sync-modules.v1.json"))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-sync-modules-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let runtime = TatwoSyncModuleRuntimeStateStore(
      fileURL: directory.appendingPathComponent(TatwoSyncModuleRuntimeDocumentV1.fileName))
    let now = Date(timeIntervalSince1970: 1_786_700_000)

    try runtime.markSyncing(moduleID: "governance-docs", registry: registry, now: now)
    XCTAssertEqual(try runtime.record(for: "governance-docs").state, .syncing)

    try runtime.markIdle(
      moduleID: "governance-docs",
      lastSyncAt: now.addingTimeInterval(12),
      registry: registry,
      now: now.addingTimeInterval(12))
    let idle = try runtime.record(for: "governance-docs")
    XCTAssertEqual(idle.state, .idle)
    XCTAssertEqual(idle.lastSyncAt, now.addingTimeInterval(12))
    XCTAssertNil(idle.reason)

    try runtime.markFailed(
      moduleID: "governance-docs",
      reason: "channel ACK missing",
      registry: registry,
      now: now.addingTimeInterval(20))
    let failed = try TatwoSyncModuleRuntimeStateStore(fileURL: runtime.fileURL)
      .record(for: "governance-docs")
    XCTAssertEqual(failed.state, .failed)
    XCTAssertEqual(failed.reason, "channel ACK missing")
    XCTAssertEqual(failed.lastSyncAt, now.addingTimeInterval(12))

    XCTAssertThrowsError(
      try runtime.markFailed(moduleID: "governance-docs", reason: "  ", registry: registry)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSyncModulesRegistryError,
        .failedStateRequiresReason("governance-docs"))
    }
    XCTAssertThrowsError(
      try runtime.markFailed(
        moduleID: "governance-docs",
        reason: "one\ntwo",
        registry: registry)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSyncModulesRegistryError,
        .multilineFailureReason("governance-docs"))
    }
  }

  func testResolvedModulesJoinRegistryEnablementAndRuntimeForVisualRound() throws {
    let registry = try TatwoSyncModulesRegistry.load(
      from: repositoryRoot().appendingPathComponent("config/sync-modules.v1.json"))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-sync-modules-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let enablement = TatwoSyncModuleEnablementStore(
      fileURL: directory.appendingPathComponent("e.json"))
    let runtime = TatwoSyncModuleRuntimeStateStore(
      fileURL: directory.appendingPathComponent("r.json"))
    try enablement.setEnabled(false, moduleID: "skillet-bundle-lane", registry: registry)
    try runtime.markFailed(
      moduleID: "skillet-bundle-lane",
      reason: "peer unsigned",
      lastSyncAt: Date(timeIntervalSince1970: 50),
      registry: registry)

    let resolved = try registry.resolvedModules(enablement: enablement, runtime: runtime)
    XCTAssertEqual(resolved.count, 13)
    XCTAssertNotNil(resolved.first { $0.id == "os-skillet-md" })
    let skillet = try XCTUnwrap(resolved.first { $0.id == "skillet-bundle-lane" })
    XCTAssertFalse(skillet.enabled)
    XCTAssertEqual(skillet.runState, .failed)
    XCTAssertEqual(skillet.reason, "peer unsigned")
    XCTAssertEqual(skillet.lastSyncAt, Date(timeIntervalSince1970: 50))
    XCTAssertEqual(skillet.definition.section, .data)

    let threads = try XCTUnwrap(resolved.first { $0.id == "threads" })
    XCTAssertFalse(threads.enabled)
    XCTAssertTrue(threads.definition.excluded)
    XCTAssertEqual(threads.runState, .idle)
  }

  private func sampleModule(
    id: String,
    section: TatwoSyncModuleSectionV1,
    titleZh: String = "標題",
    plainZh: String = "白話一行",
    excluded: Bool = false
  ) -> TatwoSyncModuleDefinitionV1 {
    TatwoSyncModuleDefinitionV1(
      id: id,
      section: section,
      titleZh: titleZh,
      plainZh: plainZh,
      transport: .manual,
      enabled: false,
      owningPaths: ["Package.swift"],
      excluded: excluded,
      notes: "")
  }

  private func requiredModules(
    replacing replacements: [TatwoSyncModuleDefinitionV1]
  ) -> [TatwoSyncModuleDefinitionV1] {
    let byID = Dictionary(uniqueKeysWithValues: replacements.map { ($0.id, $0) })
    return TatwoSyncModulesRegistry.requiredModuleIDs.map { id in
      if let replacement = byID[id] { return replacement }
      return sampleModule(
        id: id,
        section: id == "os-app-version" || id == "cli-version"
          ? .version
          : (id == "remote-loops-dispatch" || id == "device-pressure" || id == "device-trust"
            ? .compute
            : .data),
        excluded: id == "threads")
    }
  }

  private func repositoryRoot() -> URL {
    if let override = ProcessInfo.processInfo.environment["TATWO_REPOSITORY_ROOT"],
      !override.isEmpty
    {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
