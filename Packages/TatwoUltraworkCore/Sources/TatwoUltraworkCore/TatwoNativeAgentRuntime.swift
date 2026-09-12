import Foundation

public struct TatwoNativeToolDefinition: Sendable, Equatable, Hashable {
  public let name: String
  public let description: String
  public let inputSchemaJSON: String

  public init(
    name: String,
    description: String,
    inputSchemaJSON: String = #"{"type":"object"}"#
  ) {
    self.name = name
    self.description = description
    self.inputSchemaJSON = inputSchemaJSON
  }
}

public struct TatwoNativeToolCall: Sendable, Equatable, Hashable {
  public let id: String
  public let name: String
  public let argumentsJSON: String

  public init(id: String, name: String, argumentsJSON: String) {
    self.id = id
    self.name = name
    self.argumentsJSON = argumentsJSON
  }
}

public struct TatwoNativeToolResult: Sendable, Equatable, Hashable {
  public let callID: String
  public let output: String
  public let isError: Bool

  public init(callID: String, output: String, isError: Bool = false) {
    self.callID = callID
    self.output = output
    self.isError = isError
  }
}

public enum TatwoNativeModelInput: Sendable, Equatable, Hashable {
  case userText(String)
  case toolCall(TatwoNativeToolCall)
  case toolResult(TatwoNativeToolResult)
}

public struct TatwoNativeModelRequest: Sendable, Equatable {
  public let input: [TatwoNativeModelInput]
  public let tools: [TatwoNativeToolDefinition]
  public let modelStep: Int

  public init(
    input: [TatwoNativeModelInput],
    tools: [TatwoNativeToolDefinition],
    modelStep: Int
  ) {
    self.input = input
    self.tools = tools
    self.modelStep = modelStep
  }
}

public enum TatwoNativeModelResponse: Sendable, Equatable {
  case assistantText(String)
  case toolCalls([TatwoNativeToolCall])
  case failure(code: String, safeMessage: String)
}

public struct TatwoNativeModelAttestation: Sendable, Equatable, Hashable {
  public let modelID: String
  public let effort: String
  public let fallbackCount: Int

  public init(modelID: String, effort: String, fallbackCount: Int = 0) {
    self.modelID = modelID
    self.effort = effort
    self.fallbackCount = fallbackCount
  }
}

public struct TatwoNativeModelTurn: Sendable, Equatable {
  public let response: TatwoNativeModelResponse
  public let attestation: TatwoNativeModelAttestation

  public init(
    response: TatwoNativeModelResponse,
    attestation: TatwoNativeModelAttestation
  ) {
    self.response = response
    self.attestation = attestation
  }
}

public protocol TatwoNativeModelTransport: Sendable {
  func respond(to request: TatwoNativeModelRequest) async throws -> TatwoNativeModelTurn
}

public protocol TatwoNativeActionableTransportFailure: Error, Sendable {
  var nativeFailureCode: String { get }
  var nativeSafeMessage: String { get }
}

public protocol TatwoNativeToolExecuting: Sendable {
  func execute(_ call: TatwoNativeToolCall) async throws -> TatwoNativeToolResult
}

public enum TatwoNativeAgentOutcome: Sendable, Equatable {
  case completed
  case cancelled
  case stepLimitReached
  case toolCallLimitReached
  case failed(code: String)
}

public struct TatwoNativeToolInvocationID: Sendable, Equatable, Hashable {
  public let modelStep: Int
  public let toolIndex: Int
  public let providerCallID: String

  public init(modelStep: Int, toolIndex: Int, providerCallID: String) {
    self.modelStep = modelStep
    self.toolIndex = toolIndex
    self.providerCallID = providerCallID
  }
}

public enum TatwoNativeAgentEventKind: Sendable, Equatable {
  case modelRequested(step: Int)
  case toolRequested(invocation: TatwoNativeToolInvocationID, name: String)
  case toolCompleted(invocation: TatwoNativeToolInvocationID, isError: Bool)
  case assistantVisibleText(String)
  case cancelled
  case stepLimitReached(maximumModelSteps: Int)
  case toolCallLimitReached(maximumToolCalls: Int)
  case failed(code: String)
}

public struct TatwoNativeAgentEvent: Sendable, Equatable {
  public let kind: TatwoNativeAgentEventKind

  public init(kind: TatwoNativeAgentEventKind) {
    self.kind = kind
  }
}

public struct TatwoNativeAgentRunReceipt: Sendable, Equatable {
  public let outcome: TatwoNativeAgentOutcome
  public let assistantText: String?
  public let events: [TatwoNativeAgentEvent]

  public init(
    outcome: TatwoNativeAgentOutcome,
    assistantText: String?,
    events: [TatwoNativeAgentEvent]
  ) {
    self.outcome = outcome
    self.assistantText = assistantText
    self.events = events
  }
}

public struct TatwoNativeAgentRuntime<Transport, ToolExecutor>: Sendable
where Transport: TatwoNativeModelTransport, ToolExecutor: TatwoNativeToolExecuting {
  public let transport: Transport
  public let toolExecutor: ToolExecutor
  public let expectedAttestation: TatwoNativeModelAttestation
  public let maximumModelSteps: Int
  public let maximumToolCalls: Int

  public init(
    transport: Transport,
    toolExecutor: ToolExecutor,
    expectedAttestation: TatwoNativeModelAttestation,
    maximumModelSteps: Int,
    maximumToolCalls: Int
  ) {
    self.transport = transport
    self.toolExecutor = toolExecutor
    self.expectedAttestation = expectedAttestation
    self.maximumModelSteps = max(1, maximumModelSteps)
    self.maximumToolCalls = max(0, maximumToolCalls)
  }

  public func run(
    prompt: String,
    tools: [TatwoNativeToolDefinition],
    onEvent: (@Sendable (TatwoNativeAgentEvent) -> Void)? = nil
  ) async -> TatwoNativeAgentRunReceipt {
    var input: [TatwoNativeModelInput] = [.userText(prompt)]
    var events: [TatwoNativeAgentEvent] = []
    var executedToolCallCount = 0
    func record(_ kind: TatwoNativeAgentEventKind) {
      let event = TatwoNativeAgentEvent(kind: kind)
      events.append(event)
      onEvent?(event)
    }

    for step in 1...maximumModelSteps {
      guard !Task.isCancelled else {
        record(.cancelled)
        return TatwoNativeAgentRunReceipt(
          outcome: .cancelled, assistantText: nil, events: events)
      }

      record(.modelRequested(step: step))
      let turn: TatwoNativeModelTurn
      do {
        turn = try await transport.respond(
          to: TatwoNativeModelRequest(input: input, tools: tools, modelStep: step))
      } catch is CancellationError {
        record(.cancelled)
        return TatwoNativeAgentRunReceipt(
          outcome: .cancelled, assistantText: nil, events: events)
      } catch let failure as any TatwoNativeActionableTransportFailure {
        record(.failed(code: failure.nativeFailureCode))
        return TatwoNativeAgentRunReceipt(
          outcome: .failed(code: failure.nativeFailureCode),
          assistantText: failure.nativeSafeMessage,
          events: events)
      } catch {
        record(.failed(code: "transport_error"))
        return TatwoNativeAgentRunReceipt(
          outcome: .failed(code: "transport_error"),
          assistantText: "Model transport failed",
          events: events)
      }

      guard !Task.isCancelled else {
        record(.cancelled)
        return TatwoNativeAgentRunReceipt(
          outcome: .cancelled, assistantText: nil, events: events)
      }

      guard turn.attestation == expectedAttestation else {
        record(.failed(code: "model_attestation_mismatch"))
        return TatwoNativeAgentRunReceipt(
          outcome: .failed(code: "model_attestation_mismatch"),
          assistantText: "Model route verification failed",
          events: events)
      }

      let response = turn.response
      switch response {
      case .assistantText(let text):
        record(.assistantVisibleText(text))
        return TatwoNativeAgentRunReceipt(
          outcome: .completed, assistantText: text, events: events)

      case .failure(let code, let safeMessage):
        record(.failed(code: code))
        return TatwoNativeAgentRunReceipt(
          outcome: .failed(code: code), assistantText: safeMessage, events: events)

      case .toolCalls(let calls):
        guard executedToolCallCount + calls.count <= maximumToolCalls else {
          record(.toolCallLimitReached(maximumToolCalls: maximumToolCalls))
          return TatwoNativeAgentRunReceipt(
            outcome: .toolCallLimitReached, assistantText: nil, events: events)
        }

        // Responses-style transcripts require the complete assistant batch
        // before any tool outputs. Never create call/output interleaving.
        input.append(contentsOf: calls.map(TatwoNativeModelInput.toolCall))
        var completedResults: [TatwoNativeToolResult] = []
        for (toolIndex, call) in calls.enumerated() {
          guard !Task.isCancelled else {
            record(.cancelled)
            return TatwoNativeAgentRunReceipt(
              outcome: .cancelled, assistantText: nil, events: events)
          }
          let invocation = TatwoNativeToolInvocationID(
            modelStep: step,
            toolIndex: toolIndex,
            providerCallID: call.id)
          record(.toolRequested(invocation: invocation, name: call.name))
          let result: TatwoNativeToolResult
          do {
            result = try await toolExecutor.execute(call)
          } catch is CancellationError {
            record(.cancelled)
            return TatwoNativeAgentRunReceipt(
              outcome: .cancelled, assistantText: nil, events: events)
          } catch {
            result = TatwoNativeToolResult(
              callID: call.id, output: "Tool execution failed", isError: true)
          }
          guard !Task.isCancelled else {
            record(.cancelled)
            return TatwoNativeAgentRunReceipt(
              outcome: .cancelled, assistantText: nil, events: events)
          }
          executedToolCallCount += 1
          completedResults.append(result)
          record(.toolCompleted(invocation: invocation, isError: result.isError))
        }
        input.append(contentsOf: completedResults.map(TatwoNativeModelInput.toolResult))
      }
    }

    record(.stepLimitReached(maximumModelSteps: maximumModelSteps))
    return TatwoNativeAgentRunReceipt(
      outcome: .stepLimitReached, assistantText: nil, events: events)
  }
}
