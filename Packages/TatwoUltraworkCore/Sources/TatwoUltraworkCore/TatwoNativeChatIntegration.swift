import Foundation

public enum TatwoNativeGatewayTransportError: Error, Sendable, Equatable {
  case invalidRequest
  case invalidResponse
  case httpStatus(Int)
  case attestationMismatch
}

public protocol TatwoNativeGatewayHeaderProviding: Sendable {
  func headers() throws -> [String: String]
}

public struct TatwoNativeGatewayNoHeaders:
  TatwoNativeGatewayHeaderProviding
{
  public init() {}
  public func headers() throws -> [String: String] { [:] }
}

public struct TatwoNativeGatewayModelTransport: TatwoNativeModelTransport {
  public typealias Sender =
    @Sendable (URLRequest) async throws -> (Data, URLResponse)

  public let endpoint: URL
  public let modelID: String
  public let effort: String
  public let requestTimeout: TimeInterval
  private let headerProvider: any TatwoNativeGatewayHeaderProviding
  private let send: Sender

  public init(
    endpoint: URL,
    modelID: String,
    effort: String,
    requestTimeout: TimeInterval = 300,
    headerProvider: any TatwoNativeGatewayHeaderProviding =
      TatwoNativeGatewayNoHeaders(),
    send: @escaping Sender = { request in
      try await URLSession.shared.data(for: request)
    }
  ) {
    self.endpoint = endpoint
    self.modelID = modelID
    self.effort = effort
    self.requestTimeout = max(1, requestTimeout)
    self.headerProvider = headerProvider
    self.send = send
  }

  public func respond(
    to request: TatwoNativeModelRequest
  ) async throws -> TatwoNativeModelTurn {
    if Task.isCancelled { throw CancellationError() }
    guard Self.isAllowedLocalResponsesEndpoint(endpoint) else {
      throw TatwoNativeGatewayTransportError.invalidRequest
    }
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = requestTimeout
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in try headerProvider.headers() {
      let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty,
            !normalized.contains("\r"),
            !normalized.contains("\n"),
            !value.contains("\r"),
            !value.contains("\n")
      else {
        throw TatwoNativeGatewayTransportError.invalidRequest
      }
      urlRequest.setValue(value, forHTTPHeaderField: normalized)
    }
    urlRequest.httpBody = try encode(request)

    let (data, response) = try await send(urlRequest)
    if Task.isCancelled { throw CancellationError() }
    guard let http = response as? HTTPURLResponse else {
      throw TatwoNativeGatewayTransportError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw TatwoNativeGatewayTransportError.httpStatus(http.statusCode)
    }
    return try decode(data)
  }

  private func encode(_ request: TatwoNativeModelRequest) throws -> Data {
    let input: [[String: Any]] = try request.input.map { item in
      switch item {
      case .userText(let text):
        return [
          "type": "message",
          "role": "user",
          "content": [["type": "input_text", "text": text]],
        ]
      case .toolCall(let call):
        guard let arguments = Self.canonicalJSONObject(call.argumentsJSON) else {
          throw TatwoNativeGatewayTransportError.invalidRequest
        }
        return [
          "type": "function_call",
          "call_id": call.id,
          "name": call.name,
          "arguments": arguments,
        ]
      case .toolResult(let result):
        return [
          "type": "function_call_output",
          "call_id": result.callID,
          "output": result.output,
        ]
      }
    }
    let tools: [[String: Any]] = try request.tools.map { tool in
      guard let schemaData = tool.inputSchemaJSON.data(using: .utf8),
            let schema = try JSONSerialization.jsonObject(with: schemaData)
              as? [String: Any]
      else {
        throw TatwoNativeGatewayTransportError.invalidRequest
      }
      return [
        "type": "function",
        "name": tool.name,
        "description": tool.description,
        "parameters": schema,
      ]
    }
    let object: [String: Any] = [
      "model": modelID,
      "input": input,
      "tools": tools,
      "reasoning": ["effort": effort],
      "stream": false,
      "metadata": [
        "tatwo_runtime": "native-agent",
        "tatwo_model_step": String(request.modelStep),
      ],
    ]
    guard JSONSerialization.isValidJSONObject(object) else {
      throw TatwoNativeGatewayTransportError.invalidRequest
    }
    return try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
  }

  private func decode(_ data: Data) throws -> TatwoNativeModelTurn {
    guard let object = try JSONSerialization.jsonObject(with: data)
      as? [String: Any],
      object["degraded"] as? Bool != true,
      let observedModel = object["model"] as? String,
      let observedEffort = Self.observedEffort(object),
      let fallbackCount = Self.observedFallbackCount(object),
      Self.hasExactAttestation(
        object,
        requestedModel: modelID,
        observedModel: observedModel,
        fallbackCount: fallbackCount),
      observedEffort == effort,
      fallbackCount == 0
    else {
      throw TatwoNativeGatewayTransportError.attestationMismatch
    }

    if let error = object["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "provider_failed"
      return TatwoNativeModelTurn(
        response: .failure(code: code, safeMessage: "Model unavailable"),
        attestation: TatwoNativeModelAttestation(
          modelID: modelID, effort: observedEffort,
          fallbackCount: fallbackCount))
    }

    guard let output = object["output"] as? [[String: Any]] else {
      throw TatwoNativeGatewayTransportError.invalidResponse
    }
    var calls: [TatwoNativeToolCall] = []
    var textParts: [String] = []
    for item in output {
      switch item["type"] as? String {
      case "function_call":
        guard let callID = (item["call_id"] ?? item["id"]) as? String,
              let name = item["name"] as? String,
              let arguments = item["arguments"] as? String,
              Self.canonicalJSONObject(arguments) != nil
        else {
          throw TatwoNativeGatewayTransportError.invalidResponse
        }
        calls.append(TatwoNativeToolCall(
          id: callID, name: name, argumentsJSON: arguments))
      case "message":
        let content = item["content"] as? [[String: Any]] ?? []
        textParts += content.compactMap { part in
          guard ["output_text", "text"].contains(part["type"] as? String)
          else { return nil }
          return part["text"] as? String
        }
      case "output_text":
        if let text = item["text"] as? String { textParts.append(text) }
      default:
        continue
      }
    }
    let response: TatwoNativeModelResponse
    if !calls.isEmpty {
      response = .toolCalls(calls)
    } else if !textParts.isEmpty {
      response = .assistantText(textParts.joined())
    } else {
      throw TatwoNativeGatewayTransportError.invalidResponse
    }
    return TatwoNativeModelTurn(
      response: response,
      attestation: TatwoNativeModelAttestation(
        modelID: modelID, effort: observedEffort,
        fallbackCount: fallbackCount))
  }

  private static func canonicalJSONObject(_ json: String) -> String? {
    guard let data = json.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data),
          value is [String: Any],
          let canonical = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return String(decoding: canonical, as: UTF8.self)
  }

  private static func observedEffort(_ object: [String: Any]) -> String? {
    if let effort = (object["reasoning_control"] as? [String: Any])?[
      "normalized"] as? String
    {
      return effort
    }
    if let effort = object["effort"] as? String { return effort }
    if let effort = (object["reasoning"] as? [String: Any])?["effort"]
      as? String
    {
      return effort
    }
    let metadata = object["metadata"] as? [String: Any]
    return metadata?["effective_reasoning_effort"] as? String
      ?? metadata?["reasoning_effort"] as? String
  }

  private static func observedFallbackCount(
    _ object: [String: Any]
  ) -> Int? {
    if let count = (object["model_attestation"] as? [String: Any])?[
      "fallback_count"] as? Int
    {
      return count
    }
    if let count = object["fallback_count"] as? Int { return count }
    let metadata = object["metadata"] as? [String: Any]
    return metadata?["fallback_count"] as? Int
  }

  private static func hasExactAttestation(
    _ object: [String: Any],
    requestedModel: String,
    observedModel: String,
    fallbackCount: Int
  ) -> Bool {
    guard let attestation = object["model_attestation"] as? [String: Any],
      attestation["requested_model"] as? String == requestedModel,
      attestation["actual_canonical_model"] as? String == requestedModel,
      attestation["fallback_count"] as? Int == fallbackCount,
      attestation["outcome"] as? String == "VERIFIED_EXACT",
      attestation["exact"] as? Bool == true
    else { return false }

    let actualVendor = attestation["actual_vendor_model"] as? String
    switch requestedModel {
    case "opus-5":
      return ["opus-5", "claude-opus-5"].contains(observedModel)
        && actualVendor == "claude-opus-5"
    default:
      return observedModel == requestedModel
        && (actualVendor == nil || actualVendor == requestedModel)
    }
  }

  private static func isAllowedLocalResponsesEndpoint(_ url: URL) -> Bool {
    guard url.scheme == "http",
          ["/v1/responses", "/v1/responses/"].contains(url.path),
          let host = url.host?.lowercased()
    else { return false }
    return ["127.0.0.1", "localhost", "::1"].contains(host)
  }
}

public enum TatwoNativeAgentPersistedState:
  String, Codable, Sendable, Equatable
{
  case running
  case completed
  case cancelled
  case failed
  case interrupted
}

public struct TatwoNativeAgentPersistedRun:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let runID: String
  public var state: TatwoNativeAgentPersistedState
  public let modelID: String
  public let effort: String
  public var updatedAt: Date

  public init(
    schema: String = "TatwoNativeAgentPersistedRunV1",
    runID: String,
    state: TatwoNativeAgentPersistedState,
    modelID: String,
    effort: String,
    updatedAt: Date = Date()
  ) {
    self.schema = schema
    self.runID = runID
    self.state = state
    self.modelID = modelID
    self.effort = effort
    self.updatedAt = updatedAt
  }
}

public struct TatwoNativeAgentRunJournal: Sendable {
  public let directoryURL: URL

  public init(directoryURL: URL) {
    self.directoryURL = directoryURL.standardizedFileURL
  }

  public func save(_ run: TatwoNativeAgentPersistedRun) throws {
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(run)
    try data.write(to: url(for: run.runID), options: [.atomic])
  }

  public func load(runID: String) throws -> TatwoNativeAgentPersistedRun? {
    let fileURL = url(for: runID)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var run = try decoder.decode(
      TatwoNativeAgentPersistedRun.self, from: Data(contentsOf: fileURL))
    guard run.schema == "TatwoNativeAgentPersistedRunV1",
          run.runID == runID
    else {
      throw TatwoNativeGatewayTransportError.invalidResponse
    }
    if run.state == .running {
      run.state = .interrupted
      run.updatedAt = Date()
      try save(run)
    }
    return run
  }

  @discardableResult
  public func reconcileInterruptedRuns() throws -> Int {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else {
      return 0
    }
    let urls = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
      .filter { $0.pathExtension == "json" }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var reconciled = 0
    for url in urls {
      guard var run = try? decoder.decode(
        TatwoNativeAgentPersistedRun.self,
        from: Data(contentsOf: url)),
        run.schema == "TatwoNativeAgentPersistedRunV1",
        run.state == .running
      else { continue }
      run.state = .interrupted
      run.updatedAt = Date()
      try save(run)
      reconciled += 1
    }
    return reconciled
  }

  private func url(for runID: String) -> URL {
    let safeID = runID.unicodeScalars.map {
      CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        ? Character(String($0)) : "_"
    }
    return directoryURL.appendingPathComponent(
      String(safeID) + ".json", isDirectory: false)
  }
}

/// Owns only native-run persistence. It deliberately does not read or write
/// ChatCLIProcessRunner authority, so the two durability domains cannot
/// rehydrate or terminate one another.
public struct TatwoNativeAgentRunCoordinator: Sendable {
  public let journal: TatwoNativeAgentRunJournal

  public init(journal: TatwoNativeAgentRunJournal) {
    self.journal = journal
  }

  public func run<Transport, ToolExecutor>(
    runID: String,
    prompt: String,
    tools: [TatwoNativeToolDefinition],
    runtime: TatwoNativeAgentRuntime<Transport, ToolExecutor>,
    onEvent: (@Sendable (TatwoNativeAgentEvent) -> Void)? = nil
  ) async throws -> TatwoNativeAgentRunReceipt
  where Transport: TatwoNativeModelTransport,
    ToolExecutor: TatwoNativeToolExecuting
  {
    var persisted = TatwoNativeAgentPersistedRun(
      runID: runID,
      state: .running,
      modelID: runtime.expectedAttestation.modelID,
      effort: runtime.expectedAttestation.effort)
    try journal.save(persisted)
    let receipt = await runtime.run(
      prompt: prompt, tools: tools, onEvent: onEvent)
    persisted.state = Self.persistedState(for: receipt.outcome)
    persisted.updatedAt = Date()
    try journal.save(persisted)
    return receipt
  }

  private static func persistedState(
    for outcome: TatwoNativeAgentOutcome
  ) -> TatwoNativeAgentPersistedState {
    switch outcome {
    case .completed:
      return .completed
    case .cancelled:
      return .cancelled
    case .stepLimitReached, .toolCallLimitReached, .failed:
      return .failed
    }
  }
}
