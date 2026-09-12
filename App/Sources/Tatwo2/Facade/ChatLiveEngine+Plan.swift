import Foundation

extension ChatLiveEngine {
    static let feedbackDiscussionRules = """
    你在 TATWO 回報模式。先用 2–3 個問題把問題釐清（重現步驟、預期 vs 實際、發生頻率）；資料齊了就在回覆最後附 ```tatwo-issue 圍欄，內含：
    ## 標題
    一句話
    ## 環境
    由 App 自動填入，不要猜測。
    ## 重現步驟
    ## 預期
    ## 實際
    ## 附註
    不要替使用者提交。只討論整理，不改檔、不執行指令，也不呼叫提交工具；使用者說「開始」也不代表同意提交。
    """
    static let planDiscussionRules = """
    你在 TATWO plan 模式：只討論不動手、不改檔、不跑會改狀態的指令；回覆最後必須附一個 ```tatwo-plan 圍欄，內含四個標題：
    ## 做什麼
    ## 動哪些檔
    ## 怎麼驗
    ## 風險與問題
    使用者說「開始」之前都維持此模式。
    """

    private func planURL(_ threadID: UUID) -> URL {
        store.url.deletingLastPathComponent().appendingPathComponent("plans", isDirectory: true)
            .appendingPathComponent("\(threadID.uuidString).json")
    }

    func loadPlanArtifact(_ threadID: UUID, recoverInterrupted: Bool = false) throws -> TatwoPlanArtifactV1? {
        let url = planURL(threadID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var plan = try JSONDecoder.tatwoPlanArtifact.decode(TatwoPlanArtifactV1.self, from: Data(contentsOf: url))
        guard plan.threadID == threadID, plan.schema == TatwoPlanArtifactV1.schemaName else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if recoverInterrupted, plan.recoverInterruptedPR(hasActiveTurn: isRunning(threadID) || onTurnComplete[threadID] != nil) {
            try savePlanArtifact(plan)
        }
        return plan
    }

    func savePlanArtifact(_ plan: TatwoPlanArtifactV1) throws {
        let url = planURL(plan.threadID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plan.canonicalJSONData().write(to: url, options: .atomic)
        onPlanChange?(plan)
    }

    /// Appends to the existing engine-only outgoing text, never the user row.
    func planContext(_ plan: TatwoPlanArtifactV1?, userText: String) -> String? {
        guard let plan else { return nil }
        if plan.kind == "feedback" {
            return Self.feedbackDiscussionRules + "\n目前畫布：\n" + plan.editableText()
        }
        if plan.kind == "pr" {
            if plan.state == .discussing {
                return Self.planDiscussionRules + "\n這是要送回公開倉庫的貢獻；必須等人按畫布「確認」，文字「開始」不算確認。\n目前畫布：\n" + plan.editableText()
            }
            if plan.state == .confirmed, onTurnComplete[plan.threadID] != nil { return nil }
            return "PR 計畫已確認；只討論，不改檔、不 commit、不 push、不開 PR。實作只能由畫布確認啟動，提交只能按「送 PR」。"
        }
        if plan.state == .discussing { return Self.planDiscussionRules }
        guard plan.executionTurnID == nil else { return nil }
        if userText.trimmingCharacters(in: .whitespacesAndNewlines) == "開始" {
            return "使用者已確認以下計畫：\n\(plan.editableText())\n現在可以動手。"
        }
        return Self.planDiscussionRules + "\n計畫已確認，但使用者尚未說「開始」，不可執行。"
    }

    func updatePlanFromReply(_ threadID: UUID, reply: ChatMessage) {
        do {
            guard var plan = try loadPlanArtifact(threadID), plan.state == .discussing else { return }
            let parsed = plan.kind == "feedback"
                ? TatwoPlanArtifactV1.parseSections(fromReply: reply.text, fenceName: "tatwo-issue")
                : TatwoPlanArtifactV1.parseSections(fromReply: reply.text)
            guard var sections = parsed else { return }
            if plan.kind == "feedback", let environment = plan.sections.first(where: { $0.title == "環境" }) {
                sections.removeAll { $0.title == "環境" }
                sections.insert(environment, at: min(1, sections.count))
            }
            plan.updateDiscussion(objective: plan.objective, sections: sections)
            plan.sourceAssistantMessageID = reply.id
            try savePlanArtifact(plan)
        } catch {
            appendSystemMessage(threadID: threadID, text: "計畫畫布未能儲存；回覆仍保留在對話中。", status: "error|Plan")
        }
    }
}
