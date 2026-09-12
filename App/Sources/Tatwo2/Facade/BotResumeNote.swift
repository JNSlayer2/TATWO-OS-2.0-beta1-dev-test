import Foundation

struct BotStateUpdateResult: Codable {
    var conflict: Bool
    var current: BotMemoryState
    var yours: BotMemoryStatePatch?
}
struct BotPendingResult: Codable, Equatable {
    var id: String
    var text: String
    var at: String
    var status: String
}
struct BotResumeNote: Codable, Equatable {
    var lastSessionAt: String?
    var currentTask: String?
    var nextSteps: [String]
    var openQuestions: [String]
    var pendingCount: Int
    var recentEvents: [BotMemoryEvent]
    var summary: String {
        "上次做到：\(currentTask ?? "無")；下一步：\(nextSteps.joined(separator: "、"))；還沒解決：\(openQuestions.joined(separator: "、"))"
    }
}
