import XCTest

@testable import TatwoUltraworkCore

final class GatewayHealthProbeTests: XCTestCase {
  func testDecoderSeparatesHealthyRuntimeFromDegradedRoute() throws {
    let health = """
      {
        "ok": true,
        "routes": {
          "sonnet-4-6": {
            "attempts": 1,
            "has_error": false,
            "error_kind": null,
            "observed_at": "2026-07-14T18:01:39.714Z",
            "last_ok_at": "2026-07-14T18:01:39.714Z"
          },
          "grok-build": {
            "has_error": true,
            "error_kind": "model",
            "last_ok_at": null,
            "last_error_at": "2026-07-14T18:01:29.869Z"
          }
        }
      }
      """.data(using: .utf8)!
    let catalog = """
      {"object":"list","data":[{"id":"sonnet-4-6"},{"id":"grok-build"}]}
      """.data(using: .utf8)!

    let result = TatwoGatewayHealthDecoder.decode(
      healthData: health,
      catalogData: catalog,
      endpoint: URL(string: "http://127.0.0.1:4177")!,
      requiredRouteIDs: ["sonnet-4-6", "grok-build"]
    )

    XCTAssertEqual(result.runtimeState, .healthy)
    XCTAssertEqual(result.routeState, .degraded)
    XCTAssertEqual(result.catalogModelCount, 2)
    XCTAssertEqual(result.failedRoutes.map(\.id), ["grok-build"])
    XCTAssertTrue(result.directRouteSummary.contains("降級"))
  }

  func testDecoderAcceptsEmbeddedHealthzRoutesAlias() {
    let health = """
      {
        "ok": true,
        "healthz.routes": {
          "fable-5": {
            "attempts": 1,
            "has_error": false,
            "error_kind": null,
            "observed_at": "2026-07-14T18:05:24.508Z",
            "last_ok_at": "2026-07-14T18:05:24.508Z"
          }
        }
      }
      """.data(using: .utf8)!
    let catalog = """
      {"data":[{"slug":"fable-5"}]}
      """.data(using: .utf8)!

    let result = TatwoGatewayHealthDecoder.decode(
      healthData: health,
      catalogData: catalog,
      endpoint: URL(string: "http://127.0.0.1:4177")!,
      requiredRouteIDs: ["fable-5"],
      checkedAt: ISO8601DateFormatter().date(from: "2026-07-14T18:10:00Z")!
    )

    XCTAssertEqual(result.runtimeState, .healthy)
    XCTAssertEqual(result.routeState, .healthy)
    XCTAssertEqual(result.routes.first?.id, "fable-5")
  }

  func testDecoderDoesNotCountUnattemptedHasErrorFalseRouteAsProbed() {
    let health = """
      {
        "ok": true,
        "routes": {
          "haiku-4-5": {
            "attempts": 0,
            "has_error": false,
            "last_ok_at": null,
            "last_error_at": null
          }
        }
      }
      """.data(using: .utf8)!
    let catalog = """
      {"data":[{"slug":"haiku-4-5"}]}
      """.data(using: .utf8)!

    let result = TatwoGatewayHealthDecoder.decode(
      healthData: health,
      catalogData: catalog,
      endpoint: URL(string: "http://127.0.0.1:4177")!,
      requiredRouteIDs: ["haiku-4-5"]
    )

    XCTAssertEqual(result.probedRouteCount, 0)
    XCTAssertEqual(result.routeState, .unknown)
  }

  func testDecoderDoesNotTreatAttemptWithoutTimestampAsHealthy() throws {
    let health = """
      {
        "ok": true,
        "routes": {
          "fable-5": {
            "attempts": 1,
            "has_error": false,
            "last_ok_at": null,
            "last_error_at": null
          }
        }
      }
      """.data(using: .utf8)!
    let catalog = """
      {"data":[{"slug":"fable-5"}]}
      """.data(using: .utf8)!

    let result = TatwoGatewayHealthDecoder.decode(
      healthData: health,
      catalogData: catalog,
      endpoint: URL(string: "http://127.0.0.1:4177")!,
      requiredRouteIDs: ["fable-5"]
    )

    XCTAssertEqual(try XCTUnwrap(result.routes.first).attempts, 1)
    XCTAssertEqual(result.probedRouteCount, 1)
    XCTAssertEqual(result.routeState, .unknown)
  }

  func testDecoderDoesNotTrustAttemptCountWithoutExplicitOutcome() {
    let health = """
      {
        "ok": true,
        "routes": {
          "fable-5": {
            "attempts": 1
          }
        }
      }
      """.data(using: .utf8)!
    let catalog = """
      {"data":[{"slug":"fable-5"}]}
      """.data(using: .utf8)!

    let result = TatwoGatewayHealthDecoder.decode(
      healthData: health,
      catalogData: catalog,
      endpoint: URL(string: "http://127.0.0.1:4177")!,
      requiredRouteIDs: ["fable-5"]
    )

    XCTAssertEqual(result.probedRouteCount, 1)
    XCTAssertEqual(result.healthyRouteCount, 0)
    XCTAssertEqual(result.routeState, .unknown)
  }

  func testRouteHealthReceiptV2RejectsMissingRequiredFields() throws {
    let health = Data(
      """
      {
        "ok": true,
        "routes": {
          "fable-5": {
            "attempts": 1,
            "has_error": false,
            "last_ok_at": "2026-07-18T12:00:00Z"
          }
        }
      }
      """.utf8)
    let catalog = Data(#"{"data":[{"id":"fable-5"}]}"#.utf8)
    let checkedAt = ISO8601DateFormatter().date(from: "2026-07-18T12:05:00Z")!

    let result = TatwoGatewayHealthDecoder.decode(
      healthData: health,
      catalogData: catalog,
      endpoint: URL(string: "http://127.0.0.1:4177")!,
      requiredRouteIDs: ["fable-5"],
      checkedAt: checkedAt)

    let route = try XCTUnwrap(result.routes.first)
    XCTAssertFalse(route.requiredV2FieldsPresent)
    XCTAssertFalse(route.routeHealthReceiptV2.isComplete)
    XCTAssertEqual(result.routeState, .unknown)
  }

  func testRouteHealthReceiptV2RequiresFreshObservedAtAndLastOKAt() {
    let checkedAt = ISO8601DateFormatter().date(from: "2026-07-18T12:10:00Z")!
    let valid = TatwoRouteHealthReceiptV2(
      attempts: 1,
      hasError: false,
      errorKind: nil,
      observedAt: "2026-07-18T12:09:00Z",
      lastOKAt: "2026-07-18T12:09:00Z")
    XCTAssertTrue(valid.isHealthy(at: checkedAt))

    let stale = TatwoRouteHealthReceiptV2(
      attempts: 1,
      hasError: false,
      errorKind: nil,
      observedAt: "2026-07-18T11:00:00Z",
      lastOKAt: "2026-07-18T11:00:00Z")
    XCTAssertFalse(stale.isHealthy(at: checkedAt))

    let invalid = TatwoRouteHealthReceiptV2(
      attempts: 1,
      hasError: false,
      errorKind: nil,
      observedAt: "not-a-date",
      lastOKAt: "not-a-date")
    XCTAssertFalse(invalid.isHealthy(at: checkedAt))
  }

  func testRouteHealthReceiptV2RequiresExactSchema() throws {
    let checkedAt = ISO8601DateFormatter().date(from: "2026-07-18T12:10:00Z")!
    let wrongSchema = TatwoRouteHealthReceiptV2(
      schema: "TatwoRouteHealthReceiptV1",
      attempts: 1,
      hasError: false,
      errorKind: nil,
      observedAt: "2026-07-18T12:09:00Z",
      lastOKAt: "2026-07-18T12:09:00Z")
    XCTAssertFalse(wrongSchema.isComplete)
    XCTAssertFalse(wrongSchema.isHealthy(at: checkedAt))

    let missingSchemaData = Data(
      """
      {
        "attempts": 1,
        "has_error": false,
        "error_kind": null,
        "observed_at": "2026-07-18T12:09:00Z",
        "last_ok_at": "2026-07-18T12:09:00Z"
      }
      """.utf8)
    let missingSchema = try JSONDecoder().decode(
      TatwoRouteHealthReceiptV2.self,
      from: missingSchemaData)
    XCTAssertFalse(missingSchema.isComplete)
    XCTAssertFalse(missingSchema.isHealthy(at: checkedAt))
  }

  func testRouteHealthReceiptV2EncodesNullableRequiredFields() throws {
    let receipt = TatwoRouteHealthReceiptV2(
      attempts: 0,
      hasError: false,
      errorKind: nil,
      observedAt: nil,
      lastOKAt: nil)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])

    for key in ["attempts", "has_error", "error_kind", "observed_at", "last_ok_at"] {
      XCTAssertNotNil(object[key], "Required wire key \(key) must be serialized, even when null.")
    }
    XCTAssertFalse(receipt.isHealthy(at: Date()))
  }

  func testDecoderTreatsErrorKindAsActiveFailureWhenHasErrorIsMissing() {
    let health = """
      {
        "ok": true,
        "routes": {
          "fable-5": {
            "attempts": 1,
            "error_kind": "quota",
            "last_error_at": "2026-07-15T05:30:00Z"
          }
        }
      }
      """.data(using: .utf8)!
    let catalog = """
      {"data":[{"id":"fable-5"}]}
      """.data(using: .utf8)!

    let result = TatwoGatewayHealthDecoder.decode(
      healthData: health,
      catalogData: catalog,
      endpoint: URL(string: "http://127.0.0.1:4177")!,
      requiredRouteIDs: ["fable-5"]
    )

    XCTAssertEqual(result.routeState, .degraded)
    XCTAssertEqual(result.failedRoutes.map(\.id), ["fable-5"])
  }

  func testDecoderDoesNotMarkRoutesHealthyWhenARequiredRouteIsMissing() {
    let health = """
      {
        "ok": true,
        "routes": {
          "fable-5": {
            "attempts": 1,
            "has_error": false
          }
        }
      }
      """.data(using: .utf8)!
    let catalog = """
      {"data":[{"id":"fable-5"},{"id":"sonnet-4-6"}]}
      """.data(using: .utf8)!

    let result = TatwoGatewayHealthDecoder.decode(
      healthData: health,
      catalogData: catalog,
      endpoint: URL(string: "http://127.0.0.1:4177")!,
      requiredRouteIDs: ["fable-5", "sonnet-4-6"]
    )

    XCTAssertEqual(result.routeState, .unknown)
    XCTAssertEqual(result.missingRequiredRouteIDs, ["sonnet-4-6"])
  }

  func testDecoderDegradesWhenARequiredRouteIsMissingFromCatalog() {
    let health = """
      {
        "ok": true,
        "routes": {
          "fable-5": {
            "attempts": 1,
            "has_error": false
          },
          "sonnet-4-6": {
            "attempts": 1,
            "has_error": false
          }
        }
      }
      """.data(using: .utf8)!
    let catalog = """
      {"data":[{"id":"fable-5"}]}
      """.data(using: .utf8)!

    let result = TatwoGatewayHealthDecoder.decode(
      healthData: health,
      catalogData: catalog,
      endpoint: URL(string: "http://127.0.0.1:4177")!,
      requiredRouteIDs: ["fable-5", "sonnet-4-6"]
    )

    XCTAssertEqual(result.routeState, .degraded)
    XCTAssertEqual(result.missingRequiredCatalogRouteIDs, ["sonnet-4-6"])
  }

  func testDecoderRejectsStaleSuccessAndNewerErrorEvenWhenHasErrorIsFalse() {
    let health = """
      {
        "ok": true,
        "routes": {
          "fable-5": {
            "attempts": 3,
            "has_error": false,
            "last_ok_at": "2026-07-15T05:00:00Z",
            "last_error_at": "2026-07-15T05:20:00Z"
          },
          "sonnet-5": {
            "attempts": 2,
            "has_error": false,
            "last_ok_at": "2026-07-15T04:00:00Z"
          }
        }
      }
      """.data(using: .utf8)!
    let catalog = """
      {"data":[{"id":"fable-5"},{"id":"sonnet-5"}]}
      """.data(using: .utf8)!

    let result = TatwoGatewayHealthDecoder.decode(
      healthData: health,
      catalogData: catalog,
      endpoint: URL(string: "http://127.0.0.1:4177")!,
      requiredRouteIDs: ["fable-5", "sonnet-5"],
      checkedAt: ISO8601DateFormatter().date(from: "2026-07-15T05:30:00Z")!)

    XCTAssertEqual(result.routeState, .degraded)
    XCTAssertEqual(result.failedRoutes.map(\.id), ["fable-5"])
    XCTAssertEqual(result.healthyRouteCount, 0)
  }

  func testCurrentProbeDiscoversWellKnownGatewaySkillWithoutWritingHostState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let marker = home.appendingPathComponent(".codex/skills/codex-app-model-gateway/scripts")
    try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
    try "read-only marker".write(
      to: marker.appendingPathComponent("post-update-check.sh"),
      atomically: true,
      encoding: .utf8
    )

    let probe = TatwoEnvironmentProbe.current(environment: [
      "HOME": home.path,
      "TATWO_ULTRAWORK_APP_SUPPORT": root.appendingPathComponent("support").path,
    ])

    XCTAssertEqual(
      probe.gatewayRoot?.path,
      home.appendingPathComponent(".codex/skills/codex-app-model-gateway").path
    )
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: root.appendingPathComponent("host-mutated").path))
  }

  func testDoctorUsesLiveGatewaySignalsButKeepsSameThreadUnverified() throws {
    let live = TatwoGatewayLiveStatus(
      endpoint: "http://127.0.0.1:4177",
      runtimeState: .healthy,
      routeState: .degraded,
      healthOK: true,
      catalogAvailable: true,
      catalogModelCount: 12,
      routes: [
        TatwoGatewayRouteObservation(
          id: "grok-build",
          attempts: 1,
          hasError: true,
          errorKind: "model",
          lastOKAt: nil,
          lastErrorAt: "2026-07-14T18:01:29.869Z"
        )
      ]
    )
    let report = DoctorFactory.staticReport(
      chatGPTProMCPCheck: DoctorCheck(
        id: "chatgpt-pro-mcp",
        title: "ChatGPT Pro MCP",
        status: .installed,
        severity: .critical,
        message: "test"
      ),
      gatewayLiveStatus: live
    )

    XCTAssertEqual(report.checks.first { $0.id == "gateway-contract" }?.status, .installed)
    XCTAssertEqual(report.checks.first { $0.id == "gateway-route-health" }?.status, .missing)
    XCTAssertEqual(report.checks.first { $0.id == "gateway-thread-continuity" }?.status, .unknown)
    XCTAssertTrue(report.blockingReasons.contains { $0.contains("gateway-route-health:missing") })
  }

  func testDispatchGateAllowsOnlyFreshHealthySelectedRoute() {
    let checkedAt = ISO8601DateFormatter().date(from: "2026-07-15T05:30:00Z")!
    let status = TatwoGatewayLiveStatus(
      endpoint: "http://127.0.0.1:4177",
      runtimeState: .healthy,
      routeState: .degraded,
      healthOK: true,
      catalogAvailable: true,
      catalogModelCount: 2,
      routes: [
        TatwoGatewayRouteObservation(
          id: "fable-5",
          attempts: 2,
          hasError: false,
          errorKind: nil,
          observedAt: "2026-07-15T05:25:00Z",
          lastOKAt: "2026-07-15T05:25:00Z",
          lastErrorAt: nil
        ),
        TatwoGatewayRouteObservation(
          id: "grok-build",
          attempts: 1,
          hasError: true,
          errorKind: "quota",
          lastOKAt: nil,
          lastErrorAt: "2026-07-15T05:20:00Z"
        ),
      ],
      requiredRouteIDs: ["fable-5", "grok-build"],
      catalogRouteIDs: ["fable-5", "grok-build"],
      checkedAt: checkedAt
    )

    XCTAssertEqual(
      TatwoGatewayDispatchGate.evaluate(
        status: status,
        modelID: "fable5",
        now: checkedAt),
      .allowed
    )
    XCTAssertEqual(
      TatwoGatewayDispatchGate.evaluate(
        status: status,
        modelID: "grok-build",
        now: checkedAt),
      .blocked(reason: "blocker_class=quota;retry_allowed=false")
    )
  }

  func testDispatchGatePreservesSessionLimitRecoveryMetadata() throws {
    let checkedAt = ISO8601DateFormatter().date(from: "2026-07-15T05:30:00Z")!
    let health = Data(
      """
      {
        "ok": true,
        "routes": {
          "fable-5": {
            "attempts": 1,
            "has_error": true,
            "error_kind": "session_limit",
            "last_error_at": "2026-07-15T05:29:00Z",
            "reset_at": "2026-07-15T08:20:00+09:00",
            "retry_allowed": false
          }
        }
      }
      """.utf8)
    let catalog = Data(#"{"data":[{"id":"fable-5"}]}"#.utf8)
    let status = TatwoGatewayHealthDecoder.decode(
      healthData: health,
      catalogData: catalog,
      endpoint: URL(string: "http://127.0.0.1:4177/healthz")!,
      requiredRouteIDs: ["fable-5"],
      checkedAt: checkedAt)

    let route = try XCTUnwrap(status.routes.first)
    XCTAssertEqual(route.resetAt, "2026-07-15T08:20:00+09:00")
    XCTAssertEqual(route.retryAllowed, false)
    XCTAssertEqual(
      TatwoGatewayDispatchGate.evaluate(
        status: status,
        modelID: "fable-5",
        now: checkedAt),
      .blocked(
        reason: "blocker_class=session_limit;reset_at=2026-07-15T08:20:00+09:00;retry_allowed=false"))
  }

  func testOperationalBlockerDescriptorParsesStructuredReason() throws {
    let descriptor = try XCTUnwrap(
      TatwoOperationalBlockerDescriptor.parse(
        "PLG dispatch blocked：blocker_class=session_limit;"
          + "reset_at=2026-07-15T08:20:00+09:00;retry_allowed=false"))

    XCTAssertEqual(descriptor.blockerClass, "session_limit")
    XCTAssertEqual(descriptor.resetAt, "2026-07-15T08:20:00+09:00")
    XCTAssertEqual(descriptor.retryAllowed, false)
    XCTAssertEqual(descriptor.retryDisplay, "禁止自動重試")
  }

  func testDispatchGateRejectsMissingStaleOrUncataloguedRouteHealth() {
    XCTAssertEqual(
      TatwoGatewayDispatchGate.evaluate(status: nil, modelID: "fable-5"),
      .blocked(reason: "gateway_health_unavailable")
    )

    let checkedAt = ISO8601DateFormatter().date(from: "2026-07-15T05:30:00Z")!
    let stale = TatwoGatewayLiveStatus(
      endpoint: "http://127.0.0.1:4177",
      runtimeState: .healthy,
      routeState: .unknown,
      healthOK: true,
      catalogAvailable: true,
      catalogModelCount: 1,
      routes: [
        TatwoGatewayRouteObservation(
          id: "fable-5",
          attempts: 1,
          hasError: false,
          errorKind: nil,
          observedAt: "2026-07-15T04:00:00Z",
          lastOKAt: "2026-07-15T04:00:00Z",
          lastErrorAt: nil
        )
      ],
      requiredRouteIDs: ["fable-5"],
      catalogRouteIDs: ["fable-5"],
      checkedAt: checkedAt
    )
    XCTAssertEqual(
      TatwoGatewayDispatchGate.evaluate(
        status: stale,
        modelID: "fable-5",
        now: checkedAt),
      .blocked(reason: "route_health_unknown:fable-5")
    )

    let uncatalogued = TatwoGatewayLiveStatus(
      endpoint: "http://127.0.0.1:4177",
      runtimeState: .healthy,
      routeState: .degraded,
      healthOK: true,
      catalogAvailable: true,
      catalogModelCount: 1,
      routes: stale.routes,
      requiredRouteIDs: ["fable-5"],
      catalogRouteIDs: ["gpt-5.5"],
      checkedAt: checkedAt
    )
    XCTAssertEqual(
      TatwoGatewayDispatchGate.evaluate(
        status: uncatalogued,
        modelID: "fable-5",
        now: checkedAt),
      .blocked(reason: "route_catalog_missing:fable-5")
    )

    XCTAssertEqual(
      TatwoGatewayDispatchGate.evaluate(
        status: stale,
        modelID: "fable-5",
        now: checkedAt.addingTimeInterval(16 * 60)),
      .blocked(reason: "gateway_health_stale")
    )
  }

  func testLiveProbeConvertsTimeoutToUnknownWithoutThrowing() async {
    let result = await TatwoGatewayLiveProbe.fetch(
      endpoint: URL(string: "http://127.0.0.1:4177")!,
      timeout: 0.01,
      dataLoader: { _, timeout in
        XCTAssertEqual(timeout, 0.01)
        throw URLError(.timedOut)
      }
    )

    XCTAssertEqual(result.runtimeState, .unknown)
    XCTAssertEqual(result.routeState, .unknown)
    XCTAssertFalse(result.healthOK)
    XCTAssertEqual(result.errorMessage, "healthz request failed")
  }
}
