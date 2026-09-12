import Foundation

public struct TatwoLoopsSubActivityInput: Sendable, Equatable {
  public let id: String
  public let contractID: String
  public let identity: String
  public let modelName: String
  public let subtask: String
  public let queued: Bool
  public let startedAt: Date

  public init(
    id: String,
    contractID: String,
    identity: String,
    modelName: String,
    subtask: String,
    queued: Bool,
    startedAt: Date
  ) {
    self.id = id
    self.contractID = contractID
    self.identity = identity
    self.modelName = modelName
    self.subtask = subtask
    self.queued = queued
    self.startedAt = startedAt
  }
}

public enum TatwoLoopsContractActivityPhase: String, Sendable, Equatable {
  case running
  case awaitingAcceptance
  case blocked
  case completed
}

public enum TatwoLoopsSubActivityStatus: String, Sendable, Equatable {
  case queued = "排隊"
  case running = "執行中"
  case awaitingAcceptance = "等待驗收"
  case blocked = "受阻"
  case completed = "已完成"
}

public struct TatwoLoopsSubActivityPresentationRow:
  Identifiable,
  Sendable,
  Equatable
{
  public let id: String
  public let identity: String
  public let modelName: String
  public let currentWork: String
  public let status: TatwoLoopsSubActivityStatus
  public let elapsedSeconds: TimeInterval
  public let elapsedLabel: String
  public let stepNumber: Int
}

public enum TatwoLoopsSubActivityPresentation: Sendable, Equatable {
  case empty(message: String)
  case rows([TatwoLoopsSubActivityPresentationRow])
}

public enum TatwoLoopsSubActivityPresenter {
  public static func present(
    rows: [TatwoLoopsSubActivityInput],
    currentContractID: String,
    phase: TatwoLoopsContractActivityPhase,
    now: Date
  ) -> TatwoLoopsSubActivityPresentation {
    let matching = rows
      .filter { $0.contractID == currentContractID }
      .sorted { lhs, rhs in
        let lhsRank = sortRank(input: lhs, phase: phase)
        let rhsRank = sortRank(input: rhs, phase: phase)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id < rhs.id
      }

    guard !matching.isEmpty else {
      return .empty(message: "目前沒有 sub 在跑")
    }

    return .rows(
      matching.enumerated().map { index, input in
        let elapsed = max(0, now.timeIntervalSince(input.startedAt))
        return TatwoLoopsSubActivityPresentationRow(
          id: input.id,
          identity: input.identity,
          modelName: input.modelName,
          currentWork: input.subtask.isEmpty ? "未提供目前工作摘要" : input.subtask,
          status: status(input: input, phase: phase),
          elapsedSeconds: elapsed,
          elapsedLabel: elapsedLabel(seconds: elapsed),
          stepNumber: index + 1)
      })
  }

  private static func status(
    input: TatwoLoopsSubActivityInput,
    phase: TatwoLoopsContractActivityPhase
  ) -> TatwoLoopsSubActivityStatus {
    switch phase {
    case .awaitingAcceptance: return .awaitingAcceptance
    case .blocked: return .blocked
    case .completed: return .completed
    case .running: return input.queued ? .queued : .running
    }
  }

  private static func sortRank(
    input: TatwoLoopsSubActivityInput,
    phase: TatwoLoopsContractActivityPhase
  ) -> Int {
    switch status(input: input, phase: phase) {
    case .running: return 0
    case .queued: return 1
    case .awaitingAcceptance: return 2
    case .blocked: return 3
    case .completed: return 4
    }
  }

  private static func elapsedLabel(seconds: TimeInterval) -> String {
    let wholeSeconds = Int(seconds.rounded(.down))
    let hours = wholeSeconds / 3_600
    let minutes = (wholeSeconds % 3_600) / 60
    let seconds = wholeSeconds % 60
    if hours > 0 { return "\(hours) 小時 \(minutes) 分" }
    if minutes > 0 { return "\(minutes) 分 \(seconds) 秒" }
    return "\(seconds) 秒"
  }
}
