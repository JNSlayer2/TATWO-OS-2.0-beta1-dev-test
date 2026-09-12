import SwiftUI
import AppKit
import Foundation
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

private enum ChatBrowserLifecycleMutationError: Error {
    case selectionChanged
    case threadMissing
    case persistenceFailed
}

enum LoopsSessionSelectionPolicy {
    static func toggledSelection(
        current: UUID?,
        tapped: UUID
    ) -> UUID? {
        current == tapped ? nil : tapped
    }
}

extension ChatPageModel {
    // MARK: #16 loops session（右列收納串）

    var selectedThreadLoopsSessions: [TatwoLoopsSession] {
        let sessions =
            selectedDiscussion?.loopsSessions
            ?? selectedThread?.loopsSessions
            ?? []
        return sessions.filter { !$0.isArchived }
    }

    var selectedThreadArchivedLoopsSessions: [TatwoLoopsSession] {
        let sessions =
            selectedDiscussion?.loopsSessions
            ?? selectedThread?.loopsSessions
            ?? []
        return sessions.filter(\.isArchived)
    }

    var selectedDispatchRuntimeProjection: TatwoDispatchRuntimeProjection {
        TatwoDispatchRuntimeReducer.project(records: selectedDispatchRecords)
    }

    /// 監工來源：thread 主導 model（loopsConfig.primaryModelID）→ 否則當前選定模型。
    /// 這保證同一 thread 體系下 loops 的監工＝主 chat 的監工（需求 4/5）。
    var selectedThreadSupervisorModelID: String {
        selectedThread?.loopsConfig?.primaryModelID ?? selectedModel
    }

    /// #16 app 真實 loops 工作即時列：來自 Work OS dispatch 紀錄。
    /// 每次 os app 跑 ultrawork 協作派工，這裡就自動有內容 → loops UI 一眼看「做到哪／還在跑／各 sub 狀態」。
    var loopsLiveRows: [TatwoLoopsLiveRow] {
        // Discussion is a branch-local session. It must not present parent
        // dispatch activity as if the branch owned or completed it.
        guard !isDiscussionSessionSelected else { return [] }
        let projection = selectedDispatchRuntimeProjection
        #if DEBUG
        // demo（headless 自驗）：無真實 contract 記錄時，用 env 提供樣本；真實記錄一律優先。
        if projection.canonicalRecords.isEmpty,
           ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_LOOPS_LIVE_DEMO"] == "1" {
            return [
                TatwoLoopsLiveRow(id: "d1", identity: "sub", modelID: "gpt-5.6-sol", statusLabel: "已完成", detail: "盤點 Core 型別與 API 數", phase: .completed),
                TatwoLoopsLiveRow(id: "d2", identity: "sub", modelID: "gpt-5.6-sol", statusLabel: "執行中", detail: "盤點 LoopsSessionRail UI 區塊", phase: .running),
                TatwoLoopsLiveRow(id: "d3", identity: "verifier", modelID: "gpt-5.6-terra", statusLabel: "已排隊", detail: "交叉驗證測試涵蓋", phase: .queued)
            ]
        }
        #endif
        return projection.canonicalRecords
            .map { r in
                // Prefer remote five-state design labels (covers wire `.accepted` → 已啟動).
                // Fall back to local dispatch designSemanticLabel — never invent ad-hoc English.
                let label =
                    r.remoteStatus?.designSemanticLabel ?? r.status.designSemanticLabel
                let detail = r.subtask.trimmingCharacters(in: .whitespacesAndNewlines)
                return TatwoLoopsLiveRow(
                    id: r.id,
                    identity: r.identity.rawValue,
                    modelID: r.modelID,
                    statusLabel: label,
                    detail: detail.isEmpty ? "dispatch receipt" : detail,
                    phase: TatwoDispatchRuntimeReducer.phase(for: r),
                    startedAt: r.startedAt)
            }
    }

    @discardableResult
    func createLoopsSessionForSelectedThread() -> UUID? {
        guard let thread = selectedThread else { return nil }
        let supervisor = selectedThreadSupervisorModelID
        let reviewer = thread.loopsConfig?.secondaryModelID
        let projectID = selectedThreadProject?.id ?? thread.id
        let supervisorName = TatwoChatRouteProfile.resolve(supervisor).displayName
        let reviewerLine = reviewer.map { "／副審：\(TatwoChatRouteProfile.resolve($0).displayName)" } ?? "（無副審，主導直帶）"
        let inheritedGoal = [
            selectedGoalRecord?.objective,
            selectedWorkOSContract?.objective,
            activePLGRun?.planSummary,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })
            ?? selectedThreadWorkOSContext(thread: thread).objective
        let plg = TatwoLoopsPLG(
            plan: "（待監工填寫計畫）",
            loops: "主導：\(supervisorName)\(reviewerLine)",
            goal: inheritedGoal)
        let parentKind: TatwoLoopsParentKind = selectedDiscussion == nil ? .thread : .discussion
        let parentID = selectedDiscussion?.id ?? thread.id
        let session = TatwoLoopsSupervisorRule.make(
            parentSupervisorModelID: supervisor,
            parentKind: parentKind,
            parentID: parentID,
            projectID: projectID,
            title: "新 loops · \(supervisorName)",
            plg: plg,
            reviewerModelID: reviewer)
        if selectedDiscussion != nil {
            mutateSelectedDiscussion { discussion in
                discussion.loopsSessions.insert(session, at: 0)
            }
        } else {
            mutateSelectedThread { t in
                t.loopsSessions.insert(session, at: 0)
                t.updatedAt = Date()
            }
        }
        selectedLoopsSessionID = session.id
        return session.id
    }

    func selectLoopsSession(_ id: UUID) {
        selectedLoopsSessionID = LoopsSessionSelectionPolicy.toggledSelection(
            current: selectedLoopsSessionID,
            tapped: id)
    }

    /// D① 變更收據：讀當前 thread 工作目錄的 git diff（vs HEAD，含 staged/unstaged）並解析。
    func loadWorkspaceDiff() -> TatwoParsedDiff {
        if ProcessInfo.processInfo.environment[
            "TATWO_ULTRAWORK_CHAT_COMPLETION_REPORT_FIXTURE"] == "1"
        {
            return TatwoParsedDiff(files: [
                TatwoDiffFile(
                    oldPath:
                        "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageLeafViews.swift",
                    newPath:
                        "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageLeafViews.swift",
                    changeKind: .modified,
                    hunks: [],
                    addedCount: 18,
                    removedCount: 17),
                TatwoDiffFile(
                    oldPath:
                        "Apps/TatwoUltraworkMac/Tests/TatwoUltraworkMacTests/ChatPlanThoughtPresentationTests.swift",
                    newPath:
                        "Apps/TatwoUltraworkMac/Tests/TatwoUltraworkMacTests/ChatPlanThoughtPresentationTests.swift",
                    changeKind: .modified,
                    hunks: [],
                    addedCount: 5,
                    removedCount: 1),
            ])
        }
        let workdir = currentConversationWorkspaceURL().path
        let out = Self.runLoginShellCapture(
            command: "git -C \(Self.shellQuote(workdir)) diff HEAD 2>/dev/null",
            timeout: 20) ?? ""
        return TatwoDiffHunkParser.parse(unifiedDiff: out)
    }

    /// WORK_OS.md「Issue List / 支線等待佇列」：
    /// `/issue <文字>` 捕捉選取文字/想法為佇列項；`/issue`／`/issue list` 打開資訊卡的佇列。
    /// 佇列 ≠ 執行：不派工、不建 contract；一切等使用者明確 activate。不進 thread 訊息流。
    func handleIssueSlashCommand() {
        let sub = TatwoSlashCommandParser.objective(from: prompt, commands: ["/issue"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = ""
        captureIssueSlashCommand(argument: sub)
        reloadIssueList()
        if sub.isEmpty || sub.lowercased() == "list" {
            flashComposerHint(issueListEntries.isEmpty
                ? "Issue list 是空的"
                : "Issue list \(issueListEntries.count) 筆等待中")
        }
        issueProjectionRan = true
        requestOpenInfoCard = true
    }

    func captureIssueSlashCommand(argument: String) {
        let sub = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sub.isEmpty, sub.lowercased() != "list" {
            // 多行捕捉：第一行=標題、其餘行=詳細內文（composer Shift+Enter 換行）。
            let lines = sub.split(separator: "\n", omittingEmptySubsequences: false)
            let firstLine = lines.first.map(String.init) ?? sub
            let title = String(firstLine.prefix(60))
            let detail = lines.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            issueListStore.capture(
                title: title,
                body: detail.isEmpty ? sub : detail,
                sourceType: .chat,
                sourceReference: selectedThread?.title ?? "composer",
                threadReference: selectedThreadID?.uuidString,
                projectReference: selectedThreadProject?.id.uuidString)
            flashComposerHint("已捕捉進 issue list：\(title)")
        }
    }

    /// 從當前討論捕捉（資訊卡「＋」）：存標題與最近內容摘要，來源參照完整保留。
    func captureCurrentDiscussionIntoIssueList() {
        guard let thread = selectedThread else { return }
        let excerpt = (thread.messages ?? []).suffix(3).map(\.text).joined(separator: "\n")
        issueListStore.capture(
            title: String(thread.title.prefix(60)),
            body: excerpt.isEmpty ? thread.lastPreview : excerpt,
            sourceType: .chat,
            sourceReference: thread.title,
            threadReference: thread.id.uuidString,
            projectReference: selectedThreadProject?.id.uuidString)
        reloadIssueList()
        flashComposerHint("已捕捉當前討論進 issue list")
    }

    /// 三段式確認通過後的移除：只刪佇列項，來源 plan/chat 不動（規格鐵律）。
    func removeIssueListEntry(_ id: String) {
        issueListStore.remove(id: id)
        reloadIssueList()
    }

    /// Right-card quick × is intentionally non-destructive: archive it so the
    /// issue remains recoverable in Settings → Issue List.
    func archiveIssueListEntry(_ id: String) {
        issueListStore.setStatus(id: id, status: .archived)
        if focusedIssueEntryID == id { focusedIssueEntryID = nil }
        reloadIssueList()
        flashComposerHint("Issue 已封存；可在設定 → Issue List 還原。")
    }

    /// 展開處補寫內文（先快速入列、之後補細節）。
    func updateIssueListEntryBody(_ id: String, body: String) {
        issueListStore.updateBody(id: id, body: body)
        reloadIssueList()
    }

    func issueImageURLs(for entry: TatwoIssueListEntryV1) -> [URL] {
        entry.imageAssetPaths.compactMap { imageAssetStore.resolve(relativePath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func issueImageURL(relativeAssetPath: String) -> URL? {
        guard let url = imageAssetStore.resolve(relativePath: relativeAssetPath),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    func addImageNotes(to entry: TatwoIssueListEntryV1) {
        let panel = NSOpenPanel()
        panel.title = "附加 Issue 圖片備註"
        panel.prompt = "附加圖片"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard TatwoModalPanelGate.run({ panel.runModal() }) == .OK else { return }

        var imageAssets = entry.imageAssetPaths
        var failures: [String] = []
        for url in panel.urls {
            do {
                let asset = try imageAssetStore.ingest(fileURL: url)
                if !imageAssets.contains(asset.relativePath) {
                    imageAssets.append(asset.relativePath)
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        issueListStore.updateImageAssetPaths(id: entry.id, imageAssetPaths: imageAssets)
        reloadIssueList()
        flashComposerHint(failures.isEmpty
            ? "已附加 \(max(0, imageAssets.count - entry.imageAssetPaths.count)) 張 issue 圖片"
            : "部分圖片無法附加：\(failures.prefix(2).joined(separator: "、"))")
    }

    func removeIssueImageNote(_ relativePath: String, from entry: TatwoIssueListEntryV1) {
        issueListStore.updateImageAssetPaths(
            id: entry.id,
            imageAssetPaths: entry.imageAssetPaths.filter { $0 != relativePath })
        reloadIssueList()
    }

    /// Packages an issue into the composer only. It never invokes a model or
    /// creates a Work OS contract; the human still decides to press Send.
    func packIssueIntoComposer(_ entry: TatwoIssueListEntryV1) {
        let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let package = """
        [Issue List]
        標題：\(entry.title)
        內容：\(body.isEmpty ? "（未填）" : body)
        來源：\(entry.sourceType == .plan ? "Plan" : "Chat")・\(entry.sourceReference)
        [/Issue List]
        """
        let separator = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
        prompt += separator + package

        var attachedImageCount = 0
        if routeChoice.profile.supportsImageInput {
            for url in issueImageURLs(for: entry) where !droppedPaths.contains(url.path) {
                droppedPaths.append(url.path)
                droppedPathDisplayNames[url.path] = "Issue 圖片 \(attachedImageCount + 1)"
                attachedImageCount += 1
            }
        }
        let imageNote = entry.imageAssetPaths.isEmpty
            ? ""
            : (attachedImageCount > 0 ? "，含 \(attachedImageCount) 張圖片" : "（目前 route 不支援圖片，已只帶入文字）")
        flashComposerHint("已帶入「\(entry.title)」\(imageNote)；請按送出執行。")
    }

    // MARK: 設定 → Issue List 管理

    /// 全部（含 archived）；設定頁 all list 用。
    var allIssueListEntries: [TatwoIssueListEntryV1] {
        issueListEntries.sorted { $0.createdAt > $1.createdAt }
    }

    var archivedIssueListEntries: [TatwoIssueListEntryV1] {
        issueListEntries.filter { $0.status == .archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 從封存還原回等待中（可再啟用或流通）。
    func restoreIssueFromArchive(_ id: String) {
        issueListStore.setStatus(id: id, status: .queued)
        reloadIssueList()
    }

    func reloadIssueList() {
        issueListEntries = issueListStore.load()
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 資訊卡可見範圍：預設只看本 thread；同專案 threads 的 issue 可流通；
    /// 全域模式（@ 搜到 issue list）看全部。跨聊天不亂竄。
    var visibleIssueListEntries: [TatwoIssueListEntryV1] {
        let activeEntries = issueListEntries.filter { $0.status != .archived }
        if issueListShowsGlobal { return activeEntries }
        let threadID = selectedThreadID?.uuidString
        let projectID = selectedThreadProject?.id.uuidString
        return activeEntries.filter { entry in
            if let threadID, entry.threadReference == threadID { return true }
            if let projectID, entry.projectReference == projectID { return true }
            return false
        }
    }

    /// composer 尾端 `@` token 的搜尋字（nil＝沒有 @ token）。
    var issueAtMentionQuery: String? {
        guard let token = prompt
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .last.map(String.init),
            token.hasPrefix("@") else { return nil }
        return String(token.dropFirst()).lowercased()
    }

    /// `@` 搜尋結果：全域逐筆過濾（標題/內文/來源），最多 8 筆——先搜、點選才進卡。
    var issueAtMentionMatches: [TatwoIssueListEntryV1] {
        guard let query = issueAtMentionQuery else { return [] }
        let matched = query.isEmpty
            ? issueListEntries
            : issueListEntries.filter {
                $0.title.lowercased().contains(query)
                || $0.body.lowercased().contains(query)
                || $0.sourceReference.lowercased().contains(query)
            }
        return Array(matched.prefix(8))
    }

    /// 點選 @ 搜尋結果：清掉 @token、把該筆釘進資訊卡（不整包倒全域）。
    func pickIssueMention(_ entry: TatwoIssueListEntryV1) {
        var parts = prompt.split(
            whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        if let last = parts.last, last.hasPrefix("@") { parts.removeLast() }
        prompt = parts.joined(separator: " ")
        focusedIssueEntryID = entry.id
        issueProjectionRan = true
        requestOpenInfoCard = true
    }

    // MARK: #16 /plg 執行流（orchestrator 投影；身份組來自 thread loopsConfig）

    static func plgISO(_ offset: TimeInterval = 0) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
    }

    func updateGatewayLiveStatus(_ status: TatwoGatewayLiveStatus?) {
        gatewayLiveStatus = status
    }


    /// 觸發 PLG 流程（send Enter 或點 /plg 選項都走這）。
    /// 定案：/plg 先進「Plan 討論」相位，不即分工；來回釐清、人類按【確認計畫】才進入分工。
    func triggerPLGFromPrompt() {
        Task { [weak self] in
            await self?.triggerPLGFromPromptAsync()
        }
    }

    private func triggerPLGFromPromptAsync() async {
        let obj = TatwoSlashCommandParser.objective(
            from: prompt,
            commands: ["/plg(plan loops goal)", "/plan", "/plg"])
        guard !obj.isEmpty else {
            prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("/plg") ? "/plg " : "/plan "
            flashComposerHint("請在指令後輸入要規劃的目標。")
            return
        }
        restoreActivePLGProjection(from: selectedThread)
        if let run = activePLGRun {
            guard run.phase == .planning else {
                requestOpenLoopsPanel = true
                flashComposerHint("此 thread 已離開 planning，相位為 \(run.phase.rawValue)。請先結束目前 Goal。")
                return
            }
            requestOpenLoopsPanel = true
            prompt = obj
            submitCurrentChatTurn(applyPromptCollaboration: false)
            flashComposerHint("已沿用同一個 Plan；可繼續釐清，確認後再用 /goal。")
            return
        }
        if plgAuthorityState.isQuarantined {
            requestOpenLoopsPanel = true
            flashComposerHint(plgError ?? "此 thread 的 Plan chain 無法驗證，已停止建立新 run。")
            return
        }
        guard await startPLGRun(objective: obj) else {
            return
        }
        requestOpenLoopsPanel = true
        prompt = obj
        submitCurrentChatTurn(applyPromptCollaboration: false)
        guard prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            if composerHint?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty != false {
                flashComposerHint(
                    "PLG 已建立，但 planning 討論回合未送出；輸入仍保留，請依提示處理後重試。")
            }
            return
        }
        flashComposerHint("已進入 Plan 討論 → 右列流程卡；來回釐清後按【確認計畫，進入分工】")
    }

    /// /plan mirrors Codex Plan mode: it is a persistent per-thread interaction
    /// mode, not an alias for PLG and not a GoalRun by itself.
    func handlePlanSlashCommand() {
        let visibleCommand = prompt
        let value = slashObjective(prompt, strip: ["/plan"])
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        if ["off", "exit", "stop", "關閉", "結束"].contains(lower) {
            setPlanModeEnabled(false)
            prompt = ""
            flashComposerHint("已離開 Plan 模式")
            return
        }

        if selectedThreadID == nil {
            newChat()
        }
        guard let threadID = selectedThreadID else {
            prompt = visibleCommand
            flashComposerHint("Plan 模式未開啟：目前沒有可綁定的 thread。")
            return
        }
        setPlanModeEnabled(true)
        prompt = ""
        guard !normalized.isEmpty else {
            flashComposerHint("Plan 模式已開啟：接下來只規劃、不執行；輸入 /plan off 離開。")
            return
        }

        let previousClarificationRound =
            planClarificationRoundCountByThread[threadID]
        pendingPlanObjectives[threadID] = normalized
        planClarificationRoundCountByThread[threadID] = 0
        prompt = visibleCommand
        let accepted = submitCurrentChatTurn()
        if !accepted {
            pendingPlanObjectives.removeValue(forKey: threadID)
            if let previousClarificationRound {
                planClarificationRoundCountByThread[threadID] =
                    previousClarificationRound
            } else {
                planClarificationRoundCountByThread.removeValue(
                    forKey: threadID)
            }
        }
    }

    /// A user can ask for the existing Work OS confirmation surface in normal
    /// prose instead of knowing the private `/plan` control syntax. Keep this
    /// classifier deliberately conjunctive: mentioning Work OS, a plan, or a
    /// browser alone is ordinary conversation. Only an explicit clickable
    /// `送交 Work OS` gate plus a pre-confirmation runner prohibition crosses
    /// into the local Plan-artifact path.
    static func workOSConfirmationGateObjective(
        in rawText: String
    ) -> String? {
        let objective = rawText.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { return nil }
        let lower = objective.lowercased()
        let namesWorkOS = lower.contains("work os")
            || lower.contains("workos")
        let namesPlan = lower.contains("plan")
            || objective.contains("計畫")
            || objective.contains("規劃")
        let namesSubmissionGate = lower.contains("送交 work os")
            || lower.contains("submit to work os")
        let requiresClickableConfirmation = objective.contains("可點擊")
            || objective.contains("確認入口")
            || lower.contains("clickable")
            || lower.contains("confirmation gate")
        let namesPreConfirmationBoundary = objective.contains("點擊前")
            || objective.contains("確認前")
            || lower.contains("before the click")
            || lower.contains("before confirmation")
        let forbidsRunner =
            (objective.contains("不要啟動")
                || objective.contains("不得啟動")
                || objective.contains("禁止啟動")
                || lower.contains("do not start")
                || lower.contains("must not start"))
            && (lower.contains("runner")
                || lower.contains("browser")
                || objective.contains("瀏覽器"))
        guard namesWorkOS,
              namesPlan,
              namesSubmissionGate,
              requiresClickableConfirmation,
              namesPreConfirmationBoundary,
              forbidsRunner
        else { return nil }
        return objective
    }

    /// Materializes a deterministic, planning-only artifact. No model, Work OS
    /// contract, dispatch, runner, Computer Host, or browser action is started
    /// here. The existing Plan UI renders `activePlanArtifact`; its confirmation
    /// button remains the sole transition into `confirmActivePlan()`.
    @discardableResult
    func stageWorkOSConfirmationGatePlan(
        objective: String,
        threadID: UUID
    ) -> Bool {
        setPlanModeEnabled(true)
        let artifact = TatwoPlanArtifactV1(
            threadID: threadID,
            objective: objective,
            sections: [
                .init(
                    title: "Goal Contract",
                    body: "Outcome：只在使用者點擊「送交 Work OS」後執行這項需求。成功條件：確認前零 runner／dispatch／Computer Host／瀏覽器動作；確認後沿用正式 Goal／PLG execution path 並以真實工具證據回報。Non-goals：不在 Plan 階段代做搜尋或發布完成摘要。"),
                .init(
                    title: "Context / Architecture",
                    body: "控制流固定為 user request → activePlanArtifact → 既有 Plan UI confirmation → confirmActivePlan() → Goal／PLG → Work execution。確認按鈕是 runner 與 Computer Host/browser authority 的人門；Plan artifact 本身不建立 execution dispatch。"),
                .init(
                    title: "Plan",
                    body: "1. 顯示並保留本 Plan artifact 供使用者檢查。\n2. 確認前維持 planning-only，不啟動任何 runner 或瀏覽器工作。\n3. 點擊「送交 Work OS」後，使用既有 Plan→Goal／PLG→Work 路徑執行原始需求。\n4. 只依實際 execution／browser evidence 產出結果；阻塞時回報阻塞，不以普通聊天摘要冒充完成。"),
                .init(
                    title: "Validation / Rollback",
                    body: "確認前驗證 activePlanArtifact.state == discussing、無 Goal/dispatch/runtime/browser side effect。確認後由既有 Work OS receipts 驗證 runner 與工具結果。若確認後啟動失敗，沿用既有 reopenPlanAfterFailedConfirmation() 還原為可重試 Plan。"),
            ])
        guard persistPlanArtifact(artifact) else {
            return false
        }
        pendingPlanObjectives.removeValue(forKey: threadID)
        planClarificationRoundCountByThread.removeValue(forKey: threadID)
        flashComposerHint(
            "已建立 Plan；確認前未啟動 runner。請檢查後點擊「送交 Work OS」。")
        return true
    }

    // MARK: Browser agent READ → PLAN_FROZEN → HUMAN_APPROVED → EXECUTE_TYPED → VERIFY

    func updateBrowserAgentActivePage(
        sessionID: String?,
        state: EmbeddedBrowserNavigationState
    ) {
        let normalizedSessionID = sessionID?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard let normalizedSessionID,
              !normalizedSessionID.isEmpty,
              selectedThreadID?.uuidString.lowercased()
                  == normalizedSessionID,
              [.committed, .finished].contains(state.phase),
              let committedURLString =
                  state.committedMainFrameURLString,
              state.navigationGeneration > 0
        else {
            if let normalizedSessionID,
               activeBrowserAgentPageBinding?.sessionID
                == normalizedSessionID
            {
                activeBrowserAgentPageBinding = nil
            }
            return
        }
        activeBrowserAgentPageBinding =
            try? TatwoBrowserCommittedPageBindingV1(
                sessionID: normalizedSessionID,
                committedURLString: committedURLString,
                navigationGeneration: state.navigationGeneration)
    }

    func clearBrowserAgentActivePage(sessionID: String?) {
        guard let sessionID = sessionID?.trimmingCharacters(
            in: .whitespacesAndNewlines),
              activeBrowserAgentPageBinding?.sessionID == sessionID
        else { return }
        activeBrowserAgentPageBinding = nil
    }

    func issueBrowserAgentGrantForMCP(
        arguments: [String: JSONValue]
    ) throws -> TatwoBrowserAgentGrant {
        guard let runID = arguments["runID"]?.stringValue,
              let contractID = arguments["contractID"]?.stringValue,
              let leaseID = arguments["leaseID"]?.stringValue,
              let binding = computerHostBindingSlot.binding(for: runID),
              binding.decision.route == .mcp,
              binding.contractID == contractID,
              let lease = binding.lease,
              lease.id == leaseID,
              lease.contractID == contractID,
              lease.expiresAt > Date(),
              lease.allowedActions.contains(.computerUse),
              !binding.sessionID.isEmpty
        else {
            throw TatwoBrowserSecurityError.invalidGrant
        }
        guard let pageBinding = activeBrowserAgentPageBinding else {
            throw TatwoBrowserSecurityError.committedPageUnavailable
        }
        guard pageBinding.sessionID == binding.sessionID else {
            throw TatwoBrowserSecurityError.navigationBindingUnavailable
        }
        return try issueBrowserAgentGrant(
            contractID: contractID,
            runID: runID,
            leaseID: leaseID,
            sessionID: binding.sessionID,
            origin: pageBinding.origin,
            navigationGeneration:
                pageBinding.navigationGeneration)
    }

    /// Browser grants are runner capabilities, not page content. They are
    /// issued only after the existing Plan confirmation gate has moved to the
    /// confirmed state; a page cannot mint or widen its own grant.
    func issueBrowserAgentGrant(
        contractID: String,
        runID: String,
        leaseID: String,
        sessionID: String,
        origin: String,
        navigationGeneration: UInt64,
        perceptionMode: TatwoBrowserPerceptionMode = .textSafe
    ) throws -> TatwoBrowserAgentGrant {
        guard activePlanArtifact?.state == .confirmed else {
            throw TatwoBrowserSecurityError.humanApprovalRequired
        }
        let capabilities: Set<TatwoBrowserAgentCapability> =
            perceptionMode == .textSafe
            ? [.readSanitized, .planActions, .executeApprovedPlan]
            : [.visualReadOnly]
        return try TatwoBrowserAgentSecurityRuntime.shared.issueGrant(
            contractID: contractID,
            runID: runID,
            leaseID: leaseID,
            sessionID: sessionID,
            origin: origin,
            navigationGeneration: navigationGeneration,
            capabilities: capabilities,
            perceptionMode: perceptionMode)
    }

    /// Freezing is deterministic and snapshot-bound. Later page text is never
    /// appended to, removed from, or used to rewrite this action list.
    func freezeBrowserAgentPlan(
        grant: TatwoBrowserAgentGrant,
        snapshotHash: String,
        requestedActions: [TatwoBrowserRequestedActionV1]
    ) throws -> TatwoBrowserTypedPlanTokenV1 {
        try TatwoBrowserAgentSecurityRuntime.shared.freezePlan(
            grant: grant,
            snapshotHash: snapshotHash,
            requestedActions: requestedActions)
    }

    /// The runner can package web output only as a tool-result/data value.
    /// It must never concatenate this value into system, developer, contract,
    /// or user-instruction strings. Future WebMCP metadata enters through this
    /// same untrusted data-only boundary and gains no instruction authority.
    nonisolated static func browserToolResultDataChannel(
        _ envelope: TatwoUntrustedPageEnvelopeV1
    ) throws -> JSONValue {
        try browserUntrustedToolResultDataChannel(
            JSONValue.fromEncodable(envelope))
    }

    nonisolated static func browserUntrustedToolResultDataChannel(
        _ payload: JSONValue
    ) throws -> JSONValue {
        .object([
            "channel": .string("tool_result"),
            "trust": .string("untrusted_web"),
            "payload": payload,
        ])
    }

    func confirmActivePlan() {
        guard !planConfirmInFlight else { return }
        guard !isRunning else {
            flashComposerHint("目前回合仍在執行；請等回合結束後再確認計劃。")
            return
        }
        guard var artifact = activePlanArtifact else {
            flashComposerHint("沒有可確認的計劃書。")
            return
        }
        guard artifact.state == .discussing else {
            flashComposerHint("這份計畫已確認；不會重複送交 Work OS。")
            return
        }
        if let selection = artifact.planFlowSelection,
           let blocker = selection.executionBlocker
        {
            flashComposerHint(blocker)
            return
        }
        let retryableArtifact = artifact
        artifact.confirm()
        guard let planArtifactStore else {
            flashComposerHint("計劃書未更新：儲存層尚未就緒。")
            return
        }
        // Published state is applied synchronously so the confirmation click
        // remains immediately visible. The matching disk write is performed
        // by the detached worker below; a failure restores this retryable
        // snapshot on MainActor.
        activePlanArtifact = artifact
        beginConfirmedPlanConfirmationBoundary()
        beginPlanWorkOSLocalActionPresentation()
        flashComposerHint("正在確認計劃並啟動工作流程…")
        Task { [weak self] in
            guard let self else { return }
            let persistenceResult = await Task.detached(
                priority: .userInitiated
            ) { [artifact, planArtifactStore] in
                Result {
                    try planArtifactStore.save(artifact)
                }
            }.value
            guard case .success = persistenceResult else {
                self.activePlanArtifact = retryableArtifact
                self.resetConfirmedPlanComputerHostBlockerHint()
                self.planConfirmInFlight = false
                self.traceConfirmedPlanComputerHostBlockerHintState(
                    event: .confirmationReleased)
                self.finishConfirmedPlanConfirmationBoundary()
                self.failPlanWorkOSLocalActionPresentation(
                    "計畫書無法寫入本機儲存；已恢復，可重試。")
                self.flashComposerHint(
                    "計劃書未更新：無法寫入本機儲存；已恢復為可重試狀態。")
                return
            }
            await self.finishConfirmingActivePlan(artifact)
            await self.awaitConfirmedPlanDeferredStartBoundaryIfNeeded()
            self.republishConfirmedPlanComputerHostBlockerAtConfirmationBoundaryIfNeeded()
            self.planConfirmInFlight = false
            self.traceConfirmedPlanComputerHostBlockerHintState(
                event: .confirmationReleased)
            self.finishConfirmedPlanConfirmationBoundary()
        }
    }

    private func finishConfirmingActivePlan(
        _ artifact: TatwoPlanArtifactV1
    ) async {
        // 2026-08-21 使用者裁決升級（二次澄清）：畫布確認＝人門，按下
        // 後依模式自動開工——ultrawork 協作開＝進 PLG loops 管線；
        // 單模型＝走 /goal 直接開工。計劃書保持已確認；起不來時原因
        // 照 fail-closed 慣例可見。
        guard !isRunning else {
            reopenPlanAfterFailedConfirmation(artifact)
            failPlanWorkOSLocalActionPresentation(
                "目前回合仍在執行；計畫已恢復，可重試。")
            flashComposerHint("目前回合仍在執行；請等回合結束後再確認計劃。")
            return
        }
        flushCoalescedTranscriptJournal()
        let executionObjective =
            Self.confirmedPlanExecutionObjective(artifact)
        if let selection = artifact.planFlowSelection {
            guard selection.isComplete else {
                reopenPlanAfterFailedConfirmation(artifact)
                failPlanWorkOSLocalActionPresentation(
                    "計畫流程選項不完整；計畫已恢復，可重試。")
                flashComposerHint(
                    "計劃流程尚缺：\(selection.missingSelections.joined(separator: "、"))")
                return
            }
            switch selection.destination {
            case .plan:
                setPlanModeEnabled(false)
                planWorkOSLocalActionPresentation = .init(
                    phase: .succeeded,
                    message: "計畫已確認；依選擇保留在 Plan，未啟動 runner。",
                    goalID: nil,
                    contractID: nil,
                    stateRoot:
                        goalRunStore.directoryURL.standardizedFileURL.path,
                    isRetryable: false)
                flashComposerHint("計劃書已確認；依選擇停在 Plan。")
                return
            case .goal:
                await activateGoalFromPromptAsync(
                    forceSingleModel:
                        selection.collaboration == .singleModel,
                    // Picking Ultrawork collaboration and Goal in one canvas
                    // action is an explicit current-revision topology request.
                    ultraworkExplicitlyRequested:
                        selection.collaboration != .singleModel,
                    objectiveOverride: executionObjective,
                    executionPromptOverride:
                        confirmedPlanExecutionPrompt(artifact),
                    confirmedPlanArtifact: artifact)
                return
            case .plg:
                break
            case nil:
                break
            }
        }
        guard collaborationIsEnabled else {
            // 單模型：以計劃書目標走 /goal 完整路徑（含 goal rail 與
            // 原生派工），與手打 /goal 同一條管線。
            await activateGoalFromPromptAsync(
                forceSingleModel: true,
                objectiveOverride: executionObjective,
                executionPromptOverride:
                    confirmedPlanExecutionPrompt(artifact),
                confirmedPlanArtifact: artifact)
            return
        }
        guard prepareConfirmedPlanGoalRevisionIfNeeded(
            executionObjective: executionObjective,
            forceSingleModel: false)
        else {
            reopenPlanAfterFailedConfirmation(artifact)
            failPlanWorkOSLocalActionPresentation(
                selectedWorkOSStateMessage)
            flashComposerHint(selectedWorkOSStateMessage)
            return
        }
        requestOpenLoopsPanel = true
        restoreActivePLGProjection(from: selectedThread)
        // （字面刻意避開既有 /plg 合約掃描樣式；語義＝無 run 才新建。）
        let hasRestoredPLGRun = activePLGRun != nil
        if !hasRestoredPLGRun {
            guard await startPLGRun(objective: executionObjective) else {
                reopenPlanAfterFailedConfirmation(artifact)
                failPlanWorkOSLocalActionPresentation(
                    plgError ?? "PLG 未能建立新的 execution contract。")
                // startPLGRun 已把深層原因 flash 出來；沒有才補概述，
                // 不得蓋掉更具體的訊息（親測抓到 wrapper 蓋深因）。
                if composerHint?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty != false {
                    flashComposerHint(
                        "計劃書已確認，但 PLG 未能啟動："
                            + (plgError ?? "流程狀態未通過驗證"))
                }
                return
            }
        }
        guard performConfirmedPlanWorkOSLocalAction(artifact: artifact)
        else {
            reopenPlanAfterFailedConfirmation(artifact)
            flashComposerHint(planWorkOSLocalActionPresentation.message)
            return
        }
        setPlanModeEnabled(false)
        guard confirmPLGPlanAndStartLoops(
            nativeTaskOverride: executionObjective,
            executionPromptOverride:
                confirmedPlanExecutionPrompt(artifact),
            restoreProjection: false,
            usesConfirmedPlanTransport: true)
        else {
            failConfirmedPlanDispatch(
                artifact,
                reason: currentPlanDispatchFailureReason(
                    fallback:
                        "Work OS 已完成本機 canonical transition，"
                        + "但 loops dispatch/runner 未啟動。"))
            return
        }
        let published =
            publishConfirmedPlanWorkOSDispatchSuccessIfVerified(
            message:
                "已送交 Work OS：正式 dispatch 與 runner 已進入 running。")
        if !published {
            flashComposerHint(
                planWorkOSLocalActionPresentation.message)
            if planWorkOSLocalActionPresentation.phase == .failed {
                reopenPlanAfterFailedConfirmation(artifact)
            }
        }
    }

    private func confirmedPlanExecutionPrompt(
        _ artifact: TatwoPlanArtifactV1
    ) -> String {
        """
        依照以下已由使用者確認的計畫直接實作。現在是執行階段，不要重新規劃、不要只重述計畫。
        必須使用可用工具直接執行計畫；只有計畫明確要求時才修改檔案，並實際完成計畫中的測試、瀏覽器操作或其他驗證。
        不得用 swift run、swift build、--help、repo 掃描或其他開發工具探索來代替計畫要求的瀏覽器／Computer Host 任務；計畫未要求程式碼工作時，不得啟動 SwiftPM 或 repo 探索。
        若受到權限、環境或需求阻塞，請明確回報阻塞；沒有工具執行與驗證證據時不得宣稱完成。

        \(artifact.markdownExport())
        """
    }

    private func reopenPlanAfterFailedConfirmation(
        _ confirmedArtifact: TatwoPlanArtifactV1
    ) {
        var retryable = confirmedArtifact
        retryable.updateDiscussion(
            objective: confirmedArtifact.objective,
            sections: confirmedArtifact.sections)
        if persistPlanArtifact(retryable),
           selectedThreadID == confirmedArtifact.threadID
        {
            setPlanModeEnabled(true)
        }
    }

    private func currentPlanDispatchFailureReason(
        fallback: String
    ) -> String {
        let candidates = [
            composerHint,
            plgError,
            selectedWorkOSStateMessage,
        ]
        return candidates.compactMap { candidate in
            let normalized = candidate?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized?.isEmpty == false ? normalized : nil
        }.first ?? fallback
    }

    private func failConfirmedPlanDispatch(
        _ artifact: TatwoPlanArtifactV1,
        reason: String
    ) {
        reopenPlanAfterFailedConfirmation(artifact)
        let redactedReason = TatwoPrivacyRedactor.redacted(reason)
        let message =
            "送交 Work OS 失敗：\(redactedReason) "
            + "計畫已恢復，可重試。"
        failPlanWorkOSLocalActionPresentation(message)
        flashComposerHint(message)
    }

    func planMarkdownForCopy() -> String? {
        activePlanArtifact?.markdownExport()
    }

    /// 2026-08-21 畫布內編輯（使用者：鉛筆→修改→儲存）。
    func editablePlanTextForCanvas() -> String? {
        activePlanArtifact?.editableText()
    }

    func saveEditedPlanCanvasText(_ text: String) {
        guard var artifact = activePlanArtifact else {
            flashComposerHint("沒有可儲存的計劃書。")
            return
        }
        artifact.applyEditedText(text)
        guard persistPlanArtifact(artifact) else { return }
        flashComposerHint("計劃書修改已儲存。")
    }

    /// internal（非 private）：這是 /plan 真正送給模型的內容。
    static func planDiscussionPrompt(objective: String) -> String {
        """
        請只討論並產出完整計劃，不要開工、不要建立 Work OS contract、不要派工、不要啟動 Work OS runner。

        計劃目標：
        \(objective)

        詳細函式、符號與影響範圍盤點請寫入計劃書的 sections；聊天正文只給結論式摘要，避免用盤點過程洗版。若目前證據不足，請在計劃書中標出仍需查證項。
        """
    }

    @discardableResult
    func persistPlanArtifact(_ artifact: TatwoPlanArtifactV1) -> Bool {
        guard let planArtifactStore else {
            flashComposerHint("計劃書未更新：儲存層尚未就緒。")
            return false
        }
        do {
            try planArtifactStore.save(artifact)
            activePlanArtifact = artifact
            return true
        } catch {
            flashComposerHint("計劃書未更新：無法寫入本機儲存。")
            return false
        }
    }

    /// Completion hook for a turn that was frozen as Plan mode at send time.
    /// Each completed response replaces sections while preserving plan identity
    /// and objective; `updateDiscussion` also reopens a confirmed plan.
    func updatePlanArtifactFromCompletedResponse(
        _ response: String,
        threadID: UUID,
        assistantMessageID: String? = nil,
        planTurnBinding: ChatPlanTurnBinding? = nil,
        isTerminalClarificationCompletion: Bool = false,
        at: Date = Date()
    ) {
        guard let planArtifactStore else {
            preserveRetryablePlanArtifactUpdate(
                threadID: threadID,
                objectiveCandidate: planTurnBinding?.objectiveCandidate,
                message:
                    "Plan 定稿失敗：本機 Plan 儲存層尚未就緒；"
                    + "原目標已保留，可重試。")
            return
        }
        let threadMessages = planResponseMessages(threadID: threadID)
        let responseMessage: ChatMessage?
        if let assistantMessageID {
            responseMessage = threadMessages.last(where: {
                $0.id == assistantMessageID && $0.role == .assistant
            })
        } else {
            responseMessage = threadMessages.last(where: {
                $0.role == .assistant
            })
        }
        let stored: TatwoPlanArtifactV1?
        do {
            stored = try planArtifactStore.load(threadID: threadID)
        } catch {
            preserveRetryablePlanArtifactUpdate(
                threadID: threadID,
                objectiveCandidate:
                    planTurnBinding?.objectiveCandidate
                        ?? pendingPlanObjectives[threadID],
                message:
                    "Plan 定稿失敗：既有 Plan artifact 無法通過本機驗證；"
                    + "沒有建立入口，原目標已保留，可重試。")
            return
        }
        let boundUserTurn = planTurnBinding.flatMap { binding in
            threadMessages.first(where: {
                $0.id == binding.sourceUserMessageID && $0.role == .user
            })?.text
        }
        let pendingObjective =
            ChatPlanClarificationContinuationPolicy.recoveredObjective(
                bindingObjective: planTurnBinding?.objectiveCandidate,
                pendingObjective: pendingPlanObjectives[threadID],
                existingObjective:
                    stored?.objective
                    ?? planTurnBinding?.startingObjective,
                boundUserTurn: boundUserTurn)
        if let planTurnBinding {
            guard planTurnBinding.threadID == threadID else {
                preserveRetryablePlanArtifactUpdate(
                    threadID: threadID,
                    objectiveCandidate: pendingObjective,
                    message:
                        "Plan 定稿失敗：完成回應綁定到不同 thread；"
                        + "沒有建立入口，原目標已保留，可重試。")
                return
            }
            guard assistantMessageID == planTurnBinding.assistantMessageID
            else {
                preserveRetryablePlanArtifactUpdate(
                    threadID: threadID,
                    objectiveCandidate: pendingObjective,
                    message:
                        "Plan 定稿失敗：assistant response 與本輪 Plan binding"
                        + " 不一致；沒有建立入口，原目標已保留，可重試。")
                return
            }
            guard let userIndex = threadMessages.firstIndex(where: {
                $0.id == planTurnBinding.sourceUserMessageID
                    && $0.role == .user
            }) else {
                preserveRetryablePlanArtifactUpdate(
                    threadID: threadID,
                    objectiveCandidate: pendingObjective,
                    message:
                        "Plan 定稿失敗：找不到本輪綁定的 user request；"
                        + "沒有建立入口，原目標已保留，可重試。")
                return
            }
            if let responseMessage {
                guard responseMessage.id
                        == planTurnBinding.assistantMessageID,
                      let assistantIndex = threadMessages.firstIndex(where: {
                          $0.id == planTurnBinding.assistantMessageID
                              && $0.role == .assistant
                      }),
                      userIndex < assistantIndex
                else {
                    preserveRetryablePlanArtifactUpdate(
                        threadID: threadID,
                        objectiveCandidate: pendingObjective,
                        message:
                            "Plan 定稿失敗：assistant response 的 canonical"
                            + " 順序或 identity 無法驗證；原目標已保留，可重試。")
                    return
                }
            }
            // The terminal callback carries the exact response and binding.
            // Journal projection may lag that callback by one MainActor turn,
            // so absence from the projection is not itself a reason to discard
            // an otherwise exact assistant ID. A mismatched projected row still
            // fails closed above.
        }
        let validatesBoundResponse =
            assistantMessageID != nil || planTurnBinding != nil
        guard (!validatesBoundResponse
                || responseMessage?.eventKind != .failure),
              !Self.isPlanArtifactBlockingResponse(
                  response,
                  responseMessage:
                    validatesBoundResponse ? responseMessage : nil)
        else {
            preserveRetryablePlanArtifactUpdate(
                threadID: threadID,
                objectiveCandidate: pendingObjective,
                message:
                    "Plan 定稿受阻：assistant 回應是失敗／阻塞結果，"
                    + "不會把錯誤文字當成 Plan；原目標已保留，可重試。")
            return
        }
        let hasClarificationRequest =
            responseMessage?.planQuestions.isEmpty == false
        if hasClarificationRequest,
           isTerminalClarificationCompletion,
           selectedThreadID == threadID
        {
            consumePendingPlanQuestions(
                assistantMessageID: responseMessage?.id)
        }
        guard !hasClarificationRequest
                || isTerminalClarificationCompletion
        else {
            return
        }
        let sections = TatwoPlanArtifactV1.sections(
            fromModelResponse: response)
        guard !sections.isEmpty,
              (!validatesBoundResponse
                || Self.hasExplicitPlanSections(
                    in: response,
                    parsedSections: sections))
        else {
            preserveRetryablePlanArtifactUpdate(
                threadID: threadID,
                objectiveCandidate: pendingObjective,
                message:
                    "Plan 定稿失敗：assistant 未回傳可解析的完整 Markdown Plan；"
                    + "沒有建立 Goal、dispatch 或 runner，原目標已保留，可重試。")
            return
        }
        if let planTurnBinding,
           !planTurnBinding.matchesStartingArtifact(stored)
        {
            preserveRetryablePlanArtifactUpdate(
                threadID: threadID,
                objectiveCandidate: pendingObjective,
                message:
                    "Plan 定稿失敗：Plan artifact 已在本輪回應期間變更；"
                    + "已拒絕 stale response，原目標已保留，可重新定稿。")
            return
        }
        guard var artifact = stored
                ?? pendingObjective.map({
                    TatwoPlanArtifactV1(
                        threadID: threadID,
                        objective: $0)
                }),
              artifact.threadID == threadID
        else {
            preserveRetryablePlanArtifactUpdate(
                threadID: threadID,
                objectiveCandidate: pendingObjective,
                message:
                    "Plan 定稿失敗：無法恢復本輪 objective；"
                    + "沒有建立入口，請重試 Plan 定稿。")
            return
        }
        artifact.updateDiscussion(
            objective: pendingObjective ?? artifact.objective,
            sections: sections,
            at: at)
        if let assistantMessageID {
            artifact.sourceAssistantMessageID = assistantMessageID
        }
        do {
            try planArtifactStore.save(artifact)
            pendingPlanObjectives.removeValue(forKey: threadID)
            planClarificationRoundCountByThread.removeValue(
                forKey: threadID)
            if selectedThreadID == threadID {
                activePlanArtifact = artifact
            }
        } catch {
            preserveRetryablePlanArtifactUpdate(
                threadID: threadID,
                objectiveCandidate:
                    pendingObjective ?? artifact.objective,
                message:
                    "Plan 定稿失敗：artifact 無法寫入本機儲存；"
                    + "原目標已保留，可重試。")
        }
    }

    private static func hasExplicitPlanSections(
        in response: String,
        parsedSections: [TatwoPlanArtifactV1.Section]
    ) -> Bool {
        guard !parsedSections.isEmpty else { return false }
        let normalized = response
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.range(
            of:
                #"(?m)^\s*(?:#{1,6}\s+\S.*|\*\*[^*\n]+\*\*\s*|\d+[.)、]\s+\S.*)$"#,
            options: .regularExpression) != nil
    }

    private func preserveRetryablePlanArtifactUpdate(
        threadID: UUID,
        objectiveCandidate: String?,
        message: String
    ) {
        if let objective = objectiveCandidate?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !objective.isEmpty
        {
            pendingPlanObjectives[threadID] = objective
        }
        guard selectedThreadID == threadID else { return }
        flashComposerHint(message)
    }

    private static func isPlanArtifactBlockingResponse(
        _ response: String,
        responseMessage: ChatMessage?
    ) -> Bool {
        if ChatRuntimeTextHumanizer.projectedOutput(response).isBlocker {
            return true
        }
        guard let responseMessage else { return false }
        let status = responseMessage.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(
                separator: "|",
                maxSplits: 1,
                omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        return status.hasPrefix("fail")
            || status.hasPrefix("block")
            || status == "stopped"
            || status == "cancelled"
            || status == "canceled"
    }

    /// Plan completion can arrive after the user selects another session.
    /// Clarification state must therefore be read from the exact thread bound
    /// to the completed turn, never from the currently visible transcript.
    private func planResponseMessages(threadID: UUID) -> [ChatMessage] {
        let reference = TatwoNativeChatSessionReference(
            kind: .thread,
            id: threadID)
        if selectedSessionReference == reference {
            return messages
        }
        let canonical = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: reference.stableKey,
            from: chatTranscriptJournal)
        if !canonical.isEmpty {
            return canonical
        }
        if let thread = document.threads.first(where: {
            $0.id == threadID
        }) {
            return (thread.messages ?? []).map(ChatMessage.init(stored:))
        }
        for project in document.projects {
            if let thread = project.threads.first(where: {
                $0.id == threadID
            }) {
                return (thread.messages ?? []).map(
                    ChatMessage.init(stored:))
            }
        }
        return []
    }

    func refreshActivePlanArtifact() {
        guard let threadID = selectedThreadID else {
            activePlanArtifact = nil
            return
        }
        guard let planArtifactStore else {
            activePlanArtifact = nil
            return
        }
        do {
            activePlanArtifact = try planArtifactStore.load(threadID: threadID)
        } catch {
            activePlanArtifact = nil
            flashComposerHint("計劃書無法載入：本機資料未通過驗證。")
        }
    }

    /// /goal mirrors Codex goal lifecycle: create or replace the persistent
    /// objective and show its progress rail. PLG remains an explicit /plg
    /// action instead of being started implicitly.
    func commitOrActivateGoalFromPrompt(
        forceSingleModel: Bool = false,
        ultraworkExplicitlyRequested: Bool = false,
        executionPromptOverride: String? = nil
    ) {
        restoreActivePLGProjection(from: selectedThread)
        if let phase = activePLGRun?.phase,
           Self.canCommitPLGGoal(from: phase)
        {
            commitPLGGoalFromPrompt()
        } else if resumeBoundGoalWithoutProjectionIfPossible() {
            commitPLGGoalFromPrompt()
        } else {
            activateGoalFromPrompt(
                forceSingleModel: forceSingleModel,
                ultraworkExplicitlyRequested: ultraworkExplicitlyRequested,
                executionPromptOverride: executionPromptOverride)
        }
    }

    /// Goal revision promotion can leave the canonical Goal running while the
    /// App-local PLG projection is intentionally cleared as stale. A bare
    /// `/goal` must resume that exact bound Goal instead of becoming a no-op.
    ///
    /// This recovery is deliberately narrow: it accepts no replacement
    /// objective, never creates a Goal, and rebuilds only from the selected
    /// thread's verified canonical contract.
    private func resumeBoundGoalWithoutProjectionIfPossible() -> Bool {
        let note = slashObjective(prompt, strip: ["/goal"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.isEmpty,
              activePLGRun == nil,
              !plgAuthorityState.isQuarantined,
              selectedThreadHasWorkOSGoal,
              ensureSelectedThreadWorkOSContract(
                allowCreateIfUnbound: false),
              let contract = selectedWorkOSContract,
              let goalRecord = selectedGoalRecord,
              goalRecord.status == .planned || goalRecord.status == .running
        else {
            return false
        }
        return startPLGProjectionForActiveContract(
            contract,
            goalRecord: goalRecord)
    }

    func activateGoalFromPrompt(
        forceSingleModel: Bool = false,
        ultraworkExplicitlyRequested: Bool = false,
        objectiveOverride: String? = nil,
        executionPromptOverride: String? = nil
    ) {
        Task { [weak self] in
            await self?.activateGoalFromPromptAsync(
                forceSingleModel: forceSingleModel,
                ultraworkExplicitlyRequested: ultraworkExplicitlyRequested,
                objectiveOverride: objectiveOverride,
                executionPromptOverride: executionPromptOverride,
                confirmedPlanArtifact: nil)
        }
    }

    private func activateGoalFromPromptAsync(
        forceSingleModel: Bool,
        ultraworkExplicitlyRequested: Bool = false,
        objectiveOverride: String? = nil,
        executionPromptOverride: String? = nil,
        confirmedPlanArtifact: TatwoPlanArtifactV1? = nil
    ) async {
        // A confirmed Plan is a canonical UI action, not a composer draft.
        // Carry its objective as an explicit value so an empty, stale, or
        // user-edited composer cannot alter the dispatch revision. Ordinary
        // typed `/goal` turns continue to derive both values from `prompt`.
        let explicitObjective = objectiveOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let objective = explicitObjective.flatMap {
            $0.isEmpty ? nil : $0
        } ?? slashObjective(prompt, strip: ["/goal"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commandText =
            explicitObjective?.isEmpty == false
                ? "/goal \(objective)"
                : prompt
        guard !objective.isEmpty else {
            if objectiveOverride == nil {
                prompt = ""
            }
            if selectedThreadHasWorkOSGoal {
                flashComposerHint("目前目標：\(activeGoalObjectiveLabel)")
            } else {
                flashComposerHint("請輸入 /goal 加上要持續追蹤的目標")
            }
            return
        }

        let singleModelTopology =
            forceSingleModel
            || TatwoGoalTopologyAuthority.requestedTopology(
                commandText: commandText,
                explicitUltraworkRequest: ultraworkExplicitlyRequested)
                == .singleModel
        if singleModelTopology {
            guard !singleModelGoalActivationInFlight else {
                flashComposerHint(
                    "單模型 Goal 正在建立；已忽略重複執行。")
                return
            }
            singleModelGoalActivationInFlight = true
        }
        defer {
            if singleModelTopology {
                singleModelGoalActivationInFlight = false
            }
        }

        if confirmedPlanArtifact == nil {
            setPlanModeEnabled(false)
        }
        // 2026-08-27 staging61 live regression: an ordinary `/goal <objective>`
        // typed from a Terra thread was mutated into `ultrawork XXL`. Two
        // separate authorities had been collapsed into one:
        //
        //   * "does this turn ask for development work" — a visible-turn intent
        //     classification, and
        //   * "did the user ask for an Ultrawork topology" — a mutation of the
        //     thread's model topology, contract mode, and composer route.
        //
        // Only an explicit current-revision request may answer the second. A
        // thread still carrying an XXL `loopsConfig` from an earlier revision
        // (the live thread held `general-xxl-sol-opus5-luna-grok-exact` with
        // `primaryModelID: gpt-5.5`) is stale inheritance, not a request, and
        // must not decide this. Both an explicit Plan selection and an inferred
        // single-model `/goal` revision use this one topology decision for
        // contract issuance, duplicate suppression, and dispatch start.
        // 原生開發 Scenario 準備是 Ultrawork/PLG 的路：它會把這一列改成
        // XXL 多模型拓撲並清掉舊綁定。使用者明確選「單模型」時不得走這條，
        // 否則 S 合約簽發完，thread 上留的是 XXL mode/scenario，送出那一輪
        // 的 Work OS 重驗就會判定不一致而整個隔離 —— 症狀正是「單模型
        // runner 未啟動」、輸入殘留、畫面掉進 Ultrawork XXL。
        let nativeDevelopmentRequested =
            !singleModelTopology
            && TatwoChatCommandPlanner.nativeDevelopmentDecision(
                currentVisibleTurn: objective,
                mode: .chat,
                interactionMode: .plan,
                scenarioPhase: .plan,
                contractStatus: .planned)
                .requested
        if let confirmedPlanArtifact {
            guard prepareConfirmedPlanGoalRevisionIfNeeded(
                executionObjective: objective,
                forceSingleModel: singleModelTopology)
            else {
                reopenPlanAfterFailedConfirmation(confirmedPlanArtifact)
                failPlanWorkOSLocalActionPresentation(
                    selectedWorkOSStateMessage)
                flashComposerHint(selectedWorkOSStateMessage)
                return
            }
        }
        if singleModelTopology {
            // Clears any inherited Ultrawork/XXL loops config on this thread
            // (with the existing supersession receipts) so the contract below
            // is minted as S on the composing route instead of inheriting a
            // stale topology and stale model overrides.
            guard prepareSingleModelTopologyForSelectedThread() else {
                let reason = selectedWorkOSStateMessage
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                flashComposerHint(
                    reason.isEmpty
                        ? "目標未建立：單模型拓撲未能套用到這個 session。"
                        : "目標未建立：\(reason)")
                return
            }
        } else {
            guard await prepareNativeDevelopmentScenarioForPLGIfNeeded(
                objective: objective,
                synchronizePlanRoute: false)
            else {
                let reason = plgError?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let reason, !reason.isEmpty {
                    flashComposerHint("目標未建立：\(reason)")
                } else {
                    flashComposerHint(
                        "目標未建立：原生開發 Scenario 準備失敗。")
                }
                return
            }
        }
        guard ensureSelectedThreadWorkOSContract(
            objectiveHint: objective,
            requireObjectiveMatch: true,
            allowCreateIfUnbound: true,
            automaticallyBootstrapUserOwnedAuthority: true,
            forceSingleModel: singleModelTopology)
        else {
            let reason = selectedWorkOSStateMessage
                .trimmingCharacters(in: .whitespacesAndNewlines)
            flashComposerHint(
                reason.isEmpty
                    ? "目標未建立：Work OS contract 建立失敗。"
                    : "目標未建立：\(reason)")
            return
        }
        if let confirmedPlanArtifact {
            guard performConfirmedPlanWorkOSLocalAction(
                artifact: confirmedPlanArtifact)
            else {
                reopenPlanAfterFailedConfirmation(confirmedPlanArtifact)
                flashComposerHint(
                    planWorkOSLocalActionPresentation.message)
                return
            }
            if !singleModelTopology {
                setPlanModeEnabled(false)
            }
        }
        if let confirmedPlanArtifact, isRunning {
            failConfirmedPlanDispatch(
                confirmedPlanArtifact,
                reason:
                    "目前已有回合執行中；已確認 Plan 不會排入一般 chat queue，"
                    + "計畫已恢復為可重試。")
            return
        }
        if nativeDevelopmentRequested,
           let contract = selectedWorkOSContract,
           [
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID,
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLFableGrokScenarioID,
           ].contains(contract.scenario)
        {
            if isRunning {
                prompt = objective
                let accepted = submitCurrentChatTurn(
                    applyPromptCollaboration: false)
                if prompt.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                    flashComposerHint(
                        "目標已建立；首個回合已排入目前 thread 佇列。")
                } else if composerHint?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty != false {
                    flashComposerHint(
                        "目標已建立，但首個回合未排入佇列；輸入仍保留。")
                }
                if let confirmedPlanArtifact {
                    if accepted {
                        _ =
                            publishConfirmedPlanWorkOSDispatchSuccessIfVerified(
                                message:
                                    "已送交 Work OS：已排入現有正式 dispatch，"
                                    + "runner 維持 running。")
                    } else {
                        failConfirmedPlanDispatch(
                            confirmedPlanArtifact,
                            reason: currentPlanDispatchFailureReason(
                                fallback:
                                    "首個計畫回合未排入現有 running dispatch。"))
                    }
                }
                return
            }
            let preferredModelID =
                currentTurnDispatchRoute().canonicalModelSlug
            guard let selectedModelID =
                selectedNativeDevelopmentExecutorModelID(
                    contract: contract,
                    preferredModelID: preferredModelID)
            else {
                flashComposerHint(
                    "目標已建立，但原生派工未啟動：exact Scenario 沒有可驗證的 active executor binding。")
                if let confirmedPlanArtifact {
                    failConfirmedPlanDispatch(
                        confirmedPlanArtifact,
                        reason: currentPlanDispatchFailureReason(
                            fallback:
                                "exact Scenario 沒有可驗證的 active executor binding。"))
                }
                return
            }
            let nativeTask = nativeDevelopmentLaneTask(
                modelID: selectedModelID,
                objective: objective)
            guard beginSelectedNativeDevelopmentDispatch(
                subtask: nativeTask,
                selectedModelID: selectedModelID)
            else {
                let reason = composerHint?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines)
                if let reason, !reason.isEmpty {
                    flashComposerHint(
                        "目標已建立，但原生派工未啟動：\(reason)")
                } else {
                    flashComposerHint(
                        "目標已建立，但原生派工未啟動；請確認 exact Scenario 與 executor route 後重試。")
                }
                if let confirmedPlanArtifact {
                    failConfirmedPlanDispatch(
                        confirmedPlanArtifact,
                        reason: currentPlanDispatchFailureReason(
                            fallback:
                                "原生 dispatch record 未建立。"))
                }
                return
            }
            let nativeDispatchID =
                pendingNativeDevelopmentDispatch?.id
            alignTurnRouteForNativeDispatch(modelID: selectedModelID)
            let accepted: Bool
            if let confirmedPlanArtifact {
                guard let executionTurn = executionPromptOverride else {
                    if let nativeDispatchID {
                        failPendingNativeDevelopmentDispatchStart(
                            dispatchID: nativeDispatchID,
                            message:
                                "已確認 Plan 缺少 execution envelope；"
                                + "原生 runner 未啟動。")
                    }
                    failConfirmedPlanDispatch(
                        confirmedPlanArtifact,
                        reason:
                            "已確認 Plan 缺少可驗證的 execution envelope；"
                            + "runner 未啟動。")
                    return
                }
                accepted =
                    startConfirmedPlanExecutionTurn(executionTurn)
            } else {
                prompt = nativeTask
                accepted = submitCurrentChatTurn(
                    applyPromptCollaboration: false)
            }
            if !accepted, let nativeDispatchID
            {
                let startFailureReason =
                    currentPlanDispatchFailureReason(
                        fallback:
                            "原生 runner 未取得執行權；dispatch 已 fail closed。")
                failPendingNativeDevelopmentDispatchStart(
                    dispatchID: nativeDispatchID,
                    message:
                        "Goal 已建立，但原生 runner 未取得執行權；派工已 fail closed。")
                flashComposerHint(
                    "原生 runner 未啟動；dispatch 已標記失敗，沒有留下假執行中狀態。")
                if let confirmedPlanArtifact {
                    failConfirmedPlanDispatch(
                        confirmedPlanArtifact,
                        reason: startFailureReason)
                }
                return
            }
            guard isRunning else {
                if let nativeDispatchID {
                    failPendingNativeDevelopmentDispatchStart(
                        dispatchID: nativeDispatchID,
                        message:
                            "Goal 已建立且回合已接受，但原生 runner 未進入 running；派工已 fail closed。")
                }
                flashComposerHint(
                    "原生 runner 未進入 running；dispatch 已標記失敗，沒有留下假執行中狀態。")
                if let confirmedPlanArtifact {
                    failConfirmedPlanDispatch(
                        confirmedPlanArtifact,
                        reason: currentPlanDispatchFailureReason(
                            fallback:
                                "原生 runner 未進入 running；dispatch 已 fail closed。"))
                }
                return
            }
            if confirmedPlanArtifact != nil {
                _ = publishConfirmedPlanWorkOSDispatchSuccessIfVerified(
                    dispatchID: nativeDispatchID,
                    message:
                        "已送交 Work OS：正式原生 dispatch 與 runner "
                        + "已進入 running。")
                flashComposerHint(
                    planWorkOSLocalActionPresentation.message)
            }
            return
        }
        if singleModelTopology {
            if isRunning && !forceSingleModel {
                prompt = executionPromptOverride ?? objective
                let accepted = submitCurrentChatTurn(
                    applyPromptCollaboration: false,
                    suppressUserEcho: executionPromptOverride != nil)
                if prompt.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                    if executionPromptOverride == nil {
                        flashComposerHint(
                            "目標已建立；首個回合已排入目前 thread 佇列。")
                    }
                } else if composerHint?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty != false {
                    flashComposerHint(
                        "目標已建立，但首個回合未排入佇列；輸入仍保留。")
                }
                if let confirmedPlanArtifact {
                    if accepted {
                        _ =
                            publishConfirmedPlanWorkOSDispatchSuccessIfVerified(
                                message:
                                    "已送交 Work OS：已排入現有正式 dispatch，"
                                    + "runner 維持 running。")
                        flashComposerHint(
                            planWorkOSLocalActionPresentation.message)
                    } else {
                        failConfirmedPlanDispatch(
                            confirmedPlanArtifact,
                            reason: currentPlanDispatchFailureReason(
                                fallback:
                                    "首個計畫回合未排入現有 running dispatch。"))
                    }
                }
                return
            }
            guard beginSingleModelGoalDispatch(subtask: objective) else {
                if let confirmedPlanArtifact {
                    failConfirmedPlanDispatch(
                        confirmedPlanArtifact,
                        reason: currentPlanDispatchFailureReason(
                            fallback:
                                "單模型 dispatch record 未建立。"))
                }
                return
            }
            let dispatchID = pendingSingleModelGoalDispatch?.id
            let accepted: Bool
            var planModeWasEnabledForConfirmedStart = false
            if let confirmedPlanArtifact {
                guard let executionTurn = executionPromptOverride else {
                    if let dispatchID {
                        failPendingSingleModelGoalDispatch(
                            dispatchID: dispatchID,
                            message:
                                "已確認 Plan 缺少 execution envelope；"
                                + "單模型 runner 未啟動。")
                    }
                    failConfirmedPlanDispatch(
                        confirmedPlanArtifact,
                        reason:
                            "已確認 Plan 缺少可驗證的 execution envelope；"
                            + "runner 未啟動。")
                    return
                }
                planModeWasEnabledForConfirmedStart =
                    isPlanModeEnabled
                if planModeWasEnabledForConfirmedStart {
                    setPlanModeEnabled(false)
                }
                accepted =
                    startConfirmedPlanExecutionTurn(executionTurn)
            } else {
                prompt = executionPromptOverride ?? objective
                accepted = submitCurrentChatTurn(
                    applyPromptCollaboration: false,
                    suppressUserEcho: executionPromptOverride != nil)
            }
            if !accepted {
                if planModeWasEnabledForConfirmedStart {
                    setPlanModeEnabled(true)
                }
                let startFailureReason =
                    currentPlanDispatchFailureReason(
                        fallback:
                            "單模型 runner 未取得執行權；dispatch 已 fail closed。")
                if let dispatchID {
                    failPendingSingleModelGoalDispatch(
                        dispatchID: dispatchID,
                        message:
                            "單模型 runner 未取得執行權；Goal dispatch 已 fail closed。")
                }
                flashComposerHint(
                    "單模型 runner 未啟動；沒有留下假執行中狀態。")
                if let confirmedPlanArtifact {
                    failConfirmedPlanDispatch(
                        confirmedPlanArtifact,
                        reason: startFailureReason)
                }
                return
            }
            guard settleAcceptedSingleModelGoalDispatchStart(
                dispatchID: dispatchID,
                message:
                    "單模型回合已接受，但 runner 未進入 running；Goal dispatch 已 fail closed.")
            else {
                flashComposerHint(
                    "單模型 runner 未進入 running；dispatch 已標記失敗，沒有留下假執行中狀態。")
                if let confirmedPlanArtifact {
                    failConfirmedPlanDispatch(
                        confirmedPlanArtifact,
                        reason: currentPlanDispatchFailureReason(
                            fallback:
                                "單模型 runner 未進入 running；dispatch 已 fail closed。"))
                }
                return
            }
            if confirmedPlanArtifact != nil {
                _ = publishConfirmedPlanWorkOSDispatchSuccessIfVerified(
                    dispatchID: dispatchID,
                    message:
                        "已送交 Work OS：正式單模型 dispatch 與 runner "
                        + "已進入 running。")
                flashComposerHint(
                    planWorkOSLocalActionPresentation.message)
            }
            return
        }
        if let confirmedPlanArtifact {
            failConfirmedPlanDispatch(
                confirmedPlanArtifact,
                reason:
                    "Work OS 未建立可驗證的 canonical dispatch record；"
                    + "已阻止未受治理的 runner 啟動。")
            return
        }
        prompt = executionPromptOverride ?? objective
        submitCurrentChatTurn(
            applyPromptCollaboration: false,
            suppressUserEcho: executionPromptOverride != nil)
        guard prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            if composerHint?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty != false {
                flashComposerHint(
                    "目標已建立，但首個執行／補問回合未送出；輸入仍保留，請依提示重試。")
            }
            return
        }
        flashComposerHint(
            "目標已建立，首個執行／補問回合已送出：\(objective)")
    }

    @discardableResult
    func beginSingleModelGoalDispatch(subtask: String) -> Bool {
        guard let contract = selectedWorkOSContract,
              contract.mode == .s
        else {
            flashComposerHint("單模型 Goal 未派工：Work OS S 合約未建立。")
            return false
        }
        let modelID = currentTurnDispatchRoute().canonicalModelSlug
        let normalized = TatwoGatewayDispatchCatalog.normalize(modelID)
        guard let binding = contract.identityBindings.first(where: {
            $0.identity == .lead
                && $0.modelID.map(
                    TatwoGatewayDispatchCatalog.normalize) == normalized
        }) else {
            flashComposerHint("單模型 Goal 未派工：合約沒有目前模型的主導綁定。")
            return false
        }
        let normalizedSubtask = TatwoObjectiveIdentity.normalize(subtask)
        guard !normalizedSubtask.isEmpty else {
            flashComposerHint("單模型 Goal 未派工：執行內容為空。")
            return false
        }
        let logicalDispatchID = Self.singleModelGoalLogicalDispatchID(
            contractID: contract.contractID,
            bindingID: binding.id,
            normalizedSubtask: normalizedSubtask)
        let retryAttemptCap = TatwoGoalRunStore.dispatchRetryAttemptCap
        do {
            let matchingRecords = try dispatchRegistry
                .run(forContractID: contract.contractID)?
                .records
                .filter {
                    $0.bindingID == binding.id
                        && $0.resolvedLogicalDispatchID
                            == logicalDispatchID
                } ?? []
            let supersededIDs = Set(
                matchingRecords.compactMap(\.supersedes))
            let logicalHeads = matchingRecords.filter {
                !supersededIDs.contains($0.id)
            }
            guard logicalHeads.count <= 1 else {
                pendingSingleModelGoalDispatch = nil
                selectedGoalRecord =
                    try goalRunStore.requireIssuedContract(
                        contract.contractID)
                selectedDispatchRecords =
                    try dispatchRegistry.latestRecordsByBinding(
                        forContractID: contract.contractID)
                flashComposerHint(
                    "單模型 Goal 未派工：相同 logical dispatch 出現多個 durable head，"
                        + "必須先完成 ledger reconciliation。")
                return false
            }
            let retrySupersedes: String?
            if let existing = logicalHeads.first {
                if existing.status == .failed,
                   existing.failureReceipt?.failureClass == .retryable
                {
                    guard existing.resolvedAttempt < retryAttemptCap else {
                        pendingSingleModelGoalDispatch = nil
                        do {
                            selectedGoalRecord =
                                try goalRunStore.markDispatchRetryExhausted(
                                    contractID: contract.contractID,
                                    dispatchID: existing.id)
                        } catch {
                            quarantineSelectedWorkOSState(
                                "single_model_retry_exhaustion_settlement_failed: "
                                    + TatwoPrivacyRedactor.redacted(
                                        error.localizedDescription))
                            return false
                        }
                        clearSingleModelGoalDispatchRuntimeState(
                            dispatchID: existing.id)
                        selectedGoalRecord =
                            try goalRunStore.requireIssuedContract(
                                contract.contractID)
                        selectedDispatchRecords =
                            try dispatchRegistry.latestRecordsByBinding(
                                forContractID: contract.contractID)
                        flashComposerHint(
                            "單模型 Goal 未派工：Retry budget exhausted；"
                                + "相同 logical dispatch 已達 \(retryAttemptCap) 次上限。"
                                + "請重新確認計畫並建立新的 Goal revision/contract，"
                                + "再由新合約 mint 新 logical dispatch；"
                                + "系統不會自動沿用舊 logical ID。")
                        return false
                    }
                    retrySupersedes = existing.id
                } else {
                    pendingSingleModelGoalDispatch = nil
                    selectedGoalRecord =
                        try goalRunStore.requireIssuedContract(
                            contract.contractID)
                    selectedDispatchRecords =
                        try dispatchRegistry.latestRecordsByBinding(
                            forContractID: contract.contractID)
                    flashComposerHint(
                        "單模型 Goal 未重複派工：相同執行內容已有 durable dispatch"
                            + "（\(existing.status.rawValue)）。")
                    return false
                }
            } else {
                retrySupersedes = nil
            }
            let record = try TatwoGoalRunDispatchLifecycle.begin(
                contractID: contract.contractID,
                bindingID: binding.id,
                sourceSlotID: binding.sourceSlotID,
                identity: binding.identity,
                modelID: modelID,
                subtask: subtask,
                logicalDispatchID: logicalDispatchID,
                supersedes: retrySupersedes,
                retryAttemptCap:
                    try TatwoGoalRunStore.validatedDispatchRetryAttemptCap(
                        retryAttemptCap),
                helperCap: 1,
                goalStore: goalRunStore,
                dispatchRegistry: dispatchRegistry,
                scenarioBook: scenarioConfigBook)
            singleModelGoalDispatchContractIDByDispatchID[record.id] =
                record.contractID
            pendingSingleModelGoalDispatch = record
            selectedGoalRecord =
                try goalRunStore.requireIssuedContract(contract.contractID)
            selectedDispatchRecords =
                try dispatchRegistry.latestRecordsByBinding(
                    forContractID: contract.contractID)
            return true
        } catch {
            pendingSingleModelGoalDispatch = nil
            flashComposerHint(
                "單模型 Goal 派工失敗："
                    + TatwoPrivacyRedactor.redacted(
                        error.localizedDescription))
            return false
        }
    }

    private static func singleModelGoalLogicalDispatchID(
        contractID: String,
        bindingID: String,
        normalizedSubtask: String
    ) -> String {
        let material =
            "\(contractID)\n\(bindingID)\n\(normalizedSubtask)"
        let digest = TatwoLoopJobDigest.sha256(Data(material.utf8))
            .dropFirst("sha256:".count)
        return "logical-chat-single-\(digest)"
    }

    /// `submitCurrentChatTurn == true` is only an acknowledgement that the turn
    /// was accepted. It is not proof that a runner remains active. Settle the
    /// durable dispatch by ID even when submit already moved the in-memory row
    /// from `pending` to an active-turn context.
    @discardableResult
    func settleAcceptedSingleModelGoalDispatchStart(
        dispatchID: String?,
        message: String
    ) -> Bool {
        guard let dispatchID else { return false }
        let activeRunnerInstanceID =
            singleModelGoalRunnerInstanceID(dispatchID: dispatchID)
        let startReceipt =
            singleModelGoalRunnerStartReceiptByDispatchID[dispatchID]
        if activeRunnerInstanceID != nil || startReceipt != nil {
            singleModelGoalRunnerStartReceiptByDispatchID.removeValue(
                forKey: dispatchID)
            singleModelGoalDeferredStartAwaitingDispatchIDs.remove(dispatchID)
            return true
        }
        if registerSingleModelGoalDeferredStartSettlementIfActive(
            dispatchID: dispatchID)
        {
            return true
        }
        failPendingSingleModelGoalDispatch(
            dispatchID: dispatchID,
            message: message)
        return false
    }

    func failPendingSingleModelGoalDispatch(
        dispatchID: String,
        message: String
    ) {
        let contractIDs =
            singleModelGoalDispatchRuntimeContractIDs(
                dispatchID: dispatchID)
        guard let contractID = contractIDs.first else {
            quarantineSelectedWorkOSState(
                "single_model_dispatch_binding_missing: \(dispatchID)")
            return
        }
        guard contractIDs.count == 1 else {
            quarantineSelectedWorkOSState(
                "single_model_dispatch_binding_mismatch: \(dispatchID)")
            return
        }
        let durable: TatwoDispatchRecord
        do {
            guard let run = try dispatchRegistry.run(
                forContractID: contractID),
                  let record = run.records.first(where: {
                      $0.id == dispatchID
                  })
            else {
                quarantineSelectedWorkOSState(
                    "single_model_dispatch_settlement_lookup_failed: "
                        + dispatchID)
                return
            }
            durable = record
        } catch {
            quarantineSelectedWorkOSState(
                "single_model_dispatch_settlement_lookup_failed: "
                    + TatwoPrivacyRedactor.redacted(
                        error.localizedDescription))
            return
        }
        guard durable.contractID == contractID else {
            quarantineSelectedWorkOSState(
                "single_model_dispatch_binding_mismatch: \(dispatchID)")
            return
        }
        guard durable.status == .queued || durable.status == .running else {
            clearSingleModelGoalDispatchRuntimeState(
                dispatchID: dispatchID)
            return
        }
        do {
            _ = try TatwoGoalRunDispatchLifecycle.update(
                contractID: contractID,
                dispatchID: dispatchID,
                status: .failed,
                failureClass: .retryable,
                errorCode: "single_model_runner_not_started",
                errorMessage: message,
                goalStore: goalRunStore,
                dispatchRegistry: dispatchRegistry)
            clearSingleModelGoalDispatchRuntimeState(
                dispatchID: dispatchID)
            refreshSelectedWorkOSState(contractID: contractID)
            if planWorkOSLocalActionPresentation.phase == .dispatching,
               planWorkOSLocalActionPresentation.dispatchID == dispatchID,
               let artifact = activePlanArtifact
            {
                failConfirmedPlanDispatch(
                    artifact,
                    reason: message)
            }
        } catch {
            quarantineSelectedWorkOSState(
                "單模型 runner 啟動失敗且 ledger 無法收斂："
                    + TatwoPrivacyRedactor.redacted(
                        error.localizedDescription))
        }
    }

    private func selectedNativeDevelopmentExecutorModelID(
        contract: TatwoWorkOSContractV1,
        preferredModelID: String
    ) -> String? {
        func isActiveExecutor(_ modelID: String) -> Bool {
            let normalized =
                TatwoGatewayDispatchCatalog.normalize(modelID)
            let eligibleBindings = contract.identityBindings.filter {
                $0.modelID.map(
                    TatwoGatewayDispatchCatalog.normalize)
                    == normalized
                    && [.sub, .supervisor, .verifier]
                        .contains($0.identity)
                    && $0.authority == .toolIntentBridge
                    && $0.canMutateHost
            }
            return eligibleBindings.contains { binding in
                contract.loopGovernorDecision.activatedBindings
                    .contains {
                        $0.id == binding.sourceSlotID
                            && $0.phase == .loops
                            && $0.enabled
                            && $0.dynamicActivation != .disabled
                            && $0.boundModelIDs.contains {
                                TatwoGatewayDispatchCatalog
                                    .normalize($0) == normalized
                            }
                    }
            }
        }

        let candidates = [
            preferredModelID,
            selectedThread?.loopsConfig?.primaryModelID,
        ].compactMap { $0 } + [.sub, .supervisor, .verifier]
            .flatMap { identity in
                contract.identityBindings.compactMap {
                    $0.identity == identity ? $0.modelID : nil
                }
            }
        return candidates.first(where: isActiveExecutor)
    }

    /// 2026-08-21 HINTFIX-3：lane 回合必須騎在已解析 executor 的路由上。
    /// composer 停在非 lane 成員（如預設 gpt-5.5）時，回合 command 拿不到
    /// native 開發權限，runner 以 native_access_denied fail closed——閉環
    /// 驗收歷史上三個模型「啟動失敗」的同根病因。
    func alignTurnRouteForNativeDispatch(modelID: String) {
        let normalized = TatwoGatewayDispatchCatalog.normalize(modelID)
        guard TatwoGatewayDispatchCatalog.normalize(
            currentTurnDispatchRoute().canonicalModelSlug) != normalized
        else { return }
        guard let choice = ChatRouteChoice.resolveOrNil(modelID) else { return }
        selectedModel = choice.id
    }

    func setPlanModeEnabled(_ enabled: Bool) {
        mutateSelectedThread { thread in
            thread.isPlanModeEnabled = enabled
            thread.updatedAt = Date()
        }
    }

    /// /plg <目標>：由 thread 主導/loops 綁定建 PLG run，停在 planning 相位供人類討論。
    /// 不自動 advanceFromPlanning——避免「一按 Enter 還沒寫內文就送出大分工」。
    @discardableResult
    func startPLGRun(objective: String) async -> Bool {
        await startPLGRun(
            objective: objective,
            automaticallyBootstrapUserOwnedAuthority: true)
    }

    @discardableResult
    private func startPLGRun(
        objective: String,
        automaticallyBootstrapUserOwnedAuthority: Bool
    ) async -> Bool {
        guard mode == .chat, selectedThread != nil else {
            plgError = "PLG blocked：PLG 只能從 Chat 主 thread 啟動。"
            flashComposerHint("PLG 只能從 Chat 主 thread 啟動。")
            return false
        }
        guard !isDiscussionSessionSelected else {
            plgError = "PLG blocked：Discussion 的 loops 是 branch-local；請明確 merge receipt 後再由主線進入 Work OS。"
            flashComposerHint("Discussion 不會直接派工到主線；先保留 branch loops，完成後明確 merge。")
            return false
        }
        let goal = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return false }
        // A completed `/plan` does not grant topology authority. In the
        // staging67 regression a fresh project thread was still Ultrawork Off,
        // but `/plg` classified the Python plan as "native development",
        // loaded the app-wide XXL preset, and wrote stale gpt-5.5 / sonnet /
        // grok / haiku / fable roles onto this row before a contract existed.
        //
        // Fail closed at the first mutation boundary. The user can explicitly
        // enable Ultrawork (or name an Ultrawork/XXL topology in this command),
        // but a prior Plan artifact plus a development-shaped objective is not
        // permission to resurrect app-wide collaboration state.
        if activePlanRequiresExplicitUltraworkSelectionForPLG(
            objective: goal)
        {
            plgError =
                "PLG blocked：目前計劃仍是 Ultrawork Off；請先明確選擇 Ultrawork 模式與角色，再重新送出 /plg。"
            flashComposerHint(
                "PLG 未啟動：目前計劃是 Ultrawork Off；未套用舊的 XXL／角色設定。")
            return false
        }
        guard await prepareNativeDevelopmentScenarioForPLGIfNeeded(
            objective: goal)
        else {
            return false
        }
        guard ensureSelectedThreadWorkOSContract(
            objectiveHint: goal,
            requireObjectiveMatch: true,
            allowCreateIfUnbound: true,
            automaticallyBootstrapUserOwnedAuthority:
                automaticallyBootstrapUserOwnedAuthority)
        else {
            plgError = "PLG blocked：Work OS contract 建立失敗"
            let reason = selectedWorkOSStateMessage
                .trimmingCharacters(in: .whitespacesAndNewlines)
            flashComposerHint(
                reason.isEmpty
                    ? "PLG 未啟動：Work OS contract 建立失敗。"
                    : "PLG 未啟動：\(reason)")
            return false
        }

        do {
            guard let refreshedThread = selectedThread else {
                throw TatwoPLGGovernanceError.missingContract
            }
            let contractID = refreshedThread.workOSContractID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let goalID = refreshedThread.workOSGoalID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let contractID, !contractID.isEmpty else {
                throw TatwoPLGGovernanceError.missingContract
            }
            let issued = try goalRunStore.requireIssuedContract(contractID)
            let expectedObjective = selectedThreadWorkOSContext(
                thread: refreshedThread,
                objectiveHint: goal).objective
            try TatwoPLGGovernance.validateStartContext(
                contractID: contractID,
                goalID: goalID,
                issuedGoalID: issued.goalID,
                objective: expectedObjective,
                issuedObjective: issued.objective).get()

            guard let contract = selectedWorkOSContract,
                  contract.contractID == contractID,
                  contract.goalID == issued.goalID
            else {
                throw TatwoPLGGovernanceError.missingContract
            }
            let leadModelIDs = contract.identityBindings
                .filter { $0.identity == .lead }
                .compactMap(\.modelID)
            let subModelIDs = contract.identityBindings
                .filter { $0.identity == .sub }
                .compactMap(\.modelID)
            let run = TatwoPLGRunFactory.make(
                objective: goal,
                contractID: contractID,
                goalID: issued.goalID,
                leadModelIDs: leadModelIDs.isEmpty
                    ? [selectedThreadSupervisorModelID]
                    : leadModelIDs,
                subModelIDs: subModelIDs,
                nowISO: Self.plgISO())
            let projected = makePLGDomainProjection(
                run: run,
                contract: selectedWorkOSContract,
                goalRecord: selectedGoalRecord)
            try plgChainStore.begin(run: projected)
            let replay = try plgChainStore.replay(
                contractID: projected.contractID,
                goalID: projected.goalID,
                runID: projected.id)
            activePLGRun = replay.run
            appliedPLGEventIDs = replay.appliedEventIDs
            plgAuthorityState = .verified(
                runID: replay.run.id,
                headHash: replay.headHash)
            plgError = nil
            prompt = ""
            persistActivePLGProjection()
            return true
        } catch {
            activePLGRun = nil
            appliedPLGEventIDs = []
            plgAuthorityState = .quarantined(error.localizedDescription)
            plgError = "PLG blocked：Work OS contract 無效（\(error.localizedDescription)）"
            flashComposerHint("PLG 未啟動：\(error.localizedDescription)")
            return false
        }
    }

    private func activePlanRequiresExplicitUltraworkSelectionForPLG(
        objective: String
    ) -> Bool {
        guard let thread = selectedThread,
              thread.loopsConfig == nil,
              let artifact = activePlanArtifact,
              artifact.threadID == thread.id,
              artifact.sourceAssistantMessageID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false,
              !artifact.sections.isEmpty
        else { return false }
        return TatwoGoalTopologyAuthority.requestedTopology(
            commandText: objective) == .singleModel
    }

    /// Policy D：App 只把 Work OS DomainLoop 與已落盤收據投影成 PLG branch。
    /// 每支 branch 有獨立 domainLoopID 與 planSlice；App 不建立 dispatch 或寫 ledger。
    private func makePLGDomainProjection(
        run: TatwoPLGRun,
        contract: TatwoWorkOSContractV1?,
        goalRecord: TatwoStoredGoalRun?
    ) -> TatwoPLGRun {
        guard let contract, contract.contractID == run.contractID else { return run }
        return TatwoPLGPolicyDProjector.project(
            run: run,
            contract: contract,
            goalRecord: goalRecord)
    }

    /// Rebuild only the App's PLG projection for an already-issued active
    /// contract. Unlike `startPLGRun(objective:)`, this path can never call
    /// `WorkOSFactory.begin` or derive a new Goal from a Loop subtask.
    private func startPLGProjectionForActiveContract(
        _ contract: TatwoWorkOSContractV1,
        goalRecord: TatwoStoredGoalRun
    ) -> Bool {
        guard let thread = selectedThread,
              thread.workOSContractID == contract.contractID,
              thread.workOSGoalID == contract.goalID,
              goalRecord.contractID == contract.contractID,
              goalRecord.goalID == contract.goalID
        else { return false }

        do {
            let issued = try goalRunStore.requireIssuedContract(contract.contractID)
            try TatwoPLGGovernance.validateStartContext(
                contractID: contract.contractID,
                goalID: contract.goalID,
                issuedGoalID: issued.goalID,
                objective: contract.objective,
                issuedObjective: issued.objective).get()
            let leadModelIDs = contract.identityBindings
                .filter { $0.identity == .lead }
                .compactMap(\.modelID)
            let subModelIDs = contract.identityBindings
                .filter { $0.identity == .sub }
                .compactMap(\.modelID)
            let run = TatwoPLGRunFactory.make(
                objective: contract.objective,
                contractID: contract.contractID,
                goalID: contract.goalID,
                leadModelIDs: leadModelIDs.isEmpty
                    ? [selectedThreadSupervisorModelID]
                    : leadModelIDs,
                subModelIDs: subModelIDs,
                nowISO: Self.plgISO())
            let projected = makePLGDomainProjection(
                run: run,
                contract: contract,
                goalRecord: goalRecord)
            try plgChainStore.begin(run: projected)
            let replay = try plgChainStore.replay(
                contractID: projected.contractID,
                goalID: projected.goalID,
                runID: projected.id)
            activePLGRun = replay.run
            appliedPLGEventIDs = replay.appliedEventIDs
            plgAuthorityState = .verified(
                runID: replay.run.id,
                headHash: replay.headHash)
            plgError = nil
            persistActivePLGProjection()
            return true
        } catch {
            activePLGRun = nil
            appliedPLGEventIDs = []
            plgAuthorityState = .quarantined(error.localizedDescription)
            plgError = "PLG blocked：active contract 投影無效（\(error.localizedDescription)）"
            return false
        }
    }

    func refreshActivePLGDomainProjection() {
        guard let run = activePLGRun else { return }
        guard case .none = plgAuthorityState else { return }
        let projected = makePLGDomainProjection(
            run: run,
            contract: selectedWorkOSContract,
            goalRecord: selectedGoalRecord)
        guard projected != run else { return }
        activePLGRun = projected
        persistActivePLGProjection()
    }

    /// 人類在 Plan 討論後按【確認計畫】→ 才 advanceFromPlanning 進入分工（leadAdversarial / awaitingHumanAuth）。
    /// 也是 /goal 指令在 planning 相位時的動作。
    @discardableResult
    func advancePLGFromPlanning() -> Bool {
        guard let run = activePLGRun, run.phase == .planning else { return false }
        let projected = makePLGDomainProjection(
            run: run,
            contract: selectedWorkOSContract,
            goalRecord: selectedGoalRecord)
        if projected != run {
            guard applyPLG({ current in
                try TatwoPLGOrchestrator.migratePlanningProjection(
                    to: projected.branchGoals,
                    in: current,
                    expectedRevision: current.revision,
                    eventID: UUID())
            }) else {
                return false
            }
        }
        guard activePLGRun?.phase == .planning else { return false }
        return applyPLG { r in
            try TatwoPLGOrchestrator.advanceFromPlanning(
                r, expectedRevision: r.revision, eventID: UUID())
        }
    }

    /// 關閉 App 的 PLG 投影；不寫 shared ledger，也不替 Work OS 關閉 goal。
    func endPLGRun() {
        guard activePLGRun != nil else { return }
        activePLGRun = nil
        appliedPLGEventIDs = []
        plgAuthorityState = .none
        plgPaused = false
        persistActivePLGProjection()
        flashComposerHint("已關閉本機流程卡；Work OS goal 未被 App 關閉。")
    }

    /// 暫停/續跑只影響 App 投影；App 不直接派工，也不寫 shared ledger。
    func togglePLGPause() {
        guard let run = activePLGRun else { return }
        plgPaused.toggle()
        if !plgPaused {
            refreshPLGProjectionThroughWorkOSChokepoint(run)
        }
        flashComposerHint(plgPaused
            ? "已暫停本機流程投影；Work OS 執行狀態不受 App 改寫。"
            : "已續看 Work OS 流程；App 仍為唯讀控制台。")
    }

    /// /goal <目標>：只延續同 thread 已存在的 planning run；找不到或歧義時 fail-closed。
    static func canCommitPLGGoal(from phase: TatwoPLGPhase) -> Bool {
        phase == .planning || phase == .leadAdversarial
    }

    func commitPLGGoalFromPrompt() {
        let note = slashObjective(prompt, strip: ["/goal"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = confirmPLGPlanAndStartLoops(
            nativeTaskOverride: note.isEmpty ? nil : note)
    }

    /// The Plan card's human confirmation is the Goal confirmation boundary.
    /// It must create the contract-bound dispatch and start the matching
    /// native runner in the same action; advancing only the PLG projection
    /// would leave the UI claiming that Loops started without ledger evidence.
    @discardableResult
    func confirmPLGPlanAndStartLoops(
        nativeTaskOverride: String? = nil,
        executionPromptOverride: String? = nil,
        restoreProjection: Bool = true,
        usesConfirmedPlanTransport: Bool = false
    ) -> Bool {
        if restoreProjection {
            restoreActivePLGProjection(from: selectedThread)
        }
        guard let run = activePLGRun else {
            requestOpenLoopsPanel = true
            let reason = plgError ?? "找不到可延續的同 thread Plan"
            plgError = "PLG blocked：\(reason)"
            flashComposerHint("PLG 未能進入 Goal：\(reason)。請先在同一 thread 使用 /plan。")
            return false
        }
        guard Self.canCommitPLGGoal(from: run.phase) else {
            requestOpenLoopsPanel = true
            flashComposerHint("此 thread 的 Goal 已離開 planning，相位為 \(run.phase.rawValue)。")
            return false
        }
        let override = nativeTaskOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmedExecutionPrompt = executionPromptOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let objective: String
        if let override, !override.isEmpty {
            objective = override
        } else {
            let confirmedPlan = run.planSummary.trimmingCharacters(
                in: .whitespacesAndNewlines)
            objective = confirmedPlan.isEmpty
                ? selectedWorkOSContract?.objective.trimmingCharacters(
                    in: .whitespacesAndNewlines) ?? ""
                : confirmedPlan
        }
        guard !objective.isEmpty else {
            requestOpenLoopsPanel = true
            flashComposerHint(
                "PLG 未能進入 Goal：目前 Work OS contract 缺少 objective。")
            return false
        }
        guard !isRunning else {
            requestOpenLoopsPanel = true
            flashComposerHint(
                "PLG 未能進入 Goal：目前仍有一輪工作執行中，請先等待完成或停止後再確認。")
            return false
        }
        if run.phase == .planning {
            guard advancePLGFromPlanning() else {
                requestOpenLoopsPanel = true
                flashComposerHint("PLG 未能進入 Goal：\(plgError ?? "流程狀態未通過驗證")")
                return false
            }
        }
        // 2026-08-28 staging69 live regression：Ultrawork **S**（主導 terra）
        // 按下【確認計畫，進入分工】走的就是這條路徑，但這裡以前只實作了
        // XXL exact 原生開發 lane。S 合約的 identity bindings 只有
        // lead/verifier、`authority = .brain_only`、`canMutateHost = false`，
        // 永遠解不出 active executor binding，於是每次都停在「exact
        // Scenario 沒有可驗證的 active executor binding」：Loops 卡停在尚未
        // 派發、0 planned branches、無 runtime receipt、目標資料夾不存在。
        //
        // `/goal` 早就依拓撲分流（native XXL → 原生 lane；S → 單模型
        // dispatch）；人門確認鍵必須用同一組分流，否則 Ultrawork S 的 PLG
        // 結構上永遠進不了 Goal。分流之外的 fail-closed 語意不變。
        guard let plgContract = selectedWorkOSContract else {
            requestOpenLoopsPanel = true
            flashComposerHint(
                "PLG 未能進入 Goal：這個 thread 尚未簽發 Work OS contract。")
            return false
        }
        guard Self.isExactNativeDevelopmentScenario(plgContract.scenario)
        else {
            return confirmPLGPlanWithSingleModelLead(
                contract: plgContract,
                objective: objective,
                executionPromptOverride:
                    confirmedExecutionPrompt,
                usesConfirmedPlanTransport:
                    usesConfirmedPlanTransport)
        }
        // 2026-08-21 HINTFIX-2：composer 選中模型（如預設 gpt-5.5）可能
        // 不是本合約 lane 成員；/goal 路徑早就走 resolver，這條 PLG 進
        // Goal 的路徑卻塞原始 slug，coordinator 便 fail-closed——閉環
        // 驗收「/plg 靜默丟棄」的第二半真兇（第一半是 hint 無渲染點）。
        let preferredModelID =
            currentTurnDispatchRoute().canonicalModelSlug
        guard let selectedModelID =
                selectedNativeDevelopmentExecutorModelID(
                    contract: plgContract,
                    preferredModelID: preferredModelID)
        else {
            requestOpenLoopsPanel = true
            flashComposerHint(
                "PLG 未能進入 Goal：exact Scenario 沒有可驗證的 active executor binding。")
            return false
        }
        let nativeTask = nativeDevelopmentLaneTask(
            modelID: selectedModelID,
            objective: objective)
        guard beginSelectedNativeDevelopmentDispatch(
            subtask: nativeTask,
            selectedModelID: selectedModelID)
        else {
            requestOpenLoopsPanel = true
            return false
        }
        let nativeDispatchID = pendingNativeDevelopmentDispatch?.id
        requestOpenLoopsPanel = true
        alignTurnRouteForNativeDispatch(modelID: selectedModelID)
        if usesConfirmedPlanTransport {
            guard let confirmedExecutionPrompt,
                  !confirmedExecutionPrompt.isEmpty
            else {
                if let nativeDispatchID {
                    failPendingNativeDevelopmentDispatchStart(
                        dispatchID: nativeDispatchID,
                        message:
                            "Goal 已確認，但缺少 canonical execution envelope；"
                            + "派工已 fail closed。")
                }
                flashComposerHint(
                    "原生 runner 未啟動：已確認 Plan 缺少 execution envelope。")
                return false
            }
            _ = startConfirmedPlanExecutionTurn(
                confirmedExecutionPrompt)
        } else {
            prompt = nativeTask
            submitCurrentChatTurn(applyPromptCollaboration: false)
        }
        if let nativeDispatchID,
           pendingNativeDevelopmentDispatch?.id == nativeDispatchID
        {
            failPendingNativeDevelopmentDispatchStart(
                dispatchID: nativeDispatchID,
                message:
                    "Goal 已確認，但原生 runner 未取得執行權；派工已 fail closed。")
            flashComposerHint(
                "原生 runner 未啟動；dispatch 已標記失敗，沒有留下假執行中狀態。")
            return false
        }
        guard isRunning else {
            if let nativeDispatchID {
                failPendingNativeDevelopmentDispatchStart(
                    dispatchID: nativeDispatchID,
                    message:
                        "Goal 已確認且回合已接受，但原生 runner 未進入 running；派工已 fail closed。")
            }
            flashComposerHint(
                "原生 runner 未進入 running；dispatch 已標記失敗，沒有留下假執行中狀態。")
            return false
        }
        flashComposerHint(
            "目標已確認 → \(currentTurnDispatchRoute().title) 原生執行已進入 running")
        return true
    }

    /// exact 原生開發 Scenario 之外（Ultrawork S／主導單模型）的確認分支。
    /// 這裡的 executor 就是合約的 lead binding，不是 XXL 的
    /// `toolIntentBridge` sub；派工／fail-closed 語意與 `/goal` 單模型路徑
    /// 對齊，避免同一個人門動作有兩套收據行為。
    private func confirmPLGPlanWithSingleModelLead(
        contract: TatwoWorkOSContractV1,
        objective: String,
        executionPromptOverride: String?,
        usesConfirmedPlanTransport: Bool
    ) -> Bool {
        guard contract.mode == .s else {
            requestOpenLoopsPanel = true
            flashComposerHint(
                "PLG 未能進入 Goal：\(contract.mode.rawValue) 合約的 Scenario"
                    + "「\(contract.scenario)」沒有可派工的 executor lane。")
            return false
        }
        guard let leadModelID = Self.singleModelLeadExecutorModelID(
            contract: contract,
            preferredModelID: currentTurnDispatchRoute().canonicalModelSlug)
        else {
            requestOpenLoopsPanel = true
            flashComposerHint(
                "PLG 未能進入 Goal：S 合約沒有可派工的主導綁定。")
            return false
        }
        // 回合必須騎在合約主導綁定的路由上；composer 停在別的模型時
        // `beginSingleModelGoalDispatch` 會找不到主導綁定而 fail-closed。
        alignTurnRouteForNativeDispatch(modelID: leadModelID)
        guard beginSingleModelGoalDispatch(subtask: objective) else {
            requestOpenLoopsPanel = true
            return false
        }
        let singleModelDispatchID = pendingSingleModelGoalDispatch?.id
        requestOpenLoopsPanel = true
        // 2026-08-28 staging69 live r11：`/plan` 仍開著時按【確認計畫，進入分工】
        // （加號→交給 Work OS Loops 建的 PLG run 不會關掉 Plan 模式），dispatch
        // 開了、runner 也起跑，但這一輪仍以 Plan interaction semantics 送出：
        //
        //   * `currentChatInteractionMode` 判成 `.plan`，argv 走
        //     `TatwoPermissionPreset.askFirst` ＝ `-s read-only`
        //     （live spawn argc=32；workspace-write 應為 34）；
        //   * turn 仍被注入「Hidden Codex-style Plan mode contract」
        //     （`mode=plan` / `Do not execute commands…`）；
        //   * `requiresWorkOSContract` 帶 `!isPlanModeEnabled`，連 Work OS
        //     owner 關卡都被整段跳過。
        //
        // terra 因此回 `blocker_class=tool_unavailable authority_source=runner`
        // 並要求 `/plan off`，dispatch 以
        // `operational_failure: Single-model runner exited successfully without
        // tool execution evidence` 收斂，目標資料夾不存在。
        //
        // 人門確認就是 Plan interaction semantics 的終點：dispatch 一旦開出去，
        // 這個 thread 必須離開 Plan 模式。送不出去（`!accepted`）時原樣還原，
        // 讓失敗回合不會偷偷改掉使用者的 Plan 模式。
        let planModeWasEnabled = isPlanModeEnabled
        if planModeWasEnabled {
            setPlanModeEnabled(false)
        }
        let accepted: Bool
        if usesConfirmedPlanTransport {
            guard let executionPromptOverride,
                  !executionPromptOverride.isEmpty
            else {
                if let singleModelDispatchID {
                    failPendingSingleModelGoalDispatch(
                        dispatchID: singleModelDispatchID,
                        message:
                            "Goal 已確認，但缺少 canonical execution envelope；"
                            + "派工已 fail closed。")
                }
                flashComposerHint(
                    "單模型 runner 未啟動：已確認 Plan 缺少 execution envelope。")
                return false
            }
            accepted = startConfirmedPlanExecutionTurn(
                executionPromptOverride)
        } else {
            prompt = objective
            accepted = submitCurrentChatTurn(
                applyPromptCollaboration: false)
        }
        if !accepted {
            if planModeWasEnabled {
                setPlanModeEnabled(true)
            }
            // 2026-08-28 staging69：`submitCurrentChatTurn` 的深層 blocker
            // 原本會被下面這行 wrapper 蓋掉，收據只剩「未取得執行權」，
            // 主線得再跑一輪實機才知道真因（實際是 Work OS continuity
            // 隔離）。把深因一併寫進 dispatch failure receipt 與 hint。
            let blocker = composerHint?.trimmingCharacters(
                in: .whitespacesAndNewlines)
            let reason = (blocker?.isEmpty == false ? blocker : nil)
                ?? selectedWorkOSStateMessage.trimmingCharacters(
                    in: .whitespacesAndNewlines)
            if let singleModelDispatchID {
                failPendingSingleModelGoalDispatch(
                    dispatchID: singleModelDispatchID,
                    message:
                        "Goal 已確認，但單模型 runner 未取得執行權；派工已 fail closed。"
                        + (reason.isEmpty ? "" : "（\(reason)）"))
            }
            flashComposerHint(
                "單模型 runner 未啟動；dispatch 已標記失敗，沒有留下假執行中狀態。"
                    + (reason.isEmpty ? "" : "原因：\(reason)"))
            return false
        }
        guard settleAcceptedSingleModelGoalDispatchStart(
            dispatchID: singleModelDispatchID,
            message:
                "Goal 已確認且回合已接受，但單模型 runner 未進入 running；派工已 fail closed.")
        else {
            flashComposerHint(
                "單模型 runner 未進入 running；dispatch 已標記失敗，沒有留下假執行中狀態。")
            return false
        }
        let runnerIsVerified =
            singleModelDispatchID.map {
                isRunning
                    && activeSingleModelGoalDispatch?.dispatchID == $0
            } ?? false
        flashComposerHint(
            runnerIsVerified
                ? "目標已確認 → \(currentTurnDispatchRoute().title) 單模型執行已進入 running"
                : "目標已確認；canonical dispatch 已建立，"
                    + "正在等待單模型 runner liveness。")
        return true
    }

    /// exact 原生開發（XXL）Scenario 才有 `toolIntentBridge` executor lane。
    static func isExactNativeDevelopmentScenario(_ scenario: String) -> Bool {
        [
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID,
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLFableGrokScenarioID,
        ].contains(scenario)
    }

    /// S 合約的可派工 executor＝主導綁定本身。composer 目前路由命中主導
    /// 綁定時保留該 slug，否則回落到合約主導，讓確認鍵不會只因為 composer
    /// 停在非合約模型就 fail-closed。
    private static func singleModelLeadExecutorModelID(
        contract: TatwoWorkOSContractV1,
        preferredModelID: String
    ) -> String? {
        let normalizedPreferred =
            TatwoGatewayDispatchCatalog.normalize(preferredModelID)
        let leadModelIDs = contract.identityBindings.compactMap {
            $0.identity == .lead ? $0.modelID : nil
        }
        if leadModelIDs.contains(where: {
            TatwoGatewayDispatchCatalog.normalize($0) == normalizedPreferred
        }) {
            return preferredModelID
        }
        return leadModelIDs.first
    }

    func nativeDevelopmentLaneTask(
        modelID: String,
        objective: String
    ) -> String {
        let normalizedModelID =
            TatwoGatewayDispatchCatalog.normalize(modelID)
        let normalizedFable =
            TatwoGatewayDispatchCatalog.normalize("fable-5")
        let normalizedGrok =
            TatwoGatewayDispatchCatalog.normalize("grok-build")
        if normalizedModelID == normalizedFable {
            return """
            TATWO /plg 第一 lane：Fable 5 Medium。

            嚴格只處理 Tatwo Island：
            1. 修正黑塊在玻璃底板收合後，從反白恢復正常型態過慢。
            2. 黑塊維持在玻璃下方的真實模糊效果。
            3. 規劃並實作 Island 減碼、低耗能與順暢縮展。
            4. 不修改 Aurora、Fable5 紀念主題或 Ultrawork 漸變拉條。
            5. 完成後提交 diff、測試、視覺與資源 receipt，然後停止。

            不得執行 Grok lane，不得使用 Sol／Opus／API fallback。

            原始 Goal：
            \(objective)
            """
        }
        if normalizedModelID == normalizedGrok {
            return """
            TATWO /plg 第二 lane：Grok 4.6 High。

            Fable Island completed receipt 已存在後才執行：
            1. 隔離 Aurora 與 Fable5 紀念風格。
            2. 使用 Island 已驗證的液態玻璃重做 Aurora。
            3. 補齊 Aurora 缺失 UI 組件，最底版也要有液態效果。
            4. Fable5 紀念主題與 Ultrawork 漸變拉條零變動。
            5. 檢查整體完整度、設計一致性、CPU、記憶體與縮展效能。
            6. 完成後提交 diff、測試、視覺與資源 receipt，然後停止。

            不得回頭修改 Island 已驗收範圍，不得使用 Sol／Opus／API fallback。

            原始 Goal：
            \(objective)
            """
        }
        return objective
    }

    func failPendingNativeDevelopmentDispatchStart(
        dispatchID: String,
        message: String
    ) {
        let pending = pendingNativeDevelopmentDispatch
        let contractID =
            (pending?.id == dispatchID ? pending?.contractID : nil)
            ?? selectedWorkOSContract?.contractID
        guard let contractID,
              let durable = try? dispatchRegistry.run(
                forContractID: contractID)?.records.first(where: {
                    $0.id == dispatchID
                }),
              durable.status == .queued || durable.status == .running
        else { return }
        if pending?.id == dispatchID {
            pendingNativeDevelopmentDispatch = nil
        }
        do {
            _ = try TatwoNativeDevelopmentDispatchCoordinator.fail(
                contractID: contractID,
                dispatchID: dispatchID,
                errorCode: "native_runner_not_started",
                message: message,
                goalStore: goalRunStore,
                dispatchRegistry: dispatchRegistry)
            activeNativeDevelopmentDispatch = nil
            selectedGoalRecord =
                try goalRunStore.requireIssuedContract(
                    contractID)
            selectedDispatchRecords =
                try dispatchRegistry.latestRecordsByBinding(
                    forContractID: contractID)
            if planWorkOSLocalActionPresentation.phase == .dispatching,
               planWorkOSLocalActionPresentation.dispatchID == dispatchID,
               let artifact = activePlanArtifact
            {
                failConfirmedPlanDispatch(
                    artifact,
                    reason: message)
            }
        } catch {
            quarantineSelectedWorkOSState(
                "Native runner 啟動失敗且 ledger 無法收斂："
                    + TatwoPrivacyRedactor.redacted(
                        error.localizedDescription))
        }
    }

    @discardableResult
    func beginSelectedNativeDevelopmentDispatch(
        subtask: String,
        selectedModelID: String? = nil
    ) -> Bool {
        guard let contract = selectedWorkOSContract,
              [
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLFableGrokScenarioID,
              ].contains(contract.scenario)
        else {
            flashComposerHint("未派工：請選擇 exact 原生開發 Scenario。")
            return false
        }
        let route = currentTurnDispatchRoute()
        // 2026-08-21 HINTFIX-2：nil 預設同樣要經 resolver 映射到合約
        // lane 成員，不能拿 composer 原始 slug 直闖 coordinator。
        let executorModelID =
            selectedModelID
            ?? selectedNativeDevelopmentExecutorModelID(
                contract: contract,
                preferredModelID: route.canonicalModelSlug)
            ?? route.canonicalModelSlug
        do {
            let record =
                try TatwoNativeDevelopmentDispatchCoordinator
                    .beginSelectedExecutor(
                        contract: contract,
                        selectedModelID: executorModelID,
                        subtask: subtask,
                        goalStore: goalRunStore,
                        dispatchRegistry: dispatchRegistry,
                        scenarioBook: scenarioConfigBook)
            pendingNativeDevelopmentDispatch = record
            selectedGoalRecord =
                try goalRunStore.requireIssuedContract(
                    contract.contractID)
            selectedDispatchRecords =
                try dispatchRegistry.latestRecordsByBinding(
                    forContractID: contract.contractID)
            return true
        } catch {
            pendingNativeDevelopmentDispatch = nil
            if let refreshedGoal =
                try? goalRunStore.requireIssuedContract(
                    contract.contractID)
            {
                selectedGoalRecord = refreshedGoal
            }
            if let refreshedDispatches =
                try? dispatchRegistry.latestRecordsByBinding(
                    forContractID: contract.contractID)
            {
                selectedDispatchRecords = refreshedDispatches
            }
            // 2026-08-21：前綴用實際嘗試派工的 executor 模型，不是 composer
            // 當下選的模型（閉環驗收抓到 fable5 lane 失敗被標成「GPT-5.5」）。
            let executorTitle =
                TatwoChatRouteProfile.resolve(executorModelID).displayName
            flashComposerHint(
                "\(executorTitle) 原生派工失敗："
                    + TatwoPrivacyRedactor.redacted(
                        error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func preparePendingNativeDevelopmentDispatchIfNeeded(
        command: ChatCLICommand,
        subtask: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot
    ) -> Bool {
        guard command.runtimeAdapter == .nativeAgent,
              command.nativeDevelopmentAccess == .mutation,
              let contract = selectedWorkOSContract,
              [
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLFableGrokScenarioID,
              ].contains(contract.scenario)
        else {
            return true
        }
        guard dispatchSnapshot.phase == .loops,
              dispatchSnapshot.contractID == contract.contractID
        else {
            flashComposerHint(
                "原生派工失敗：本輪 frozen route 未綁定目前 Loops contract。")
            return false
        }
        if let pending = pendingNativeDevelopmentDispatch {
            let pendingMatches =
                pending.contractID == contract.contractID
                && pending.status == .running
                && TatwoGatewayDispatchCatalog.normalize(pending.modelID)
                    == TatwoGatewayDispatchCatalog.normalize(
                        dispatchSnapshot.canonicalModelID)
            guard pendingMatches else {
                flashComposerHint(
                    "原生派工失敗：已有不同 contract／model 的 pending dispatch。")
                return false
            }
            return true
        }
        return beginSelectedNativeDevelopmentDispatch(
            subtask: subtask,
            selectedModelID: dispatchSnapshot.canonicalModelID)
    }

    /// /蒸餾 <主題>：目前只有原型入口，不產生文件也不寫入磁碟。
    func triggerDistillFromPrompt() {
        let topic = slashObjective(prompt, strip: ["/蒸餾"])
        prompt = ""
        flashComposerHint(topic.isEmpty
            ? "／蒸餾是原型：目前尚未產生文件，也不會寫入磁碟。"
            : "／蒸餾「\(topic)」是原型：目前尚未產生文件，也不會寫入磁碟。")
    }

    /// 斜線指令比對：開頭命令，或正文最後一個非空白獨立命令行；code block/內文不觸發。
    func matchesSlash(_ text: String, _ cmd: String) -> Bool {
        TatwoSlashCommandParser.matchesCommand(in: text, commands: [cmd])
    }

    /// 從 prompt 去掉斜線指令前綴，取剩餘目標文字。
    private func slashObjective(_ raw: String, strip cmds: [String]) -> String {
        TatwoSlashCommandParser.objective(from: raw, commands: cmds)
    }

    /// 斜線指令選單資料（打「/」浮現，可點）。
    struct SlashCommandItem: Identifiable, Equatable {
        var id: String { cmd }
        let cmd: String
        let title: String
        let subtitle: String
        let icon: String
    }
    static let slashCommandItems: [SlashCommandItem] = [
        SlashCommandItem(cmd: "/plg", title: "/plg — 開始 PLG 流程",
            subtitle: "Plan 討論 → 確認 → agents 跑 loops 分工", icon: "point.3.filled.connected.trianglepath.dotted"),
        SlashCommandItem(cmd: "/plan", title: "/plan — Plan 討論",
            subtitle: "只做規劃釐清（Codex plan 樣式，可展開全文）", icon: "list.bullet.rectangle"),
        SlashCommandItem(cmd: "/goal", title: "/goal — 送出目標並分工",
            subtitle: "項目明細＋完成度（進行中%／已完成／佇列中）", icon: "target"),
        SlashCommandItem(cmd: "/issue", title: "/issue — 支線等待佇列",
            subtitle: "/issue <文字> 捕捉支線討論；/issue 打開佇列（不啟動執行）", icon: "tray.full"),
        SlashCommandItem(cmd: "/蒸餾", title: "/蒸餾 — 原型（尚不產生文件）",
            subtitle: "目前只記錄需求，不會建立或寫入文件", icon: "drop.triangle"),
    ]

    /// 依目前 prompt 前綴過濾出要顯示的斜線指令。
    var matchingSlashCommands: [SlashCommandItem] {
        guard mode == .chat else { return [] }
        let matchingIDs = Set(
            ChatComposerSlashCatalog.matches(prompt: prompt).map(\.command))
        return Self.slashCommandItems.filter { matchingIDs.contains($0.cmd) }
    }

    /// Codex composer-style：picker 只插入命令，使用者補完內容後再 Enter 執行。
    func applySlashCommandSuggestion(_ item: SlashCommandItem) {
        prompt = ChatComposerSlashCatalog.inserting(
            command: item.cmd,
            into: prompt)
    }

    func authorizePLG() {
        guard let run = activePLGRun else { return }
        guard !plgAuthorityState.isQuarantined else {
            plgError = plgAuthorityState.quarantineMessage
            return
        }
        refreshPLGProjectionThroughWorkOSChokepoint(run)
        plgError = "human_gate 必須由 Work OS/MCP 提交；App 不寫 receipt。"
        flashComposerHint("授權請交由 Work OS/MCP；App 僅更新唯讀投影。")
    }

    @available(*, deprecated, message: "Use applySlashCommandSuggestion; execution occurs on send().")
    func runSlashCommand(_ item: SlashCommandItem) {
        applySlashCommandSuggestion(item)
    }

    func evaluatePLGMainline(_ met: Bool) {
        guard !met else {
            flashComposerHint("收據 READY，等待 Work OS close/gate；App 無權直接完成 goal。")
            return
        }
        applyPLG { r in
            try TatwoPLGOrchestrator.setMainlineGoalMet(
                false, in: r, expectedRevision: r.revision, eventID: UUID())
        }
    }

    func rollbackPLG() {
        guard let run = activePLGRun else { return }
        refreshPLGProjectionThroughWorkOSChokepoint(run)
        plgError = "rollback 必須由 Work OS/MCP 執行；App 無權改寫 run。"
        flashComposerHint("回滾請交由 Work OS/MCP；App 僅顯示狀態。")
    }

    @discardableResult
    private func applyPLG(_ transition: (TatwoPLGRun) throws -> TatwoPLGTransition) -> Bool {
        guard let run = activePLGRun else { return false }
        guard case .verified(let runID, _) = plgAuthorityState,
              runID == run.id
        else {
            plgError = "PLG blocked：host-anchored replay 尚未驗證。"
            return false
        }
        do {
            let t = try transition(run)
            // Phase 5 治理：事件去重/合法性驗證（防重放/非法轉移）。
            if case .failure(let e) = TatwoPLGGovernance.validateEvent(
                t.event, appliedEventIDs: appliedPLGEventIDs, run: run) {
                plgError = "governance: \(e)"
                return false
            }
            let replay = try plgChainStore.append(
                transition: t,
                from: run)
            appliedPLGEventIDs = replay.appliedEventIDs
            activePLGRun = replay.run
            plgAuthorityState = .verified(
                runID: replay.run.id,
                headHash: replay.headHash)
            plgError = nil
            persistActivePLGProjection()
            // App 只投影 Work OS 狀態；派工與 ledger 更新必須走 OS/MCP chokepoint。
            if !plgPaused {
                refreshPLGProjectionThroughWorkOSChokepoint(replay.run)
            }
            return true
        } catch {
            plgAuthorityState = .quarantined(error.localizedDescription)
            plgError = "\(error)"
            return false
        }
    }

    /// App 唯一可做的是向 Work OS chokepoint 驗證 contract，再重讀 ledger/receipt 投影。
    /// 它不建立 dispatch、不改 dispatch 狀態，也不直接呼叫 gateway。
    private func refreshPLGProjectionThroughWorkOSChokepoint(_ run: TatwoPLGRun) {
        guard !plgAuthorityState.isQuarantined else {
            plgError = plgAuthorityState.quarantineMessage
            return
        }
        let decision = TatwoWorkOSChokepoint.authorize(
            contractID: run.contractID,
            action: "app.plg.read_projection",
            store: goalRunStore)
        guard decision.ok, !decision.bypassed else {
            plgError = "PLG projection blocked：\(decision.message)"
            return
        }
        refreshSelectedWorkOSState(contractID: run.contractID)
        plgError = nil
        flashComposerHint("已交由 Work OS/MCP；App 僅顯示 ledger 與收據。")
    }

    func restoreActivePLGProjection(from thread: TatwoNativeChatThread?) {
        guard
            let thread,
            let contractID = thread.workOSContractID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !contractID.isEmpty,
            let goalID = thread.workOSGoalID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !goalID.isEmpty
        else {
            activePLGRun = nil
            appliedPLGEventIDs = []
            plgAuthorityState = .none
            plgPaused = false
            return
        }
        let projection = thread.activePLGRunProjection.flatMap {
            $0.contractID == contractID && $0.goalID == goalID ? $0 : nil
        }
        do {
            let replay = try plgChainStore.replayUnique(
                contractID: contractID,
                goalID: goalID,
                preferredRunID: projection?.id)
            activePLGRun = replay.run
            appliedPLGEventIDs = replay.appliedEventIDs
            plgAuthorityState = .verified(
                runID: replay.run.id,
                headHash: replay.headHash)
            plgError = nil
        } catch TatwoPLGChainStoreError.missingChain where projection == nil {
            activePLGRun = nil
            appliedPLGEventIDs = []
            plgAuthorityState = .none
            plgError = nil
        } catch {
            let message = "PLG restore quarantined：缺少、歧義或無效的 host-anchored event chain（\(error.localizedDescription)）"
            activePLGRun = nil
            appliedPLGEventIDs = []
            plgAuthorityState = .quarantined(message)
            plgError = message
        }
        plgPaused = false
    }

    private func persistActivePLGProjection() {
        guard let location = selectedThreadLocation() else { return }
        var thread = thread(at: location)
        guard thread.activePLGRunProjection != activePLGRun else { return }
        thread.activePLGRunProjection = activePLGRun
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        publishDocumentChangeAndPersist()
    }

    /// #16 主 chat → loops 橋：統一進 contract-bound PLG，禁止建立第二個裸執行來源。
    ///
    /// This is a human-authorized creation surface reached only from the
    /// explicit composer menu action 「交給 Work OS Loops」. Ordinary Chat
    /// submit never calls this method and remains fail-closed when unbound.
    @discardableResult
    func createAndDispatchLoopFromPrompt() async -> UUID? {
        guard mode == .chat, selectedThread != nil else { return nil }
        let goal = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return nil }
        if isDiscussionSessionSelected {
            guard let loopID = createLoopsSessionForSelectedThread() else { return nil }
            appendHumanLoopNote(loopID, text: goal)
            prompt = ""
            requestOpenLoopsPanel = true
            flashComposerHint("已建立 Discussion 專屬 branch loop；尚未派工或改寫主線。")
            return loopID
        }
        guard await startPLGRun(
            objective: goal,
            automaticallyBootstrapUserOwnedAuthority: false)
        else { return nil }
        requestOpenLoopsPanel = true
        flashComposerHint("已交給 Work OS PLG；先完成 Plan／主導驗證，再由 Loops 身份組派工。")
        return activePLGRun?.id
    }

    func archiveLoopsSession(_ id: UUID) {
        mutateLoopsSession(id) { session in
            guard !session.isArchived else { return }
            session.archivedISO = ISO8601DateFormatter().string(from: Date())
        }
        if selectedLoopsSessionID == id { selectedLoopsSessionID = nil }
        flashComposerHint("Loops 規劃已封存；可在 Loops 工作區還原。")
    }

    func restoreLoopsSession(_ id: UUID) {
        mutateLoopsSession(id) { session in
            session.archivedISO = nil
        }
        selectedLoopsSessionID = id
        requestOpenLoopsPanel = true
        flashComposerHint("Loops 規劃已還原。")
    }

    func mutateLoopsSession(_ id: UUID, _ transform: (inout TatwoLoopsSession) -> Void) {
        if selectedDiscussion != nil {
            mutateSelectedDiscussion { discussion in
                guard let idx = discussion.loopsSessions.firstIndex(where: { $0.id == id }) else { return }
                transform(&discussion.loopsSessions[idx])
            }
        } else {
            mutateSelectedThread { thread in
                guard let idx = thread.loopsSessions.firstIndex(where: { $0.id == id }) else { return }
                transform(&thread.loopsSessions[idx])
                thread.updatedAt = Date()
            }
        }
    }

    /// User-authored planning notes have one fixed provenance contract.
    func appendHumanLoopNote(_ id: UUID, text: String) {
        appendLoopMessage(id, role: "human", authorModelID: nil, text: text)
    }

    private func appendLoopMessage(
        _ id: UUID,
        role: String,
        authorModelID: String?,
        text: String
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateLoopsSession(id) { s in
            s.messages.append(TatwoLoopsMessage(
                id: UUID(), role: role, authorModelID: authorModelID,
                text: trimmed, createdISO: ISO8601DateFormatter().string(from: Date())))
            // Loops messages are planning conversation only. A local message must
            // never promote the session to running without a runtime dispatch
            // record from the canonical Work OS ledger.
        }
    }

    /// #16 P4 開新一輪 cycle。
    func advanceLoopRound(_ id: UUID) {
        mutateLoopsSession(id) { s in
            // A planning round is a local planning artifact, not execution.
            // Keep runtime status unchanged until a contract-bound dispatch
            // record proves that Work OS actually accepted the work.
            s = TatwoLoopsDispatchPlanner.advanceRound(s)
        }
    }

    /// 舊 Loops session 的派工入口也必須回到同一個 contract-bound PLG。
    func dispatchLoopSub(_ id: UUID) {
        guard dispatchingLoopID == nil,
              let session = selectedThreadLoopsSessions.first(where: { $0.id == id })
        else { return }
        guard !isDiscussionSessionSelected else {
            appendLoopMessage(
                id,
                role: "system",
                authorModelID: nil,
                text: "Branch-local loop 已保留；未經明確 merge receipt，不會派工或改寫主線 Work OS。")
            flashComposerHint("Discussion loop 已 fail-closed：先收據 merge，主線才可派工。")
            return
        }
        guard !isRunning,
              pendingNativeDevelopmentDispatch == nil,
              pendingSingleModelGoalDispatch == nil,
              activeNativeDevelopmentDispatch == nil
        else {
            requestOpenLoopsPanel = true
            flashComposerHint(
                "Work OS 已有執行中的 dispatch；已保留目前 runner，沒有重複派工。")
            return
        }
        guard let thread = selectedThread else { return }
        let threadID = thread.id
        let planSlice = TatwoLoopsDispatchPlanner.dispatchObjective(
            session: session,
            fallbackObjective:
                selectedWorkOSContract?.objective
                    ?? selectedThreadWorkOSContext(thread: thread).objective)
        dispatchingLoopID = id
        requestOpenLoopsPanel = true
        flashComposerHint("正在送交 Work OS…")

        // Publish the pending state before contract replay / ledger validation.
        // The next MainActor turn revalidates the exact thread + loop identity,
        // so a session switch cannot dispatch stale work.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.performLoopSubDispatch(
                id,
                threadID: threadID,
                planSlice: planSlice)
        }
    }

    private func performLoopSubDispatch(
        _ id: UUID,
        threadID: UUID,
        planSlice: String
    ) {
        defer {
            if dispatchingLoopID == id {
                dispatchingLoopID = nil
            }
        }
        guard dispatchingLoopID == id,
              selectedThreadID == threadID,
              !isDiscussionSessionSelected,
              selectedThreadLoopsSessions.contains(where: { $0.id == id }),
              let thread = selectedThread,
              thread.id == threadID
        else {
            flashComposerHint(
                "Loops 派工已取消：thread／session 已切換，沒有送出 stale work。")
            return
        }
        restoreActivePLGProjection(from: thread)
        guard thread.workOSContractID?.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty == false,
              thread.workOSGoalID?.trimmingCharacters(
                  in: .whitespacesAndNewlines).isEmpty == false,
              ensureSelectedThreadWorkOSContract(
                allowCreateIfUnbound: false)
        else {
            flashComposerHint("Loops 派工受阻：canonical Work OS contract／GoalRun 無法驗證。")
            return
        }
        guard let refreshedThread = selectedThread else { return }
        guard let contract = selectedWorkOSContract,
              let goalRecord = selectedGoalRecord,
              goalRecord.contractID == contract.contractID,
              goalRecord.goalID == contract.goalID,
              refreshedThread.workOSContractID == contract.contractID,
              refreshedThread.workOSGoalID == contract.goalID
        else {
            flashComposerHint("Loops 派工受阻：找不到此 thread 已綁定的 active Work OS contract。")
            return
        }
        let started: Bool
        if let run = activePLGRun {
            started =
                run.contractID == contract.contractID
                && run.goalID == contract.goalID
        } else {
            // The Loop session can refine the plan slice, but it must never mint
            // a second Goal whose objective is the subtask text.
            started = startPLGProjectionForActiveContract(
                contract,
                goalRecord: goalRecord)
        }
        guard started,
              activePLGRun?.contractID == contract.contractID,
              activePLGRun?.goalID == contract.goalID
        else {
            flashComposerHint("Loops 派工受阻：無法在原 active Goal 上建立 plan slice。")
            return
        }
        guard confirmPLGPlanAndStartLoops(
            nativeTaskOverride: planSlice,
            restoreProjection: false)
        else {
            return
        }
        appendLoopMessage(
            id,
            role: "system",
            authorModelID: nil,
            text: "Work OS 已接受此 Plan slice；runner 已進入 running。")
        requestOpenLoopsPanel = true
        flashComposerHint(
            "已送交 Work OS：沿用原 active Goal，正式 dispatch 與 runner 已啟動。")
    }

    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 以 login shell 跑命令並回收 stdout（解析使用者 PATH/env）；逾時回 nil。
    nonisolated private static func runLoginShellCapture(command: String, timeout: TimeInterval) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        let handle = stdout.fileHandleForReading
        var data = Data()
        while process.isRunning && Date() < deadline {
            data.append(handle.availableData)
            usleep(120_000)
        }
        if process.isRunning { process.terminate() }
        data.append(handle.readDataToEndOfFile())
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    func recoverPendingBrowserLifecycleIntent(
        for threadID: UUID?
    ) async {
        guard let threadID,
              let profile = EmbeddedBrowserSessionPersistenceContract.profile(
                for: threadID.uuidString.lowercased()),
              let identifier = profile.dataStoreIdentifier
        else { return }
        do {
            let intent = try await Task.detached(priority: .utility) {
                try EmbeddedBrowserLifecycleIntentStore.live.pendingIntent(
                    profileIdentifier: identifier)
            }.value
            guard selectedThreadID == threadID, let intent else { return }
            flashComposerHint(
                "Browser lifecycle recovery required: intent \(intent.intentID.uuidString.lowercased()) is \(intent.stage.rawValue). This session remains fail-closed until the formal mutation commits or safely retries.")
        } catch {
            guard selectedThreadID == threadID else { return }
            flashComposerHint(
                "Browser lifecycle recovery check failed closed: \(error)")
        }
    }

    func archiveSelectedThread() {
        guard let location = selectedThreadLocation() else { return }
        let thread = thread(at: location)
        let projectID = boundProjectID(for: location)
        let ref = thread.id.uuidString
        let queued = issueListStore.countQueued(threadReference: ref)
        if queued > 0 {
            pendingArchiveIssuePrompt = (ref, thread.id, projectID, thread.title, queued)
            return
        }
        Task { @MainActor in
            await performArchiveSelectedThread(
                threadID: thread.id,
                projectID: projectID,
                archiveIssues: false)
        }
    }

    func resolveArchiveIssuePrompt(keepIssues: Bool) {
        guard let pending = pendingArchiveIssuePrompt else { return }
        pendingArchiveIssuePrompt = nil
        Task { @MainActor in
            await performArchiveSelectedThread(
                threadID: pending.threadID,
                projectID: pending.projectID,
                archiveIssues: !keepIssues)
        }
    }

    private func performArchiveSelectedThread(
        threadID: UUID,
        projectID: UUID?,
        archiveIssues: Bool
    ) async {
        guard selectedThreadID == threadID,
              let initialLocation = selectedThreadLocation(),
              thread(at: initialLocation).id == threadID,
              boundProjectID(for: initialLocation) == projectID
        else {
            flashComposerHint("無法封存：選取位置已變更，原 Thread 已保留。")
            return
        }

        let transaction = EmbeddedBrowserSessionLifecycleTransaction(
            disposition: .archive,
            sessionID: threadID.uuidString.lowercased())
        let prepared = await transaction.prepare()
        guard case let .success(receipt) = prepared else {
            if case let .failure(error) = prepared {
                flashComposerHint(
                    "無法封存：browser lifecycle 準備失敗，原 Thread 已保留。\(error)")
            }
            return
        }

        guard selectedThreadID == threadID,
              let commitLocation = selectedThreadLocation(),
              thread(at: commitLocation).id == threadID,
              boundProjectID(for: commitLocation) == projectID
        else {
            flashComposerHint(
                "無法封存：等待 browser lifecycle 時選取位置已變更；recoverable intent \(receipt.intentID.uuidString.lowercased()) 已保留。")
            return
        }

        do {
            _ = try remoteBorrowAuthorizationStore.revokeSession(
                sessionID: threadID.uuidString.lowercased())
        } catch {
            flashComposerHint(
                "無法封存：遠端借用授權撤銷失敗，原 Thread 與 recoverable browser intent 已保留。\(error.localizedDescription)")
            return
        }

        let committed = transaction.commit(
            receipt: receipt,
            finalMutation: EmbeddedBrowserFinalMutationContract(
                idempotencyKey:
                    "archive-thread:\(threadID.uuidString.lowercased()):"
                    + receipt.intentID.uuidString.lowercased(),
                alreadyApplied: { _ in
                    guard let location =
                            self.browserLifecycleThreadLocation(
                                threadID: threadID,
                                projectID: projectID)
                    else {
                        throw ChatBrowserLifecycleMutationError.threadMissing
                    }
                    return self.thread(at: location).isArchived
                },
                apply: { _ in
                    guard self.selectedThreadID == threadID,
                          let finalLocation =
                            self.browserLifecycleThreadLocation(
                                threadID: threadID,
                                projectID: projectID),
                          self.thread(at: finalLocation).id == threadID,
                          self.boundProjectID(for: finalLocation) == projectID
                    else {
                        throw ChatBrowserLifecycleMutationError.selectionChanged
                    }
                    let documentBeforeMutation = self.document
                    self.preserveCurrentMessages()
                    var archived = self.thread(at: finalLocation)
                    archived.isArchived = true
                    archived.isPinned = false
                    archived.lastPreview = "Archived"
                    archived.updatedAt = Date()
                    self.replaceThread(archived, at: finalLocation)
                    guard self.persistStore() else {
                        self.document = documentBeforeMutation
                        throw ChatBrowserLifecycleMutationError
                            .persistenceFailed
                    }
                    if archiveIssues {
                        self.issueListStore.archiveIssues(
                            threadReference: threadID.uuidString)
                        self.reloadIssueList()
                    }
                }))
        guard case .success = committed else {
            if case let .failure(error) = committed {
                flashComposerHint(
                    "無法封存：final mutation 未提交，原 Thread 與 recoverable browser intent 已保留。\(error)")
            }
            return
        }

        selectFallbackAfterArchivedThread(projectID: projectID)
    }

    func performFormalBrowserResetOrDelete(
        disposition: EmbeddedBrowserSessionDisposition,
        threadID: UUID,
        finalMutation: EmbeddedBrowserFinalMutationContract?
    ) async -> Result<
        EmbeddedBrowserSessionLifecycleReceipt,
        EmbeddedBrowserSessionLifecycleError
    > {
        guard disposition == .reset || disposition == .delete,
              let finalMutation
        else {
            return .failure(.unsupportedFormalMutation(
                disposition: disposition))
        }
        let transaction = EmbeddedBrowserSessionLifecycleTransaction(
            disposition: disposition,
            sessionID: threadID.uuidString.lowercased())
        let prepared = await transaction.prepare()
        guard case let .success(receipt) = prepared else { return prepared }
        return transaction.commit(
            receipt: receipt,
            finalMutation: finalMutation)
    }

    func performBrowserManagementAction(
        _ action: TatwoBrowserManagementAction,
        session: TatwoBrowserManagementSession
    ) async -> String {
        switch action {
        case .clearCurrentSite:
            guard let originURL = session.currentOriginURL else {
                return "此 Session 尚無可安全辨識的目前網站，未清除任何資料。"
            }
            let result = await EmbeddedBrowserSiteDataMaintenanceCoordinator()
                .clear(
                    originURL: originURL,
                    sessionID: session.id.uuidString.lowercased(),
                    engine: EmbeddedBrowserEnginePolicy.current)
            switch result {
            case let .success(outcome):
                return outcome.visibleMessage
            case let .failure(error):
                return error.visibleMessage
            }

        case .reset:
            let transaction = EmbeddedBrowserSessionLifecycleTransaction(
                disposition: .reset,
                sessionID: session.id.uuidString.lowercased())
            switch await transaction.prepare() {
            case let .success(receipt):
                switch transaction.commitProfileOnly(receipt: receipt) {
                case .success:
                    return "此 Session 的瀏覽資料已重設。"
                case let .failure(error):
                    return error.visibleMessage
                }
            case let .failure(error):
                return error.visibleMessage
            }

        case .delete:
            let transaction = EmbeddedBrowserSessionLifecycleTransaction(
                disposition: .delete,
                sessionID: session.id.uuidString.lowercased())
            switch await transaction.prepare() {
            case let .success(receipt):
                switch transaction.commitDeletedProfile(receipt: receipt) {
                case .success:
                    return "瀏覽器 Session 資料已刪除；Chat 對話未刪除。"
                case let .failure(error):
                    return error.visibleMessage
                }
            case let .failure(error):
                return error.visibleMessage
            }

        case .archive:
            guard let target = browserManagementThreadTarget(
                threadID: session.id)
            else {
                return "找不到對應 Chat Session，瀏覽器資料與對話均未變更。"
            }
            let transaction = EmbeddedBrowserSessionLifecycleTransaction(
                disposition: .archive,
                sessionID: session.id.uuidString.lowercased())
            switch await transaction.prepare() {
            case let .failure(error):
                return error.visibleMessage
            case let .success(receipt):
                let documentBeforeMutation = document
                let committed = transaction.commit(
                    receipt: receipt,
                    finalMutation: EmbeddedBrowserFinalMutationContract(
                        idempotencyKey:
                            "browser-management-archive:"
                            + session.id.uuidString.lowercased()
                            + ":\(receipt.intentID.uuidString.lowercased())",
                        alreadyApplied: { _ in
                            guard let current =
                                    self.browserManagementThreadTarget(
                                        threadID: session.id)
                            else {
                                throw ChatBrowserLifecycleMutationError
                                    .threadMissing
                            }
                            return self.thread(at: current.location).isArchived
                        },
                        apply: { _ in
                            guard let current =
                                    self.browserManagementThreadTarget(
                                        threadID: session.id)
                            else {
                                throw ChatBrowserLifecycleMutationError
                                    .threadMissing
                            }
                            var archived = self.thread(at: current.location)
                            archived.isArchived = true
                            archived.isPinned = false
                            archived.updatedAt = Date()
                            self.replaceThread(
                                archived,
                                at: current.location)
                            guard self.persistStore() else {
                                self.document = documentBeforeMutation
                                throw ChatBrowserLifecycleMutationError
                                    .persistenceFailed
                            }
                        }))
                switch committed {
                case .success:
                    if selectedThreadID == session.id {
                        selectFallbackAfterArchivedThread(
                            projectID: target.projectID)
                    }
                    return "Chat Session 已封存；瀏覽器資料保留，可從封存區還原。"
                case let .failure(error):
                    return error.visibleMessage
                }
            }
        }
    }

    private func browserManagementThreadTarget(
        threadID: UUID
    ) -> (location: ThreadLocation, projectID: UUID?)? {
        if let index = document.threads.firstIndex(where: {
            $0.id == threadID
        }) {
            return (.standalone(index), nil)
        }
        for projectIndex in document.projects.indices {
            if let threadIndex = document.projects[projectIndex].threads
                .firstIndex(where: { $0.id == threadID })
            {
                return (
                    .project(
                        projectIndex: projectIndex,
                        threadIndex: threadIndex),
                    document.projects[projectIndex].id)
            }
        }
        return nil
    }

    private func browserLifecycleThreadLocation(
        threadID: UUID,
        projectID: UUID?
    ) -> ThreadLocation? {
        if let projectID {
            guard let projectIndex = document.projects.firstIndex(where: {
                $0.id == projectID
            }),
                  let threadIndex = document.projects[projectIndex].threads
                    .firstIndex(where: { $0.id == threadID })
            else {
                return nil
            }
            return .project(
                projectIndex: projectIndex,
                threadIndex: threadIndex)
        }
        guard let threadIndex = document.threads.firstIndex(where: {
            $0.id == threadID
        }) else {
            return nil
        }
        return .standalone(threadIndex)
    }

    private func boundProjectID(for location: ThreadLocation) -> UUID? {
        switch location {
        case .standalone:
            return nil
        case let .project(projectIndex, _):
            guard document.projects.indices.contains(projectIndex) else {
                return nil
            }
            return document.projects[projectIndex].id
        }
    }

    private func selectFallbackAfterArchivedThread(projectID: UUID?) {
        if let projectID,
           let project = document.projects.first(where: { $0.id == projectID }),
           let next = project.threads.first(where: { !$0.isArchived })
        {
            select(projectID: projectID, threadID: next.id)
            return
        }
        if let next = document.threads.first(where: { !$0.isArchived }) {
            selectStandaloneThread(next.id)
            return
        }
        if let fallbackProject = document.projects.first(where: { project in
            project.threads.contains(where: { !$0.isArchived })
        }), let fallbackThread = fallbackProject.threads.first(where: {
            !$0.isArchived
        }) {
            select(projectID: fallbackProject.id, threadID: fallbackThread.id)
            return
        }
        selectedThreadID = nil
        selectedDiscussionID = nil
        messages = []
        activeAssistantID = nil
        selectedWorkOSContract = nil
        selectedGoalRecord = nil
        selectedDispatchRecords = []
        selectedWorkOSStateMessage = "目前沒有未封存 thread"
    }

    func restoreMostRecentArchivedThread() {
        preserveCurrentMessages()
        let standaloneCandidates = document.threads.indices.compactMap { threadIndex -> (location: ThreadLocation, updatedAt: Date)? in
            let thread = document.threads[threadIndex]
            return thread.isArchived ? (.standalone(threadIndex), thread.updatedAt) : nil
        }
        let projectCandidates = document.projects.indices.flatMap { projectIndex in
            document.projects[projectIndex].threads.indices.compactMap { threadIndex -> (projectIndex: Int, threadIndex: Int, updatedAt: Date)? in
                let thread = document.projects[projectIndex].threads[threadIndex]
                return thread.isArchived ? (projectIndex, threadIndex, thread.updatedAt) : nil
            }
            .map { item -> (location: ThreadLocation, updatedAt: Date) in
                (.project(projectIndex: item.projectIndex, threadIndex: item.threadIndex), item.updatedAt)
            }
        }
        guard let target = (standaloneCandidates + projectCandidates).max(by: { $0.updatedAt < $1.updatedAt }) else { return }
        var restored = thread(at: target.location)
        restored.isArchived = false
        if restored.lastPreview == "Archived" {
            restored.lastPreview = ""
        }
        restored.updatedAt = Date()
        replaceThread(restored, at: target.location)
        let restoredThreadID = restored.id
        var restoredProjectID: UUID?
        if case .project(let projectIndex, _) = target.location {
            document.projects[projectIndex].isExpanded = true
            restoredProjectID = document.projects[projectIndex].id
        }
        persistStore()
        if let restoredProjectID {
            select(projectID: restoredProjectID, threadID: restoredThreadID)
        } else {
            selectStandaloneThread(restoredThreadID)
        }
    }
}
