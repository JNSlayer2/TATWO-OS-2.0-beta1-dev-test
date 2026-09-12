import Foundation

/// R2 遙控資料源：畫面仍吃 LiveEngineAPI，底下改走主機 os.sock。
@MainActor
final class RemoteLiveEngine: LiveEngineAPI {
    let store: ChatLiveStore
    private(set) var doc = LiveDocumentRecord()
    var onChange: (() -> Void)?
    var permissionDecider: ((_ tool: String, _ inputPretty: String) -> Bool)?
    var autoApprove = false
    var onHint: ((String) -> Void)?
    var onRoomArchived: ((UUID) -> Void)?
    var onConnectionStateChange: ((Result<Int64, Error>) -> Void)?
    var dispatchPaused = false

    private let link: RemoteHostLink
    private var revision: Int64 = -1
    private var transcriptCache: [UUID: [ChatMessage]] = [:]
    private var runningThreadIDs: Set<UUID> = []
    private var pollTask: Task<Void, Never>?
    private(set) var currentRevision: Int64 = -1

    /// initial＝連線時在背景先拉好的第一份文件（不在主執行緒做網路）。沒有就等第一次輪詢。
    init(link: RemoteHostLink, store: ChatLiveStore, initial: [String: Any]? = nil) throws {
        self.link = link
        self.store = store
        if let initial { try apply(result: initial, notify: false) }
        let link = self.link
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard self != nil, !Task.isCancelled else { return }
                // 網路在背景執行緒，主執行緒只套用結果（不能再讓 UI 等 socket）
                let outcome = await Task.detached(priority: .utility) {
                    Result { try link.call(method: "get_document", params: [:]) }
                }.value
                guard let self, !Task.isCancelled else { return }
                switch outcome {
                case .success(let result):
                    do { try self.apply(result: result, notify: true) }
                    catch { self.onHint?("遙控資料讀不懂：\(error.localizedDescription)") }
                case .failure(let error):
                    self.onHint?("遙控連線中斷，正在重連：\(error.localizedDescription)")
                    self.onConnectionStateChange?(.failure(error))
                    return
                }
            }
        }
    }

    var document: TatwoNativeChatStoreDocument {
        TatwoNativeChatStoreDocument(projects: doc.projects.map { project in
            TatwoNativeChatProject(
                id: project.id,
                name: project.name,
                workdir: project.workdir,
                isExpanded: project.isExpanded,
                threads: doc.threads
                    .filter { $0.projectID == project.id && !$0.isArchived }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .map { thread in
                        TatwoNativeChatThread(
                            id: thread.id,
                            title: thread.title,
                            isPinned: thread.isPinned,
                            lastPreview: thread.messages.last(where: { $0.eventKind == "message" })?.text ?? "",
                            parentThreadID: thread.parentThreadID,
                            liveness: ThreadLiveness.from(
                                status: thread.subStatus,
                                lastOutputAt: thread.lastOutputAt),
                            lastOutputAt: thread.lastOutputAt,
                            engineLabel: thread.engine)
                    },
                githubRepos: project.githubRepos.map { TatwoGitHubRepoBinding(url: $0) })
        })
    }

    func transcript(for threadID: UUID?) -> [ChatMessage] {
        guard let threadID else { return [] }
        do {
            let result = try link.call(
                method: "transcript",
                params: ["threadID": threadID.uuidString])
            let records: [LiveMessageRecord] = try Self.decode(result["messages"])
            let messages = records.map(\.chatMessage)
            transcriptCache[threadID] = messages
            return messages
        } catch {
            onHint?("遙控對話讀取失敗：\(error.localizedDescription)")
            return transcriptCache[threadID] ?? []
        }
    }

    func isRunning(_ threadID: UUID?) -> Bool {
        guard let thread = threadRecord(threadID) else { return false }
        if runningThreadIDs.contains(thread.id) { return true }
        if thread.subStatus == "running" { return true }
        return thread.messages.last?.status?.hasPrefix("writing") == true
    }

    func activityDate(_ threadID: UUID) -> Date {
        threadRecord(threadID)?.updatedAt ?? .distantPast
    }

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

    func appendSystemMessage(threadID: UUID, text: String, status: String) {
        unsupported("新增系統訊息")
    }

    func setEnabledMCP(_ pluginID: String, enabled: Bool, engine: PluginsSource.MCPEngine) {
        unsupported("修改 MCP")
    }

    func newThread(in projectID: UUID?, title: String) -> UUID {
        do {
            var params: [String: Any] = ["title": title]
            if let projectID { params["projectID"] = projectID.uuidString }
            let result = try link.call(method: "new_thread", params: params)
            guard
                let raw = result["threadID"] as? String,
                let threadID = UUID(uuidString: raw)
            else { throw RemoteHostLinkError.invalidResponse }
            try refreshDocument(notify: true)
            return threadID
        } catch {
            onHint?("遙控建立討論串失敗：\(error.localizedDescription)")
            return doc.selectedThreadID ?? UUID()
        }
    }

    func newProject(name: String, workdir: String) -> UUID {
        unsupported("新增專案")
        return doc.projects.first?.id ?? UUID()
    }

    func select(_ threadID: UUID) {
        doc.selectedThreadID = threadID
    }

    func setExpanded(_ projectID: UUID, _ expanded: Bool) {
        if let index = doc.projects.firstIndex(where: { $0.id == projectID }) {
            doc.projects[index].isExpanded = expanded
            onChange?()
        }
    }

    func togglePinned(_ threadID: UUID) {
        unsupported("釘選討論串")
    }

    func rename(_ threadID: UUID, _ title: String) {
        unsupported("重新命名")
    }

    func archive(_ threadID: UUID) -> UUID? {
        unsupported("封存討論串")
        return doc.selectedThreadID
    }

    func restoreMostRecentArchivedThread() -> UUID? {
        unsupported("還原封存討論串")
        return nil
    }

    func duplicate(_ threadID: UUID, asBranch: Bool) -> UUID? {
        unsupported(asBranch ? "建立支線副本" : "複製討論串")
        return nil
    }

    func createDiscussion(parentThreadID: UUID) -> UUID? {
        unsupported("建立支線")
        return nil
    }

    func compressDiscussion(_ discussionID: UUID) -> UUID? {
        unsupported("壓縮支線")
        return nil
    }

    func mergeDiscussionIntoParent(_ discussionID: UUID) -> UUID? {
        unsupported("合併支線")
        return nil
    }

    func setGitHubRepos(_ repos: [String], for projectID: UUID) {
        unsupported("修改 GitHub 綁定")
    }

    func issues(threadID: UUID?, global: Bool) -> [TatwoIssueListEntryV1] {
        if global {
            return doc.threads.flatMap(\.issues).sorted { $0.createdAt > $1.createdAt }
        }
        guard let threadID, let thread = doc.threads.first(where: { $0.id == threadID }) else {
            return []
        }
        return thread.issues.sorted { $0.createdAt > $1.createdAt }
    }

    func addIssue(threadID: UUID, title: String, body: String) { unsupported("issue") }
    func captureIssue(threadID: UUID) {
        unsupported("新增 issue")
    }

    func updateIssue(_ id: String, _ body: (inout TatwoIssueListEntryV1) -> Void) {
        unsupported("修改 issue")
    }

    func removeIssue(_ id: String) {
        unsupported("移除 issue")
    }

    func gitSummary(
        for threadID: UUID?,
        completion: @escaping (ChatLiveEngine.GitSummary) -> Void
    ) {
        unsupported("讀取遠端 Git 狀態")
        completion(ChatLiveEngine.GitSummary())
    }

    @discardableResult func send(
        threadID: UUID,
        text: String,
        model: String?,
        engine: ClaudeSidecar.Kind,
        systemPrompt: String?,
        attachments: [String],
        reasoningEffort: String?,
        serviceTier: String?
    ) -> Bool {
        if !attachments.isEmpty {
            onHint?("遠端討論串不支援附件；已只送出文字")
        }
        do {
            var params: [String: Any] = [
                "threadID": threadID.uuidString,
                "text": text,
            ]
            if let model { params["model"] = model }
            if let reasoningEffort { params["reasoningEffort"] = reasoningEffort }
            if let serviceTier { params["serviceTier"] = serviceTier }
            // A pre-upgrade host must reject rather than silently ignore new
            // turn controls. One call, same transport; no extra polling.
            let method = reasoningEffort != nil || serviceTier != nil ? "send_message_with_options" : "send_message"
            _ = try link.call(method: method, params: params)
        } catch {
            onHint?("遙控送出失敗：\(error.localizedDescription)")
            return false
        }
        transcriptCache[threadID] = nil
        do { try refreshDocument(notify: true) }
        catch { onHint?("訊息已送出，但遠端狀態尚未更新：\(error.localizedDescription)") }
        return true
    }

    func stop(threadID: UUID) {
        do {
            _ = try link.call(
                method: "stop_thread",
                params: ["threadID": threadID.uuidString])
            try refreshDocument(notify: true)
        } catch {
            onHint?("遙控停止失敗：\(error.localizedDescription)")
        }
    }

    func pushThread(
        projectName: String?,
        title: String,
        messages: [RemoteThreadTransferMessage],
        files: [RemoteThreadTransferFile]
    ) throws -> UUID {
        var params: [String: Any] = [
            "title": title,
            "messages": try Self.jsonObject(messages),
            "files": try Self.jsonObject(files),
        ]
        if let projectName { params["projectName"] = projectName }
        let result = try link.call(method: "push_thread", params: params)
        guard
            let rawThreadID = result["threadID"] as? String,
            let threadID = UUID(uuidString: rawThreadID)
        else {
            throw RemoteHostLinkError.invalidResponse
        }
        try refreshDocument(notify: true)
        return threadID
    }

    func pullThread(
        threadID: UUID
    ) throws -> (
        projectName: String?,
        title: String,
        messages: [RemoteThreadTransferMessage],
        files: [RemoteThreadTransferFile]
    ) {
        let result = try link.call(
            method: "pull_thread",
            params: ["threadID": threadID.uuidString])
        guard let title = result["title"] as? String else {
            throw RemoteHostLinkError.invalidResponse
        }
        let messages: [RemoteThreadTransferMessage] = try Self.decode(result["messages"])
        let files: [RemoteThreadTransferFile] = try Self.decode(result["files"])
        try refreshDocument(notify: true)
        return (result["projectName"] as? String, title, messages, files)
    }

    func shutdownAll() {
        pollTask?.cancel()
        pollTask = nil
        link.disconnect()
    }

    func configureRoom(
        threadID: UUID,
        parentThreadID: UUID,
        roomBrief: String,
        engine: String,
        cwdOverride: String,
        deviceID: String?
    ) {
        unsupported("設定派工房間")
    }

    func sidecarProcessID(threadID: UUID) -> Int32? {
        nil
    }

    private func unsupported(_ action: String) {
        onHint?("遠端討論串不支援 \(action)")
    }

    private func refreshDocument(notify: Bool) throws {
        let result = try link.call(method: "get_document", params: [:])
        try apply(result: result, notify: notify)
    }

    private func apply(result: [String: Any], notify: Bool) throws {
        let fetched: LiveDocumentRecord = try Self.decode(result["document"])
        let fetchedRevision = (result["revision"] as? NSNumber)?.int64Value ?? 0
        runningThreadIDs = Set(
            (result["runningThreadIDs"] as? [String] ?? [])
                .compactMap(UUID.init(uuidString:)))
        let changed = fetchedRevision != revision
        doc = fetched
        revision = fetchedRevision
        currentRevision = fetchedRevision
        onConnectionStateChange?(.success(fetchedRevision))
        guard notify, changed else { return }
        transcriptCache.removeAll(keepingCapacity: true)
        onChange?()
    }

    private static func decode<T: Decodable>(_ value: Any?) throws -> T {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            throw RemoteHostLinkError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
}
