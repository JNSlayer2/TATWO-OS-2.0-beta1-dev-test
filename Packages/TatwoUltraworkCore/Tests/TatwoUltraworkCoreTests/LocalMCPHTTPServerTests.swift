import XCTest

@testable import TatwoUltraworkCore

final class LocalMCPHTTPServerTests: XCTestCase {
  func testLocalHTTPServerExposesHealthManifestAndToolCall() async throws {
    let server = TatwoLocalMCPHTTPServer()
    let port = try server.start(port: 0)
    defer { server.stop() }

    let base = URL(string: "http://127.0.0.1:\(port)")!
    try await waitUntilReachable(base.appendingPathComponent("health"))

    let healthResponse = try await request(URLRequest(url: base.appendingPathComponent("health")))
    XCTAssertEqual(healthResponse.statusCode, 200)
    let healthData = healthResponse.data
    let healthText = String(data: healthData, encoding: .utf8) ?? ""
    XCTAssertTrue(healthText.contains("TatwoMCPHTTPHealthV1"))
    XCTAssertTrue(healthText.contains("engineAgnostic"))
    XCTAssertTrue(healthText.contains("false"), "hostMutationAllowed should stay false")

    let manifestResponse = try await request(URLRequest(url: base.appendingPathComponent("manifest")))
    XCTAssertEqual(manifestResponse.statusCode, 200)
    let manifestData = manifestResponse.data
    let manifestText = String(data: manifestData, encoding: .utf8) ?? ""
    XCTAssertTrue(manifestText.contains("TatwoMCPServerManifestV1"))
    XCTAssertTrue(manifestText.contains("local-http"))

    let call = try await postToolCall(
      base: base,
      body: [
        "tool": "tatwo.mode.plan",
        "arguments": ["mode": "XL", "scenario": "ui-ux"],
      ])
    XCTAssertTrue(call.ok)
    XCTAssertEqual(call.tool, "tatwo.mode.plan")
    XCTAssertFalse(call.fallbackCoreLibraryUsed)
    XCTAssertFalse(call.hostMutationAllowed)

    let encoded = String(data: try JSONEncoder().encode(call), encoding: .utf8) ?? ""
    XCTAssertTrue(encoded.contains("identitySlots"))
    XCTAssertTrue(encoded.contains("sandboxRequired"))
  }

  func testUnknownEndpointReturns404AndTatwoErrorEnvelope() async throws {
    let (server, base) = try await startedServer()
    defer { server.stop() }

    let response = try await request(URLRequest(url: base.appendingPathComponent("does-not-exist")))
    XCTAssertEqual(response.statusCode, 404)
    let result = try JSONDecoder().decode(TatwoMCPToolCallResult.self, from: response.data)
    XCTAssertEqual(result.schema, "TatwoMCPToolCallResultV1")
    XCTAssertFalse(result.ok)
    XCTAssertTrue(result.error?.hasPrefix("not_found:") == true)
  }

  func testUnknownToolReturns404AndOkFalse() async throws {
    let (server, base) = try await startedServer()
    defer { server.stop() }

    let response = try await post(
      base: base,
      body: [
        "tool": "tatwo.tool.does-not-exist",
        "arguments": [:],
      ])
    XCTAssertEqual(response.statusCode, 404)
    XCTAssertFalse(try JSONDecoder().decode(TatwoMCPToolCallResult.self, from: response.data).ok)
  }

  func testKnownToolContractFailureReturns422AndOkFalse() async throws {
    let (server, base) = try await startedServer()
    defer { server.stop() }

    let response = try await post(
      base: base,
      body: [
        "tool": "tatwo.mode.plan",
        "arguments": ["mode": "not-a-mode", "scenario": "ui-ux"],
      ])
    XCTAssertEqual(response.statusCode, 422)
    let result = try JSONDecoder().decode(TatwoMCPToolCallResult.self, from: response.data)
    XCTAssertFalse(result.ok)
    XCTAssertTrue(result.error?.contains("Unknown mode") == true)
    XCTAssertEqual(result.failureKind, .contract)
  }

  func testHTTPModePlanUsesExactStagingCustomPreviewAndUnknownCustomReturns422() async throws {
    let duplicated = try TatwoScenarioConfigMutator.duplicateScenario(
      in: TatwoScenarioConfigDefaults.book,
      scenarioID: TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID)
    var book = duplicated.book
    let scenarioIndex = try XCTUnwrap(
      book.scenarios.firstIndex { $0.id == duplicated.scenarioID })
    var config = try XCTUnwrap(book.scenarios[scenarioIndex].modeConfigs[.xxl])
    config.bindings = [
      TatwoScenarioIdentityBinding(
        id: "http-preview-lead",
        phase: .plan,
        identity: "主導",
        boundModelIDs: ["gpt-5.6-sol"],
        responsibility: "HTTP exact preview lead",
        dynamicActivation: .always),
      TatwoScenarioIdentityBinding(
        id: "http-preview-supervisor",
        phase: .loops,
        identity: "副審",
        boundModelIDs: ["opus-5"],
        responsibility: "HTTP exact preview supervisor",
        dynamicActivation: .always),
      TatwoScenarioIdentityBinding(
        id: "http-preview-sub",
        phase: .loops,
        identity: "sub",
        boundModelIDs: ["gpt-5.6-luna", "grok-build"],
        responsibility: "HTTP exact preview subs",
        dynamicActivation: .allowed),
    ]
    book.scenarios[scenarioIndex].modeConfigs[.xxl] = config

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-http-preview-\(UUID().uuidString)", isDirectory: true)
    let configURL = root.appendingPathComponent("scenario-config.json")
    try TatwoScenarioConfigStore(fileURL: configURL).save(book)
    setenv("TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH", configURL.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH")
      try? FileManager.default.removeItem(at: root)
    }

    let (server, base) = try await startedServer()
    defer { server.stop() }

    let exact = try await postToolCall(
      base: base,
      body: [
        "tool": "tatwo.mode.plan",
        "arguments": [
          "mode": "XXL",
          "scenario": duplicated.scenarioID,
        ],
      ])
    XCTAssertTrue(exact.ok, exact.error ?? "")
    guard case .object(let modePlan)? = exact.payload,
      case .array(let slots)? = modePlan["identitySlots"]
    else {
      return XCTFail("expected HTTP ModeIdentityPlan payload")
    }
    let models = slots.compactMap { slot -> String? in
      guard case .object(let slotObject) = slot,
        case .array(let candidates)? = slotObject["candidates"],
        case .object(let primary)? = candidates.first,
        case .string(let modelID)? = primary["modelID"]
      else { return nil }
      return modelID
    }
    XCTAssertEqual(models, ["gpt-5.6-sol", "opus-5", "gpt-5.6-luna", "grok-build"])

    for tool in [
      "tatwo.mode.plan",
      "tatwo.workflow.preview",
      "tatwo.receipt.requirements",
    ] {
      let unknown = try await post(
        base: base,
        body: [
          "tool": tool,
          "arguments": [
            "mode": "XXL",
            "scenario": "custom-copy-does-not-exist",
          ],
        ])
      XCTAssertEqual(unknown.statusCode, 422, tool)
      XCTAssertFalse(
        try JSONDecoder().decode(
          TatwoMCPToolCallResult.self,
          from: unknown.data).ok,
        tool)
    }
  }

  func testInternalToolFailureReturns500AndTypedEnvelope() async throws {
    let server = TatwoLocalMCPHTTPServer { tool, _ in
      TatwoMCPToolCallResult(
        tool: tool,
        ok: false,
        payload: nil,
        error: "internal_error:simulated_storage_failure",
        failureKind: .internalFailure)
    }
    let port = try server.start(port: 0)
    defer { server.stop() }
    let base = URL(string: "http://127.0.0.1:\(port)")!
    try await waitUntilReachable(base.appendingPathComponent("health"))

    let response = try await post(
      base: base,
      body: [
        "tool": "tatwo.mode.plan",
        "arguments": ["mode": "M"],
      ])
    XCTAssertEqual(response.statusCode, 500)
    let result = try JSONDecoder().decode(TatwoMCPToolCallResult.self, from: response.data)
    XCTAssertFalse(result.ok)
    XCTAssertEqual(result.failureKind, .internalFailure)
    XCTAssertTrue(result.error?.hasPrefix("internal_error:") == true)
  }

  func testMalformedToolCallReturns400AndOkFalse() async throws {
    let (server, base) = try await startedServer()
    defer { server.stop() }

    var malformed = URLRequest(url: base.appendingPathComponent("tools/call"))
    malformed.httpMethod = "POST"
    malformed.setValue("application/json", forHTTPHeaderField: "Content-Type")
    malformed.httpBody = Data("{invalid-json".utf8)
    let response = try await request(malformed)

    XCTAssertEqual(response.statusCode, 400)
    let result = try JSONDecoder().decode(TatwoMCPToolCallResult.self, from: response.data)
    XCTAssertFalse(result.ok)
    XCTAssertEqual(result.error, "bad_request:malformed_json")
  }

  func testHealthAndSuccessfulToolRemain2xx() async throws {
    let (server, base) = try await startedServer()
    defer { server.stop() }

    let health = try await request(URLRequest(url: base.appendingPathComponent("health")))
    XCTAssertEqual(health.statusCode, 200)

    let tool = try await post(
      base: base,
      body: [
        "tool": "tatwo.mode.plan",
        "arguments": ["mode": "XL", "scenario": "ui-ux"],
      ])
    XCTAssertEqual(tool.statusCode, 200)
    XCTAssertTrue(try JSONDecoder().decode(TatwoMCPToolCallResult.self, from: tool.data).ok)
  }

  private func startedServer() async throws -> (TatwoLocalMCPHTTPServer, URL) {
    let server = TatwoLocalMCPHTTPServer()
    let port = try server.start(port: 0)
    let base = URL(string: "http://127.0.0.1:\(port)")!
    try await waitUntilReachable(base.appendingPathComponent("health"))
    return (server, base)
  }

  private func waitUntilReachable(_ url: URL) async throws {
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
      if (try? await get(url)) != nil { return }
      usleep(25_000)
    }
    _ = try await get(url)
  }

  private func get(_ url: URL) async throws -> Data {
    let response = try await request(URLRequest(url: url))
    XCTAssertTrue((200..<300).contains(response.statusCode))
    return response.data
  }

  private func postToolCall(base: URL, body: [String: Any]) async throws -> TatwoMCPToolCallResult {
    var request = URLRequest(url: base.appendingPathComponent("tools/call"))
    request.httpMethod = "POST"
    request.timeoutInterval = 2
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let response = try await self.request(request)
    XCTAssertTrue((200..<300).contains(response.statusCode))
    return try JSONDecoder().decode(TatwoMCPToolCallResult.self, from: response.data)
  }

  private func post(base: URL, body: [String: Any]) async throws -> HTTPResult {
    var request = URLRequest(url: base.appendingPathComponent("tools/call"))
    request.httpMethod = "POST"
    request.timeoutInterval = 2
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return try await self.request(request)
  }

  private func request(_ request: URLRequest) async throws -> HTTPResult {
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    return HTTPResult(statusCode: http.statusCode, data: data)
  }
}

private struct HTTPResult {
  let statusCode: Int
  let data: Data
}
