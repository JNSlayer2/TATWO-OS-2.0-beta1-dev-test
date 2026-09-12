import Foundation

public enum AgentKernelSchema {
  public static let version = 1
}

public enum AgentRunPhase: String, Codable, Sendable {
  case running
  case awaitingApproval
  case completed
  case failed
  case stopped
}

public enum AgentItemKind: String, Codable, Sendable {
  case message
  case toolCall
  case toolResult
}

public enum AgentUsageSource: String, Codable, Sendable, Equatable {
  case reported
  case measured
  case estimated
  case unavailable
}

public struct AgentUsage: Codable, Sendable, Equatable {
  public let source: AgentUsageSource
  public let input: Int?
  public let output: Int?
  public let unavailableReason: String?

  public init(
    source: AgentUsageSource,
    input: Int?,
    output: Int?,
    unavailableReason: String? = nil
  ) {
    self.source = source
    self.input = input
    self.output = output
    self.unavailableReason = unavailableReason
  }
}

public struct AgentKernelAttestation: Codable, Sendable, Equatable {
  public let requested: String
  public let actual: String
  public let effort: String

  public init(requested: String, actual: String, effort: String) {
    self.requested = requested
    self.actual = actual
    self.effort = effort
  }
}

public struct AgentKernelCheckpoint: Codable, Sendable, Equatable {
  public let completedStep: Int
  public let messages: [String]
  public let toolResults: [TatwoNativeToolResultRecord]

  public init(
    completedStep: Int,
    messages: [String],
    toolResults: [TatwoNativeToolResultRecord]
  ) {
    self.completedStep = completedStep
    self.messages = messages
    self.toolResults = toolResults
  }
}

public struct TatwoNativeToolResultRecord: Codable, Sendable, Equatable {
  public let callID: String
  public let output: String
  public let isError: Bool

  public init(
    callID: String,
    output: String,
    isError: Bool = false
  ) {
    self.callID = callID
    self.output = output
    self.isError = isError
  }
}

public struct AgentInvocationEvidence: Codable, Sendable, Equatable {
  public let argsHash: String
  public let resultDigest: String
  public let artifactDigests: [String]

  public init(
    argsHash: String,
    resultDigest: String,
    artifactDigests: [String]
  ) {
    self.argsHash = argsHash
    self.resultDigest = resultDigest
    self.artifactDigests = artifactDigests
  }
}

public enum AgentKernelEventPayload: Codable, Sendable, Equatable {
  case runStarted
  case checkpointCommitted(AgentKernelCheckpoint)
  case invocationStarted(id: String, sideEffecting: Bool)
  case invocationArgsRecorded(id: String, argsHash: String)
  case invocationCompleted(id: String)
  case invocationEvidenceRecorded(id: String, evidence: AgentInvocationEvidence)
  case invocationOutcomeUnknown(id: String)
  case approvalRequested(id: String)
  case approvalResolved(id: String)
  case usageReported(AgentUsage)
  case turnAttested(AgentKernelAttestation)
  case transportChanged(from: String, to: String)
  case stopped(reason: String)
}

public struct AgentKernelEvent: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let runID: String
  public let runSequence: Int
  public let eventSequence: Int
  public let occurredAt: Date
  public let payload: AgentKernelEventPayload
  public let previousEventHash: String?
  public let eventHash: String

  public init(
    runID: String,
    runSequence: Int,
    eventSequence: Int,
    occurredAt: Date = Date(),
    payload: AgentKernelEventPayload,
    previousEventHash: String? = nil
  ) {
    schemaVersion = AgentKernelSchema.version
    self.runID = runID
    self.runSequence = runSequence
    self.eventSequence = eventSequence
    self.occurredAt = occurredAt
    self.payload = payload
    self.previousEventHash = previousEventHash
    eventHash = Self.computeHash(
      schemaVersion: schemaVersion,
      runID: runID,
      runSequence: runSequence,
      eventSequence: eventSequence,
      occurredAt: occurredAt,
      payload: payload,
      previousEventHash: previousEventHash)
  }

  func sealed(after previous: AgentKernelEvent?) -> AgentKernelEvent {
    AgentKernelEvent(
      runID: runID,
      runSequence: runSequence,
      eventSequence: eventSequence,
      occurredAt: occurredAt,
      payload: payload,
      previousEventHash: previous?.eventHash)
  }

  func hasValidHash() -> Bool {
    eventHash == Self.computeHash(
      schemaVersion: schemaVersion,
      runID: runID,
      runSequence: runSequence,
      eventSequence: eventSequence,
      occurredAt: occurredAt,
      payload: payload,
      previousEventHash: previousEventHash)
  }

  private static func computeHash(
    schemaVersion: Int,
    runID: String,
    runSequence: Int,
    eventSequence: Int,
    occurredAt: Date,
    payload: AgentKernelEventPayload,
    previousEventHash: String?
  ) -> String {
    struct Material: Encodable {
      let schemaVersion: Int
      let runID: String
      let runSequence: Int
      let eventSequence: Int
      let occurredAt: Date
      let payload: AgentKernelEventPayload
      let previousEventHash: String?
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(
      Material(
        schemaVersion: schemaVersion,
        runID: runID,
        runSequence: runSequence,
        eventSequence: eventSequence,
        occurredAt: occurredAt,
        payload: payload,
        previousEventHash: previousEventHash))
    return AgentKernelDigest.sha256Hex(data)
  }
}

public struct AgentKernelSnapshot: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let runID: String
  public let lastEventSequence: Int
  public let checkpoint: AgentKernelCheckpoint?

  public init(
    runID: String,
    lastEventSequence: Int,
    checkpoint: AgentKernelCheckpoint?
  ) {
    schemaVersion = AgentKernelSchema.version
    self.runID = runID
    self.lastEventSequence = lastEventSequence
    self.checkpoint = checkpoint
  }
}
