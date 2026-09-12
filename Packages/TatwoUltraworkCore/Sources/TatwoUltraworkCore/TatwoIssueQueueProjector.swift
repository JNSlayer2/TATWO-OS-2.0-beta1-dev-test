import Foundation
import TatwoWorkReceiptContracts

/// Pure projector that turns stored goal runs and dispatch failure records into
/// `TatwoIssueProjectionV1` issue rows for the issue queue surface.
///
/// No I/O: every input is supplied by the caller. `now` is accepted for API
/// stability (projection timestamps are derived from the records themselves).
public enum TatwoIssueQueueProjector {

  public static func project(
    goalRuns: [TatwoStoredGoalRun],
    dispatchFailures: [TatwoDispatchRecord],
    now: Date
  ) -> [TatwoIssueProjectionV1] {
    var issues: [TatwoIssueProjectionV1] = []

    // One issue per goal run: if the same goalID appears more than once,
    // keep only the record with the latest updatedAt.
    var latestRunByGoalID: [String: TatwoStoredGoalRun] = [:]
    for run in goalRuns {
      if let existing = latestRunByGoalID[run.goalID], existing.updatedAt >= run.updatedAt {
        continue
      }
      latestRunByGoalID[run.goalID] = run
    }

    for run in latestRunByGoalID.values {
      guard let mapping = issueMapping(for: run.status) else { continue }
      issues.append(
        TatwoIssueProjectionV1(
          issueID: "goalrun:\(run.goalID)",
          goalRunID: run.goalID,
          title: summarize(run.objective),
          status: mapping.status,
          priority: mapping.priority,
          createdAt: run.issuedAt,
          updatedAt: run.updatedAt))
    }

    // One issue per failed dispatch record. Only records that actually carry
    // failure evidence (failure receipt, failed status, or error message)
    // are projected.
    for record in dispatchFailures {
      guard let reason = failureReason(for: record) else { continue }
      issues.append(
        TatwoIssueProjectionV1(
          issueID: "dispatch:\(record.id)",
          goalRunID: record.goalID,
          title: summarize("Dispatch \(record.id) failed: \(reason)"),
          status: .active,
          priority: .high,
          createdAt: record.failureReceipt?.occurredAt ?? record.startedAt,
          updatedAt: record.updatedAt))
    }

    return issues.sorted { lhs, rhs in
      if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
      if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
      return lhs.issueID < rhs.issueID
    }
  }

  // MARK: - Mapping

  private static func issueMapping(
    for status: GoalRunStatus
  ) -> (status: TatwoIssueProjectionStatusV1, priority: TatwoIssueProjectionPriorityV1)? {
    switch status {
    case .failed, .rollbackRequired:
      return (.active, .high)
    case .blocked:
      return (.blocked, .high)
    case .running, .dispatching:
      return (.active, .normal)
    case .humanGate:
      return (.blocked, .normal)
    case .awaitingNextCycle:
      return (.active, .normal)
    case .planned:
      return (.queued, .normal)
    case .passed, .succeeded, .cancelled, .superseded:
      return nil
    }
  }

  private static func failureReason(for record: TatwoDispatchRecord) -> String? {
    if let receipt = record.failureReceipt {
      return receipt.operatorMessage
    }
    if let message = record.errorMessage, !message.isEmpty {
      return message
    }
    if record.status == .failed {
      return "dispatch failed"
    }
    return nil
  }

  private static func summarize(_ text: String, limit: Int = 120) -> String {
    let collapsed = text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard collapsed.count > limit else { return collapsed }
    return String(collapsed.prefix(limit - 1)) + "…"
  }
}
