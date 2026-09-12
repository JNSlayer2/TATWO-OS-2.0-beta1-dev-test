import XCTest

@testable import TatwoUltraworkCore

final class TatwoTransportCapabilityTests: XCTestCase {
  func testFableImageCapabilityTracksEffectiveTransport() {
    let route = TatwoChatRouteProfile.resolve("fable5")
    XCTAssertEqual(route.imageTransportCapability(), .claudeReadRescue)
    XCTAssertEqual(
      route.imageTransportCapability(requiresTatwoComputerHost: true),
      .claudeReadRescue)
  }

  func testClaudeNativeImageCapabilityUsesReadRescue() {
    let route = TatwoChatRouteProfile.resolve("sonnet5")
    XCTAssertEqual(route.runtimeAdapter, .claudeCLI)
    XCTAssertEqual(route.imageTransportCapability(), .claudeReadRescue)
  }

  func testTextOnlyGatewayRouteFailsClosedInsteadOfIgnoringImage() {
    let route = TatwoChatRouteProfile.resolve("minimax-m3")
    XCTAssertEqual(route.imageTransportCapability(), .none)
    XCTAssertFalse(route.acceptsAttachmentPath("/tmp/reference.png"))

    let plan = TatwoChatCommandPlanner.plan(
      mode: .chat,
      route: route,
      turn: "Inspect the image.",
      workingDirectoryPath: "/tmp/tatwo-chat",
      permissionPreset: .askFirst,
      effort: .low,
      droppedPaths: ["/tmp/reference.png"],
      gatewayDirectScriptPath: "/tmp/tatwo-direct-gateway-chat.mjs")

    XCTAssertEqual(plan.runtimeAdapter, .unavailable)
    XCTAssertEqual(plan.executable, "/usr/bin/false")
    XCTAssertFalse(plan.arguments.contains("/tmp/reference.png"))
  }
}
