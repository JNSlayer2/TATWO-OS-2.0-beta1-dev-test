import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class GatewayDispatchPayloadTests: XCTestCase {
  func testNonDryRunDispatchRequiresFreshSelectedRouteHealth() throws {
    try withContract { contractID in
      let unavailable = TatwoMCPRegistry.gatewayDispatchPayload(
        arguments: [
          "contractID": .string(contractID),
          "model": .string("minimax-m3"),
          "prompt": .string("Return one sentence."),
        ],
        liveStatusProvider: { _ in nil })
      XCTAssertFalse(unavailable.ok)
      XCTAssertEqual(
        unavailable.error,
        "route_health_v2_required:minimax-m3:gateway_health_unavailable")

      let healthy = TatwoMCPRegistry.gatewayDispatchPayload(
        arguments: [
          "contractID": .string(contractID),
          "model": .string("sonnet-4-6"),
          "prompt": .string("Review only."),
        ],
        liveStatusProvider: { model in Self.healthyStatus(modelID: model) })
      XCTAssertTrue(healthy.ok, healthy.error ?? "")
      guard case .object(let payload)? = healthy.payload else {
        return XCTFail("expected dispatch payload")
      }
      XCTAssertEqual(payload["model"], .string("sonnet-5"))
      XCTAssertEqual(payload["routeHealthV2Verified"], .bool(true))
    }
  }

  func testFanoutPropagatesChildFailureAndKeepsChildErrorPayload() throws {
    try withContract { contractID in
      let result = TatwoMCPRegistry.call(
        tool: "tatwo.gateway.fanout",
        arguments: [
          "contractID": .string(contractID),
          "models": .array([
            .string("minimax-m3"),
            .string("not-a-real-model"),
          ]),
          "prompt": .string("Return one sentence."),
          "dryRun": .bool(true),
        ])

      XCTAssertFalse(result.ok)
      XCTAssertEqual(result.error, "gateway_fanout_child_failure")
      guard case .object(let payload)? = result.payload else {
        return XCTFail("expected partial fanout payload")
      }
      XCTAssertEqual(payload["ok"], .bool(false))
      XCTAssertEqual(payload["status"], .string("partial_or_failed"))
      guard case .array(let receipts)? = payload["receipts"] else {
        return XCTFail("expected child receipts")
      }
      XCTAssertEqual(receipts.count, 2)
      guard case .object(let failedChild) = receipts[1] else {
        return XCTFail("expected failed child envelope")
      }
      XCTAssertEqual(failedChild["ok"], .bool(false))
      XCTAssertEqual(failedChild["status"], .string("failed"))
      guard case .string(let error)? = failedChild["error"] else {
        return XCTFail("expected child error")
      }
      XCTAssertTrue(error.contains("model not allowlisted"))
    }
  }

  private func withContract<T>(
    _ body: (String) throws -> T
  ) throws -> T {
    let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-gateway-dispatch-\(UUID().uuidString)",
      isDirectory: true)
    setenv("TATWO_ULTRAWORK_APP_SUPPORT", appSupport.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_APP_SUPPORT")
      try? FileManager.default.removeItem(at: appSupport)
    }

    let begin = TatwoMCPRegistry.call(
      tool: "tatwo.os.begin",
      arguments: try WorkOSMCPBeginTestSupport.arguments(
        mode: "M",
        scenario: "coding",
        objective: "gateway dispatch health gate"))
    guard
      begin.ok,
      case .object(let payload)? = begin.payload,
      case .string(let contractID)? = payload["contractID"]
    else {
      throw NSError(
        domain: "GatewayDispatchPayloadTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "expected contractID"])
    }
    return try body(contractID)
  }

  private static func healthyStatus(modelID: String, now: Date = Date())
    -> TatwoGatewayLiveStatus
  {
    let timestamp = ISO8601DateFormatter().string(from: now)
    return TatwoGatewayLiveStatus(
      endpoint: "http://127.0.0.1:4177",
      runtimeState: .healthy,
      routeState: .healthy,
      healthOK: true,
      catalogAvailable: true,
      catalogModelCount: 1,
      routes: [
        TatwoGatewayRouteObservation(
          id: modelID,
          attempts: 1,
          hasError: false,
          errorKind: nil,
          observedAt: timestamp,
          lastOKAt: timestamp,
          lastErrorAt: nil),
      ],
      requiredRouteIDs: [modelID],
      catalogRouteIDs: [modelID],
      checkedAt: now)
  }
}
