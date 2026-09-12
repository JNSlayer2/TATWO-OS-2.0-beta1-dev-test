import XCTest

@testable import TatwoUltraworkCore

final class ChatRouteProfileResolveTests: XCTestCase {
  func testDefaultsExposeVerifiedGPT56CatalogAndRetireGPT52() throws {
    XCTAssertEqual(
      Array(TatwoChatRouteProfile.defaults.prefix(4).map(\.id)),
      ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"])
    XCTAssertFalse(TatwoChatRouteProfile.defaults.contains { $0.id == "gpt-5.2" })

    for slug in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
      let profile = TatwoChatRouteProfile.resolve(slug)
      XCTAssertEqual(profile.id, slug)
      XCTAssertEqual(profile.family, "Codex/GPT")
      XCTAssertEqual(profile.engine, .codex)
      XCTAssertEqual(profile.modelArgument, slug)
      XCTAssertTrue(profile.supportsImageInput)
    }

    XCTAssertEqual(TatwoChatRouteProfile.resolve("").runtimeAdapter, .unavailable)
    XCTAssertEqual(TatwoChatRouteProfile.resolve("gpt-5.2").runtimeAdapter, .unavailable)
    XCTAssertEqual(TatwoChatRouteProfile.resolve("gpt-5.2").canonicalModelSlug, "gpt-5.2")
  }

  func testClaudeNativeRoutesAcceptImagesThroughReadRescue() {
    for id in ["haiku4.5", "sonnet5", "opus5"] {
      let profile = TatwoChatRouteProfile.resolve(id)
      XCTAssertEqual(profile.runtimeAdapter, .claudeCLI, id)
      XCTAssertTrue(profile.supportsImageInput, id)
      XCTAssertTrue(profile.acceptsAttachmentPath("/tmp/reference.png"), id)
      XCTAssertTrue(profile.acceptsAttachmentPath("/tmp/notes.txt"), id)
    }
  }

  func testNonClaudeRoutesRejectImagesExceptGrokBuild() {
    // 2026-08-21 使用者裁決：grok 多模態，圖片輸入開通（LANE-C C3）
    for id in ["minimax-m3", "grok-build"] {
      let profile = TatwoChatRouteProfile.resolve(id)
      XCTAssertEqual(
        profile.runtimeAdapter,
        id == "minimax-m3" ? .minimaxDirect : .grokCLI,
        id)
      if id == "grok-build" {
        XCTAssertTrue(profile.supportsImageInput, id)
        XCTAssertTrue(profile.acceptsAttachmentPath("/tmp/reference.png"), id)
      } else {
        XCTAssertFalse(profile.supportsImageInput, id)
        XCTAssertFalse(profile.acceptsAttachmentPath("/tmp/reference.png"), id)
      }
      XCTAssertTrue(profile.acceptsAttachmentPath("/tmp/notes.txt"), id)
    }
  }

  func testResolveAcceptsCanonicalClaudeAndFableSlugs() throws {
    for alias in [
      "haiku4.5",
      "haiku-4-5",
      "claude-haiku-4-5",
      "haiku",
    ] {
      let profile = TatwoChatRouteProfile.resolve(alias)
      XCTAssertEqual(profile.id, "haiku4.5", alias)
      XCTAssertEqual(profile.displayName, "haiku4.5", alias)
      XCTAssertEqual(profile.canonicalModelSlug, "haiku-4-5", alias)
      XCTAssertEqual(profile.modelArgument, "haiku-4-5", alias)
    }
    for unavailable in ["haiku4.6", "haiku-4-6", "claude-haiku-4-6"] {
      XCTAssertEqual(TatwoChatRouteProfile.resolve(unavailable).runtimeAdapter, .unavailable)
    }
    XCTAssertEqual(TatwoChatRouteProfile.resolve("sonnet4.6").id, "sonnet5")
    XCTAssertEqual(TatwoChatRouteProfile.resolve("sonnet-4-6").id, "sonnet5")
    XCTAssertEqual(TatwoChatRouteProfile.resolve("claude-sonnet-4-6").id, "sonnet5")
    XCTAssertEqual(TatwoChatRouteProfile.resolve("sonnet-5").id, "sonnet5")
    XCTAssertEqual(TatwoChatRouteProfile.resolve("sonnet5").id, "sonnet5")
    XCTAssertEqual(TatwoChatRouteProfile.resolve("fable-5").id, "fable5")
    XCTAssertEqual(TatwoChatRouteProfile.resolve("fable").id, "fable5")
    XCTAssertEqual(TatwoChatRouteProfile.resolve("opus-5").id, "opus5")
    XCTAssertEqual(TatwoChatRouteProfile.resolve("opus5").id, "opus5")
    XCTAssertEqual(TatwoChatRouteProfile.resolve("claude-opus-5").id, "opus5")
    XCTAssertEqual(TatwoChatRouteProfile.resolve("opus").id, "opus5")
  }

  func testUnknownRoutePlansFailClosedWithoutInvokingCodexOrGateway() {
    let route = TatwoChatRouteProfile.resolve("future-model-that-is-not-installed")
    let plan = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: route,
      turn: "must not be sent upstream",
      workingDirectoryPath: "/tmp/tatwo-chat",
      permissionPreset: .askFirst,
      effort: .low,
      gatewayDirectScriptPath: "/tmp/tatwo-direct-gateway-chat.mjs")

    XCTAssertEqual(route.runtimeAdapter, .unavailable)
    XCTAssertEqual(plan.runtimeAdapter, .unavailable)
    XCTAssertEqual(plan.executable, "/usr/bin/false")
    XCTAssertFalse(plan.arguments.contains("must not be sent upstream"))
  }
}
