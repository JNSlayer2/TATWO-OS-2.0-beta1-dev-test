// 來源：Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+FixturesAndPersistence.swift:850-932；只保留 11 個 Chat 金樣場景的純資料
import Foundation

struct ChatFixture {
    let sceneID: String
    let threadTitle: String
    let messages: [ChatMessage]
    let isRunning: Bool
    let selectedModel: String
    let hasWorkOSGoal: Bool

    static func resolve(environment: [String: String]) -> ChatFixture {
        let scene = environment["TATWO_ULTRAWORK_EXPORT_CHAT_SCENE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "send"
        return make(sceneID: supportedSceneIDs.contains(scene) ? scene : "send")
    }

    static let supportedSceneIDs = [
        "send", "stream", "stop", "resume", "slash", "plg",
        "engine_switch", "reattach", "cold_start", "orphan", "queued_turn",
    ]

    private static func make(sceneID: String) -> ChatFixture {
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func row(
            _ suffix: String,
            _ role: ChatMessageRole,
            _ text: String,
            status: String? = nil,
            offset: TimeInterval
        ) -> ChatMessage {
            ChatMessage(
                id: "g3-\(sceneID)-\(suffix)",
                role: role,
                text: text,
                status: status,
                eventKind: .message,
                createdAt: startedAt.addingTimeInterval(offset))
        }

        let messages: [ChatMessage]
        switch sceneID {
        case "stream":
            messages = [
                row("user", .user, "串流整理目前的 Chat 金樣捕捉條件。", offset: 0),
                row("assistant", .assistant, "正在整理：場景固定、viewport 固定、PNG bytes hash 固定…", status: "writing|串流回覆中", offset: 14),
            ]
        case "stop":
            messages = [
                row("user", .user, "開始盤點，但我會在中途停止。", offset: 0),
                row("partial", .assistant, "已盤點場景注入與尺寸守門；sidecar 驗證尚未完成。", status: "cancelled|使用者已停止", offset: 12),
            ]
        case "resume":
            messages = [
                row("user-1", .user, "先完成第一段盤點。", offset: 0),
                row("assistant-1", .assistant, "第一段已完成：確認沿用同一 thread 與 execution spine。", status: "done", offset: 12),
                row("user-2", .user, "在同一個 thread 繼續。", offset: 22),
                row("assistant-2", .assistant, "已從原進度續跑，沒有建立新的 thread。", status: "done", offset: 36),
            ]
        case "slash":
            messages = [
                row("user", .user, "/plan 檢查 11 場景視覺金樣", offset: 0),
                row("assistant", .assistant, "Plan 已建立：注入、捕捉、hash、manifest、獨立驗證。", status: "done", offset: 14),
            ]
        case "plg":
            messages = [
                row("user", .user, "/plg 清償 G3-1 視覺債", offset: 0),
                row("assistant", .assistant, "Plan：建立 export-only 場景；Loops：捕捉 11 張；Goal：PNG 與 sidecar hash 全部鎖定。", status: "planning|PLG 已綁定 Goal", offset: 16),
            ]
        case "engine_switch":
            messages = [
                row("user-1", .user, "先用 gpt-5.6-sol 檢查注入層。", offset: 0),
                row("assistant-1", .assistant, "注入守門完成，thread transcript 保持連續。", status: "done", offset: 12),
                row("user-2", .user, "同一 thread 切換到 Sonnet 5 做視覺副審。", offset: 22),
                row("assistant-2", .assistant, "已切換引擎；沿用原 thread 與既有訊息。", status: "done", offset: 34),
            ]
        case "reattach":
            messages = [
                row("user", .user, "重新掛接仍在執行的金樣捕捉。", offset: 0),
                row("assistant", .assistant, "已重掛同一工作；保留先前輸出，不重放已完成副作用。", status: "waiting|已重掛 · 執行中", offset: 15),
            ]
        case "cold_start":
            messages = [
                row("user", .user, "從 durable 狀態恢復這個 Chat。", offset: 0),
                row("assistant", .assistant, "冷啟動恢復完成：thread、訊息與上次可續跑位置已還原。", status: "done", offset: 16),
            ]
        case "orphan":
            messages = [
                row("user", .user, "這是沒有 Goal 的一般閒聊，可以正常存在嗎？", offset: 0),
                row("assistant", .assistant, "可以。一般聊天不需要 Goal，也不會被 PLG spine 閘誤殺。", status: "done", offset: 14),
            ]
        case "queued_turn":
            messages = [
                row("user-1", .user, "先執行第一個回合。", offset: 0),
                row("assistant-1", .assistant, "第一個回合正在產生可驗收輸出…", status: "writing|第 1 回合執行中", offset: 12),
                row("user-2", .user, "接著再驗證 sidecar hash。", status: "queued|已排入第 2 回合", offset: 18),
            ]
        default:
            messages = [
                row("user", .user, "請確認這則訊息已送出，並回覆可驗收結果。", offset: 0),
                row("assistant", .assistant, "已收到並完成回覆；本回合有可見輸出與完成狀態。", status: "done", offset: 18),
            ]
        }

        return ChatFixture(
            sceneID: sceneID,
            threadTitle: sceneID == "orphan" ? "一般 thread smoke" : "C0 Chat \(sceneID)",
            messages: messages,
            isRunning: ["stream", "reattach", "queued_turn"].contains(sceneID),
            selectedModel: sceneID == "engine_switch" ? "sonnet5" : "gpt-5.5",
            hasWorkOSGoal: sceneID == "plg")
    }
}
