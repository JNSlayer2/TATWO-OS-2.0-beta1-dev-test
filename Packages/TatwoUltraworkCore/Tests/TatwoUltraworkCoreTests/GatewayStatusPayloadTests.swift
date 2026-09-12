import XCTest

@testable import TatwoUltraworkCore

final class GatewayStatusPayloadTests: XCTestCase {
  func testReachabilityWithoutRouteHealthV2IsNeverHealthy() {
    XCTAssertEqual(
      TatwoMCPRegistry.gatewayStatusClassification(
        liveHealthReachable: true,
        routeHealthV2Verified: false),
      "reachable_unverified")
    XCTAssertNotEqual(
      TatwoMCPRegistry.gatewayStatusClassification(
        liveHealthReachable: true,
        routeHealthV2Verified: false),
      "healthy_or_reachable")
  }

  func testVerifiedRouteHealthV2HasDistinctStatus() {
    XCTAssertEqual(
      TatwoMCPRegistry.gatewayStatusClassification(
        liveHealthReachable: true,
        routeHealthV2Verified: true),
      "route_health_v2_verified")
  }
}
