import Foundation

/// Narrow test seam; production conformance is the existing live engine, not a substitute.
@MainActor protocol DispatchRoomMessaging: AnyObject {
    func markSubStatus(_ threadID: UUID, _ status: String)
    func appendSystemMessage(threadID: UUID, text: String, status: String)
    @discardableResult func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind, systemPrompt: String?, attachments: [String]) -> Bool
}
extension ChatLiveEngine: DispatchRoomMessaging {}

enum DispatchRoomActions {
    @MainActor static func recordMerge(_ context: DispatchGitContext, sha: String, messenger: any DispatchRoomMessaging) {
        messenger.appendSystemMessage(threadID: context.id,
            text: "已合併子任務 \(context.title)（\(context.branch)），合併 commit \(sha)", status: "info|派工合併")
    }
    @MainActor static func returnRoom(_ context: DispatchGitContext, reason: String, engine: ClaudeSidecar.Kind, messenger: any DispatchRoomMessaging) throws {
        try context.requireLocal()
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DispatchGitFailure(message: "請填退回原因") }
        messenger.markSubStatus(context.id, "running")
        messenger.send(threadID: context.id, text: "【退回重做】" + text, model: nil, engine: engine, systemPrompt: nil, attachments: [])
    }
}
