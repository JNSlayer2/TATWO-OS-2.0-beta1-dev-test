import Foundation
import AppKit

/// B3 派工引擎（ultrawork 2.0 第 2 步）：把房間規格接成真的子討論串＋各自獨立的 git worktree＋真的送出。
/// 合約見 docs/goal-ui-2.0/rooms/engine-e1-dispatch.md；資料形狀給 OSAgentBridge／os-mcp 用。
struct RoomSpec {
    let title: String
    let engine: String   // "codex" | "claude" | "grok"
    let model: String?
    let brief: String
    let device: String?
    let readOnly: Bool

    init(title: String, engine: String, model: String?, brief: String, device: String? = nil, readOnly: Bool = false) {
        self.title = title
        self.engine = engine
        self.model = model
        self.brief = brief
        self.device = device
        self.readOnly = readOnly
    }
}

struct DispatchedRoom {
    let roomID: String
    let threadID: String
    let worktree: String
    var readOnly = false
    var workingDirectory: String?
    var branch: String { readOnly ? "" : OSAgentBridge.worktreeBranch(worktree) }
}

struct ReclaimedRoom {
    let roomID: String
    let originalPath: String
    let archivedPath: String?
    let stash: String?
    let branch: String?
    let branchDeleted: Bool
}

extension ChatPageModel {
    enum DispatchError: Error, CustomStringConvertible {
        case missingWorkdirMapping
        case remoteCommandFailed(String)
        case readOnlyUnavailable

        var description: String {
            switch self {
            case .missingWorkdirMapping: return "這台沒有這個專案的對映"
            case .remoteCommandFailed(let detail): return "遠端 worktree 建立失敗：\(detail)"
            case .readOnlyUnavailable: return "此路徑尚不支援唯讀副審；未改用可寫入派工。目前僅支援本機 Claude 引擎。"
            }
        }
    }

    static func dispatchTitle(_ brief: String) -> String {
        let sentence = brief.split(whereSeparator: { "。！？\n\r".contains($0) }).first.map(String.init) ?? ""
        return sentence.count > 24 ? String(sentence.prefix(24)) + "…" : sentence
    }

    static func dispatchModel(thread: LiveThreadRecord?, fallback: String?) -> String? {
        guard let model = thread?.model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return model
    }

    /// Exclude managed worktrees in the shared git directory, including linked worktrees.
    nonisolated static func excludeRoomWorktrees(workdir: String) {
        do {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", workdir, "rev-parse", "--git-common-dir"]
            var environment = ProcessInfo.processInfo.environment
            for key in environment.keys where key.hasPrefix("GIT_") { environment[key] = nil }
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw DispatchGitFailure(message: "git common directory unavailable") }
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let directory = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workdir, isDirectory: true)).standardizedFileURL
            let exclude = directory.appendingPathComponent("info/exclude")
            let fm = FileManager.default
            let text = fm.fileExists(atPath: exclude.path) ? try String(contentsOf: exclude, encoding: .utf8) : ""
            guard !text.components(separatedBy: .newlines).contains(".tatwo2/") else { return }
            try fm.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + ".tatwo2/\n").write(to: exclude, atomically: true, encoding: .utf8)
        } catch {
            NSLog("dispatch: exclude update skipped: %@", String(describing: error))
        }
    }

    /// 便利呼叫：parent 用目前選取的討論串。os-mcp 的 dispatch_rooms 不帶 parent 參數，靠這個解析。
    @discardableResult
    func dispatch(rooms: [RoomSpec]) -> [DispatchedRoom] {
        guard let parent = selectedThreadID else { return [] }
        return (try? dispatchChecked(rooms: rooms, parent: parent)) ?? []
    }

    /// 每個房間＝ live.newThread 開一條子討論串、指到自己的 git worktree（或普通資料夾）、然後真的送出 brief。
    @discardableResult
    func dispatch(rooms: [RoomSpec], parent: UUID) -> [DispatchedRoom] {
        (try? dispatchChecked(rooms: rooms, parent: parent)) ?? []
    }

    @discardableResult
    func dispatchChecked(rooms: [RoomSpec], parent: UUID) throws -> [DispatchedRoom] {
        guard isLive, let live else { return [] }
        guard let parentRecord = live.threadRecord(parent),
              let project = live.doc.projects.first(where: { $0.id == parentRecord.projectID })
        else { return [] }
        // Validate the whole batch before creating threads, worktrees or remote sessions.
        // Other engines remain unavailable until their native boundaries are verified.
        if rooms.contains(where: \.readOnly) {
            guard live is ChatLiveEngine, parentRecord.deviceID == nil,
                  rooms.filter(\.readOnly).allSatisfy({ $0.engine == "claude" && $0.device == nil })
            else { throw DispatchError.readOnlyUnavailable }
        }
        var results: [DispatchedRoom] = []
        for room in rooms {
            if room.readOnly {
                guard let local = live as? ChatLiveEngine else { throw DispatchError.readOnlyUnavailable }
                let reviewCwd = parentRecord.cwdOverride ?? project.workdir
                let threadID = local.newThread(in: project.id, title: room.title)
                local.configureReadOnlyRoom(threadID: threadID, parentThreadID: parent,
                                            roomBrief: room.brief, cwd: reviewCwd)
                local.setRequestedModel(room.model, threadID: threadID)
                guard local.send(threadID: threadID, text: room.brief, model: room.model, engine: .claude) else {
                    throw DispatchGitFailure(message: "唯讀副審未啟動，請查看子討論串錯誤；未改用施工模式")
                }
                results.append(DispatchedRoom(roomID: threadID.uuidString, threadID: threadID.uuidString,
                                              worktree: "", readOnly: true, workingDirectory: reviewCwd))
                continue
            }
            let kind = ClaudeSidecar.Kind(rawValue: room.engine) ?? .codex
            let remote: RemoteDeviceRef?
            let remoteProjectWorkdir: String?
            var remoteHandle: RemoteEngineHandle? = nil
            if let deviceID = room.device {
                let ref = try RemoteDeviceLookup(root: live.store.url.deletingLastPathComponent()).device(id: deviceID)
                guard let mapped = ref.workdirMap[project.workdir], !mapped.isEmpty else {
                    throw DispatchError.missingWorkdirMapping
                }
                remoteHandle = try RemoteEngineSync.ensureEnginesOnDevice(ref, kind: kind)   // 同一份 session handle 一路傳下去，不丟棄
                remote = ref
                remoteProjectWorkdir = mapped
            } else {
                remote = nil
                remoteProjectWorkdir = nil
            }
            let threadID = live.newThread(in: project.id, title: room.title)
            let roomID = threadID.uuidString
            let worktree: String
            if let remoteHandle, remoteHandle.isCaptureOnly {
                worktree = try Self.captureRemoteRoomWorktree(handle: remoteHandle, roomID: roomID)   // fixture：同一 planner 只記錄 ssh argv，不執行
                (live as? ChatLiveEngine)?.remoteHandles.set(threadID, remoteHandle)
            } else if let remote, let remoteProjectWorkdir {
                worktree = try Self.prepareRemoteRoomWorktree(ref: remote, workdir: remoteProjectWorkdir, roomID: roomID)
                if let remoteHandle { (live as? ChatLiveEngine)?.remoteHandles.set(threadID, remoteHandle) }
            } else {
                do {
                    worktree = try Self.prepareRoomWorktree(workdir: project.workdir, roomID: roomID)
                } catch {
                    live.appendSystemMessage(threadID: threadID, text: "派工工作副本建立失敗，未送出：\(error)", status: "error|派工")
                    throw error
                }
            }
            live.configureRoom(threadID: threadID, parentThreadID: parent, roomBrief: room.brief, engine: room.engine, cwdOverride: worktree, deviceID: remote?.id)
            (live as? ChatLiveEngine)?.setRequestedModel(room.model, threadID: threadID)
            live.send(threadID: threadID, text: room.brief, model: room.model, engine: kind)
            results.append(DispatchedRoom(roomID: roomID, threadID: threadID.uuidString, worktree: worktree))
        }
        return results
    }

    /// 純 planner（production 與 fixture 共用同一 formatter）：遠端房間 worktree 路徑＋要在遠端跑的兩條命令（與原 prepareRemoteRoomWorktree 逐字相同）。
    static func remoteWorktreePlan(workdir: String, roomID: String) -> (worktree: String, commands: [[String]]) {
        let worktree = (workdir as NSString).appendingPathComponent(".tatwo2/wt/\(roomID)")
        let parent = (worktree as NSString).deletingLastPathComponent
        return (worktree, [["/bin/mkdir", "-p", parent], ["/usr/bin/git", "-C", workdir, "worktree", "add", "-b", "room/\(roomID)", worktree]])
    }

    /// 純 formatter：runSSH 實際送出的 ssh argv（production 執行與 fixture 擷取用同一份）。
    static func sshArguments(_ ref: RemoteDeviceRef, command: [String]) -> [String] {
        ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=8", "-p", String(ref.sshPort), ref.sshTarget]
            + command.map { remoteShellQuote($0, expandHome: $0.hasPrefix("~/")) }
    }

    /// capture-only：workdir＝fixture 的 owned remote-project component，同一個 planner，只把 ssh argv 寫進 capture-chain，不執行。壞 handle 不自造路徑。
    private static func captureRemoteRoomWorktree(handle: RemoteEngineHandle, roomID: String) throws -> String {
        guard let projectRoot = handle.remoteProjectRoot else { throw RemoteEngineSyncError.fixtureBlocked("capture-only handle 缺 remoteProjectRoot") }
        let plan = remoteWorktreePlan(workdir: projectRoot, roomID: roomID)
        #if DEBUG
        try handle.capture(stage: "worktree", commands: plan.commands.map { ["/usr/bin/ssh"] + sshArguments(handle.device, command: $0) })
        #endif
        return plan.worktree
    }

    private static func prepareRemoteRoomWorktree(ref: RemoteDeviceRef, workdir: String, roomID: String) throws -> String {
        let plan = remoteWorktreePlan(workdir: workdir, roomID: roomID)
        for command in plan.commands { try runSSH(ref, command: command) }
        return plan.worktree
    }

    private static func runSSH(_ ref: RemoteDeviceRef, command: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments(ref, command: command)   // 與 fixture 擷取同一份 formatter
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw DispatchError.remoteCommandFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw DispatchError.remoteCommandFailed("exit=\(process.terminationStatus)\(text.isEmpty ? "" : " — \(text)")")
        }
    }

    /// 本機分支名為 tatwo2-room-<roomID 前 8 碼>。
    /// workdir 是 git repo → 底下建 worktree（<workdir>/.tatwo2/wt/<roomID>）；不是 → 建普通資料夾（<workdir>/.tatwo2/rooms/<roomID>）。
    static func prepareRoomWorktree(workdir: String, roomID: String) throws -> String {
        let fm = FileManager.default
        guard UUID(uuidString: roomID) != nil else {
            throw DispatchGitFailure(message: "無效的派工房間 ID")
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: workdir, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DispatchGitFailure(message: "派工專案資料夾不存在")
        }
        func run(_ args: [String], cwd: String) throws -> (status: Int32, out: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-c", "core.hooksPath=/dev/null"] + args
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            var environment = ProcessInfo.processInfo.environment
            for key in environment.keys where key.hasPrefix("GIT_") { environment[key] = nil }
            environment["LC_ALL"] = "C"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            p.environment = environment
            p.standardInput = FileHandle.nullDevice
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            try p.run()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            return (p.terminationStatus, text)
        }
        let (gitStatus, gitOut) = try run(["rev-parse", "--is-inside-work-tree"], cwd: workdir)
        let isRepo = gitStatus == 0 && gitOut.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        if isRepo {
            Self.excludeRoomWorktrees(workdir: workdir)
            let path = (workdir as NSString).appendingPathComponent(".tatwo2/wt/\(roomID)")
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let branch = "tatwo2-room-\(roomID.prefix(8))"
            let result = try run(["worktree", "add", "-b", branch, path], cwd: workdir)
            guard result.status == 0 else {
                throw DispatchGitFailure(message: "工作樹建立失敗（exit \(result.status)）：\(result.out.prefix(300))")
            }
            return path
        }
        // A broken/bare repository is not a normal folder. Do not silently
        // substitute an empty working copy when git could not inspect it.
        guard gitStatus == 128, gitOut.contains("fatal: not a git repository") else {
            throw DispatchGitFailure(message: "無法確認派工專案（exit \(gitStatus)）：\(gitOut.prefix(300))")
        }
        var ancestor = URL(fileURLWithPath: workdir, isDirectory: true).resolvingSymlinksInPath()
        while true {
            let marker = ancestor.appendingPathComponent(".git").path
            guard !fm.fileExists(atPath: marker),
                  (try? fm.destinationOfSymbolicLink(atPath: marker)) == nil else {
                throw DispatchGitFailure(message: "專案 git 資料無法讀取，未改建普通工作副本")
            }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        let path = (workdir as NSString).appendingPathComponent(".tatwo2/rooms/\(roomID)")
        guard !fm.fileExists(atPath: path) else {
            throw DispatchGitFailure(message: "派工工作副本已存在，未重用")
        }
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// 房間收尾的唯一回收路徑：git worktree 先 stash 再解除；普通資料夾只搬進 .tatwo2/trash。
    func reclaimRoom(_ roomID: UUID, keepBranch: Bool = true) throws -> ReclaimedRoom {
        guard isLive, let live, let room = live.threadRecord(roomID),
              room.parentThreadID != nil,
              let project = live.projectRecord(room.projectID),
              let roomPath = room.cwdOverride
        else { throw RoomReclaimError.roomNotFound }
        guard !live.isRunning(roomID) else { throw RoomReclaimError.roomRunning }
        if room.roomReadOnly == true {
            // A reviewer owns no working copy. Never stash/move/delete the reviewed project.
            return ReclaimedRoom(roomID: roomID.uuidString, originalPath: "", archivedPath: nil,
                                 stash: nil, branch: nil, branchDeleted: false)
        }

        let fm = FileManager.default
        let workdir = URL(fileURLWithPath: project.workdir, isDirectory: true).standardizedFileURL.path
        let path = URL(fileURLWithPath: roomPath, isDirectory: true).standardizedFileURL.path
        let gitRoomRoot = URL(fileURLWithPath: workdir, isDirectory: true)
            .appendingPathComponent(".tatwo2/wt", isDirectory: true).standardizedFileURL.path
        let ordinaryRoomRoot = URL(fileURLWithPath: workdir, isDirectory: true)
            .appendingPathComponent(".tatwo2/rooms", isDirectory: true).standardizedFileURL.path
        guard path.hasPrefix(gitRoomRoot + "/") || path.hasPrefix(ordinaryRoomRoot + "/") else {
            throw RoomReclaimError.pathOutsideRoomRoot
        }
        guard fm.fileExists(atPath: path) else {
            return ReclaimedRoom(roomID: roomID.uuidString, originalPath: path, archivedPath: nil, stash: nil, branch: nil, branchDeleted: false)
        }

        if path.hasPrefix(gitRoomRoot + "/") {
            let branchResult = Self.runGit(["branch", "--show-current"], cwd: path)
            guard branchResult.status == 0 else { throw RoomReclaimError.gitFailed(branchResult.output) }
            let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = Self.runGit(["status", "--porcelain", "--untracked-files=all"], cwd: path)
            guard status.status == 0 else { throw RoomReclaimError.gitFailed(status.output) }
            var stashName: String?
            if !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let stash = Self.runGit(["stash", "push", "-u", "-m", "reclaim \(roomID.uuidString)"], cwd: path)
                guard stash.status == 0 else { throw RoomReclaimError.gitFailed(stash.output) }
                let latest = Self.runGit(["stash", "list", "-1", "--format=%gd"], cwd: path)
                stashName = latest.status == 0
                    ? latest.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil
            }
            let removal = Self.runGit(["worktree", "remove", "--force", path], cwd: workdir)
            guard removal.status == 0 else { throw RoomReclaimError.gitFailed(removal.output) }

            var deleted = false
            if !keepBranch, !branch.isEmpty {
                let merged = Self.runGit(["branch", "--merged", "--format=%(refname:short)"], cwd: workdir)
                guard merged.status == 0 else { throw RoomReclaimError.gitFailed(merged.output) }
                let mergedBranches = Set(merged.output.split(whereSeparator: \.isNewline).map(String.init))
                if mergedBranches.contains(branch) {
                    let deletion = Self.runGit(["branch", "-d", branch], cwd: workdir)
                    guard deletion.status == 0 else { throw RoomReclaimError.gitFailed(deletion.output) }
                    deleted = true
                }
            }
            return ReclaimedRoom(
                roomID: roomID.uuidString,
                originalPath: path,
                archivedPath: nil,
                stash: stashName,
                branch: branch.isEmpty ? nil : branch,
                branchDeleted: deleted)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let trashRoot = URL(fileURLWithPath: workdir, isDirectory: true)
            .appendingPathComponent(".tatwo2/trash", isDirectory: true)
        try fm.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        var destination = trashRoot.appendingPathComponent("\(roomID.uuidString)-\(formatter.string(from: Date()))", isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            destination.appendPathExtension(UUID().uuidString.prefix(8).lowercased())
        }
        do {
            try fm.moveItem(atPath: path, toPath: destination.path)
        } catch {
            throw RoomReclaimError.archiveFailed(error.localizedDescription)
        }
        return ReclaimedRoom(roomID: roomID.uuidString, originalPath: path, archivedPath: destination.path, stash: nil, branch: nil, branchDeleted: false)
    }

    private static func runGit(_ arguments: [String], cwd: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }
        return (
            process.terminationStatus,
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    enum RoomReclaimError: Error, CustomStringConvertible {
        case roomNotFound
        case roomRunning
        case pathOutsideRoomRoot
        case gitFailed(String)
        case archiveFailed(String)

        var description: String {
            switch self {
            case .roomNotFound: "room_not_found"
            case .roomRunning: "room_running"
            case .pathOutsideRoomRoot: "room_path_outside_managed_root"
            case .gitFailed(let output): "git_failed:\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .archiveFailed(let output): "archive_failed:\(output)"
            }
        }
    }
}

// dispatch-ui: resolve from the live child record, never from a UI label or selected cwd.
extension ChatPageModel {
    /// Composer entrypoint: worktree creation is also off-main; existing synchronous bridge API is unchanged.
    func dispatchPromptRoom(_ spec: RoomSpec, parent: UUID) async throws -> [DispatchedRoom] {
        if spec.readOnly { return try dispatchChecked(rooms: [spec], parent: parent) }
        guard let source = live, let record = source.threadRecord(parent),
              let project = source.projectRecord(record.projectID) else {
            throw DispatchGitFailure(message: "找不到派工專案")
        }
        guard spec.device == nil, record.deviceID == nil else {
            throw DispatchGitFailure(message: "遠端子任務不支援")
        }
        let workdir = project.workdir
        try await DispatchGit.background {
            let result = try DispatchGit.run(["rev-parse", "--show-toplevel"], cwd: workdir)
            guard result.status == 0 else { throw DispatchGitFailure(message: "派工需要本機 git 專案") }
        }
        let thread = source.newThread(in: project.id, title: spec.title)
        let canonicalPath = (workdir as NSString).appendingPathComponent(".tatwo2/wt/" + thread.uuidString)
        do {
            try await DispatchGit.background {
                Self.excludeRoomWorktrees(workdir: workdir)
                try FileManager.default.createDirectory(atPath: (canonicalPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                let result = try DispatchGit.run(["worktree", "add", "-b", "tatwo2-room-" + thread.uuidString.prefix(8), canonicalPath], cwd: workdir)
                guard result.status == 0 else { throw DispatchGitFailure(message: String(result.text.prefix(200))) }
            }
        } catch {
            source.appendSystemMessage(threadID: thread, text: "派工工作樹準備失敗，未送出：\(error)", status: "error|派工")
            throw error
        }
        source.configureRoom(threadID: thread, parentThreadID: parent, roomBrief: spec.brief,
                             engine: spec.engine, cwdOverride: canonicalPath, deviceID: nil)
        (source as? ChatLiveEngine)?.setRequestedModel(spec.model, threadID: thread)
        source.send(threadID: thread, text: spec.brief, model: spec.model, engine: ClaudeSidecar.Kind(rawValue: spec.engine) ?? .codex)
        return [DispatchedRoom(roomID: thread.uuidString, threadID: thread.uuidString, worktree: canonicalPath)]
    }

    func dispatchGitContext(_ id: UUID) throws -> DispatchGitContext {
        guard isLive, let live, let room = live.threadRecord(id), room.parentThreadID != nil,
              let project = live.projectRecord(room.projectID), let path = room.cwdOverride else {
            throw DispatchGitFailure(message: "找不到本機子任務工作樹")
        }
        guard room.roomReadOnly != true else {
            throw DispatchGitFailure(message: "唯讀副審沒有施工工作樹或可合併分支")
        }
        let context = DispatchGitContext(id: id, title: room.title, workdir: project.workdir,
                                         worktree: path, branch: "tatwo2-room-\(id.uuidString.prefix(8))", deviceID: room.deviceID)
        try context.requireLocal()
        return context
    }

    /// 卡片上顯示用：工作副本路徑只留資料夾＋id 前 8 碼（完整路徑在 help／複製指令）。
    func dispatchBranchPathShort(_ id: UUID) -> String {
        let full = dispatchBranchPath(id)
        guard let dot = full.range(of: " · ") else { return full }
        let path = String(full[dot.upperBound...])
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let last = parts.last, last.count > 12 { parts[parts.count - 1] = String(last.prefix(8)) + "…" }
        return String(full[..<dot.lowerBound]) + " · " + parts.joined(separator: "/")
    }
    func dispatchBranchPath(_ id: UUID) -> String {
        if live?.threadRecord(id)?.roomReadOnly == true { return "唯讀副審 · 無施工工作樹" }
        if !isLive, Self.isDispatchExportScene,
           ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil {
            return "分支 tatwo2-room-\(id.uuidString.prefix(8)) · .tatwo2/wt/\(id.uuidString)"
        }
        do {
            let context = try dispatchGitContext(id)
            return "分支 \(context.branch) · \(context.relativePath)"
        } catch { return String(describing: error) }
    }

    func copyDispatchMergeCommand(_ id: UUID) {
        do {
            let command = try dispatchGitContext(id).mergeCommand()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            flashComposerHint("已複製")
        } catch { flashComposerHint(String(describing: error)) }
    }

    func loadDispatchDiff(_ id: UUID) async throws -> DispatchGitDiff {
        let context = try dispatchGitContext(id)
        return try await DispatchGit.background { try DispatchGit.diff(context) }
    }

    func confirmDispatchMerge(_ id: UUID) async {
        do {
            let context = try dispatchGitContext(id)
            guard let source = live as? ChatLiveEngine, !source.isRunning(id) else {
                throw DispatchGitFailure(message: "子任務仍在執行，請先停止再合併")
            }
            let preview = try await DispatchGit.background { try DispatchGit.preview(context) }
            let alert = NSAlert()
            alert.messageText = "合併到主分支"
            alert.informativeText = "分支：\(context.branch)\n目標 workdir：\(context.workdir)\n目前 HEAD：\(preview.shortHead)"
            alert.addButton(withTitle: "合併"); alert.addButton(withTitle: "取消")
            guard let window = NSApp.keyWindow else { throw DispatchGitFailure(message: "找不到確認視窗，未合併") }
            let response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            guard response == .alertFirstButtonReturn else { return }
            guard !source.isRunning(id), try dispatchGitContext(id).worktree == context.worktree else {
                throw DispatchGitFailure(message: "子任務狀態已改變，請重新確認")
            }
            let sha = try await DispatchGit.background { try DispatchGit.merge(context, expected: preview) }
            DispatchRoomActions.recordMerge(context, sha: sha, messenger: source)
            flashComposerHint("已合併 \(sha)")
        } catch { flashComposerHint(String(String(describing: error).prefix(200))) }
    }

    func returnDispatchRoom(_ id: UUID, reason: String) throws {
        let context = try dispatchGitContext(id)
        guard let engine = live as? ChatLiveEngine,
              let room = engine.threadRecord(id),
              let kind = ClaudeSidecar.Kind(rawValue: room.engine ?? "") else {
            throw DispatchGitFailure(message: "找不到子討論串引擎")
        }
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DispatchGitFailure(message: "請填退回原因") }
        guard !engine.isRunning(id) else { throw DispatchGitFailure(message: "子任務仍在執行，請先停止再退回") }
        try context.requireLocal()
        guard !EngineDisableStore.isDisabled(kind) else { throw DispatchGitFailure(message: "子任務引擎已禁用，未退回") }
        try DispatchRoomActions.returnRoom(context, reason: text, engine: kind, messenger: engine)
        flashComposerHint("已退回重做")
    }

    func presentDispatchReturn(_ id: UUID) {
        do {
            _ = try dispatchGitContext(id)
            guard let window = NSApp.keyWindow else { throw DispatchGitFailure(message: "找不到退回視窗") }
            let alert = NSAlert()
            alert.messageText = "退回原因"
            alert.addButton(withTitle: "退回重做"); alert.addButton(withTitle: "取消")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
            let editor = NSTextView(frame: scroll.bounds)
            editor.isRichText = false
            editor.setAccessibilityLabel("退回原因")
            scroll.documentView = editor; scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                do { try self?.returnDispatchRoom(id, reason: editor.string) }
                catch { self?.flashComposerHint(String(describing: error)) }
            }
        } catch { flashComposerHint(String(describing: error)) }
    }
}
