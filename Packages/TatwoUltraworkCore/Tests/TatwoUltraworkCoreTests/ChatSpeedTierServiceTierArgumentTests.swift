import XCTest

@testable import TatwoUltraworkCore

/// 2026-08-28 正式主 App 修復：UI 選 `standard` 時 runner 仍額外帶
/// `-c service_tier="standard"`，Codex runtime 回報該 tier 未 advertised 並忽略，
/// 每一輪都留下啟動警告。契約：`standard` 是預設，argv 不帶 `service_tier`；
/// 只有 `fast` 明確傳值。UI 仍要能保存／顯示 `standard`。
final class ChatSpeedTierServiceTierArgumentTests: XCTestCase {
  private let bundle = URL(fileURLWithPath: "/tmp/Tatwo Ultrawork.app")
  private var codexHelper: String {
    bundle.appendingPathComponent("Contents/Helpers/TatwoSubscriptionRuntime").path
  }

  private func terraPlan(speedTier: TatwoModelSpeedTier) -> TatwoChatCommandPlan {
    TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: TatwoChatRouteProfile.resolve("gpt-5.6-terra"),
      turn: "只回 OK",
      workingDirectoryPath: "/tmp/tatwo-chat",
      permissionPreset: .approveForMe,
      effort: .high,
      speedTier: speedTier,
      gatewayDirectScriptPath: "/tmp/scripts/tatwo-direct-gateway-chat.mjs",
      bundleURL: bundle,
      isExecutableFile: { [codexHelper] in $0 == codexHelper })
  }

  func testStandardSpeedTierIsTheImplicitDefaultAndEmitsNoServiceTierArgument() {
    XCTAssertEqual(TatwoModelSpeedTier.standard.codexArguments, [])
    XCTAssertEqual(TatwoModelSpeedTier.fast.codexArguments, ["-c", "service_tier=\"fast\""])
  }

  func testTerraStandardChatTurnDropsServiceTierFromSpawnArgv() {
    let plan = terraPlan(speedTier: .standard)
    XCTAssertEqual(plan.engine, .codex)
    XCTAssertEqual(plan.runtimeAdapter, .codexExec)
    XCTAssertEqual(plan.executable, codexHelper)
    XCTAssertFalse(
      plan.arguments.contains { $0.hasPrefix("service_tier=") },
      "standard 是預設 tier，不得出現在 argv：\(plan.arguments)")
    XCTAssertTrue(plan.arguments.contains("model_reasoning_effort=\"high\""))
    XCTAssertTrue(plan.arguments.contains("gpt-5.6-terra"))
  }

  func testTerraFastChatTurnStillPassesServiceTierExplicitly() {
    let plan = terraPlan(speedTier: .fast)
    let index = plan.arguments.firstIndex(of: "service_tier=\"fast\"")
    XCTAssertNotNil(index, "fast 必須顯式傳遞：\(plan.arguments)")
    if let index {
      XCTAssertEqual(plan.arguments[index - 1], "-c")
    }
  }

  /// 使用者實測：standard 的 spawn argc 比 fast 少 2（`-c` + `service_tier=...`），
  /// 其餘 argv 逐項相同。
  func testStandardArgvEqualsFastArgvMinusTheServiceTierPair() {
    let standard = terraPlan(speedTier: .standard).arguments
    let fast = terraPlan(speedTier: .fast).arguments
    XCTAssertEqual(standard.count + 2, fast.count)
    var reduced = fast
    if let index = reduced.firstIndex(of: "service_tier=\"fast\"") {
      reduced.removeSubrange((index - 1)...index)
    }
    XCTAssertEqual(reduced, standard)
  }
}
