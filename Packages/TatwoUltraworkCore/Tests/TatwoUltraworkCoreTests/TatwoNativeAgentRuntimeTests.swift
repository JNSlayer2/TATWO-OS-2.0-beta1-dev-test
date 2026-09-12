import XCTest
@testable import TatwoUltraworkCore

final class TatwoNativeAgentRuntimeTests: XCTestCase {
  func testActionableTransportFailureIsPreservedInsteadOfCollapsed() async {
    let runtime = TatwoNativeAgentRuntime(
      transport: ActionableFailureTransport(),
      toolExecutor: RecordingNativeToolExecutor(outputs: [:]),
      expectedAttestation: TatwoNativeModelAttestation(
        modelID: "gpt-5.6-sol",
        effort: "high"),
      maximumModelSteps: 2,
      maximumToolCalls: 2)

    let receipt = await runtime.run(prompt: "inspect", tools: [])

    XCTAssertEqual(
      receipt.outcome,
      TatwoNativeAgentOutcome.failed(
        code: "subscription_login_required"))
    XCTAssertEqual(
      receipt.assistantText,
      "請到 TATWO OS 設定 → 模型存取，登入 ChatGPT 訂閱帳號。")
  }

  private let expectedAttestation = TatwoNativeModelAttestation(
    modelID: "gpt-5.6-sol",
    effort: "high")

  func testToolCallsExecuteSequentiallyAndResultsReturnToModel() async throws {
    let transport = ScriptedNativeModelTransport(turns: [
      TatwoNativeModelTurn(response: .toolCalls([
        TatwoNativeToolCall(id: "call-1", name: "read_file", argumentsJSON: #"{"path":"a.swift"}"#),
        TatwoNativeToolCall(id: "call-2", name: "search", argumentsJSON: #"{"pattern":"TODO"}"#),
      ]), attestation: expectedAttestation),
      TatwoNativeModelTurn(response: .assistantText("done"), attestation: expectedAttestation),
    ])
    let executor = RecordingNativeToolExecutor(outputs: [
      "call-1": TatwoNativeToolResult(callID: "call-1", output: "file body"),
      "call-2": TatwoNativeToolResult(callID: "call-2", output: "a.swift:1"),
    ])
    let runtime = TatwoNativeAgentRuntime(
      transport: transport,
      toolExecutor: executor,
      expectedAttestation: expectedAttestation,
      maximumModelSteps: 4,
      maximumToolCalls: 8)

    let receipt = await runtime.run(
      prompt: "inspect",
      tools: [
        TatwoNativeToolDefinition(name: "read_file", description: "Read a file"),
        TatwoNativeToolDefinition(name: "search", description: "Search workspace"),
      ])

    XCTAssertEqual(receipt.outcome, .completed)
    XCTAssertEqual(receipt.assistantText, "done")
    let executedCallIDs = await executor.executedCallIDs()
    XCTAssertEqual(executedCallIDs, ["call-1", "call-2"])

    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].tools.map(\.name), ["read_file", "search"])
    XCTAssertEqual(
      requests[1].input,
      [
        .userText("inspect"),
        .toolCall(requests[0].input.isEmpty
          ? TatwoNativeToolCall(id: "missing", name: "missing", argumentsJSON: "{}")
          : TatwoNativeToolCall(
            id: "call-1", name: "read_file", argumentsJSON: #"{"path":"a.swift"}"#)),
        .toolCall(TatwoNativeToolCall(
          id: "call-2", name: "search", argumentsJSON: #"{"pattern":"TODO"}"#)),
        .toolResult(TatwoNativeToolResult(callID: "call-1", output: "file body")),
        .toolResult(TatwoNativeToolResult(callID: "call-2", output: "a.swift:1")),
      ])
    XCTAssertFalse(receipt.events.contains {
      if case .assistantVisibleText(let text) = $0.kind {
        return text.contains(#""path":"a.swift""#) || text.contains(#""pattern":"TODO""#)
      }
      return false
    })
  }

  func testTypedEventsStreamBeforeRuntimeCompletion() async {
    let transport = ScriptedNativeModelTransport(turns: [
      TatwoNativeModelTurn(
        response: .toolCalls([
          TatwoNativeToolCall(
            id: "call-1", name: "read_file", argumentsJSON: "{}"),
        ]),
        attestation: expectedAttestation),
      TatwoNativeModelTurn(
        response: .assistantText("done"),
        attestation: expectedAttestation),
    ])
    let runtime = TatwoNativeAgentRuntime(
      transport: transport,
      toolExecutor: RecordingNativeToolExecutor(outputs: [
        "call-1": TatwoNativeToolResult(callID: "call-1", output: "body"),
      ]),
      expectedAttestation: expectedAttestation,
      maximumModelSteps: 3,
      maximumToolCalls: 2)
    let recorder = NativeAgentEventRecorder()

    let receipt = await runtime.run(
      prompt: "inspect",
      tools: [TatwoNativeToolDefinition(name: "read_file", description: "Read")]
    ) { event in
      recorder.append(event)
    }

    XCTAssertEqual(receipt.outcome, .completed)
    XCTAssertEqual(recorder.events, receipt.events)
    XCTAssertEqual(recorder.events.map(\.kind), [
      .modelRequested(step: 1),
      .toolRequested(
        invocation: TatwoNativeToolInvocationID(
          modelStep: 1, toolIndex: 0, providerCallID: "call-1"),
        name: "read_file"),
      .toolCompleted(
        invocation: TatwoNativeToolInvocationID(
          modelStep: 1, toolIndex: 0, providerCallID: "call-1"),
        isError: false),
      .modelRequested(step: 2),
      .assistantVisibleText("done"),
    ])
  }

  func testStepLimitStopsRepeatedToolLoopDeterministically() async {
    let repeatedCall = TatwoNativeToolCall(
      id: "loop", name: "read_file", argumentsJSON: #"{"path":"a.swift"}"#)
    let transport = ScriptedNativeModelTransport(turns: [
      TatwoNativeModelTurn(response: .toolCalls([repeatedCall]), attestation: expectedAttestation),
      TatwoNativeModelTurn(response: .toolCalls([repeatedCall]), attestation: expectedAttestation),
      TatwoNativeModelTurn(
        response: .assistantText("must not be reached"),
        attestation: expectedAttestation),
    ])
    let executor = RecordingNativeToolExecutor(outputs: [
      "loop": TatwoNativeToolResult(callID: "loop", output: "body"),
    ])
    let runtime = TatwoNativeAgentRuntime(
      transport: transport,
      toolExecutor: executor,
      expectedAttestation: expectedAttestation,
      maximumModelSteps: 2,
      maximumToolCalls: 8)

    let receipt = await runtime.run(
      prompt: "loop",
      tools: [TatwoNativeToolDefinition(name: "read_file", description: "Read")])

    XCTAssertEqual(receipt.outcome, .stepLimitReached)
    XCTAssertNil(receipt.assistantText)
    let requestCount = await transport.recordedRequests().count
    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(receipt.events.last?.kind, .stepLimitReached(maximumModelSteps: 2))
  }

  func testCancellationStopsBeforeAnotherModelOrToolAction() async {
    let transport = CancellingNativeModelTransport()
    let executor = RecordingNativeToolExecutor(outputs: [:])
    let runtime = TatwoNativeAgentRuntime(
      transport: transport,
      toolExecutor: executor,
      expectedAttestation: expectedAttestation,
      maximumModelSteps: 4,
      maximumToolCalls: 8)

    let task = Task {
      await runtime.run(
        prompt: "cancel",
        tools: [TatwoNativeToolDefinition(name: "read_file", description: "Read")])
    }
    await transport.waitUntilRequested()
    task.cancel()
    await transport.release()
    let receipt = await task.value

    XCTAssertEqual(receipt.outcome, .cancelled)
    let cancelledExecutedCallIDs = await executor.executedCallIDs()
    XCTAssertEqual(cancelledExecutedCallIDs, [])
    XCTAssertEqual(receipt.events.last?.kind, .cancelled)
  }

  func testTransportFailureBecomesTypedFailureWithoutProviderPayloadInChat() async {
    let transport = ScriptedNativeModelTransport(turns: [
      TatwoNativeModelTurn(
        response: .failure(code: "provider_failed", safeMessage: "Model unavailable"),
        attestation: expectedAttestation),
    ])
    let runtime = TatwoNativeAgentRuntime(
      transport: transport,
      toolExecutor: RecordingNativeToolExecutor(outputs: [:]),
      expectedAttestation: expectedAttestation,
      maximumModelSteps: 2,
      maximumToolCalls: 8)

    let receipt = await runtime.run(prompt: "hello", tools: [])

    XCTAssertEqual(receipt.outcome, .failed(code: "provider_failed"))
    XCTAssertEqual(receipt.assistantText, "Model unavailable")
    XCTAssertFalse(receipt.assistantText?.contains("raw") == true)
  }

  func testModelAttestationMismatchFailsClosedBeforeToolExecution() async {
    let transport = ScriptedNativeModelTransport(turns: [
      TatwoNativeModelTurn(
        response: .toolCalls([
          TatwoNativeToolCall(id: "forbidden", name: "write_file", argumentsJSON: "{}"),
        ]),
        attestation: TatwoNativeModelAttestation(modelID: "fallback-model", effort: "low")),
    ])
    let executor = RecordingNativeToolExecutor(outputs: [:])
    let runtime = TatwoNativeAgentRuntime(
      transport: transport,
      toolExecutor: executor,
      expectedAttestation: expectedAttestation,
      maximumModelSteps: 2,
      maximumToolCalls: 8)

    let receipt = await runtime.run(
      prompt: "edit",
      tools: [TatwoNativeToolDefinition(name: "write_file", description: "Write")])

    XCTAssertEqual(receipt.outcome, .failed(code: "model_attestation_mismatch"))
    let callIDs = await executor.executedCallIDs()
    XCTAssertEqual(callIDs, [])
    XCTAssertFalse(receipt.events.contains {
      if case .assistantVisibleText = $0.kind { return true }
      return false
    })
  }

  func testToolCallBudgetRejectsOversizedBatchBeforeAnyExecution() async {
    let transport = ScriptedNativeModelTransport(turns: [
      TatwoNativeModelTurn(
        response: .toolCalls([
          TatwoNativeToolCall(id: "one", name: "read_file", argumentsJSON: "{}"),
          TatwoNativeToolCall(id: "two", name: "read_file", argumentsJSON: "{}"),
          TatwoNativeToolCall(id: "three", name: "read_file", argumentsJSON: "{}"),
        ]),
        attestation: expectedAttestation),
    ])
    let executor = RecordingNativeToolExecutor(outputs: [:])
    let runtime = TatwoNativeAgentRuntime(
      transport: transport,
      toolExecutor: executor,
      expectedAttestation: expectedAttestation,
      maximumModelSteps: 4,
      maximumToolCalls: 2)

    let receipt = await runtime.run(
      prompt: "read",
      tools: [TatwoNativeToolDefinition(name: "read_file", description: "Read")])

    XCTAssertEqual(receipt.outcome, .toolCallLimitReached)
    let callIDs = await executor.executedCallIDs()
    XCTAssertEqual(callIDs, [])
    XCTAssertEqual(receipt.events.last?.kind, .toolCallLimitReached(maximumToolCalls: 2))
  }

  func testCancellationDuringToolExecutionReturnsCancelled() async {
    let call = TatwoNativeToolCall(id: "slow", name: "test", argumentsJSON: "{}")
    let transport = ScriptedNativeModelTransport(turns: [
      TatwoNativeModelTurn(response: .toolCalls([call]), attestation: expectedAttestation),
    ])
    let executor = BlockingNativeToolExecutor()
    let runtime = TatwoNativeAgentRuntime(
      transport: transport,
      toolExecutor: executor,
      expectedAttestation: expectedAttestation,
      maximumModelSteps: 2,
      maximumToolCalls: 2)

    let task = Task {
      await runtime.run(
        prompt: "test",
        tools: [TatwoNativeToolDefinition(name: "test", description: "Test")])
    }
    await executor.waitUntilStarted()
    task.cancel()
    await executor.release()
    let receipt = await task.value

    XCTAssertEqual(receipt.outcome, .cancelled)
    XCTAssertEqual(receipt.events.last?.kind, .cancelled)
    let requestCount = await transport.recordedRequests().count
    XCTAssertEqual(requestCount, 1)
  }

  func testDuplicateProviderCallIDsHaveDistinctInvocationReceipts() async {
    let duplicate = TatwoNativeToolCall(id: "same", name: "read_file", argumentsJSON: "{}")
    let transport = ScriptedNativeModelTransport(turns: [
      TatwoNativeModelTurn(response: .toolCalls([duplicate]), attestation: expectedAttestation),
      TatwoNativeModelTurn(response: .toolCalls([duplicate]), attestation: expectedAttestation),
    ])
    let runtime = TatwoNativeAgentRuntime(
      transport: transport,
      toolExecutor: RecordingNativeToolExecutor(outputs: [
        "same": TatwoNativeToolResult(callID: "same", output: "ok"),
      ]),
      expectedAttestation: expectedAttestation,
      maximumModelSteps: 2,
      maximumToolCalls: 2)

    let receipt = await runtime.run(
      prompt: "read twice",
      tools: [TatwoNativeToolDefinition(name: "read_file", description: "Read")])

    let invocations = receipt.events.compactMap { event -> TatwoNativeToolInvocationID? in
      if case .toolRequested(let invocation, _) = event.kind { return invocation }
      return nil
    }
    XCTAssertEqual(invocations, [
      TatwoNativeToolInvocationID(modelStep: 1, toolIndex: 0, providerCallID: "same"),
      TatwoNativeToolInvocationID(modelStep: 2, toolIndex: 0, providerCallID: "same"),
    ])
  }

  func testThrownTransportErrorBecomesSafeTypedFailure() async {
    let runtime = TatwoNativeAgentRuntime(
      transport: ThrowingNativeModelTransport(),
      toolExecutor: RecordingNativeToolExecutor(outputs: [:]),
      expectedAttestation: expectedAttestation,
      maximumModelSteps: 2,
      maximumToolCalls: 2)

    let receipt = await runtime.run(prompt: "hello", tools: [])

    XCTAssertEqual(receipt.outcome, .failed(code: "transport_error"))
    XCTAssertEqual(receipt.assistantText, "Model transport failed")
    XCTAssertFalse(receipt.assistantText?.contains("provider-secret") == true)
  }

  func testThrownToolErrorFeedsBackAndLoopContinues() async {
    let call = TatwoNativeToolCall(id: "boom", name: "read_file", argumentsJSON: "{}")
    let transport = ScriptedNativeModelTransport(turns: [
      TatwoNativeModelTurn(response: .toolCalls([call]), attestation: expectedAttestation),
      TatwoNativeModelTurn(response: .assistantText("recovered"), attestation: expectedAttestation),
    ])
    let runtime = TatwoNativeAgentRuntime(
      transport: transport,
      toolExecutor: ThrowingNativeToolExecutor(),
      expectedAttestation: expectedAttestation,
      maximumModelSteps: 2,
      maximumToolCalls: 2)

    let receipt = await runtime.run(
      prompt: "recover",
      tools: [TatwoNativeToolDefinition(name: "read_file", description: "Read")])

    XCTAssertEqual(receipt.outcome, .completed)
    XCTAssertEqual(receipt.assistantText, "recovered")
    let requests = await transport.recordedRequests()
    XCTAssertEqual(
      requests[1].input.last,
      .toolResult(TatwoNativeToolResult(
        callID: "boom",
        output: "Tool execution failed",
        isError: true)))
    XCTAssertTrue(receipt.events.contains {
      $0.kind == .toolCompleted(
        invocation: TatwoNativeToolInvocationID(
          modelStep: 1,
          toolIndex: 0,
          providerCallID: "boom"),
        isError: true)
    })
  }
}

private struct ActionableFailureTransport:
  TatwoNativeModelTransport
{
  func respond(
    to request: TatwoNativeModelRequest
  ) async throws -> TatwoNativeModelTurn {
    throw ActionableFailure()
  }
}

private struct ActionableFailure:
  TatwoNativeActionableTransportFailure
{
  let nativeFailureCode = "subscription_login_required"
  let nativeSafeMessage =
    "請到 TATWO OS 設定 → 模型存取，登入 ChatGPT 訂閱帳號。"
}

private final class NativeAgentEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvents: [TatwoNativeAgentEvent] = []

  var events: [TatwoNativeAgentEvent] {
    lock.withLock { storedEvents }
  }

  func append(_ event: TatwoNativeAgentEvent) {
    lock.withLock {
      storedEvents.append(event)
    }
  }
}

private actor ScriptedNativeModelTransport: TatwoNativeModelTransport {
  private var turns: [TatwoNativeModelTurn]
  private var requests: [TatwoNativeModelRequest] = []

  init(turns: [TatwoNativeModelTurn]) {
    self.turns = turns
  }

  func respond(to request: TatwoNativeModelRequest) async throws -> TatwoNativeModelTurn {
    requests.append(request)
    guard !turns.isEmpty else {
      return TatwoNativeModelTurn(
        response: .failure(code: "fixture_exhausted", safeMessage: "Fixture exhausted"),
        attestation: TatwoNativeModelAttestation(modelID: "fixture", effort: "none"))
    }
    return turns.removeFirst()
  }

  func recordedRequests() -> [TatwoNativeModelRequest] {
    requests
  }
}

private actor RecordingNativeToolExecutor: TatwoNativeToolExecuting {
  private let outputs: [String: TatwoNativeToolResult]
  private var callIDs: [String] = []

  init(outputs: [String: TatwoNativeToolResult]) {
    self.outputs = outputs
  }

  func execute(_ call: TatwoNativeToolCall) async throws -> TatwoNativeToolResult {
    callIDs.append(call.id)
    return outputs[call.id]
      ?? TatwoNativeToolResult(callID: call.id, output: "missing fixture", isError: true)
  }

  func executedCallIDs() -> [String] {
    callIDs
  }
}

private actor CancellingNativeModelTransport: TatwoNativeModelTransport {
  private var continuation: CheckedContinuation<Void, Never>?
  private var requested = false

  func respond(to request: TatwoNativeModelRequest) async throws -> TatwoNativeModelTurn {
    requested = true
    await withCheckedContinuation { continuation = $0 }
    return TatwoNativeModelTurn(
      response: .toolCalls([
        TatwoNativeToolCall(id: "must-not-run", name: "read_file", argumentsJSON: "{}"),
      ]),
      attestation: TatwoNativeModelAttestation(modelID: "gpt-5.6-sol", effort: "high"))
  }

  func waitUntilRequested() async {
    while !requested {
      await Task.yield()
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private actor BlockingNativeToolExecutor: TatwoNativeToolExecuting {
  private var continuation: CheckedContinuation<Void, Never>?
  private var started = false

  func execute(_ call: TatwoNativeToolCall) async throws -> TatwoNativeToolResult {
    started = true
    await withCheckedContinuation { continuation = $0 }
    return TatwoNativeToolResult(callID: call.id, output: "late")
  }

  func waitUntilStarted() async {
    while !started {
      await Task.yield()
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private struct ThrowingNativeModelTransport: TatwoNativeModelTransport {
  struct ProviderError: Error {}

  func respond(to request: TatwoNativeModelRequest) async throws -> TatwoNativeModelTurn {
    throw ProviderError()
  }
}

private struct ThrowingNativeToolExecutor: TatwoNativeToolExecuting {
  struct ToolError: Error {}

  func execute(_ call: TatwoNativeToolCall) async throws -> TatwoNativeToolResult {
    throw ToolError()
  }
}
