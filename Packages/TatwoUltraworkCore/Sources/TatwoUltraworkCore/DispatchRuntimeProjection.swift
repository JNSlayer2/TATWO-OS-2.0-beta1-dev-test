import Foundation

/// The only reducer allowed to turn dispatch-ledger records into user-facing
/// execution state. Planning sessions, branch projections, and artifact
/// counters are intentionally excluded.
public enum TatwoDispatchRuntimePhase:
  String,
  Codable,
  Sendable,
  Equatable
{
  case none
  case queued
  case delivered
  case started
  case running
  case completed
  case verified
  case failed
}

public struct TatwoDispatchRuntimeSummary:
  Codable,
  Sendable,
  Equatable
{
  public let phase: TatwoDispatchRuntimePhase
  public let recordCount: Int
  public let queuedCount: Int
  public let deliveredCount: Int
  public let startedCount: Int
  public let runningCount: Int
  public let completedCount: Int
  public let verifiedCount: Int
  public let failedCount: Int
  public let cancelledCount: Int
  public let runtimeReceiptCount: Int

  public var activeCount: Int {
    queuedCount + deliveredCount + startedCount + runningCount
  }

  public var terminalCount: Int {
    completedCount + failedCount + cancelledCount
  }

  /// Latest logical dispatches that reached an execution outcome. Verification
  /// is a later acceptance state, so it is settled but not counted again as an
  /// execution terminal.
  public var settledCount: Int {
    completedCount + verifiedCount + failedCount + cancelledCount
  }

  /// Latest logical dispatches accepted by a runtime, including every later
  /// execution or settlement phase. Queued and delivered work is not accepted.
  public var acceptedCount: Int {
    startedCount + runningCount + settledCount
  }

  public var hasRuntimeEvidence: Bool {
    recordCount > 0
  }

  public var headline: String {
    switch phase {
    case .none: return "尚未派發"
    case .queued: return "已排隊"
    case .delivered: return "已送達"
    case .started: return "已啟動"
    case .running: return "執行中"
    case .completed: return "已完成，等待驗收"
    case .verified: return "已驗收"
    case .failed: return "執行受阻"
    }
  }

  public var progressLabel: String {
    guard hasRuntimeEvidence else {
      return "dispatch ledger 尚無紀錄"
    }
    return [
      queuedCount > 0 ? "\(queuedCount) 排隊" : nil,
      deliveredCount > 0 ? "\(deliveredCount) 送達" : nil,
      startedCount > 0 ? "\(startedCount) 啟動" : nil,
      runningCount > 0 ? "\(runningCount) 執行" : nil,
      completedCount > 0 ? "\(completedCount) 完成" : nil,
      verifiedCount > 0 ? "\(verifiedCount) 驗收" : nil,
      failedCount > 0 ? "\(failedCount) 失敗" : nil,
      cancelledCount > 0 ? "\(cancelledCount) 取消" : nil,
    ]
    .compactMap { $0 }
    .joined(separator: " · ")
  }

  public var runtimeReceiptLabel: String {
    runtimeReceiptCount == 0
      ? "無 runtime receipt"
      : "\(runtimeReceiptCount) 份 runtime receipt"
  }
}

public struct TatwoDispatchRuntimeProjection:
  Sendable,
  Equatable
{
  public let canonicalRecords: [TatwoDispatchRecord]
  public let summary: TatwoDispatchRuntimeSummary

  public init(
    canonicalRecords: [TatwoDispatchRecord],
    summary: TatwoDispatchRuntimeSummary
  ) {
    self.canonicalRecords = canonicalRecords
    self.summary = summary
  }
}

public enum TatwoDispatchRuntimeReducer {
  public static func project(
    records: [TatwoDispatchRecord],
    contractID: String? = nil
  ) -> TatwoDispatchRuntimeProjection {
    let canonicalRecords = latestRecords(
      records.filter { record in
        guard let contractID else { return true }
        return record.contractID == contractID
      })
    return TatwoDispatchRuntimeProjection(
      canonicalRecords: canonicalRecords,
      summary: summarize(canonicalRecords))
  }

  public static func reduce(
    records: [TatwoDispatchRecord],
    contractID: String? = nil
  ) -> TatwoDispatchRuntimeSummary {
    project(records: records, contractID: contractID).summary
  }

  private static func summarize(
    _ scoped: [TatwoDispatchRecord]
  ) -> TatwoDispatchRuntimeSummary {
    var queuedCount = 0
    var deliveredCount = 0
    var startedCount = 0
    var runningCount = 0
    var completedCount = 0
    var verifiedCount = 0
    var failedCount = 0
    var cancelledCount = 0

    for record in scoped {
      switch phase(for: record) {
      case .none:
        break
      case .queued:
        queuedCount += 1
      case .delivered:
        deliveredCount += 1
      case .started:
        startedCount += 1
      case .running:
        runningCount += 1
      case .completed:
        completedCount += 1
      case .verified:
        verifiedCount += 1
      case .failed:
        if record.remoteStatus == .cancelled {
          cancelledCount += 1
        } else {
          failedCount += 1
        }
      }
    }

    let aggregatePhase: TatwoDispatchRuntimePhase
    if failedCount > 0 || cancelledCount > 0 {
      aggregatePhase = .failed
    } else if runningCount > 0 {
      aggregatePhase = .running
    } else if startedCount > 0 {
      aggregatePhase = .started
    } else if deliveredCount > 0 {
      aggregatePhase = .delivered
    } else if queuedCount > 0 {
      aggregatePhase = .queued
    } else if completedCount > 0 {
      aggregatePhase = .completed
    } else if verifiedCount > 0 {
      aggregatePhase = .verified
    } else {
      aggregatePhase = .none
    }

    let runtimeReceiptCount = scoped.compactMap {
      $0.receiptID?.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }.count

    return TatwoDispatchRuntimeSummary(
      phase: aggregatePhase,
      recordCount: scoped.count,
      queuedCount: queuedCount,
      deliveredCount: deliveredCount,
      startedCount: startedCount,
      runningCount: runningCount,
      completedCount: completedCount,
      verifiedCount: verifiedCount,
      failedCount: failedCount,
      cancelledCount: cancelledCount,
      runtimeReceiptCount: runtimeReceiptCount)
  }

  public static func phase(
    for record: TatwoDispatchRecord
  ) -> TatwoDispatchRuntimePhase {
    if let remoteStatus = record.remoteStatus {
      switch remoteStatus {
      case .queued: return .queued
      case .delivered: return .delivered
      case .accepted: return .started
      case .running: return .running
      case .completed: return .completed
      case .verified: return .verified
      case .failed, .cancelled: return .failed
      }
    }

    switch record.status {
    case .queued: return .queued
    case .running: return .running
    case .completed: return .completed
    case .verified: return .verified
    case .failed: return .failed
    }
  }

  private static func latestRecords(
    _ records: [TatwoDispatchRecord]
  ) -> [TatwoDispatchRecord] {
    var latest: [String: TatwoDispatchRecord] = [:]
    for record in records {
      let trimmedBinding = record.bindingID
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let key = trimmedBinding.isEmpty
        ? record.resolvedLogicalDispatchID
        : trimmedBinding
      guard let existing = latest[key] else {
        latest[key] = record
        continue
      }
      if record.resolvedAttempt > existing.resolvedAttempt
        || (
          record.resolvedAttempt == existing.resolvedAttempt
            && record.updatedAt > existing.updatedAt
        )
        || (
          record.resolvedAttempt == existing.resolvedAttempt
            && record.updatedAt == existing.updatedAt
            && record.id < existing.id
        )
      {
        latest[key] = record
      }
    }
    return latest.values.sorted {
      if $0.updatedAt != $1.updatedAt {
        return $0.updatedAt > $1.updatedAt
      }
      return $0.id < $1.id
    }
  }
}
