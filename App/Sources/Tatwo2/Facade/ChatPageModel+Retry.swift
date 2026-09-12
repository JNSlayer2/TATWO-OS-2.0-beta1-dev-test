import Foundation

extension ChatPageModel {
    /// 錯誤卡上的「再送一次」：把這條串最後一句你說的話原樣再送給目前的引擎。
    /// 回合還在跑就不動（避免重複送）。
    func resendLastUserMessage() {
        guard !isRunning else { return }
        guard let last = transcriptMessages.last(where: { $0.role == .user }) else { return }
        prompt = last.text
        send()
    }

    var canRetryLastTurn: Bool {
        !isRunning && transcriptMessages.contains { $0.role == .user }
    }
}
