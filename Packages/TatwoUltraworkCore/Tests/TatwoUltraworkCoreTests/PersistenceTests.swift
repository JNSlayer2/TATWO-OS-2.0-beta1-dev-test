import XCTest

@testable import TatwoUltraworkCore

final class PersistenceTests: XCTestCase {
  func testPreferenceStorePersistsModePluginAndSafeMemory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoPreferenceStore(fileURL: root.appendingPathComponent("preferences.json"))

    var preferences = try store.updateMode(.xl, scenario: .coding)
    XCTAssertEqual(preferences.selectedMode, .xl)
    XCTAssertEqual(preferences.selectedScenario, .coding)

    preferences = try store.setPluginDecision(pluginID: "chatgpt-pro-mcp", action: .later)
    XCTAssertEqual(preferences.pluginDecisions["chatgpt-pro-mcp"], .later)

    preferences = try store.appendSafeMemory(
      SafeMemoryReceipt(
        id: "m1", category: .failureMode, summary: "UI needs screenshot hash before pass",
        tags: ["ui", "gate"]))
    XCTAssertEqual(preferences.safeMemories.count, 1)

    let reloaded = try store.load()
    XCTAssertEqual(reloaded.selectedMode, .xl)
    XCTAssertEqual(reloaded.pluginDecisions["chatgpt-pro-mcp"], .later)
    XCTAssertEqual(reloaded.safeMemories.first?.id, "m1")
  }

  func testPreferenceStoreRejectsUnsafeMemory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoPreferenceStore(fileURL: root.appendingPathComponent("preferences.json"))

    XCTAssertThrowsError(
      try store.appendSafeMemory(
        SafeMemoryReceipt(
          id: "bad", category: .failureMode, summary: "raw log at /Users/demo/private"))
    ) { error in
      guard case TatwoPersistenceError.unsafeMemory(let reasons) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reasons.contains("unsafe_memory_content"))
    }
  }

  func testPreferenceStorePersistsExternalCodexMirrorOptInAndDefaultsLegacyFilesOff() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("preferences.json")
    let store = TatwoPreferenceStore(fileURL: fileURL)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoder.encode(TatwoUserPreferences())) as? [String: Any])
    legacyObject.removeValue(forKey: "codexThreadMirrorExternalVolumeOptIn")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: legacyObject).write(to: fileURL, options: .atomic)

    XCTAssertFalse(try store.load().codexThreadMirrorExternalVolumeOptIn)

    let enabled = try store.setCodexThreadMirrorExternalVolumeOptIn(true)
    XCTAssertTrue(enabled.codexThreadMirrorExternalVolumeOptIn)
    XCTAssertTrue(try store.load().codexThreadMirrorExternalVolumeOptIn)
  }

  /// 2026-08-27 staging launch blocker：LaunchServices 啟動的 staging bundle 之後
  /// HOME 是真實家目錄，隔離改靠 TATWO_STAGING_SCRATCH_HOME。preference store 落到
  /// HOME fallback 時必須 fail-closed 導回 scratch home，不得寫進正式 App Support。
  func testDefaultStoreKeepsStagingPreferencesOutOfRealHomeWhenScratchHomeIsSet() {
    let store = TatwoPreferenceStore.defaultStore(environment: [
      "HOME": "/Users/example",
      "TATWO_STAGING_SCRATCH_HOME": "/staging/runtime-58/home",
    ])

    XCTAssertEqual(
      store.fileURL.path,
      "/staging/runtime-58/home/Library/Application Support/Tatwo Ultrawork/preferences.json")
    XCTAssertFalse(store.fileURL.path.hasPrefix("/Users/example"))
  }

  func testDefaultStorePrefersExplicitStateDirOverStagingScratchHome() {
    let store = TatwoPreferenceStore.defaultStore(environment: [
      "HOME": "/Users/example",
      "TATWO_STAGING_SCRATCH_HOME": "/staging/runtime-58/home",
      "TATWO_ULTRAWORK_STATE_DIR": "/staging/runtime-58/state",
    ])

    XCTAssertEqual(store.fileURL.path, "/staging/runtime-58/state/preferences.json")
  }

  func testDefaultStoreIgnoresBlankScratchHomeAndKeepsFormalHomeLayout() {
    let store = TatwoPreferenceStore.defaultStore(environment: [
      "HOME": "/Users/example",
      "TATWO_STAGING_SCRATCH_HOME": "   ",
    ])

    XCTAssertEqual(
      store.fileURL.path,
      "/Users/example/Library/Application Support/Tatwo Ultrawork/preferences.json")
  }
}
