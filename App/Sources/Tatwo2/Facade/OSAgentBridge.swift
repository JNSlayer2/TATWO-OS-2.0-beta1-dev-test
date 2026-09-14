import Foundation
import CoreFoundation
import Darwin

/// App-local OS 派工橋（ultrawork 2.0 第 2 步）。跟 BrowserAgentBridge 同款寫法：0600 UNIX socket，
/// 只轉房間／討論串中繼資料（標題、引擎、活性、worktree 路徑），不帶任何密鑰。
final class OSAgentBridge: @unchecked Sendable {
    static let shared = OSAgentBridge()

    private weak var model: ChatPageModel?
    private var botTestLibrary: BotLibrary?
    // In-process test fixture only; does not expose an environment-enabled confirmation bypass.
    func startBotCoreTest(library: BotLibrary) {
        botTestLibrary = library
        queue.async { [weak self] in self?.listen() }
    }
    /// Owned real-library acceptance seam; does not start or replace a socket.
    static func botCoreTestBridge(library: BotLibrary) -> OSAgentBridge {
        let bridge = OSAgentBridge()
        bridge.botTestLibrary = library
        return bridge
    }
    // App-only entrypoints. perform(method:) intentionally has no matching MCP cases.
    @MainActor func confirmBotMemory(botID: String, pendingID: String) async throws {
        guard let library = model?.botLibraryForBridge else { throw BotLibraryError.invalid("bot_library_unavailable") }
        try await BotMemory(library: library).confirm(botID: botID, pendingID: pendingID)
    }
    @MainActor func rejectBotMemory(botID: String, pendingID: String) async throws {
        guard let library = model?.botLibraryForBridge else { throw BotLibraryError.invalid("bot_library_unavailable") }
        try await BotMemory(library: library).reject(botID: botID, pendingID: pendingID)
    }
    @MainActor func forgetBotMemory(botID: String, memoryID: String) async throws {
        guard let library = model?.botLibraryForBridge else { throw BotLibraryError.invalid("bot_library_unavailable") }
        try await BotMemory(library: library).forget(botID: botID, memoryID: memoryID)
    }
    private func awaitBot<T>(_ operation: @escaping () async throws -> T) throws -> T {
        precondition(!Thread.isMainThread)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        Task.detached { do { result = .success(try await operation()) } catch { result = .failure(error) }; semaphore.signal() }
        semaphore.wait()
        return try result!.get()
    }

    private let queue = DispatchQueue(label: "ai.tatwo.tatwo2.os-agent", qos: .userInitiated)
    private let computerQueue = DispatchQueue(label: "ai.tatwo.tatwo2.computer", qos: .userInitiated, attributes: .concurrent)
    private let computerSlots = DispatchSemaphore(value: 2)
    private let stateLock = NSLock()
    private var listenerFD: Int32 = -1
    private var listenerStarting = false
    private var backgroundJobs: BackgroundJobManager?
    private var jobsTestThreads: Set<UUID> = []
    private var jobsTestArtifacts: TurnArtifacts?

    /// In-process acceptance seam only; never starts a socket or launches an engine.
    static func jobsTestBridge(manager: BackgroundJobManager, artifacts: TurnArtifacts, threads: Set<UUID>) -> OSAgentBridge {
        let bridge = OSAgentBridge()
        bridge.backgroundJobs = manager
        bridge.jobsTestArtifacts = artifacts
        bridge.jobsTestThreads = threads
        return bridge
    }

    private func jobsCaller(_ params: [String: Any]) throws -> (id: UUID, source: String) {
        let id: UUID
        let source: String
        if let raw = params["callerThreadID"] {
            guard let text = raw as? String, let parsed = UUID(uuidString: text) else { throw BridgeError.invalidParams }
            id = parsed; source = "caller"
        } else {
            if jobsTestArtifacts != nil { throw BridgeError.noParentThread }
            guard let selected = onMain({ [weak self] in self?.model?.selectedThreadID }) else { throw BridgeError.noParentThread }
            id = selected; source = "selected"
        }
        if jobsTestThreads.contains(id) { return (id, source) }
        let exists = onMain { [weak self] in self?.model?.live?.threadRecord(id) != nil }
        guard exists else { throw BridgeError.invalidParams }
        return (id, source)
    }

    /// Only expose the existing manager; Island must never create one.
    @MainActor func backgroundJobSnapshot(includeLastLine: Bool = true) async -> [BackgroundJobManager.Snapshot] {
        guard let manager = backgroundJobs else { return [] }
        return await manager.snapshot(includeLastLine: includeLastLine)
    }

    private init() {}

    @MainActor func configureCallerTest(model: ChatPageModel, manager: BackgroundJobManager) {
        self.model = model
        ComputerUseController.shared.consentPolicyProvider = { [weak model] caller in
            guard let model, let thread = model.live?.threadRecord(caller) else { return .askOncePerSession }
            return .resolve(user: model.permissionPreset, bot: thread.botPermissionPreset,
                            readOnly: thread.roomReadOnly == true)
        }
        self.backgroundJobs = manager
    }

    var socketPath: String { Self.resolveSocketPath() }

    /// 這個 App 實際使用的 OS 橋位址（給 sidecar 傳進 MCP 子程序，MCP 才不會退回正式預設路徑）。
    static func resolveSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["TATWO2_OS_SOCKET"], !override.isEmpty {
            return override
        }
        if let root = environment["TATWO2_LIVE_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("os.sock").path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tatwo2/live/os.sock").path
    }

    @MainActor
    func start(model: ChatPageModel) {
        self.model = model
        ComputerUseController.shared.consentPolicyProvider = { [weak model] caller in
            guard let model, let thread = model.live?.threadRecord(caller) else { return .askOncePerSession }
            return .resolve(user: model.permissionPreset, bot: thread.botPermissionPreset,
                            readOnly: thread.roomReadOnly == true)
        }
        if backgroundJobs == nil {
            let manager = BackgroundJobManager()
            manager.onCompletion = { [weak self] job in
                self?.model?.receiveLocalBackgroundCompletion(job)
            }
            backgroundJobs = manager
        }
        stateLock.lock()
        let alreadyStarted = listenerStarting || listenerFD >= 0
        if !alreadyStarted { listenerStarting = true }
        stateLock.unlock()
        guard !alreadyStarted else { return }
        queue.async { [weak self] in self?.listen() }
    }

    private func listen() {
        defer {
            stateLock.lock()
            listenerStarting = false
            stateLock.unlock()
        }
        let path = socketPath
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fputs("os_agent_bridge_error=create_directory_failed\n", stderr)
            return
        }
        _ = unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fputs("os_agent_bridge_error=socket_failed\n", stderr)
            return
        }
        // PTYs must not inherit bridge listeners across exec.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        let copied = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strlcpy(destination, source, sunPathSize)
            }
        }
        guard copied < sunPathSize else {
            close(fd)
            fputs("os_agent_bridge_error=socket_path_too_long\n", stderr)
            return
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            _ = unlink(path)
            fputs("os_agent_bridge_error=bind_or_listen_failed\n", stderr)
            return
        }
        _ = chmod(path, S_IRUSR | S_IWUSR)
        stateLock.lock(); listenerFD = fd; stateLock.unlock()
        fputs("os_agent_bridge_socket=\(path)\n", stderr)
        while true {
            let client = accept(fd, nil, nil)
            if client >= 0 {
                // cli_open may fork before this request returns; otherwise Node waits for the shell to close its inherited socket.
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                // 客戶端提早斷線時，寫回應不可以讓整個 App 吃 SIGPIPE 死掉（實機驗收 2026-09-04 踩到）
                var on: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            }
            if client < 0 { continue }
            autoreleasepool { handle(clientFD: client) }
        }
    }

    private func handle(clientFD: Int32) {
        let handle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: true)
        let input = (try? handle.readToEnd()) ?? Data()
        guard let line = String(data: input, encoding: .utf8)?
            .split(whereSeparator: \.isNewline).first,
              let data = String(line).data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            write(["id": NSNull(), "ok": false, "error": "bad_request"], to: handle)
            return
        }
        let id = request["id"] ?? NSNull()
        guard let method = request["method"] as? String else {
            write(["id": id, "ok": false, "error": "missing_method"], to: handle)
            return
        }
        let params = request["params"] as? [String: Any] ?? [:]
        if method == "computer_stop" {
            // Revocation must not compete with capture/action slots. Caller and
            // current scope still pass through the same native validation.
            let connected: @Sendable () -> Bool = {
                ComputerUseConnection.isAlive(handle.fileDescriptor)
            }
            do {
                let result = try perform(method: method, params: params, computerConnection: connected)
                write(["id": id, "ok": true, "result": result], to: handle)
            } catch {
                write(["id": id, "ok": false, "error": (error as? LocalizedError)?.errorDescription ?? String(describing: error)], to: handle)
            }
            return
        }
        if method.hasPrefix("computer_") {
            // Native consent/capture must not occupy the shared OS accept loop.
            // Bound this lane independently; local UI stop uses neither queue.
            guard computerSlots.wait(timeout: .now()) == .success else {
                write(["id": id, "ok": false, "error": "computer_busy"], to: handle)
                return
            }
            computerQueue.async { [self, handle] in
                defer { computerSlots.signal() }
                let connected: @Sendable () -> Bool = {
                    ComputerUseConnection.isAlive(handle.fileDescriptor)
                }
                do {
                    let result = try perform(method: method, params: params, computerConnection: connected)
                    write(["id": id, "ok": true, "result": result], to: handle)
                } catch {
                    write(["id": id, "ok": false, "error": (error as? LocalizedError)?.errorDescription ?? String(describing: error)], to: handle)
                }
            }
            return
        }
        let response: [String: Any]
        do {
            response = ["id": id, "ok": true, "result": try perform(method: method, params: params)]
        } catch {
            response = ["id": id, "ok": false, "error": String(describing: error)]
        }
        write(response, to: handle)
    }

    private func write(_ value: [String: Any], to handle: FileHandle) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private enum BridgeError: Error, CustomStringConvertible {
        case invalidParams, noParentThread, remoteAccessDisabled, unsupportedMethod
        var description: String {
            switch self {
            case .invalidParams: "invalid_params"
            case .noParentThread: "no_parent_thread_selected"
            case .remoteAccessDisabled: "remote_access_disabled_no_paired_devices"
            case .unsupportedMethod: "unsupported_method"
            }
        }
    }

    private static let ownedMethods: Set<String> = [
        "whoami", "run_background", "background_status", "stop_background", "dispatch_rooms",
        "list_rooms", "stop_room", "stop_all_rooms", "merge_reports", "reclaim_room", "cli_open", "os_binding_status"
    ]

    private func perform(method: String, params: [String: Any],
                         computerConnection: (@Sendable () -> Bool)? = nil) throws -> [String: Any] {
        var resolved = params
        if Self.ownedMethods.contains(method) {
            let owner: UUID
            if let supplied = params["callerThreadID"] {
                guard let raw = supplied as? String, let id = UUID(uuidString: raw) else { throw BridgeError.invalidParams }
                owner = id
            } else {
                guard let selected = onMain({ [weak self] in self?.model?.selectedThreadID }) else { throw BridgeError.noParentThread }
                owner = selected
            }
            // 無頭驗收（jobs-index 的 TurnArtifacts 測試）沒有 model；那時只信 callerThreadID，不進主執行緒查對話（合併時 Fable 加：dispatchMain 下 assumeIsolated 會炸）
            if model != nil {
                guard onMain({ [weak self] in self?.model?.live?.threadRecord(owner) != nil }) else { throw BridgeError.invalidParams }
            }
            resolved["callerThreadID"] = owner.uuidString
            var result = try performResolved(method: method, params: resolved)
            result["ownerSource"] = params["callerThreadID"] == nil ? "selected" : "caller"
            return result
        }
        return try performResolved(method: method, params: params, computerConnection: computerConnection)
    }

    private func performResolved(method: String, params: [String: Any],
                                 computerConnection: (@Sendable () -> Bool)? = nil) throws -> [String: Any] {
        let owner = (params["callerThreadID"] as? String).flatMap(UUID.init(uuidString:))
        if Self.remoteMethods.contains(method) {
            let allowed = onMain { [weak self] in
                !(self?.model?.deviceRecordsForBridge() ?? []).isEmpty
            }
            guard allowed else { throw BridgeError.remoteAccessDisabled }
        }
        switch method {
        case "bot_list", "bot_get", "bot_state_get", "bot_state_update", "bot_remember", "bot_profile", "bot_pending_list":
            let library = botTestLibrary ?? onMain { [weak self] in self?.model?.botLibraryForBridge }
            guard let library else { throw BotLibraryError.invalid("bot_library_unavailable") }
            try awaitBot { await library.ready() }
            if method == "bot_list" {
                let bots = library.list()
                let isolated = botTestLibrary != nil || onMain { [weak self] in
                    !(self?.model?.osBindingEnvironment["TATWO2_LIVE_ROOT"] ?? "").isEmpty
                }
                return ["bots": try Self.jsonObject(bots), "scope": [
                    "instance": isolated ? "isolated" : "app",
                    "libraryRoot": library.root.standardizedFileURL.pathComponents.filter { $0 != "/" }.suffix(2).joined(separator: "/"),
                    "reason": bots.isEmpty ? "no_bots_in_library" : ""
                ]]
            }
            let callerThread = ((params["callerThreadID"] ?? params["_threadID"]) as? String).flatMap(UUID.init(uuidString:))
            let boundID: String? = callerThread.flatMap { thread in
                onMain { [weak self] in self?.model?.botIDForBridge(threadID: thread) }
                    ?? library.snapshot.sessions.first(where: { $0.value.contains(where: { $0.threadID == thread.uuidString }) })?.key
            }
            let id = params["id"] as? String ?? boundID
            if method == "bot_pending_list" {
                if id == nil {
                    return ["pending": [], "scope": ["threadIsBot": false, "boundBotID": NSNull(),
                        "canProceed": false, "hint": "這條對話不是 bot；帶 id 只能查自己綁定的 bot"]]
                }
                guard let boundID, boundID == id else { throw BotLibraryError.invalid("pending_requires_own_bot") }
            }
            guard let id else { throw BotLibraryError.invalid("這條對話不是 bot") }
            guard let bot = library.bot(id: id) else { throw BotLibraryError.invalid("bot_not_found") }
            let memory = BotMemory(library: library)
            switch method {
            case "bot_get": return ["bot": try Self.jsonObject(bot), "instructions": library.snapshot.instructions[id] ?? ""]
            case "bot_pending_list":
                guard let boundID, boundID == id else { throw BotLibraryError.invalid("pending_requires_own_bot") }
                return ["pending": try Self.jsonObject(memory.pendingList(botID: id))]
            case "bot_profile": return ["profile": try Self.jsonObject(memory.profile(botID: id))]
            case "bot_state_get": return ["state": try Self.jsonObject(memory.state(botID: id) ?? BotMemoryState())]
            case "bot_remember":
                guard let text = params["text"] as? String else { throw BridgeError.invalidParams }
                let pending = try awaitBot { try await memory.remember(botID: id, text: text, threadID: callerThread?.uuidString ?? "unknown") }
                return ["pendingID": pending, "status": "pending", "message": "待使用者在 App 確認；尚未寫入長期記憶"]
            default:
                if params["currentTask"] != nil && !(params["currentTask"] is String) { throw BridgeError.invalidParams }
                if params["nextSteps"] != nil && !(params["nextSteps"] is [String]) { throw BridgeError.invalidParams }
                if params["openQuestions"] != nil && !(params["openQuestions"] is [String]) { throw BridgeError.invalidParams }
                let patch = BotMemoryStatePatch(currentTask: params["currentTask"] as? String, nextSteps: params["nextSteps"] as? [String], openQuestions: params["openQuestions"] as? [String], lastThreadID: callerThread?.uuidString)
                var baseVersion: Int?
                if let raw = params["baseVersion"] {
                    guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                          n.doubleValue >= 0, n.doubleValue < Double(Int.max),
                          n.doubleValue.rounded(.towardZero) == n.doubleValue else { throw BridgeError.invalidParams }
                    baseVersion = n.intValue
                }
                let result = try awaitBot { try await memory.updateState(botID: id, patch: patch, baseVersion: baseVersion) }
                if result.conflict { return ["conflict": true, "current": try Self.jsonObject(result.current), "yours": try Self.jsonObject(patch)] }
                return ["state": try Self.jsonObject(result.current)]
            }
        case "cli_sessions_list":
            let records = onMain { [weak self] in self?.model?.cliSessionStore?.sessions ?? [] }
            return ["sessions": try Self.jsonObject(records)]
        case "os_binding_status":
            // Read-only（Goal #7 擴充點）：只回 metadata；不回 original／diff／規則全文；沒有 write／apply。
            // 只接受 bridge 注入的 callerThreadID；使用者帶任何參數（path／target／environment…）一律拒絕。
            guard Set(params.keys).isSubset(of: ["callerThreadID"]), owner != nil else { throw BridgeError.invalidParams }
            let environment: [String: String] = try onMainThrowing { [weak self] in
                guard let model = self?.model else { throw BridgeError.invalidParams }
                return model.osBindingEnvironment   // 只在主執行緒抓 env；讀檔在 bridge queue
            }
            let preview = OSUpstreamBinding.preview(environment: environment)
            return [
                "osRoot": preview.root,
                "upstreamHash": OSUpstreamBinding.upstreamHash(environment: environment),
                "seed": preview.seed,
                "error": preview.error ?? NSNull() as Any,
                "writable": false,
                "items": preview.items.map { item -> [String: Any] in
                    ["id": item.target.id, "label": item.target.label, "path": item.path, "state": item.state.rawValue,
                     "currentBlockHash": item.currentBlockHash ?? NSNull() as Any, "expectedHash": item.expectedHash,
                     "error": item.error ?? NSNull() as Any]
                }
            ]
        case "whoami":
            var result: [String: Any] = try onMainThrowing { [weak self] in
                guard let model = self?.model, let live = model.live, let owner,
                      let thread = live.threadRecord(owner) else { throw BridgeError.invalidParams }
                return [
                    "threadID": owner.uuidString,
                    "parentThreadID": thread.parentThreadID?.uuidString ?? NSNull() as Any,
                    "botID": model.botIDForBridge(threadID: owner) ?? NSNull() as Any,
                    "callerWorktree": thread.cwdOverride ?? NSNull() as Any,
                    "projectWorkdir": live.projectRecord(thread.projectID)?.workdir ?? NSNull() as Any,
                    "cwd": thread.cwdOverride ?? live.projectRecord(thread.projectID)?.workdir ?? NSNull() as Any,
                    "engine": thread.engine ?? NSNull() as Any,
                    "permissions": ["approval": thread.botPermissionPreset?.rawValue ?? NSNull() as Any,
                                    "mcp": thread.enabledMCP.isEmpty ? NSNull() : (thread.enabledMCP == ["__tatwo_none__"] ? [] : thread.enabledMCP) as Any]
                ]
            }
            result["upstream"] = CallerUpstream.identity()
            return result
        case "cli_open":
            var isDirectory: ObjCBool = false
            guard let cwd = params["cwd"] as? String, cwd.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { throw BridgeError.invalidParams }
            return try onMainThrowing { [weak self] in
                guard let model = self?.model else { throw BridgeError.invalidParams }
                guard let id = model.openCLITab(engine: .generic, workdir: cwd, callerThreadID: owner) else { throw BridgeError.invalidParams }
                if let title = params["title"] as? String { model.renameCLITab(id, title: title) }
                return ["id": id.uuidString, "readWith": "cli_tail"]
            }
        case "cli_send", "cli_tail", "cli_close":
            guard let raw = params["id"] as? String, let id = UUID(uuidString: raw) else { throw BridgeError.invalidParams }
            let cliModel: ChatPageModel = try onMainThrowing { [weak self] in
                guard let model = self?.model, model.cliSessionStore?.sessions.contains(where: { $0.id == id }) == true
                else { throw BridgeError.invalidParams }
                return model
            }
            return try awaitBot {
                if method == "cli_tail" {
                    let lines = max(0, min(params["lines"] as? Int ?? 80, 10000))
                    let text = await cliModel.cliWorkbenchTail(id)
                    return ["id": raw, "text": CLISessionStore.textTail(text, lines: lines)]
                }
                if method == "cli_send" {
                    guard let text = params["text"] as? String,
                          let session = await cliModel.cliTabPTYSession(for: id) else { throw BridgeError.invalidParams }
                    try await session.sendLineAwaited(text)
                    return Self.cliSendReceipt(id: raw)
                }
                try await cliModel.terminateCLIWorkbenchPane(id)
                return ["closed": true]
            }
        case "get_document":
            let snapshot: (LiveDocumentRecord, URL, [String])? = onMain { [weak self] in
                guard let live = self?.model?.live else { return nil }
                let snapshot = Self.snapshot(live)
                if !Self.documentsEqual(snapshot, live.store.load()) {
                    live.store.save(snapshot)
                }
                let runningThreadIDs = snapshot.threads
                    .filter { live.isRunning($0.id) }
                    .map { $0.id.uuidString }
                return (snapshot, live.store.url, runningThreadIDs)
            }
            guard let snapshot else { throw BridgeError.invalidParams }
            let attributes = try? FileManager.default.attributesOfItem(atPath: snapshot.1.path)
            let modifiedAt = attributes?[.modificationDate] as? Date ?? .distantPast
            return [
                "document": try Self.jsonObject(snapshot.0),
                "revision": Int64(modifiedAt.timeIntervalSince1970 * 1_000),
                "runningThreadIDs": snapshot.2,
            ]
        case "transcript":
            guard
                let rawThreadID = params["threadID"] as? String,
                let threadID = UUID(uuidString: rawThreadID)
            else { throw BridgeError.invalidParams }
            let messages: [LiveMessageRecord] = onMain { [weak self] in
                (self?.model?.live?.transcript(for: threadID) ?? []).map(LiveMessageRecord.init)
            }
            return ["messages": try Self.jsonObject(messages)]
        case "send_message", "send_message_with_options":
            guard
                let rawThreadID = params["threadID"] as? String,
                let threadID = UUID(uuidString: rawThreadID),
                let text = params["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw BridgeError.invalidParams }
            let modelArgument = params["model"] as? String
            let reasoningEffort = params["reasoningEffort"] as? String
            let serviceTier = params["serviceTier"] as? String
            // Native catalogs own the supported values; this boundary validates
            // shape without freezing future model capabilities into an OS list.
            guard params["reasoningEffort"] == nil || reasoningEffort?.isEmpty == false,
                  params["serviceTier"] == nil || serviceTier?.isEmpty == false,
                  method != "send_message_with_options" || reasoningEffort != nil || serviceTier != nil else {
                throw BridgeError.invalidParams
            }
            try onMainThrowing { [weak self] in
                guard let live = self?.model?.live, live.threadRecord(threadID) != nil else {
                    throw BridgeError.invalidParams
                }
                let engine: ClaudeSidecar.Kind
                if let modelArgument {
                    let lowered = modelArgument.lowercased()
                    if lowered.contains("claude") {
                        engine = .claude
                    } else if lowered.contains("grok") {
                        engine = .grok
                    } else {
                        engine = .codex
                    }
                } else {
                    engine = live.threadRecord(threadID)?.engine.flatMap(ClaudeSidecar.Kind.init(rawValue:))
                        ?? .claude
                }
                guard engine == .codex || (reasoningEffort == nil && serviceTier == nil) else { throw BridgeError.invalidParams }
                guard live.send(
                    threadID: threadID,
                    text: text,
                    model: modelArgument,
                    engine: engine,
                    systemPrompt: nil,
                    attachments: [],
                    reasoningEffort: reasoningEffort,
                    serviceTier: serviceTier) else {
                    throw BridgeError.invalidParams
                }
                live.store.save(Self.snapshot(live))
            }
            return ["sent": true]
        case "new_thread":
            let projectID: UUID?
            if let rawProjectID = params["projectID"] as? String {
                guard let parsed = UUID(uuidString: rawProjectID) else { throw BridgeError.invalidParams }
                projectID = parsed
            } else {
                projectID = nil
            }
            let rawTitle = (params["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let threadID: UUID = try onMainThrowing { [weak self] in
                guard let live = self?.model?.live else { throw BridgeError.invalidParams }
                if let projectID, live.projectRecord(projectID) == nil { throw BridgeError.invalidParams }
                return live.newThread(
                    in: projectID,
                    title: rawTitle?.isEmpty == false ? rawTitle! : "新聊天")
            }
            return ["threadID": threadID.uuidString]
        case "stop_thread":
            guard
                let rawThreadID = params["threadID"] as? String,
                let threadID = UUID(uuidString: rawThreadID)
            else { throw BridgeError.invalidParams }
            let stopped: Bool = try onMainThrowing { [weak self] in
                guard let live = self?.model?.live, live.threadRecord(threadID) != nil else {
                    throw BridgeError.invalidParams
                }
                live.stop(threadID: threadID)
                return !live.isRunning(threadID)
            }
            return ["stopRequested": true, "stopped": stopped]
        case "push_thread":
            guard
                let title = params["title"] as? String,
                let rawMessages = params["messages"]
            else { throw BridgeError.invalidParams }
            let messages: [RemoteThreadTransferMessage] = try Self.decode(rawMessages)
            let files: [RemoteThreadTransferFile]
            if let rawFiles = params["files"] {
                files = try Self.decode(rawFiles)
            } else {
                files = []
            }
            let threadID: UUID = try onMainThrowing { [weak self] in
                guard let live = self?.model?.live as? ChatLiveEngine else {
                    throw BridgeError.invalidParams
                }
                return try live.importTransferredThread(
                    projectName: params["projectName"] as? String,
                    title: title,
                    messages: messages,
                    files: files)
            }
            return ["threadID": threadID.uuidString]
        case "pull_thread":
            guard
                let rawThreadID = params["threadID"] as? String,
                let threadID = UUID(uuidString: rawThreadID)
            else { throw BridgeError.invalidParams }
            let transfer: (
                projectName: String?,
                title: String,
                messages: [RemoteThreadTransferMessage],
                files: [RemoteThreadTransferFile]
            ) = try onMainThrowing { [weak self] in
                guard
                    let live = self?.model?.live as? ChatLiveEngine,
                    let thread = live.threadRecord(threadID),
                    let project = live.projectRecord(thread.projectID)
                else { throw BridgeError.invalidParams }
                live.appendSystemMessage(
                    threadID: threadID,
                    text: "這條討論串已被另一台設備拉走一份副本（訊息與有改動的檔案）；這裡的原件不變。",
                    status: "info|設備搬移")
                return (
                    project.name,
                    thread.title,
                    live.transcript(for: threadID).map(RemoteThreadTransferMessage.init),
                    RemoteThreadTransfer.changedFiles(in: thread.cwdOverride ?? project.workdir))
            }
            return [
                "projectName": transfer.projectName ?? NSNull(),
                "title": transfer.title,
                "messages": try Self.jsonObject(transfer.messages),
                "files": try Self.jsonObject(transfer.files),
            ]
        case "dispatch_rooms":
            guard let rawRooms = params["rooms"] as? [[String: Any]], !rawRooms.isEmpty else { throw BridgeError.invalidParams }
            let specs: [RoomSpec] = try rawRooms.map { row in
                guard let title = row["title"] as? String, let engine = row["engine"] as? String, let brief = row["brief"] as? String else {
                    throw BridgeError.invalidParams
                }
                if let value = row["readOnly"],
                   !(value is NSNumber) || CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() {
                    throw BridgeError.invalidParams
                }
                return RoomSpec(title: title, engine: engine, model: row["model"] as? String, brief: brief,
                                device: row["device"] as? String, readOnly: row["readOnly"] as? Bool ?? false)
            }
            let dispatched: [DispatchedRoom] = try onMainThrowing { [weak self] in
                guard let self, let model = self.model, let parent = owner else {
                    throw BridgeError.noParentThread
                }
                return try model.dispatchChecked(rooms: specs, parent: parent)
            }
            guard !dispatched.isEmpty else { throw BridgeError.noParentThread }
            return ["rooms": dispatched.map { room -> [String: Any] in
                ["roomID": room.roomID, "threadID": room.threadID, "worktree": room.worktree,
                 "branch": room.branch, "readOnly": room.readOnly, "cwd": room.workingDirectory ?? room.worktree]
            }]
        case "list_rooms":
            // Capture only in-memory fields on the main actor; no filesystem or du here.
            let captured: [(DispatchRoom, String?, String?, String?, Bool)] = onMain { [weak self] in
                guard let model = self?.model else { return [] }
                return model.document.projects.lazy.flatMap(\.threads).filter { $0.parentThreadID == owner }.prefix(1000).map { t in
                    (DispatchRoom(id: t.id, title: t.title, engineLabel: t.engineLabel ?? "",
                                  liveness: t.liveness ?? .idle, lastOutputAt: t.lastOutputAt,
                                  reportAvailable: t.liveness == .done, deviceLabel: model.live?.threadRecord(t.id)?.deviceID.flatMap { id in model.devices.first(where: { $0.id == id })?.name }),
                     model.live?.threadRecord(t.id)?.roomReadOnly == true ? nil : model.live?.threadRecord(t.id)?.cwdOverride,
                     model.live?.projectRecord(model.live?.threadRecord(t.id)?.projectID)?.workdir,
                     model.live?.threadRecord(t.id)?.requestedModel,
                     model.live?.threadRecord(t.id)?.roomReadOnly == true)
                }
            }
            var mergeChecks = 0
            // 整次請求共用時間預算：MCP 端 45 秒逾時，這裡最多花 8 秒查合併狀態；超過預算的列保留「未查」（checkedAt 空）。
            let mergeDeadline = ProcessInfo.processInfo.systemUptime + 8
            return ["rooms": captured.map { room, path, projectWorkdir, requestedModel, readOnly -> [String: Any] in
                let branch = Self.worktreeBranch(path)
                var merge: [String: Any] = ["merged": false, "commit": "", "checkedAt": ""]
                if room.liveness == .done, !branch.isEmpty, let projectWorkdir, mergeChecks < 50,
                   ProcessInfo.processInfo.systemUptime < mergeDeadline {
                    mergeChecks += 1
                    let work = DispatchWorkItem { merge = Self.mergeReceipt(branch: branch, workdir: projectWorkdir, deadline: mergeDeadline) }
                    Self.mergeQueue.async(execute: work)
                    work.wait()
                }
                let size = CallerDirectoryCache.shared.snapshot(path)
                return ["roomID": room.id.uuidString, "title": room.title, "engine": room.engineLabel,
                        "liveness": room.liveness.rawValue,
                        "lastOutputAt": room.lastOutputAt.map { Self.iso8601.string(from: $0) } ?? "",
                        "reportAvailable": room.reportAvailable,
                        "branch": branch, "merge": merge, "readOnly": readOnly,
                        // 派工時要求的模型（dispatch-hygiene 持久化欄位）；沒有就空字串，不拿目前可變的 model 冒充。
                        "requestedModel": requestedModel ?? "",
                        "dispatchedBy": owner?.uuidString ?? "",
                        "worktreeExists": path.map { FileManager.default.fileExists(atPath: $0) } ?? false,
                        // Timestamp belongs to the last successful measurement, never this query.
                        "sizeMeasuredAt": size.measuredAt.map { Self.iso8601.string(from: $0) } ?? "",
                        "worktreeSizeMB": size.megabytes, "sizeStale": size.isStale(), "device": room.deviceLabel ?? ""]
            }]
        case "select_thread":   // 自動化／驗收用：把畫面切到某條對話
            guard let raw = params["threadID"] as? String, let id = UUID(uuidString: raw) else { throw BridgeError.invalidParams }
            onMain { [weak self] in self?.model?.selectLocalThread(id) }
            return ["ok": true]
        case "github_import_from_gh":   // 本機自動化用：讓 App 自己建立 Keychain 項目，ACL 才會信任這個 App
            onMain { [weak self] in self?.model?.importGitHubAccountsFromGH() }
            return ["ok": true]
        case "list_devices":
            let devices: [DeviceRecord] = onMain { [weak self] in
                self?.model?.deviceRecordsForBridge() ?? DeviceRegistry().list()
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(devices),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return ["devices": []] }
            return ["devices": rows]
        case "computer_list_apps", "computer_start", "computer_observe", "computer_action", "computer_batch", "computer_stop":
            // Unlike legacy room tools, this lane never infers caller identity
            // from the currently selected tab and is unavailable headlessly.
            guard let raw = params["callerThreadID"] as? String, let caller = UUID(uuidString: raw),
                  let computerConnection, computerConnection(),
                  let model = onMain({ [weak self] in self?.model }) else { throw BridgeError.invalidParams }
            return try awaitBot {
                try await model.performComputerTool(method, params: params, caller: caller, requestIsConnected: computerConnection)
            }
        case "ipad_prepare", "ipad_status", "ipad_screenshot", "ipad_open_app", "ipad_touch", "ipad_stop":
            guard let raw = params["callerThreadID"] as? String, let caller = UUID(uuidString: raw),
                  onMain({ [weak self] in self?.model?.live?.threadRecord(caller) != nil }) else { throw BridgeError.invalidParams }
            return try awaitBot {
                try await IPadUseController.shared.perform(method, params: params, caller: caller)
            }
        case "run_background":
            guard params["requestKey"] == nil || params["requestKey"] is String, let command = params["cmd"] as? String else { throw BridgeError.invalidParams }
            let context: (UUID, String)? = onMain { [weak self] in
                guard let model = self?.model, let live = model.live, let threadID = owner,
                      let thread = live.threadRecord(threadID) else { return nil }
                let cwd = (params["cwd"] as? String) ?? thread.cwdOverride ?? live.projectRecord(thread.projectID)?.workdir ?? NSHomeDirectory()
                return (threadID, cwd)
            }
            guard let context else { throw BridgeError.noParentThread }
            guard let manager = backgroundJobs else { throw BridgeError.unsupportedMethod }
            let title = (params["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return manager.response(try manager.run(command: command, cwd: context.1, title: title?.isEmpty == false ? title! : command, threadID: context.0, requestKey: params["requestKey"] as? String))
        case "background_list":
            let caller = try jobsCaller(params)
            guard let manager = backgroundJobs else { throw BridgeError.unsupportedMethod }
            return ["jobs": manager.list(threadID: caller.id), "ownerSource": caller.source]
        case "artifacts_list":
            let caller = try jobsCaller(params)
            if let raw = params["turnID"], !(raw is String) { throw BridgeError.invalidParams }
            let turn = params["turnID"] as? String
            guard turn == nil || (turn!.utf8.count <= 1024 && !turn!.isEmpty) else { throw BridgeError.invalidParams }
            let artifacts = jobsTestArtifacts ?? onMain { [weak self] in
                (self?.model?.live as? ChatLiveEngine)?.turnArtifacts
            }
            guard let artifacts else { throw BridgeError.unsupportedMethod }
            let index = try awaitBot { try await artifacts.list(threadID: caller.id, turnID: turn) }
            guard let index else { return ["artifacts": [], "turnID": turn as Any? ?? NSNull(), "ownerSource": caller.source] }
            var value = try Self.jsonObject(index) as? [String: Any] ?? [:]
            value["ownerSource"] = caller.source
            return value
        case "background_status":
            guard let text = params["jobID"] as? String, let id = UUID(uuidString: text),
                  let manager = backgroundJobs, let record = manager.status(jobID: id), record.threadID == owner else { throw BridgeError.invalidParams }
            if let raw = params["tailBytes"], !(raw is Int) { throw BridgeError.invalidParams }
            return manager.response(record, tailBytes: params["tailBytes"] as? Int ?? 8192)
        case "stop_background":
            guard let text = params["jobID"] as? String, let id = UUID(uuidString: text),
                  let manager = backgroundJobs, manager.status(jobID: id)?.threadID == owner, let record = manager.stop(jobID: id) else { throw BridgeError.invalidParams }
            return manager.response(record)
        case "reclaim_room":
            guard let roomIDText = params["roomID"] as? String, let roomID = UUID(uuidString: roomIDText) else { throw BridgeError.invalidParams }
            guard onMain({ [weak self] in self?.model?.live?.threadRecord(roomID)?.parentThreadID == owner }) else { throw BridgeError.invalidParams }
            let keepBranch = params["keepBranch"] as? Bool ?? true
            let reclaimResult: Result<ReclaimedRoom, Error> = onMain { [weak self] in
                Result {
                    guard let model = self?.model else { throw BridgeError.invalidParams }
                    return try model.reclaimRoom(roomID, keepBranch: keepBranch)
                }
            }
            let reclaimed = try reclaimResult.get()
            return [
                "roomID": reclaimed.roomID,
                "originalPath": reclaimed.originalPath,
                "archivedPath": reclaimed.archivedPath ?? NSNull(),
                "stash": reclaimed.stash ?? NSNull(),
                "branch": reclaimed.branch ?? NSNull(),
                "branchDeleted": reclaimed.branchDeleted,
            ]
        case "stop_room":
            guard let roomIDText = params["roomID"] as? String, let roomID = UUID(uuidString: roomIDText) else { throw BridgeError.invalidParams }
            guard onMain({ [weak self] in self?.model?.live?.threadRecord(roomID)?.parentThreadID == owner }) else { throw BridgeError.invalidParams }
            let stopped: Bool = onMain { [weak self] in
                self?.model?.stopDispatchRoom(roomID)
                return !(self?.model?.live?.isRunning(roomID) ?? true)
            }
            return ["stopRequested": true, "stopped": stopped]
        case "stop_all_rooms":
            let stopped: Bool = onMain { [weak self] in
                guard let model = self?.model, let live = model.live else { return false }
                model.stopAllDispatchRooms(parent: owner)
                return model.dispatchRooms(parent: owner).allSatisfy { !live.isRunning($0.id) }
            }
            return ["stopRequested": true, "stopped": stopped]
        case "merge_reports":
            let text: String = onMain { [weak self] in self?.model?.mergeDispatchReports(parent: owner) ?? "" }
            return ["text": text]
        default:
            throw BridgeError.unsupportedMethod
        }
    }

    static func cliSendReceipt(id: String) -> [String: Any] {
        ["sent": true, "id": id, "readWith": "cli_tail"]
    }

    private static let mergeQueue = DispatchQueue(label: "ai.tatwo.tatwo2.os-agent.merge", qos: .utility)

    /// Read-only git commands; argument arrays (not shell), bounded time and output.
    /// 單次 git：上限 2 秒，且不超過整次請求的 deadline（絕對 systemUptime）；預算用完直接回 nil。
    private static func mergeGit(_ arguments: [String], workdir: String, deadline: TimeInterval) -> String? {
        precondition(!Thread.isMainThread)
        let budget = min(2, deadline - ProcessInfo.processInfo.systemUptime)
        guard budget > 0.05 else { return nil }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-C", workdir] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Drain while git runs so a long merge history cannot fill the pipe.
        let drained = DispatchSemaphore(value: 0)
        var tail = Data()
        let drain = DispatchWorkItem {
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                tail.append(chunk)
                if tail.count > 8192 { tail = Data(tail.suffix(8192)) }
            }
            drained.signal()
        }
        DispatchQueue.global(qos: .utility).async(execute: drain)
        let stopAt = ProcessInfo.processInfo.systemUptime + budget
        while process.isRunning && ProcessInfo.processInfo.systemUptime < stopAt { Thread.sleep(forTimeInterval: 0.005) }
        if process.isRunning {
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
            _ = drained.wait(timeout: .now() + 0.2)
            return nil
        }
        guard drained.wait(timeout: .now() + min(1, max(0.05, deadline - ProcessInfo.processInfo.systemUptime))) == .success, process.terminationStatus == 0 else { return nil }
        return String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// deadline＝整次請求的絕對 systemUptime 上限；預算內查不完就回「未查」（checkedAt 空），不寫成未合併。
    static func mergeReceipt(branch: String, workdir: String, deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 8) -> [String: Any] {
        precondition(!Thread.isMainThread)
        var result: [String: Any] = ["merged": false, "commit": "", "checkedAt": ""]
        // Fully qualified local ref prevents option/revision injection from branch text.
        let ref = "refs/heads/" + branch
        // 「有查到結論」才填 checkedAt：預算不足／git 起不來／逾時／非 0、1 的狀態一律保持「未查」（Codex round 3）。
        guard !branch.isEmpty else { result["checkedAt"] = ISO8601DateFormatter().string(from: Date()); return result }
        guard let refStatus = mergeGitStatus(["check-ref-format", ref], workdir: workdir, deadline: deadline) else { return result }
        guard refStatus == 0 else { result["checkedAt"] = ISO8601DateFormatter().string(from: Date()); return result }   // 名字不合法＝確定不是分支
        // is-ancestor：exit 0＝已合併、exit 1＝未合併、其他（缺 ref／壞 repo）或 nil（逾時／預算用完）＝未查
        let ancestor = mergeGitStatus(["merge-base", "--is-ancestor", ref, "HEAD"], workdir: workdir, deadline: deadline)
        guard let ancestor, ancestor == 0 || ancestor == 1 else { return result }
        if ancestor == 0,
           let history = mergeGit(["log", "--merges", "--ancestry-path", "--format=%H", ref + "..HEAD", "--"], workdir: workdir, deadline: deadline) {
            let commit = history.split(separator: "\n").last.map(String.init)
                ?? mergeGit(["rev-parse", "--verify", ref + "^{commit}"], workdir: workdir, deadline: deadline)
            guard let commit, !commit.isEmpty else { return result }
            result["merged"] = true; result["commit"] = commit
        } else if ancestor == 0 {
            return result   // 預算內取不到 commit → 未查
        }
        result["checkedAt"] = ISO8601DateFormatter().string(from: Date())
        return result
    }
    /// 同 mergeGit 但回 exit status（nil＝逾時／預算用完／起不來）。
    private static func mergeGitStatus(_ arguments: [String], workdir: String, deadline: TimeInterval) -> Int32? {
        precondition(!Thread.isMainThread)
        let budget = min(2, deadline - ProcessInfo.processInfo.systemUptime)
        guard budget > 0.05 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-C", workdir] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let stopAt = ProcessInfo.processInfo.systemUptime + budget
        while process.isRunning && ProcessInfo.processInfo.systemUptime < stopAt { Thread.sleep(forTimeInterval: 0.005) }
        if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL); return nil }
        return process.terminationStatus
    }

    /// Read only this worktree's HEAD; never infer a parent's branch for an ordinary directory.
    /// Remote worktrees cannot be inspected using the local filesystem.
    static func worktreeBranch(_ path: String?) -> String {
        guard let path else { return "" }
        let dotGit = URL(fileURLWithPath: path).appendingPathComponent(".git")
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &directory) else { return "" }
        let gitDirectory: URL
        if directory.boolValue {
            gitDirectory = dotGit
        } else {
            guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
                  pointer.hasPrefix("gitdir: ") else { return "" }
            let target = String(pointer.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: path, isDirectory: true))
        }
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8),
              head.hasPrefix("ref: refs/heads/") else { return "" }
        return String(head.dropFirst("ref: refs/heads/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func callForSelfTest(method: String, params: [String: Any]) throws -> [String: Any] {
        try perform(method: method, params: params)
    }

    func stopBackgroundJobs() { backgroundJobs?.stopAll() }

    private static let remoteMethods: Set<String> = [
        "get_document",
        "transcript",
        "send_message",
        "send_message_with_options",
        "new_thread",
        "stop_thread",
        "push_thread",
        "pull_thread",
    ]
    private static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    private static func decode<T: Decodable>(_ value: Any) throws -> T {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw BridgeError.invalidParams
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            T.self,
            from: JSONSerialization.data(withJSONObject: value))
    }

    private static func documentsEqual(
        _ lhs: LiveDocumentRecord,
        _ rhs: LiveDocumentRecord
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else {
            return false
        }
        return left == right
    }

    @MainActor
    private static func snapshot(_ live: any LiveEngineAPI) -> LiveDocumentRecord {
        var snapshot = live.doc
        for index in snapshot.threads.indices {
            snapshot.threads[index].messages = live
                .transcript(for: snapshot.threads[index].id)
                .map(LiveMessageRecord.init)
        }
        return snapshot
    }

    private func onMain<T>(_ body: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private func onMainThrowing<T>(_ body: @escaping @MainActor () throws -> T) throws -> T {
        if Thread.isMainThread { return try MainActor.assumeIsolated(body) }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }
}
