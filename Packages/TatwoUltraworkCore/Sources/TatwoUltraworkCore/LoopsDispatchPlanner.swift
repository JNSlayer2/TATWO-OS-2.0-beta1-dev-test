import Foundation

public enum TatwoLoopsRuntimeTruthState:
  String,
  Codable,
  Sendable,
  Equatable
{
  case planningPreview = "planning_preview"
  case notDispatched = "not_dispatched"
  case dispatched
  case running
  case receiptGated = "receipt_gated"
  case blocked
}

public struct TatwoLoopsRuntimeTruthSummary:
  Codable,
  Sendable,
  Equatable
{
  public let state: TatwoLoopsRuntimeTruthState
  public let headline: String
  public let dispatchLabel: String
  public let runtimeReceiptLabel: String
  public let nextAction: String
  public let plannedAgentCount: Int
  public let activeAgentCount: Int
  public let producedArtifactCount: Int
  public let verifiedArtifactCount: Int
  public let blockedArtifactCount: Int
  public let runtimeReceiptCount: Int
  public let countsAsRuntimeProgress: Bool

  public init(
    state: TatwoLoopsRuntimeTruthState,
    headline: String,
    dispatchLabel: String,
    runtimeReceiptLabel: String,
    nextAction: String,
    plannedAgentCount: Int,
    activeAgentCount: Int,
    producedArtifactCount: Int,
    verifiedArtifactCount: Int,
    blockedArtifactCount: Int,
    runtimeReceiptCount: Int,
    countsAsRuntimeProgress: Bool
  ) {
    self.state = state
    self.headline = headline
    self.dispatchLabel = dispatchLabel
    self.runtimeReceiptLabel = runtimeReceiptLabel
    self.nextAction = nextAction
    self.plannedAgentCount = plannedAgentCount
    self.activeAgentCount = activeAgentCount
    self.producedArtifactCount = producedArtifactCount
    self.verifiedArtifactCount = verifiedArtifactCount
    self.blockedArtifactCount = blockedArtifactCount
    self.runtimeReceiptCount = runtimeReceiptCount
    self.countsAsRuntimeProgress = countsAsRuntimeProgress
  }
}

public enum TatwoLoopsDispatchPlanner {
  public static func dispatchObjective(
    session: TatwoLoopsSession,
    fallbackObjective: String? = nil
  ) -> String {
    let inheritedGoal = session.plg.goal.trimmingCharacters(in: .whitespacesAndNewlines)
    let isLegacyPlaceholder = inheritedGoal.isEmpty
      || inheritedGoal == "（待監工填寫目標）"
    guard isLegacyPlaceholder else { return inheritedGoal }
    return fallbackObjective?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  public static func composeSubTask(
    session: TatwoLoopsSession,
    subLabel: String,
    subModelID: String
  ) -> String {
    """
    給 sub 的派工內容
    狀態：這是派工內容，不代表已派發；真正啟動以 runtime dispatch record 為準。
    Sub：\(subLabel)（\(subModelID)）
    監工：\(session.supervisorModelID)
    目標：\(session.plg.goal)
    範圍（PLG）：
    - Plan：\(session.plg.plan)
    - Loops：\(session.plg.loops)
    - Goal：\(session.plg.goal)
    規則：你只做被指派的事，不得自行擴張範圍。
    回報：完成後回報給監工 \(session.supervisorModelID)。
    收據：回報產出摘要、驗證結果、blocked 原因（若有）與可重跑的測試／檢查證據。
    """
  }

  public static func runtimeTruth(
    session: TatwoLoopsSession,
    dispatchRecords: [TatwoDispatchRecord] = []
  ) -> TatwoLoopsRuntimeTruthSummary {
    let plannedAgentCount = session.subAgents.filter { $0.status == .planned }.count
    let latestCycle = session.cycles.last
    let producedArtifactCount = latestCycle?.producedCount ?? 0
    let verifiedArtifactCount = latestCycle?.verifiedCount ?? 0
    let blockedArtifactCount = latestCycle?.blockedCount ?? 0
    let ledger = TatwoDispatchRuntimeReducer.reduce(records: dispatchRecords)

    let state: TatwoLoopsRuntimeTruthState
    let headline: String
    let dispatchLabel: String
    let nextAction: String
    let countsAsRuntimeProgress: Bool

    switch ledger.phase {
    case .failed:
      state = .blocked
      headline = "執行受阻"
      dispatchLabel = ledger.progressLabel
      nextAction = "先處理 dispatch ledger 的失敗／取消原因，再以新 attempt 重派。"
      countsAsRuntimeProgress = true
    case .running:
      state = .running
      headline = "執行中"
      dispatchLabel = ledger.progressLabel
      nextAction = "等待 terminal output，並把正式 receipt 寫入 dispatch ledger。"
      countsAsRuntimeProgress = true
    case .queued, .delivered, .started:
      state = .dispatched
      headline = ledger.headline
      dispatchLabel = ledger.progressLabel
      nextAction = "等待 runner 接受並開始執行；排隊、送達與啟動不可冒充執行中。"
      countsAsRuntimeProgress = true
    case .completed:
      state = .receiptGated
      headline = "已完成，等待驗收"
      dispatchLabel = ledger.progressLabel
      nextAction = "核對 output、verifier 與 Goal criteria；完成不等於已驗收。"
      countsAsRuntimeProgress = true
    case .verified:
      state = .receiptGated
      headline = "已驗收"
      dispatchLabel = ledger.progressLabel
      nextAction = "保留 receipt 與 Goal Judge 證據鏈；App 不自行關閉正式 Goal。"
      countsAsRuntimeProgress = true
    case .none:
      if session.subAgents.isEmpty && session.cycles.isEmpty {
        state = .planningPreview
        headline = "規劃預覽"
        dispatchLabel = "尚未派發"
      } else {
        state = .notDispatched
        headline = "規劃預覽"
        dispatchLabel = "尚未派發；session 狀態、planned agents 與 artifact 計數不算 runtime 進度"
      }
      nextAction = "需要執行時，先建立 contract-bound runtime dispatch record。"
      countsAsRuntimeProgress = false
    }

    return TatwoLoopsRuntimeTruthSummary(
      state: state,
      headline: headline,
      dispatchLabel: dispatchLabel,
      runtimeReceiptLabel: ledger.runtimeReceiptLabel,
      nextAction: nextAction,
      plannedAgentCount: plannedAgentCount,
      activeAgentCount: ledger.runningCount,
      producedArtifactCount: producedArtifactCount,
      verifiedArtifactCount: verifiedArtifactCount,
      blockedArtifactCount: blockedArtifactCount,
      runtimeReceiptCount: ledger.runtimeReceiptCount,
      countsAsRuntimeProgress: countsAsRuntimeProgress)
  }

  public static func foldSubResult(
    into session: TatwoLoopsSession,
    subLabel: String,
    subModelID: String,
    resultText: String,
    verified: Bool
  ) -> TatwoLoopsSession {
    var folded = session
    folded.messages.append(
      TatwoLoopsMessage(
        role: "sub",
        authorModelID: subModelID,
        text: resultText,
        createdISO: session.messages.last?.createdISO ?? session.createdISO))

    let subStatus: TatwoLoopsStatus = verified ? .passed : .blocked
    if let subIndex = folded.subAgents.firstIndex(where: { $0.label == subLabel }) {
      folded.subAgents[subIndex].status = subStatus
    } else {
      folded.subAgents.append(
        TatwoLoopsSubAgent(
          label: subLabel,
          modelID: subModelID,
          status: subStatus))
    }

    if let cycleIndex = folded.cycles.indices.last {
      let latest = folded.cycles[cycleIndex]
      folded.cycles[cycleIndex] = TatwoLoopsCycleProgress(
        round: latest.round,
        totalRounds: latest.totalRounds,
        producedCount: latest.producedCount + 1,
        verifiedCount: latest.verifiedCount + (verified ? 1 : 0),
        blockedCount: latest.blockedCount + (verified ? 0 : 1))
    } else {
      folded.cycles.append(
        TatwoLoopsCycleProgress(
          round: 1,
          totalRounds: 1,
          producedCount: 1,
          verifiedCount: verified ? 1 : 0,
          blockedCount: verified ? 0 : 1))
    }

    return folded
  }

  public static func supervisorBriefing(
    session: TatwoLoopsSession
  ) -> String {
    let truth = runtimeTruth(session: session)
    let subRows = session.subAgents.isEmpty
      ? "- none（規劃預覽；尚未派發）"
      : session.subAgents.map {
        let status =
          $0.status == .planned
          ? "規劃預覽／尚未派發"
          : $0.status.rawValue
        return "- \($0.label)（\($0.modelID)）：\(status)"
      }.joined(separator: "\n")

    let cycleRow: String
    if let latest = session.cycles.last {
      if latest.producedCount == 0,
        latest.verifiedCount == 0,
        latest.blockedCount == 0
      {
        cycleRow =
          "規劃預覽 round \(latest.round) / \(latest.totalRounds)；"
          + "尚未派發，空 cycle 不算 runtime 進度"
      } else {
        cycleRow =
          "round \(latest.round) / \(latest.totalRounds), "
          + "produced \(latest.producedCount), "
          + "verified artifacts \(latest.verifiedCount), "
          + "blocked \(latest.blockedCount)；"
          + "artifact 計數不等於 runtime receipt"
      }
    } else {
      cycleRow = "規劃預覽；尚未派發"
    }

    return """
    當前 loop 全局狀態
    真值：\(truth.headline)
    派發：\(truth.dispatchLabel)
    收據：\(truth.runtimeReceiptLabel)
    計數口徑：planned agents、空 cycle 與 receipt requirements 都不算 runtime 進度。
    監工：\(session.supervisorModelID)
    Plan：\(session.plg.plan)
    Loops：\(session.plg.loops)
    Goal：\(session.plg.goal)
    Subs：
    \(subRows)
    最新 cycle：\(cycleRow)
    下一步：\(truth.nextAction)
    """
  }

  public static func advanceRound(
    _ session: TatwoLoopsSession
  ) -> TatwoLoopsSession {
    var advanced = session
    let nextRound = (session.cycles.last?.round ?? 0) + 1
    let totalRounds = max(session.cycles.last?.totalRounds ?? 1, nextRound)
    advanced.cycles.append(
      TatwoLoopsCycleProgress(
        round: nextRound,
        totalRounds: totalRounds,
        producedCount: 0,
        verifiedCount: 0,
        blockedCount: 0))
    return advanced
  }
}
