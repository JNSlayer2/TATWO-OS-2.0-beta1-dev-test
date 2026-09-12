// 2.0 真水電：把 Claude 常駐 sidecar 的事件，收斂成 1.0 畫面看得懂的 ChatMessage 列。
// 一條討論串一個 sidecar；sidecar 活著就不重開；關 App 再開用 sessionID 續接。
import AppKit
import Foundation

@MainActor
protocol LiveEngineAPI: AnyObject {
    var store: ChatLiveStore { get }
    var doc: LiveDocumentRecord { get }
    var document: TatwoNativeChatStoreDocument { get }
    var onChange: (() -> Void)? { get set }
    var permissionDecider: ((_ tool: String, _ inputPretty: String) -> Bool)? { get set }
    var pendingPermissionThreadIDs: Set<UUID> { get }
    var autoApprove: Bool { get set }
    var onHint: ((String) -> Void)? { get set }
    var onRoomArchived: ((UUID) -> Void)? { get set }
    var dispatchPaused: Bool { get set }

    func transcript(for threadID: UUID?) -> [ChatMessage]
    func isRunning(_ threadID: UUID?) -> Bool
    func activityDate(_ threadID: UUID) -> Date
    func threadRecord(_ threadID: UUID?) -> LiveThreadRecord?
    func projectRecord(_ projectID: UUID?) -> LiveProjectRecord?
    var archivedThreadCount: Int { get }
    func appendSystemMessage(threadID: UUID, text: String, status: String)
    func setEnabledMCP(_ pluginID: String, enabled: Bool, engine: PluginsSource.MCPEngine)
    func newThread(in projectID: UUID?, title: String) -> UUID
    func newProject(name: String, workdir: String) -> UUID
    func select(_ threadID: UUID)
    func setExpanded(_ projectID: UUID, _ expanded: Bool)
    func togglePinned(_ threadID: UUID)
    func rename(_ threadID: UUID, _ title: String)
    func archive(_ threadID: UUID) -> UUID?
    func restoreMostRecentArchivedThread() -> UUID?
    func duplicate(_ threadID: UUID, asBranch: Bool) -> UUID?
    func createDiscussion(parentThreadID: UUID) -> UUID?
    func compressDiscussion(_ discussionID: UUID) -> UUID?
    func mergeDiscussionIntoParent(_ discussionID: UUID) -> UUID?
    func setGitHubRepos(_ repos: [String], for projectID: UUID)
    func issues(threadID: UUID?, global: Bool) -> [TatwoIssueListEntryV1]
    func captureIssue(threadID: UUID)
    func addIssue(threadID: UUID, title: String, body: String)
    func updateIssue(_ id: String, _ body: (inout TatwoIssueListEntryV1) -> Void)
    func removeIssue(_ id: String)
    func gitSummary(for threadID: UUID?, completion: @escaping (ChatLiveEngine.GitSummary) -> Void)
    @discardableResult func send(
        threadID: UUID,
        text: String,
        model: String?,
        engine: ClaudeSidecar.Kind,
        systemPrompt: String?,
        attachments: [String],
        reasoningEffort: String?,
        serviceTier: String?
    ) -> Bool
    func stop(threadID: UUID)
    func shutdownAll()
    func configureRoom(
        threadID: UUID,
        parentThreadID: UUID,
        roomBrief: String,
        engine: String,
        cwdOverride: String,
        deviceID: String?
    )
    func sidecarProcessID(threadID: UUID) -> Int32?
}

extension LiveEngineAPI {
    @discardableResult func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind,
              systemPrompt: String?, attachments: [String]) -> Bool {
        return send(threadID: threadID, text: text, model: model, engine: engine,
             systemPrompt: systemPrompt, attachments: attachments, reasoningEffort: nil, serviceTier: nil)
    }
    var pendingPermissionThreadIDs: Set<UUID> { [] }
    func appendSystemMessage(threadID: UUID, text: String) {
        appendSystemMessage(threadID: threadID, text: text, status: "info|監工")
    }

    func newThread(in projectID: UUID?) -> UUID {
        newThread(in: projectID, title: "新聊天")
    }

    @discardableResult func send(
        threadID: UUID,
        text: String,
        model: String?,
        engine: ClaudeSidecar.Kind
    ) -> Bool {
        return send(
            threadID: threadID,
            text: text,
            model: model,
            engine: engine,
            systemPrompt: nil,
            attachments: [])
    }

    @discardableResult func send(
        threadID: UUID,
        text: String,
        model: String?,
        engine: ClaudeSidecar.Kind,
        systemPrompt: String?
    ) -> Bool {
        return send(
            threadID: threadID,
            text: text,
            model: model,
            engine: engine,
            systemPrompt: systemPrompt,
            attachments: [])
    }
}

@MainActor
final class ChatLiveEngine: LiveEngineAPI {
    let store: ChatLiveStore
    private let environment: [String: String]
    private(set) var doc: LiveDocumentRecord
    private var messages: [UUID: [ChatMessage]] = [:]
    private var sidecars: [UUID: ClaudeSidecar] = [:]
    private var sidecarPermissionModes: [UUID: String] = [:]
    /// 遠端 handle 登記（session-only、本 engine 專屬；隨 engine 釋放）
    let remoteHandles = RemoteSessionHandles()
    private var streamingRowID: [UUID: String] = [:]
    /// 引擎自己回報的模型（sdk init 的 model／assistant message 的 model）；回覆列的 modelID 只從這裡來，不拿使用者選的冒充。
    private var attestedModel: [UUID: String] = [:]
    private var turnID: [UUID: String] = [:]
    private var artifactClaims: [UUID: [String]] = [:]
    private var artifactClaimsTruncated: Set<UUID> = []
    private var indexedArtifactTurn: [UUID: String] = [:]
    lazy var turnArtifacts = TurnArtifacts(root: store.url.deletingLastPathComponent())
    /// One-shot terminal observers, installed before send; no polling or selected-thread dependency.
    var onTurnComplete: [UUID: (Bool, String) -> Void] = [:]
    private func notifyTurnComplete(_ threadID: UUID, succeeded: Bool) {
        guard let callback = onTurnComplete.removeValue(forKey: threadID) else { return }
        let reply = (messages[threadID] ?? []).last {
            $0.turnID == turnID[threadID] && $0.role == .assistant && $0.eventKind == .message
        }?.text ?? ""
        callback(succeeded, reply)
    }
    private var runningThreads: Set<UUID> = []
    private var stoppingThreads: Set<UUID> = []
    private struct PendingSteer {
        let requestID: String
        let targetTurnID: String
        let completion: (Bool, String?) -> Void
    }
    private var pendingSteers: [UUID: PendingSteer] = [:]
    private var currentNativeGoals: Set<UUID> = []
    private var nativeGoalErrors: [UUID: String] = [:]
    private var pendingGoalControls: [UUID: (id: String, completion: (Bool, String?) -> Void)] = [:]
    private(set) var pendingPermissionThreadIDs: Set<UUID> = []
    private var pendingPermissionDepth: [UUID: Int] = [:]

    /// Scope covers both the modal decision and sending its response, including reentrant prompts.
    func withPendingPermission<T>(_ threadID: UUID, _ body: () throws -> T) rethrows -> T {
        pendingPermissionDepth[threadID, default: 0] += 1
        pendingPermissionThreadIDs.insert(threadID)
        onChange?()
        defer {
            let remaining = (pendingPermissionDepth[threadID] ?? 1) - 1
            if remaining == 0 {
                pendingPermissionDepth[threadID] = nil
                pendingPermissionThreadIDs.remove(threadID)
            } else { pendingPermissionDepth[threadID] = remaining }
            onChange?()
        }
        return try body()
    }

    /// 每次資料變動都叫一次，讓 ChatPageModel 重新發佈 document / transcript。
    var onChange: (() -> Void)?
    var onPlanChange: ((TatwoPlanArtifactV1) -> Void)?
    /// 權限詢問：回 true 允許。預設「代我核准」→ 直接允許；其他 → 跳 AppKit 確認框。
    var permissionDecider: ((_ tool: String, _ inputPretty: String) -> Bool)?
    /// 代我核准：Codex 以 acceptEdits 起 sidecar（MCP 工具直接放行，其餘詢問由 permissionDecider 自動允許）
    var autoApprove = false
    var userPermissionPreset: TatwoPermissionPreset?
    var onHint: ((String) -> Void)?
    var onRoomArchived: ((UUID) -> Void)?
    /// E2 監工：機器壓力過高時設 true，`DispatchEngine.dispatch` 應拒絕新派工（回 `dispatch_paused_pressure`）。
    var dispatchPaused = false
    private var watchdog: DispatchWatchdog?

    init(
        store: ChatLiveStore,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.store = store
        self.environment = environment
        var d = store.load()
        d.prepareChatHierarchy()
        if d.threads.isEmpty {
            let t = LiveThreadRecord(projectID: d.projects.first?.id, title: "新聊天")
            d.threads = [t]; d.selectedThreadID = t.id
        }
        if d.selectedThreadID == nil { d.selectedThreadID = d.threads.first?.id }
        for i in d.threads.indices {
            for j in d.threads[i].messages.indices where d.threads[i].messages[j].status?.hasPrefix("steering|") == true {
                d.threads[i].messages[j].status = "steer_unknown|插話送達狀態待確認"
            }
        }
        self.doc = d
        for t in d.threads { messages[t.id] = t.messages.map(\.chatMessage) }
        watchdog = DispatchWatchdog.attach(to: self)
    }

    // MARK: - 讀

    var document: TatwoNativeChatStoreDocument {
        TatwoNativeChatStoreDocument(projects: doc.projects.map { p in
            TatwoNativeChatProject(
                id: p.id, name: p.name, workdir: p.workdir, isExpanded: p.isExpanded,
                threads: doc.threads.filter { $0.projectID == p.id && !$0.isArchived }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .map { t in
                        TatwoNativeChatThread(id: t.id, title: t.title, isPinned: t.isPinned,
                                              lastPreview: t.messages.last(where: { $0.eventKind == "message" })?.text ?? "",
                                              parentThreadID: t.parentThreadID,
                                              liveness: ThreadLiveness.from(status: t.subStatus, lastOutputAt: t.lastOutputAt),
                                              lastOutputAt: t.lastOutputAt, engineLabel: t.engine)
                    },
                githubRepos: p.githubRepos.map { TatwoGitHubRepoBinding(url: $0) })
        }, generalProjectID: doc.generalProjectID)
    }

    func transcript(for threadID: UUID?) -> [ChatMessage] {
        guard let threadID else { return [] }
        return messages[threadID] ?? []
    }

    func isRunning(_ threadID: UUID?) -> Bool { threadID.map { runningThreads.contains($0) } ?? false }
    func acceptsBrowserAgentRequests(_ threadID: UUID) -> Bool {
        runningThreads.contains(threadID) && !stoppingThreads.contains(threadID)
    }
    func activityDate(_ threadID: UUID) -> Date { doc.threads.first { $0.id == threadID }?.updatedAt ?? .distantPast }
    func threadRecord(_ threadID: UUID?) -> LiveThreadRecord? {
        guard let threadID else { return nil }
        return doc.threads.first { $0.id == threadID }
    }

    func projectRecord(_ projectID: UUID?) -> LiveProjectRecord? {
        guard let projectID else { return nil }
        return doc.projects.first { $0.id == projectID }
    }

    var archivedThreadCount: Int {
        doc.threads.filter(\.isArchived).count
    }

    /// E2 監工：在指定討論串貼一則 system 訊息（活性/機器壓力警報用）。
    func appendSystemMessage(threadID: UUID, text: String, status: String = "info|監工") {
        appendSystem(threadID, text, status: status)
    }

    /// Completion belongs to its original local thread, not the selected turn.
    /// Reuse the transcript as the durable receipt; no notification database.
    func appendBackgroundCompletion(_ job: BackgroundJobManager.Record) {
        guard job.state != "running", threadRecord(job.threadID) != nil else { return }
        let id = "background:\(job.jobID.uuidString)"
        let legacyText = "背景工作「\(job.title)」結束，exit=\(job.exitCode.map(String.init) ?? "unknown")，log：\(job.logPath)"
        guard !(messages[job.threadID] ?? []).contains(where: {
            $0.id == id || ($0.role == .system && $0.status == "info|背景工作" && $0.text == legacyText)
        }) else { return }
        let text = job.state == "unknown"
            ? "背景工作「\(job.title)」已無法確認執行狀態，log：\(job.logPath)"
            : legacyText
        append(job.threadID, ChatMessage(id: id, role: .system, text: text, status: job.completionStatus))
        persist()
    }

    /// E2 監工：直接改子討論串的 subStatus（例如卡死自動停止時標成 "stalled"）。
    func markSubStatus(_ threadID: UUID, _ status: String) {
        guard let i = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        doc.threads[i].subStatus = status
        persist()
    }

    func setEnabledMCP(_ pluginID: String, enabled: Bool, engine: PluginsSource.MCPEngine) {
        guard let threadID = doc.selectedThreadID,
              let index = doc.threads.firstIndex(where: { $0.id == threadID }),
              PluginsSource.mcpEngine(from: pluginID) == engine,
              let name = PluginsSource.mcpName(from: pluginID)
        else { return }
        var names = PluginsSource.effectiveEnabledNames(
            stored: doc.threads[index].enabledMCP,
            engine: engine,
            environment: environment)
        if enabled {
            if !names.contains(name) { names.append(name) }
        } else {
            names.removeAll { $0 == name }
        }
        doc.threads[index].enabledMCP = PluginsSource.storedSelection(
            names: names,
            engine: engine,
            environment: environment)
        if !runningThreads.contains(threadID), let sidecar = sidecars.removeValue(forKey: threadID) {
            sidecar.onEvent = nil
            sidecar.close()
        }
        persist()
    }

    // MARK: - 討論串／專案

    @discardableResult
    func newThread(in projectID: UUID?, title: String = "新聊天") -> UUID {
        let destination = projectID ?? doc.ensureGeneralProject()
        let t = LiveThreadRecord(projectID: destination, title: title)
        doc.threads.insert(t, at: 0); messages[t.id] = []; doc.selectedThreadID = t.id
        persist(); return t.id
    }

    func newProject(name: String, workdir: String) -> UUID {
        let p = LiveProjectRecord(name: name, workdir: workdir)
        doc.projects.append(p); persist(); return p.id
    }

    @discardableResult
    func importTransferredThread(
        projectName: String?,
        title: String,
        messages transferredMessages: [RemoteThreadTransferMessage],
        files: [RemoteThreadTransferFile]
    ) throws -> UUID {
        let requestedProjectName = projectName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let projectID: UUID
        if let requestedProjectName,
           !requestedProjectName.isEmpty,
           let matched = doc.projects.first(where: {
               $0.name.caseInsensitiveCompare(requestedProjectName) == .orderedSame
           }) {
            projectID = matched.id
        } else if let general = doc.projects.first(where: {
            $0.name.caseInsensitiveCompare("一般") == .orderedSame
        }) {
            projectID = general.id
        } else {
            projectID = newProject(name: "一般", workdir: NSHomeDirectory())
        }
        guard let project = projectRecord(projectID) else {
            throw RemoteHostLinkError.invalidResponse
        }

        try RemoteThreadTransfer.write(files, to: project.workdir)
        let rows = transferredMessages.map(\.chatMessage)
        let thread = LiveThreadRecord(
            projectID: projectID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "新聊天"
                : String(title.prefix(120)),
            messages: rows.map(LiveMessageRecord.init))
        doc.threads.insert(thread, at: 0)
        messages[thread.id] = rows
        doc.selectedThreadID = thread.id
        persist()
        return thread.id
    }

    func select(_ threadID: UUID) { doc.selectedThreadID = threadID; persist() }
    func setModelPreferences(threadID: UUID, model: String, effort: String, speedTier: String) {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        guard doc.threads[index].requestedModel != model
                || doc.threads[index].requestedEffort != effort
                || doc.threads[index].requestedSpeedTier != speedTier else { return }
        doc.threads[index].requestedModel = model
        doc.threads[index].requestedEffort = effort
        doc.threads[index].requestedSpeedTier = speedTier
        persist()
    }
    func setExpanded(_ projectID: UUID, _ expanded: Bool) {
        if let i = doc.projects.firstIndex(where: { $0.id == projectID }) { doc.projects[i].isExpanded = expanded; persist() }
    }
    func togglePinned(_ threadID: UUID) {
        if let i = doc.threads.firstIndex(where: { $0.id == threadID }) { doc.threads[i].isPinned.toggle(); persist() }
    }
    func rename(_ threadID: UUID, _ title: String) {
        if let i = doc.threads.firstIndex(where: { $0.id == threadID }) { doc.threads[i].title = title; persist() }
    }

    @discardableResult
    func archive(_ threadID: UUID) -> UUID? {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }) else { return doc.selectedThreadID }
        if doc.threads[index].cwdOverride != nil, isRunning(threadID) { stop(threadID: threadID) }
        let projectID = doc.threads[index].projectID
        doc.threads[index].isArchived = true
        doc.threads[index].isPinned = false
        doc.threads[index].updatedAt = Date()
        let archivedRoomID = doc.threads[index].cwdOverride == nil ? nil : threadID
        if doc.selectedThreadID == threadID {
            doc.selectedThreadID = doc.threads
                .filter { $0.projectID == projectID && !$0.isArchived }
                .max(by: { $0.updatedAt < $1.updatedAt })?
                .id
        }
        persist()
        if let archivedRoomID { onRoomArchived?(archivedRoomID) }
        return doc.selectedThreadID
    }

    @discardableResult
    func restoreMostRecentArchivedThread() -> UUID? {
        guard let index = doc.threads.indices
            .filter({ doc.threads[$0].isArchived })
            .max(by: { doc.threads[$0].updatedAt < doc.threads[$1].updatedAt })
        else { return nil }
        doc.threads[index].isArchived = false
        doc.threads[index].updatedAt = Date()
        doc.selectedThreadID = doc.threads[index].id
        persist()
        return doc.threads[index].id
    }

    @discardableResult
    func duplicate(_ threadID: UUID, asBranch: Bool) -> UUID? {
        guard let sourceIndex = doc.threads.firstIndex(where: { $0.id == threadID }) else { return nil }
        let source = doc.threads[sourceIndex]
        let sourceRows = messages[threadID] ?? source.messages.map(\.chatMessage)
        let copiedRows = sourceRows.map { row in
            ChatMessage(
                role: row.role,
                text: row.text,
                status: row.status,
                modelID: row.modelID,
                eventKind: row.eventKind,
                runtimeAdapterID: row.runtimeAdapterID,
                runtimeFallbackReason: row.runtimeFallbackReason,
                turnID: row.turnID,
                planQuestions: row.planQuestions,
                createdAt: row.createdAt)
        }
        let now = Date()
        var copy = LiveThreadRecord(
            projectID: source.projectID,
            title: "\(source.title) 副本",
            isPinned: false,
            isArchived: false,
            sessionID: nil,
            sessionIDs: [:],
            engine: source.engine,
            model: source.model,
            enabledMCP: source.enabledMCP,
            messages: copiedRows.map(LiveMessageRecord.init),
            createdAt: now,
            updatedAt: now)
        copy.parentThreadID = asBranch ? source.id : source.parentThreadID
        if source.roomReadOnly == true {
            copy.roomReadOnly = true
            copy.cwdOverride = source.cwdOverride
        }
        doc.threads.insert(copy, at: min(sourceIndex + 1, doc.threads.endIndex))
        messages[copy.id] = copiedRows
        doc.selectedThreadID = copy.id
        persist()
        return copy.id
    }

    @discardableResult
    func createDiscussion(parentThreadID: UUID) -> UUID? {
        guard let parent = doc.threads.first(where: { $0.id == parentThreadID && !$0.isArchived }) else { return nil }
        let number = doc.threads.filter { $0.parentThreadID == parentThreadID }.count + 1
        var discussion = LiveThreadRecord(
            projectID: parent.projectID,
            title: "支線 \(number)",
            engine: parent.engine,
            model: parent.model,
            enabledMCP: parent.enabledMCP)
        discussion.parentThreadID = parentThreadID
        if parent.roomReadOnly == true {
            discussion.roomReadOnly = true
            discussion.cwdOverride = parent.cwdOverride
        }
        discussion.requestedModel = parent.requestedModel
        discussion.requestedEffort = parent.requestedEffort
        discussion.requestedSpeedTier = parent.requestedSpeedTier
        doc.threads.insert(discussion, at: 0)
        messages[discussion.id] = []
        doc.selectedThreadID = discussion.id
        persist()
        return discussion.id
    }

    @discardableResult
    func compressDiscussion(_ discussionID: UUID) -> UUID? {
        guard
            let childIndex = doc.threads.firstIndex(where: { $0.id == discussionID }),
            let parentID = doc.threads[childIndex].parentThreadID,
            doc.threads.contains(where: { $0.id == parentID })
        else { return nil }
        let child = doc.threads[childIndex]
        if child.cwdOverride != nil, isRunning(discussionID) { stop(threadID: discussionID) }
        if let summary = (messages[discussionID] ?? [])
            .last(where: { $0.role == .assistant && $0.eventKind == .message })?
            .text
        {
            appendSystem(
                parentID,
                "〔支線 \(child.title) 摘要〕\n\(summary)",
                status: "info|支線摘要")
        }
        doc.threads[childIndex].isArchived = true
        doc.threads[childIndex].updatedAt = Date()
        doc.selectedThreadID = parentID
        persist()
        if child.cwdOverride != nil { onRoomArchived?(discussionID) }
        return parentID
    }

    @discardableResult
    func mergeDiscussionIntoParent(_ discussionID: UUID) -> UUID? {
        guard
            let childIndex = doc.threads.firstIndex(where: { $0.id == discussionID }),
            let parentID = doc.threads[childIndex].parentThreadID,
            doc.threads.contains(where: { $0.id == parentID })
        else { return nil }
        let child = doc.threads[childIndex]
        if child.cwdOverride != nil, isRunning(discussionID) { stop(threadID: discussionID) }
        let prefix = "〔支線 \(child.title)〕"
        let mergedRows = (messages[discussionID] ?? []).map { row in
            ChatMessage(
                role: row.role,
                text: "\(prefix)\n\(row.text)",
                status: row.status,
                modelID: row.modelID,
                eventKind: row.eventKind,
                runtimeAdapterID: row.runtimeAdapterID,
                runtimeFallbackReason: row.runtimeFallbackReason,
                turnID: row.turnID,
                planQuestions: row.planQuestions,
                createdAt: row.createdAt)
        }
        messages[parentID, default: []].append(contentsOf: mergedRows)
        touch(parentID)
        doc.threads[childIndex].isArchived = true
        doc.threads[childIndex].updatedAt = Date()
        doc.selectedThreadID = parentID
        persist()
        if child.cwdOverride != nil { onRoomArchived?(discussionID) }
        return parentID
    }

    func setGitHubRepos(_ repos: [String], for projectID: UUID) {
        guard let index = doc.projects.firstIndex(where: { $0.id == projectID }) else { return }
        doc.projects[index].githubRepos = repos
        persist()
    }

    // MARK: - issue 清單（右側資訊卡）

    func issues(threadID: UUID?, global: Bool) -> [TatwoIssueListEntryV1] {
        if global { return doc.threads.flatMap(\.issues).sorted { $0.createdAt > $1.createdAt } }
        guard let threadID, let t = doc.threads.first(where: { $0.id == threadID }) else { return [] }
        return t.issues.sorted { $0.createdAt > $1.createdAt }
    }
    /// /issue 直接記進右側資訊卡的 issue 清單（1.0 語意：快速記問題，不叫模型）
    func addIssue(threadID: UUID, title: String, body: String) {
        guard let i = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        let entry = TatwoIssueListEntryV1(title: String(title.prefix(60)), body: body, sourceReference: threadID.uuidString,
                                          threadReference: threadID.uuidString, projectReference: doc.threads[i].projectID?.uuidString)
        doc.threads[i].issues.append(entry); persist()
    }
    /// Publish only after checked persistence. The caller retains the id on failure.
    func addIssueChecked(threadID: UUID, entry: TatwoIssueListEntryV1) throws {
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID && !$0.isArchived }) else {
            throw BotLibraryError.invalid("討論串不存在或已封存")
        }
        if doc.threads[index].issues.contains(where: { $0.id == entry.id }) { return }
        var candidate = doc
        for i in candidate.threads.indices {
            candidate.threads[i].messages = (messages[candidate.threads[i].id] ?? []).map(LiveMessageRecord.init)
        }
        candidate.threads[index].issues.append(entry)
        try store.saveChecked(candidate)
        doc = candidate
        onChange?()
    }
    func updateIssueImagesChecked(id: String, body: String, images: [String]) throws {
        var candidate = doc
        guard let ti = candidate.threads.firstIndex(where: { $0.issues.contains(where: { $0.id == id }) }),
              let ii = candidate.threads[ti].issues.firstIndex(where: { $0.id == id }) else {
            throw BotLibraryError.invalid("issue 不存在")
        }
        candidate.threads[ti].issues[ii].body = body
        candidate.threads[ti].issues[ii].imageAssetPaths = images
        for i in candidate.threads.indices {
            candidate.threads[i].messages = (messages[candidate.threads[i].id] ?? []).map(LiveMessageRecord.init)
        }
        try store.saveChecked(candidate)
        doc = candidate
        onChange?()
    }
    func captureIssue(threadID: UUID) {
        guard let i = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        let rows = messages[threadID] ?? []
        let lastAssistant = rows.last { $0.role == .assistant && $0.eventKind == .message }?.text ?? ""
        let lastUser = rows.last { $0.role == .user }?.text ?? doc.threads[i].title
        let entry = TatwoIssueListEntryV1(title: String(lastUser.prefix(60)), body: lastAssistant, sourceReference: threadID.uuidString,
                                          threadReference: threadID.uuidString, projectReference: doc.threads[i].projectID?.uuidString)
        doc.threads[i].issues.append(entry); persist()
    }
    func updateIssue(_ id: String, _ body: (inout TatwoIssueListEntryV1) -> Void) {
        for ti in doc.threads.indices {
            if let ii = doc.threads[ti].issues.firstIndex(where: { $0.id == id }) { body(&doc.threads[ti].issues[ii]); persist(); return }
        }
    }
    func removeIssue(_ id: String) {
        for ti in doc.threads.indices { doc.threads[ti].issues.removeAll { $0.id == id } }
        persist()
    }

    // MARK: - git 狀態（專案 workdir）

    struct GitSummary { var branch = "—"; var files: [String] = []; var additions = 0; var deletions = 0; var perFile: [String: (Int, Int)] = [:]; var truncated = false }
    func gitSummary(for threadID: UUID?, completion: @escaping (GitSummary) -> Void) {
        guard let threadID, let t = doc.threads.first(where: { $0.id == threadID }),
              let cwd = t.cwdOverride ?? doc.projects.first(where: { $0.id == t.projectID })?.workdir else { completion(GitSummary()); return }
        DispatchQueue.global(qos: .utility).async {
            var readFailed = false
            func run(_ args: [String]) -> String {
                guard let output = TurnArtifactsGit.run(args, cwd: cwd) else { readFailed = true; return "" }
                return output
            }
            var g = GitSummary()
            let branch = run(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else { g.truncated = readFailed; DispatchQueue.main.async { completion(g) }; return }
            g.branch = branch
            let paths = TurnArtifactsGit.paths(run(["status", "--porcelain=v1", "-z", "--untracked-files=all"]))
            g.files = Array(paths.prefix(TurnArtifacts.maxPaths))
            for line in run(["diff", "--numstat"]).split(separator: "\n") {
                let parts = line.split(separator: "\t"); if parts.count >= 2 { g.additions += Int(parts[0]) ?? 0; g.deletions += Int(parts[1]) ?? 0 }
                if parts.count >= 3 { g.perFile[parts[2...].joined(separator: "\t")] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0) }   // 結語卡每個檔的 +/-（未追蹤檔沒有 numstat，顯示 0/0）
            }
            g.truncated = readFailed || paths.count > TurnArtifacts.maxPaths
            DispatchQueue.main.async { completion(g) }
        }
    }

    // Bot-only preparation; the caller supplies an already-loaded library snapshot.
    // No filesystem work and no engine process is started in this method.
    func prepareBotThread(existing: UUID?, bot: BotLibraryRecord, registeredMCP: [String],
                          reservedID: UUID? = nil, selectThread: Bool = true) throws -> UUID {
        if let existing, isRunning(existing) { throw BotLibraryError.invalid("bot_turn_in_progress") }
        let resolved = bot.permissions.resolve(registeredMCP: registeredMCP)
        let id: UUID
        if let existing, doc.threads.contains(where: { $0.id == existing }) { id = existing }
        else {
            let projectID: UUID
            if let project = doc.projects.first(where: { $0.workdir == bot.workdir }) { projectID = project.id }
            else {
                let project = LiveProjectRecord(name: bot.name, workdir: bot.workdir)
                doc.projects.append(project); projectID = project.id
            }
            var thread = LiveThreadRecord(id: reservedID ?? UUID(), projectID: projectID, title: bot.name)
            thread.engine = bot.engine
            doc.threads.insert(thread, at: 0); messages[thread.id] = []; id = thread.id
        }
        guard let i = doc.threads.firstIndex(where: { $0.id == id }) else { throw BotLibraryError.invalid("bot_thread_missing") }
        // Empty means default-all in the legacy engine; keep the established deny-all sentinel.
        let selection = resolved.enabledMCP.isEmpty ? ["__tatwo_none__"] : resolved.enabledMCP
        if doc.threads[i].enabledMCP != selection || doc.threads[i].botPermissionPreset != resolved.approval || doc.threads[i].cwdOverride != bot.workdir {
            if let sidecar = sidecars.removeValue(forKey: id) { sidecar.onEvent = nil; sidecar.close() }
        }
        doc.threads[i].enabledMCP = selection
        doc.threads[i].botPermissionPreset = resolved.approval
        doc.threads[i].cwdOverride = bot.workdir
        if selectThread { doc.selectedThreadID = id }
        return id
    }

    // MARK: - 講話

    @discardableResult func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind = .claude, systemPrompt: String? = nil, attachments: [String] = [], reasoningEffort: String? = nil, serviceTier: String? = nil) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!t.isEmpty || !attachments.isEmpty), !runningThreads.contains(threadID) else { return false }
        var plan: TatwoPlanArtifactV1?
        do { plan = try loadPlanArtifact(threadID) }
        catch {
            appendSystemMessage(threadID: threadID, text: "計畫讀取失敗，這句未送出；請先修復畫布資料。", status: "error|Plan")
            return false
        }
        if EngineDisableStore.isDisabled(engine) {   // 使用者在模型登入頁禁用了這家：實質不送，不燒 API
            appendSystemMessage(threadID: threadID, text: "\(EngineDisableStore.displayName(engine)) 的 API 已被你禁用，這句沒有送出。要用請到設定 › 模型登入解除禁用。", status: "error|已禁用")
            return false
        }
        let thread = threadRecord(threadID)
        let effort = engine == .codex
            ? reasoningEffort ?? thread?.requestedEffort ?? (model == "gpt-6-astra" ? "medium" : nil) : nil
        let tier = engine == .codex
            ? serviceTier ?? thread?.requestedSpeedTier.flatMap(TatwoModelSpeedTier.init(rawValue:))?.appServerValue
                ?? (model == "gpt-6-astra" ? TatwoModelSpeedTier.fast.appServerValue : nil) : nil
        if let index = doc.threads.firstIndex(where: { $0.id == threadID }) {
            if let model { doc.threads[index].requestedModel = model }
            if let effort { doc.threads[index].requestedEffort = effort }
            if let tier {
                doc.threads[index].requestedSpeedTier = tier == "default" ? "standard" : "fast"
            }
        }
        guard let sidecar = ensureSidecar(threadID, model: model, engine: engine, systemPrompt: systemPrompt) else { return false }
        let turn = UUID().uuidString
        let planBriefing = planContext(plan, userText: t)
        if var confirmed = plan, confirmed.kind != "feedback", confirmed.state == .confirmed, confirmed.executionTurnID == nil, t == "開始" {
            confirmed.executionTurnID = turn
            do { try savePlanArtifact(confirmed) }
            catch {
                appendSystemMessage(threadID: threadID, text: "計畫執行狀態未能儲存，這句未送出。", status: "error|Plan")
                return false
            }
        }
        turnID[threadID] = turn
        artifactClaims[threadID] = []
        artifactClaimsTruncated.remove(threadID)
        let shown = ChatAttachmentTranscript.displayTurn(text: t, attachmentPaths: attachments)
        append(threadID, ChatMessage(role: .user, text: shown, turnID: turn))
        if let i = doc.threads.firstIndex(where: { $0.id == threadID }), doc.threads[i].title == "新聊天" {
            doc.threads[i].title = String(ChatAttachmentTranscript.previewText(userText: t, attachmentPaths: attachments).prefix(24))
        }
        runningThreads.insert(threadID)
        streamingRowID[threadID] = nil
        // D3：討論串中途換引擎、且新引擎在這條串還沒有 session → 把最近對話摘要當第一句餵給它
        var outgoing = t
        if let th = thread, let prev = th.engine, prev != engine.rawValue, th.sessionIDs[engine.rawValue] == nil {
            let recent = (messages[threadID] ?? []).filter { $0.eventKind == .message && $0.role != .system }.suffix(13).dropLast()
            if !recent.isEmpty {
                let summary = recent.map { "\($0.role == .user ? "使用者" : "助理")：\($0.text.prefix(600))" }.joined(separator: "\n")
                outgoing = "（這條討論串先前是用 \(prev) 引擎談的，以下是最近對話，請接續，不要重複回答舊問題）\n\(summary)\n\n（現在的訊息）\n\(t)"
            }
        }
        if let planBriefing { outgoing += "\n\n" + planBriefing }
        sidecar.send(text: outgoing, uuid: turn, attachments: attachments, model: model,
                     reasoningEffort: effort, serviceTier: tier)
        persist()
        return true
    }

    func savePastedAttachment(data: Data, suggestedName: String) throws -> URL {
        try store.saveAttachment(data: data, suggestedName: suggestedName)
    }

    func nativeGoalIsCurrent(_ threadID: UUID) -> Bool {
        currentNativeGoals.contains(threadID) && sidecars[threadID]?.kind == .codex &&
        sidecars[threadID]?.isRunning == true
    }
    func nativeGoalError(_ threadID: UUID) -> String? { nativeGoalErrors[threadID] }
    func nativeGoalControlPending(_ threadID: UUID) -> Bool { pendingGoalControls[threadID] != nil }

    @discardableResult
    func setNativeGoal(threadID: UUID, status: String?, objective: String? = nil, model: String? = nil,
                       completion: @escaping (Bool, String?) -> Void) -> Bool {
        guard let thread = threadRecord(threadID), thread.deviceID == nil,
              pendingGoalControls[threadID] == nil, !EngineDisableStore.isDisabled(.codex),
              !isRunning(threadID) || sidecars[threadID]?.kind == .codex,
              let sidecar = ensureSidecar(threadID, model: model, engine: .codex) else { return false }
        let id = UUID().uuidString
        let targetTurn = turnID[threadID]
        pendingGoalControls[threadID] = (id, { [weak self] accepted, error in
            if accepted, status == nil || status == "paused", let self,
               self.turnID[threadID] == targetTurn || self.turnID[threadID]?.hasPrefix("native:") == true {
                self.requestStop(threadID, pauseGoal: false)
            }
            completion(accepted, error)
        })
        nativeGoalErrors[threadID] = nil
        let choice = ChatRouteChoice.resolve(model ?? thread.requestedModel ?? thread.model ?? "gpt-6-astra")
        let configure = status == "active" && choice.brandGroup == .openAI
        sidecar.goal(status: status, objective: objective, requestID: id,
                     model: configure ? choice.modelArgument ?? choice.canonicalModelSlug : nil,
                     effort: configure ? thread.requestedEffort ?? choice.defaultEffort.codexRawValue : nil,
                     serviceTier: configure ? thread.requestedSpeedTier.flatMap(TatwoModelSpeedTier.init(rawValue:))?.appServerValue
                        ?? choice.defaultSpeedTier?.appServerValue : nil)
        onChange?()
        return true
    }

    func refreshNativeGoal(_ threadID: UUID) {
        // Navigation never creates a provider process or wakes a model.
        sidecars[threadID]?.refreshGoal()
    }

    private func finishGoalControl(_ threadID: UUID, accepted: Bool, message: String?) {
        guard let pending = pendingGoalControls.removeValue(forKey: threadID) else { return }
        if !accepted { nativeGoalErrors[threadID] = message ?? "目標操作未確認" }
        onChange?()
        pending.completion(accepted, message)
    }

    func canSteer(_ threadID: UUID) -> Bool {
        runningThreads.contains(threadID) && !stoppingThreads.contains(threadID) &&
        pendingSteers[threadID] == nil && sidecars[threadID]?.kind == .codex &&
        threadRecord(threadID)?.deviceID == nil
    }

    @discardableResult
    func steer(threadID: UUID, text: String, attachments: [String],
               completion: @escaping (Bool, String?) -> Void) -> Bool {
        guard canSteer(threadID), let target = turnID[threadID],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        else { return false }
        let requestID = UUID().uuidString
        pendingSteers[threadID] = .init(requestID: requestID, targetTurnID: target, completion: completion)
        append(threadID, ChatMessage(id: requestID, role: .user,
            text: ChatAttachmentTranscript.displayTurn(text: text, attachmentPaths: attachments),
            status: "steering|等待插話確認", turnID: target))
        // Keep subsequent assistant text below the inserted user message.
        endStreaming(threadID)
        sidecars[threadID]?.steer(text: text, attachments: attachments,
                                 requestID: requestID, targetTurnUUID: target)
        persist()
        return true
    }

    private func finishSteer(_ threadID: UUID, accepted: Bool, message: String?, unknown: Bool = false) {
        guard let pending = pendingSteers.removeValue(forKey: threadID) else { return }
        update(threadID, pending.requestID) {
            $0.status = accepted ? nil : unknown
                ? "steer_unknown|插話送達狀態待確認"
                : "steer_failed|插話未送出"
        }
        persist()
        pending.completion(accepted, message)
    }

    func stop(threadID: UUID) {
        requestStop(threadID, pauseGoal: threadRecord(threadID)?.nativeGoal?.status == "active" ? true : nil)
    }

    private func requestStop(_ threadID: UUID, pauseGoal: Bool?) {
        ComputerUseController.shared.stop(owner: threadID)
        BrowserAgentBridge.shared.revokeRequests(owner: threadID)
        guard sidecars[threadID] != nil,
              runningThreads.contains(threadID) || (pauseGoal != false &&
                (pendingGoalControls[threadID] != nil || threadRecord(threadID)?.nativeGoal?.status == "active")) else { return }
        if runningThreads.contains(threadID) { stoppingThreads.insert(threadID) }
        sidecars[threadID]?.interrupt(pauseGoal: pauseGoal)
        // Sending interrupt is not confirmation. Reuse the existing running
        // state until the engine emits its terminal event; no timer or poller.
        if let rid = streamingRowID[threadID] {
            update(threadID, rid) { $0.status = "writing|正在停止" }
        }
        persist()
    }

    func shutdownAll() {
        for id in Array(onTurnComplete.keys) { notifyTurnComplete(id, succeeded: false) }
        for id in Array(pendingGoalControls.keys) {
            finishGoalControl(id, accepted: false, message: "引擎已離線，目標操作結果待確認")
        }
        currentNativeGoals.removeAll()
        for id in Array(pendingSteers.keys) {
            finishSteer(id, accepted: false, message: "引擎已離線，請先確認插話是否送達", unknown: true)
        }
        for (_, s) in sidecars { s.close() }
        sidecars.removeAll(); remoteHandles.removeAll()
        runningThreads.removeAll(); stoppingThreads.removeAll()
        persist()
    }

    // MARK: - 派工引擎（E1）

    /// A new local reviewer retains the source cwd but never owns a worktree.
    /// Persist the capability with the thread so reopening cannot widen it.
    func configureReadOnlyRoom(threadID: UUID, parentThreadID: UUID, roomBrief: String, cwd: String) {
        guard let i = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        doc.threads[i].roomReadOnly = true
        configureRoom(threadID: threadID, parentThreadID: parentThreadID, roomBrief: roomBrief,
                      engine: "claude", cwdOverride: cwd, deviceID: nil)
    }

    /// 把新開的子討論串設成一個房間：父串、施工單、初始引擎、專屬 worktree。
    func configureRoom(threadID: UUID, parentThreadID: UUID, roomBrief: String, engine: String, cwdOverride: String, deviceID: String? = nil) {
        guard let i = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        doc.threads[i].parentThreadID = parentThreadID
        doc.threads[i].roomBrief = roomBrief
        doc.threads[i].subStatus = "running"
        doc.threads[i].engine = engine
        doc.threads[i].lastOutputAt = Date()
        doc.threads[i].cwdOverride = cwdOverride
        doc.threads[i].deviceID = deviceID
        persist()
    }

    func setRequestedModel(_ model: String?, threadID: UUID) {
        guard let i = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        doc.threads[i].requestedModel = model
        persist()
    }

    // MARK: - sidecar

    private func ensureSidecar(_ threadID: UUID, model: String?, engine: ClaudeSidecar.Kind, systemPrompt: String? = nil) -> ClaudeSidecar? {
        // Enforce before reusing a resident runner as well as after a restart.
        if let record = threadRecord(threadID), record.roomReadOnly == true,
           engine != .claude || record.deviceID != nil {
            appendSystem(threadID, "此引擎／設備尚不支援唯讀副審，未啟動可寫入模式", status: "error|唯讀副審")
            markSubStatus(threadID, "failed")
            runningThreads.remove(threadID)
            return nil
        }
        guard let record = threadRecord(threadID) else { return nil }
        let permissionMode = TatwoPermissionPreset.resolvedSidecarMode(
            user: userPermissionPreset, bot: record.botPermissionPreset,
            readOnly: record.roomReadOnly == true,
            legacyCodexAutoApprove: autoApprove && engine == .codex)
        if let s = sidecars[threadID], s.isRunning {
            if s.kind == engine && sidecarPermissionModes[threadID] == (permissionMode ?? "configured-default") { return s }
            finishGoalControl(threadID, accepted: false, message: "引擎或權限已切換，目標操作結果待確認")
            currentNativeGoals.remove(threadID)
            s.onEvent = nil; s.close(); sidecars[threadID] = nil   // 換引擎：舊的先解除事件再關，免得它的「結束」事件蓋掉新引擎的狀態
        }
        guard let idx = doc.threads.firstIndex(where: { $0.id == threadID }) else { return nil }
        let thread = doc.threads[idx]
        let cwd = thread.cwdOverride ?? doc.projects.first { $0.id == thread.projectID }?.workdir ?? NSHomeDirectory()
        let resume = thread.sessionIDs[engine.rawValue] ?? (engine == .claude ? thread.sessionID : nil)
        doc.threads[idx].engine = engine.rawValue
        let script = ClaudeSidecar.scriptPath(for: engine, allowsOverride: thread.roomReadOnly != true)
        let remote: RemoteDeviceRef?
        do {
            remote = try thread.deviceID.map {
                try RemoteDeviceLookup(root: store.url.deletingLastPathComponent()).device(id: $0)
            }
        } catch {
            appendSystem(threadID, String(describing: error), status: "error|遠端設備")
            runningThreads.remove(threadID)
            return nil
        }
        var remoteHandle: RemoteEngineHandle? = nil
        if let remote {
            do {
                // session handle 必須與本次 device／engine 一致；不一致：fixture fail-closed、production 依 registered device 重新 resolve 固定 handle（正常恢復語意不變）
                var testRequested = false
                #if DEBUG
                testRequested = RemoteSyncFixture.isRequested(environment: ProcessInfo.processInfo.environment)
                #endif
                remoteHandle = try RemoteEngineHandle.resolve(session: remoteHandles.get(threadID), device: remote, engine: engine, testRequested: testRequested)
            } catch {
                appendSystem(threadID, "capture-only／fixture fail-closed：\(error)", status: "error|遠端 handle")
                markSubStatus(threadID, "failed")
                runningThreads.remove(threadID)
                return nil
            }
        }
        guard remote != nil || FileManager.default.fileExists(atPath: script) else {
            appendSystem(threadID, "\(engine.rawValue) 引擎的 sidecar 還沒接（缺 \(script)）", status: "error|引擎未接")
            runningThreads.remove(threadID)
            return nil
        }
        let s = ClaudeSidecar(kind: engine)
        s.onEvent = { [weak self, weak s] e in
            guard let self, let s, self.sidecars[threadID] === s else { return }   // 只認目前這條串「現任」的 sidecar
            self.handle(threadID, e)
        }
        do {
            let mcpEngine = PluginsSource.MCPEngine(rawValue: engine.rawValue) ?? .grok
            let mcpConfig = thread.roomReadOnly == true ? nil : PluginsSource.sidecarMCPConfig(
                engine: mcpEngine,
                stored: thread.enabledMCP,
                threadID: threadID,
                environment: environment)
            try s.start(cwd: cwd, resume: resume, model: model, systemPrompt: OSUpstream.compose(threadSystemPrompt: systemPrompt), mcpConfig: mcpConfig, permissionMode: permissionMode, remote: remoteHandle)
            sidecars[threadID] = s
            sidecarPermissionModes[threadID] = permissionMode ?? "configured-default"
            return s
        } catch let error as RemoteCaptureOnlyError {
            appendSystem(threadID, String(describing: error), status: "error|capture-only")   // 明確 capture／BLOCKED，不冒充真房間完成
            markSubStatus(threadID, "failed")
            runningThreads.remove(threadID)
            return nil
        } catch {
            appendSystem(threadID, "sidecar 啟動失敗：\(error.localizedDescription)", status: "error|sidecar")
            if thread.roomReadOnly == true { markSubStatus(threadID, "failed") }
            runningThreads.remove(threadID)
            return nil
        }
    }

    /// R3 無頭驗收只讀：回目前討論串 sidecar（本機 node 或遠端 ssh）的 PID。
    func sidecarProcessID(threadID: UUID) -> Int32? {
        sidecars[threadID]?.processIdentifier
    }

    private func handle(_ threadID: UUID, _ e: ClaudeSidecar.Event) {
        switch e {
        case .sdk(let m): handleSDK(threadID, m)
        case .permission(let id, let tool, let input, _, let description):
            if threadRecord(threadID)?.roomReadOnly == true {
                sidecars[threadID]?.respondPermission(id: id, allow: false)
                appendSystem(threadID, "唯讀副審不允許擴張工具權限", status: "done|權限")
                return
            }
            withPendingPermission(threadID) {
            let pretty = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(input)"
            let botPreset = doc.threads.first(where: { $0.id == threadID })?.botPermissionPreset
            let botDecision: Bool?
            if botPreset == .askFirst, permissionDecider == nil {
                let alert = NSAlert(); alert.messageText = "Bot 想要執行 " + tool
                alert.informativeText = String(pretty.prefix(1200))
                alert.addButton(withTitle: "允許"); alert.addButton(withTitle: "拒絕")
                botDecision = alert.runModal() == .alertFirstButtonReturn
            } else if botPreset == .approveForMe || botPreset == .fullAccess { botDecision = true }
            else { botDecision = nil }
            let automatic = (botPreset ?? userPermissionPreset)?.automaticallyApprovesTools ?? autoApprove
            let allow = botDecision ?? (automatic ? true :
                permissionDecider?(tool + (description.map { "：\($0)" } ?? ""), pretty) ?? true)
            sidecars[threadID]?.respondPermission(id: id, allow: allow)
            appendSystem(threadID, (allow ? "允許 " : "拒絕 ") + tool, status: "done|權限")
            }
        case .stderr(let s):
            // 引擎的雜訊：去掉 ANSI 色碼；codex 的日誌行（時間戳＋INFO/WARN/ERROR）不當提示，只留人看得懂的
            var line = s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.range(of: #"^\d{4}-\d{2}-\d{2}T[0-9:.]+Z?\s+(TRACE|DEBUG|INFO|WARN|ERROR)\b"#, options: .regularExpression) != nil {
                if line.contains("ERROR") { line = "引擎回報錯誤：" + (line.split(separator: " ", maxSplits: 3).last.map(String.init) ?? line) }
                else { return }
            }
            if !line.isEmpty { onHint?(String(line.prefix(120))) }
        case .error(let s):
            appendSystem(threadID, s, status: "error|sidecar")
        case .closed:
            currentNativeGoals.remove(threadID)
            finishGoalControl(threadID, accepted: false, message: "引擎已離線，目標操作結果待確認")
            finishSteer(threadID, accepted: false, message: "引擎已離線，請先確認插話是否送達", unknown: true)
            if let rid = streamingRowID[threadID] { update(threadID, rid) { if $0.status?.hasPrefix("writing") == true { $0.status = "cancelled|sidecar 結束" } } }
            streamingRowID[threadID] = nil
            if runningThreads.contains(threadID) {
                appendSystem(threadID, "引擎在這一輪中途結束。常見原因：剛啟動時 macOS 跳出「取用可卸除式卷宗」權限詢問還沒按允許（Codex 的設定在外接卷上）。按允許後把這句再送一次即可。", status: "error|引擎結束")
                indexTurnArtifacts(threadID)
            }
            runningThreads.remove(threadID); stoppingThreads.remove(threadID); remoteHandles.remove(threadID)
            sidecars[threadID] = nil; persist()
            notifyTurnComplete(threadID, succeeded: false)
        }
    }

    func handleSDK(_ threadID: UUID, _ m: [String: Any]) {
        // A preboot cancellation has no native session yet. Only a matching
        // pending request from this Codex sidecar may settle that rejection.
        if m["type"] as? String == "system", m["subtype"] as? String == "goal_result",
           m["session_id"] == nil || m["session_id"] is NSNull {
            guard sidecars[threadID]?.kind == .codex, m["accepted"] as? Bool == false,
                  let id = m["request_id"] as? String, id == pendingGoalControls[threadID]?.id else { return }
            finishGoalControl(threadID, accepted: false, message: m["message"] as? String)
            return
        }
        if m["type"] as? String == "system", let subtype = m["subtype"] as? String,
           ["goal", "goal_unavailable", "goal_result", "native_turn_started"].contains(subtype) {
            guard let index = doc.threads.firstIndex(where: { $0.id == threadID }),
                  let session = m["session_id"] as? String,
                  session == doc.threads[index].sessionIDs["codex"],
                  sidecars[threadID]?.kind == .codex else { return }
            switch subtype {
            case "goal":
                if m["goal"] is NSNull {
                    doc.threads[index].nativeGoal = nil
                } else if let value = m["goal"], let goal = ChatNativeGoal.decode(value), goal.threadId == session {
                    doc.threads[index].nativeGoal = goal
                } else { return }
                currentNativeGoals.insert(threadID)
                nativeGoalErrors[threadID] = nil
                persist()
            case "goal_unavailable":
                currentNativeGoals.remove(threadID)
                nativeGoalErrors[threadID] = m["message"] as? String ?? "無法確認原生目標"
                onChange?()
            case "goal_result":
                guard let id = m["request_id"] as? String, id == pendingGoalControls[threadID]?.id else { return }
                finishGoalControl(threadID, accepted: m["accepted"] as? Bool == true,
                                  message: m["message"] as? String)
            default:
                guard let id = m["client_turn_id"] as? String, id.hasPrefix("native:"),
                      !id.dropFirst("native:".count).isEmpty,
                      !isRunning(threadID) || turnID[threadID] == id else { return }
                if turnID[threadID] == id { return }
                turnID[threadID] = id
                artifactClaims[threadID] = []
                artifactClaimsTruncated.remove(threadID)
                streamingRowID[threadID] = nil
                runningThreads.insert(threadID)
                if m["stopping"] as? Bool == true { stoppingThreads.insert(threadID) }
                touchLiveness(threadID)
                persist()
            }
            return
        }
        // An acknowledgement can arrive after this turn's terminal event.
        // Bind it to its own pending request, not whichever turn runs now.
        if m["type"] as? String == "system", m["subtype"] as? String == "steer_result" {
            guard let requestID = m["request_id"] as? String, let target = m["target_turn_id"] as? String else { return }
            guard let pending = pendingSteers[threadID],
                  requestID == pending.requestID, target == pending.targetTurnID else {
                // A late native reply may resolve a previously unknown row,
                // but must not clear a newer composer draft or another turn.
                if messages[threadID]?.contains(where: {
                    $0.id == requestID && $0.turnID == target && $0.status?.hasPrefix("steer_unknown|") == true
                }) == true, m["unknown"] as? Bool != true {
                    update(threadID, requestID) { $0.status = m["accepted"] as? Bool == true ? nil : "steer_failed|插話未送出" }
                    persist()
                }
                return
            }
            finishSteer(threadID, accepted: m["accepted"] as? Bool == true,
                        message: m["message"] as? String, unknown: m["unknown"] as? Bool == true)
            return
        }
        // Codex uses the UUID already sent by this App, not a second state store.
        // A cancelled turn may still emit while its native interrupt settles.
        // Never let that old result clear a subsequent send's running state.
        if let clientTurn = m["client_turn_id"] as? String {
            guard clientTurn == turnID[threadID], runningThreads.contains(threadID) else { return }
        }
        touchLiveness(threadID)
        let type = m["type"] as? String ?? ""
        switch type {
        case "system":
            if m["subtype"] as? String == "turn_error", let message = m["message"] as? String {
                appendSystem(threadID, message, status: "error|停止失敗")
            }
            if m["subtype"] as? String == "model" {
                let reported = (m["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                attestedModel[threadID] = reported   // native settings event, not the UI's requested model
                if let reported, let index = doc.threads.firstIndex(where: { $0.id == threadID }) {
                    doc.threads[index].model = reported
                    persist()
                }
            }
            if m["subtype"] as? String == "init", let sid = m["session_id"] as? String,
               let i = doc.threads.firstIndex(where: { $0.id == threadID }) {
                let kind = sidecars[threadID]?.kind ?? .claude
                doc.threads[i].sessionIDs[kind.rawValue] = sid
                if kind == .claude { doc.threads[i].sessionID = sid }
                if let model = m["model"] as? String {
                    doc.threads[i].model = model
                    attestedModel[threadID] = (model.isEmpty || model == "default") ? nil : model
                }
                persist()
            }
        case "stream_event":
            guard let ev = m["event"] as? [String: Any] else { return }
            if ev["type"] as? String == "content_block_delta",
               let d = ev["delta"] as? [String: Any], d["type"] as? String == "text_delta",
               let t = d["text"] as? String { appendStreaming(threadID, t) }
        case "assistant":
            guard let msg = m["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            if let reported = msg["model"] as? String, !reported.isEmpty { attestedModel[threadID] = reported }   // Claude SDK 每則 assistant message 都帶實際模型
            for b in content where b["type"] as? String == "tool_use" {
                endStreaming(threadID)
                let name = b["name"] as? String ?? "工具"
                let input = b["input"] as? [String: Any] ?? [:]
                for path in TurnArtifacts.claimedPaths(tool: name, input: input) {
                    if artifactClaims[threadID, default: []].contains(path) { continue }
                    if artifactClaims[threadID, default: []].count < TurnArtifacts.maxPaths {
                        artifactClaims[threadID, default: []].append(path)
                    } else { artifactClaimsTruncated.insert(threadID) }
                }
                let summary = (input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["pattern"] as? String)
                    ?? (input["description"] as? String) ?? (input["prompt"] as? String).map { String($0.prefix(80)) } ?? ""
                let row = ChatMessage(id: b["id"] as? String ?? UUID().uuidString, role: .assistant,
                                      text: summary.isEmpty ? name : "\(name)：\(summary)",
                                      status: "running-command|\(name)", eventKind: .toolUse, turnID: turnID[threadID])
                append(threadID, row)
            }
        case "user":
            guard let msg = m["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for b in content where b["type"] as? String == "tool_result" {
                guard let useID = b["tool_use_id"] as? String else { continue }
                let isError = b["is_error"] as? Bool == true
                update(threadID, useID) { row in
                    let name = row.status?.split(separator: "|").last.map(String.init) ?? "工具"
                    row.status = isError ? "error|\(name)" : "done|\(name)"
                }
            }
        case "result":
            let cancelled = m["subtype"] as? String == "cancelled"
            let failed = m["is_error"] as? Bool == true
            endStreaming(threadID, status: cancelled ? "cancelled|已停止" : "done")
            if let turn = turnID[threadID] {
                let unfinishedStatus = cancelled ? "cancelled|已停止"
                    : failed ? "error|回合失敗" : "info|回合已結束，工具結果未回報"
                for row in messages[threadID] ?? []
                where row.turnID == turn && row.status?.hasPrefix("running-command") == true {
                    update(threadID, row.id) { $0.status = unfinishedStatus }
                }
            }
            touchLiveness(threadID, done: true)
            if failed, let index = doc.threads.firstIndex(where: { $0.id == threadID }),
               doc.threads[index].parentThreadID != nil {
                doc.threads[index].subStatus = "failed"
            }
            if failed, let r = m["result"] as? String {
                appendSystem(threadID, r, status: "error|回合失敗")
            }
            indexTurnArtifacts(threadID)
            finishSteer(threadID, accepted: false, message: "回合已結束，請先確認插話是否送達", unknown: true)
            let succeeded = !cancelled && !failed && !stoppingThreads.contains(threadID)
            if succeeded, runningThreads.contains(threadID),
               let reply = messages[threadID]?.last(where: {
                   $0.turnID == turnID[threadID] && $0.role == .assistant && $0.eventKind == .message
               }) {
                updatePlanFromReply(threadID, reply: reply)
            }
            runningThreads.remove(threadID); stoppingThreads.remove(threadID); remoteHandles.remove(threadID); persist()
            notifyTurnComplete(threadID, succeeded: succeeded)
        default: break
        }
    }

    // MARK: - 列操作

    private func indexTurnArtifacts(_ threadID: UUID) {
        guard let turn = turnID[threadID], let thread = threadRecord(threadID),
              indexedArtifactTurn[threadID] != turn,
              thread.deviceID == nil else { return }
        // 跟 ensureSidecar 用同一套 cwd 規則：沒有專案的對話（例如「新聊天」）也在家目錄跑，索引也要用同一個根，
        // 不然回合結尾永遠沒有產出卡（lab 實測 2026-09-06 抓到）。
        let cwd = thread.cwdOverride ?? projectRecord(thread.projectID)?.workdir ?? NSHomeDirectory()
        indexedArtifactTurn[threadID] = turn
        let claimed = artifactClaims.removeValue(forKey: threadID) ?? []
        let truncated = artifactClaimsTruncated.remove(threadID) != nil
        let messageID = messages[threadID]?.last(where: { $0.turnID == turn })?.id
        let endedAt = Date()
        let artifacts = turnArtifacts
        gitSummary(for: threadID) { [weak self] summary in
            Task {
                do {
                    _ = try await artifacts.collect(threadID: threadID, turnID: turn, messageID: messageID,
                                                    endedAt: endedAt, cwd: cwd, claimed: claimed,
                                                    gitFiles: summary.files, truncated: truncated || summary.truncated)
                    self?.onChange?()
                } catch {
                    self?.appendSystemMessage(threadID: threadID, text: "本回合產出索引未能儲存。",
                                              status: "error|產出索引")
                }
            }
        }
    }

    private func appendStreaming(_ threadID: UUID, _ delta: String) {
        if let rid = streamingRowID[threadID] {
            update(threadID, rid) { $0.appendTranscriptText(delta) }
        } else {
            let row = ChatMessage(role: .assistant, text: delta, status: "writing|回覆中", turnID: turnID[threadID])
            streamingRowID[threadID] = row.id
            append(threadID, row)
        }
    }

    /// 子討論串活性：每收到一個事件就記時間；回合結束記 done
    private func touchLiveness(_ threadID: UUID, done: Bool = false) {
        // Late init/model metadata is still useful, but cannot restart work.
        guard done || runningThreads.contains(threadID) else { return }
        guard var t = doc.threads.first(where: { $0.id == threadID }) else { return }
        if t.parentThreadID == nil && t.subStatus == nil { return }
        t.lastOutputAt = Date(); t.subStatus = done ? "done" : "running"
        if let i = doc.threads.firstIndex(where: { $0.id == threadID }) { doc.threads[i] = t }
    }

    private func endStreaming(_ threadID: UUID, status: String = "done") {
        // Ending a text segment to show a tool is not ending the native turn.
        if let rid = streamingRowID[threadID] {
            let attested = attestedModel[threadID]
            update(threadID, rid) { $0.status = status; $0.modelID = attested }
        }
        streamingRowID[threadID] = nil
    }

    /// 只有這些系統列代表這條房間這一輪已經死了：sidecar 起不來／退出、回合失敗、引擎沒接、遠端設備連不上。
    static let fatalRoomStatuses: Set<String> = ["error|sidecar", "error|回合失敗", "error|引擎結束", "error|引擎未接", "error|遠端設備"]

    private func appendSystem(_ threadID: UUID, _ text: String, status: String) {
        // 房間（子對話）遇到「致命」的引擎事件才立刻標 failed（白名單；review：通用 error 如產出索引存檔失敗可能晚到下一回合，不能拿來改工作狀態）
        if Self.fatalRoomStatuses.contains(status), let i = doc.threads.firstIndex(where: { $0.id == threadID }),
           doc.threads[i].parentThreadID != nil, doc.threads[i].subStatus == "running" {
            doc.threads[i].subStatus = "failed"
            persist()
        }
        append(threadID, ChatMessage(role: .system, text: text, status: status, turnID: turnID[threadID]))
    }

    private func append(_ threadID: UUID, _ row: ChatMessage) {
        messages[threadID, default: []].append(row); touch(threadID); onChange?()
    }

    private func update(_ threadID: UUID, _ rowID: String, _ body: (inout ChatMessage) -> Void) {
        guard var rows = messages[threadID], let i = rows.firstIndex(where: { $0.id == rowID }) else { return }
        body(&rows[i]); messages[threadID] = rows; touch(threadID); onChange?()
    }

    private func touch(_ threadID: UUID) {
        if let i = doc.threads.firstIndex(where: { $0.id == threadID }) { doc.threads[i].updatedAt = Date() }
    }

    private func persist() {
        for i in doc.threads.indices { doc.threads[i].messages = (messages[doc.threads[i].id] ?? []).map(LiveMessageRecord.init) }
        store.save(doc); onChange?()
    }

    func persistSpaceConversation() throws {
        for i in doc.threads.indices {
            doc.threads[i].messages = (messages[doc.threads[i].id] ?? []).map(LiveMessageRecord.init)
        }
        try store.saveChecked(doc)
    }
}
