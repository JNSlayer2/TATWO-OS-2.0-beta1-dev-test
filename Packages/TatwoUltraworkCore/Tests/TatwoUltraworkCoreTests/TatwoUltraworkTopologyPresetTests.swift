import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoUltraworkTopologyPresetTests: XCTestCase {
  private let updatedAt = Date(timeIntervalSince1970: 1_777_777_777)

  func testPresetConvertsToAndFromLoopsConfig() throws {
    let preset = TatwoUltraworkTopologyPresetV1(
      presetID: "daily-xl",
      displayName: "日常 XL",
      scenarioID: "code",
      mode: .xl,
      primaryModelID: "fable-5",
      subModelIDs: ["gpt-5.6-sol", "gpt-5.6-terra"],
      tokenBudget: "350k",
      updatedAt: updatedAt,
      identitySummary: "lead=fable-5；builder=gpt-5.6-sol；verifier=gpt-5.6-terra")

    let config = preset.loopsConfig()
    XCTAssertEqual(config.scenarioID, "code")
    XCTAssertEqual(config.mode, .xl)
    XCTAssertEqual(config.primaryModelID, "fable-5")
    XCTAssertEqual(config.secondaryModelID, "gpt-5.6-sol")
    XCTAssertEqual(config.identitySummary, preset.identitySummary)

    let restored = TatwoUltraworkTopologyPresetV1(
      from: config,
      presetID: "restored",
      displayName: "Restored",
      updatedAt: updatedAt)
    XCTAssertEqual(restored.scenarioID, preset.scenarioID)
    XCTAssertEqual(restored.mode, preset.mode)
    XCTAssertEqual(restored.primaryModelID, preset.primaryModelID)
    XCTAssertEqual(restored.subModelIDs, ["gpt-5.6-sol"])
    XCTAssertEqual(restored.tokenBudget, preset.tokenBudget)
    XCTAssertEqual(restored.identitySummary, preset.identitySummary)
  }

  func testCanonicalEncodingIsStableAndSorted() throws {
    let preset = TatwoUltraworkTopologyPresetV1(
      presetID: "daily-m",
      displayName: "日常 M",
      scenarioID: "code",
      mode: .m,
      primaryModelID: "fable-5",
      subModelIDs: ["gpt-5.6-sol"],
      tokenBudget: "120k",
      updatedAt: updatedAt)

    let first = try preset.canonicalData()
    let second = try preset.canonicalData()
    XCTAssertEqual(first, second)
    XCTAssertTrue(String(decoding: first, as: UTF8.self).hasPrefix("{\"displayName\""))
    XCTAssertEqual(try JSONDecoder.tatwoTopologyPreset.decode(
      TatwoUltraworkTopologyPresetV1.self, from: first), preset)
  }

  func testStoreSurvivesReinitializationAndTracksDefault() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let preset = makePreset(id: "daily-xl")

    let first = TatwoUltraworkTopologyPresetStore(directoryURL: directory)
    try first.save(preset)
    try first.setDefault(id: preset.presetID)

    let restarted = TatwoUltraworkTopologyPresetStore(directoryURL: directory)
    XCTAssertEqual(restarted.list(), [preset])
    XCTAssertEqual(restarted.defaultPreset(), preset)
  }

  func testStoreReturnsEmptyForCorruptFile() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("not-json".utf8).write(
      to: directory.appendingPathComponent("ultrawork-topology-presets.json"))

    let store = TatwoUltraworkTopologyPresetStore(directoryURL: directory)
    XCTAssertEqual(store.list(), [])
    XCTAssertNil(store.defaultPreset())
  }

  func testStoreAtomicallyReplacesCanonicalDocumentAndDeletesPreset() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TatwoUltraworkTopologyPresetStore(directoryURL: directory)
    let old = makePreset(id: "old")
    let replacement = makePreset(id: "new")

    try store.save(old)
    try store.setDefault(id: old.presetID)
    try store.save(replacement)
    try store.delete(id: old.presetID)

    XCTAssertEqual(store.list(), [replacement])
    XCTAssertNil(store.defaultPreset())
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(names, ["ultrawork-topology-presets.json"])
    let data = try Data(contentsOf: store.fileURL)
    XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
  }

  func testResolveForNewThreadPrefersDefaultOverLastUsed() {
    let defaultPreset = makePreset(id: "default")
    let lastUsed = makePreset(id: "last-used")

    let resolved = TatwoUltraworkTopologyPreset.resolveForNewThread(
      default: defaultPreset,
      lastUsed: lastUsed)

    XCTAssertEqual(resolved, defaultPreset.loopsConfig())
  }

  func testResolveForNewThreadFallsBackToLastUsed() {
    let lastUsed = makePreset(id: "last-used")
    XCTAssertEqual(
      TatwoUltraworkTopologyPreset.resolveForNewThread(
        default: nil,
        lastUsed: lastUsed),
      lastUsed.loopsConfig())
  }

  func testResolveForNewThreadPreservesExistingBehaviorWhenNoPresetExists() {
    XCTAssertNil(
      TatwoUltraworkTopologyPreset.resolveForNewThread(
        default: nil,
        lastUsed: nil))
  }

  private func makePreset(id: String) -> TatwoUltraworkTopologyPresetV1 {
    TatwoUltraworkTopologyPresetV1(
      presetID: id,
      displayName: id,
      scenarioID: "code",
      mode: .xl,
      primaryModelID: "fable-5",
      subModelIDs: ["gpt-5.6-sol"],
      tokenBudget: "350k",
      updatedAt: updatedAt)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-topology-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
