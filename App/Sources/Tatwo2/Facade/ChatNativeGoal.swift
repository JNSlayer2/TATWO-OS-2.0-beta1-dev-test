import Foundation

/// Native snapshot, stored in the existing thread document. No local scheduler
/// or inferred completion percentage: only the provider reports Goal state.
struct ChatNativeGoal: Codable, Equatable {
    let threadId: String
    let objective: String
    let status: String
    let tokenBudget: Int?
    let tokensUsed: Int
    let timeUsedSeconds: Int
    let createdAt: Int
    let updatedAt: Int

    static func decode(_ value: Any) -> ChatNativeGoal? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let goal = try? JSONDecoder().decode(Self.self, from: data),
              !goal.threadId.isEmpty, !goal.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !goal.status.isEmpty, goal.createdAt >= 0, goal.updatedAt >= 0,
              goal.tokensUsed >= 0, goal.timeUsedSeconds >= 0,
              goal.tokenBudget.map({ $0 >= 0 }) ?? true else { return nil }
        return goal
    }

    var statusLabel: String {
        switch status {
        case "active": "進行中"
        case "paused": "已暫停"
        case "blocked": "待處理阻礙"
        case "usageLimited": "用量受限"
        case "budgetLimited": "預算已達上限"
        case "complete": "已完成"
        default: "狀態待確認"
        }
    }
    var canResume: Bool { ["paused", "blocked", "usageLimited"].contains(status) }
    var elapsedLabel: String {
        let hours = timeUsedSeconds / 3600
        let minutes = (timeUsedSeconds % 3600) / 60
        let seconds = timeUsedSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
    var usageLabel: String {
        if let tokenBudget { return "\(tokensUsed.formatted()) / \(tokenBudget.formatted()) tokens" }
        return "\(tokensUsed.formatted()) tokens"
    }
}
