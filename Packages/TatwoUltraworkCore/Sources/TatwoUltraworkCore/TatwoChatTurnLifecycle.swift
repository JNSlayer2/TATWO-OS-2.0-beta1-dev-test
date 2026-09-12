import CryptoKit
import Darwin
import Foundation

public enum TatwoChatRunnerLifecyclePhase: String, Codable, Sendable, Equatable {
  case running
  case terminationRequested
  case terminated
}

public struct TatwoChatRunnerLivenessSnapshot: Sendable, Equatable {
  public let runID: String
  public let phase: TatwoChatRunnerLifecyclePhase
  public let processIsAlive: Bool
  public let lastActivityAt: Date
  public let formalExitStatus: Int32?
  public let formalFailureMessage: String?

  public init(
    runID: String,
    phase: TatwoChatRunnerLifecyclePhase,
    processIsAlive: Bool,
    lastActivityAt: Date,
    formalExitStatus: Int32?,
    formalFailureMessage: String? = nil
  ) {
    self.runID = runID
    self.phase = phase
    self.processIsAlive = processIsAlive
    self.lastActivityAt = lastActivityAt
    self.formalExitStatus = formalExitStatus
    self.formalFailureMessage = formalFailureMessage
  }
}

public enum TatwoChatTurnLifecyclePhase: String, Codable, Sendable, Equatable {
  case running
  case cancellationRequested
  case terminal
}

public struct TatwoChatTurnLifecycle: Sendable, Equatable {
  public let runID: String
  public let assistantID: String
  public let runnerInstanceID: UUID
  public let runnerRevision: UInt64
  public let computerHostRoute: TatwoComputerHostTurnRoute
  public let startedAt: Date
  public private(set) var phase: TatwoChatTurnLifecyclePhase
  public private(set) var formalExitStatus: Int32?

  public init(
    runID: String,
    assistantID: String,
    runnerInstanceID: UUID = UUID(),
    runnerRevision: UInt64 = 1,
    computerHostRoute: TatwoComputerHostTurnRoute = .none,
    startedAt: Date = Date()
  ) {
    self.runID = runID
    self.assistantID = assistantID
    self.runnerInstanceID = runnerInstanceID
    self.runnerRevision = runnerRevision
    self.computerHostRoute = computerHostRoute
    self.startedAt = startedAt
    self.phase = .running
    self.formalExitStatus = nil
  }

  @discardableResult
  public mutating func requestCancellation() -> Bool {
    guard phase == .running else { return false }
    phase = .cancellationRequested
    return true
  }

  public func shouldAcceptNonTerminalEvent(runID: String) -> Bool {
    self.runID == runID && phase == .running
  }

  @discardableResult
  public mutating func recordFormalTerminalEvent(
    runID: String,
    status: Int32
  ) -> Bool {
    guard self.runID == runID, phase != .terminal else { return false }
    phase = .terminal
    formalExitStatus = status
    return true
  }

  public func shouldReconcileInactiveRunner(
    snapshot: TatwoChatRunnerLivenessSnapshot,
    now: Date = Date()
  ) -> Bool {
    _ = now
    return phase != .terminal
      && snapshot.runID == runID
      && snapshot.phase == .terminated
      && !snapshot.processIsAlive
      && snapshot.formalExitStatus != nil
  }
}
