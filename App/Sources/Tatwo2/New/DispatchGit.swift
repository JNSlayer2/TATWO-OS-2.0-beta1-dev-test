import Foundation

/// Local-only dispatch operations. All git subprocesses share a background queue.
struct DispatchGitContext: Sendable {
    let id: UUID
    let title: String
    let workdir: String
    let worktree: String
    let branch: String
    let deviceID: String?

    func requireLocal() throws {
        if deviceID != nil { throw DispatchGitFailure(message: "遠端子任務不支援") }
    }
    var relativePath: String {
        let prefix = workdir.hasSuffix("/") ? workdir : workdir + "/"
        return worktree.hasPrefix(prefix) ? String(worktree.dropFirst(prefix.count)) : "路徑不在專案內"
    }
    func mergeCommand() throws -> String {
        try requireLocal()
        // Double quotes must also escape shell expansion, not just embedded quotes.
        let quoted = workdir.reduce(into: "") { result, char in
            if "\\\"$`".contains(char) { result.append("\\") }
            result.append(char)
        }
        guard branch == "tatwo2-room-\(id.uuidString.prefix(8))" else {
            throw DispatchGitFailure(message: "子任務分支不符")
        }
        return "cd \"\(quoted)\" && git merge --no-ff refs/heads/\(branch)"   // 完整 ref：同名 tag 不能頂替
    }
}
struct DispatchGitFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
struct DispatchGitDiff: Sendable {
    let id = UUID()
    let stat: String
    let text: String
    let truncated: Bool
    var parsed: TatwoParsedDiff { TatwoDiffHunkParser.parse(unifiedDiff: text) }
}
struct DispatchMergePreview: Sendable {
    let head: String
    let branchHead: String
    var shortHead: String { String(head.prefix(8)) }
}
enum DispatchGit {
    static let limit = 512 * 1024
    private static let queue = DispatchQueue(label: "tatwo2.dispatch.git", qos: .userInitiated)

    static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
    // Drain while the child runs (including discarded bytes); never wait on a full pipe.
    /// 單一 git 子程序的時間界線；超過就 terminate→kill 並 throw，不讓共用 queue 永遠卡住。
    static let timeout: TimeInterval = 30
    static func run(_ args: [String], cwd: String, cap: Int = limit, timeout: TimeInterval = timeout) throws -> (status: Int32, text: String, truncated: Bool) {
        precondition(!Thread.isMainThread, "git must run off the main thread")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "--no-pager"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment[key] = nil }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // 有界等待：讀 pipe 在背景執行緒；主等待用 deadline。逾時就 SIGKILL 直接子程序並關掉我們這端的 pipe，
        // 即使 merge driver／hook 的後代程序仍握著 pipe 也不會拖住 runner（後代由 OS 收，這裡如實回報）。
        let started = ProcessInfo.processInfo.systemUptime
        let lock = NSLock(); var data = Data(); var truncated = false
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = (try? reader.read(upToCount: 65536)) ?? nil
                guard let chunk, !chunk.isEmpty else { break }
                lock.lock()
                let available = max(0, cap - data.count)
                data.append(chunk.prefix(available))
                if chunk.count > available { truncated = true }
                lock.unlock()
            }
            drained.signal()
        }
        let deadline = DispatchTime.now() + timeout
        var expired = false
        if drained.wait(timeout: deadline) == .timedOut {
            expired = true
        } else {
            // EOF 之後也只等到 deadline；仍沒退出就當逾時
            while process.isRunning && ProcessInfo.processInfo.systemUptime - started < timeout { Thread.sleep(forTimeInterval: 0.005) }
            if process.isRunning { expired = true }
        }
        if expired {
            if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL) }
            try? reader.close()   // 解除 drain 執行緒對後代程序 pipe 的等待
            _ = drained.wait(timeout: .now() + 0.5)
            throw DispatchGitFailure(message: String(format: "git 逾時（>%.2f 秒）已中止：%@", timeout, args.prefix(2).joined(separator: " ")))
        }
        process.waitUntilExit()
        lock.lock(); defer { lock.unlock() }
        var utf8 = Data(String(decoding: data, as: UTF8.self).utf8)
        if utf8.count > cap { utf8 = Data(utf8.prefix(cap)); truncated = true }
        // A byte cap may split a scalar; drop only that incomplete trailing scalar.
        while !utf8.isEmpty && String(data: utf8, encoding: .utf8) == nil { utf8.removeLast() }
        return (process.terminationStatus, String(data: utf8, encoding: .utf8) ?? "", truncated)
    }
    private static func checked(_ args: [String], _ cwd: String) throws -> String {
        let result = try run(args, cwd: cwd)
        guard result.status == 0 else { throw DispatchGitFailure(message: String(result.text.prefix(200))) }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func validate(_ context: DispatchGitContext) throws {
        try context.requireLocal()
        _ = try context.mergeCommand()
        let root = URL(fileURLWithPath: context.workdir).resolvingSymlinksInPath().standardizedFileURL.path
        let tree = URL(fileURLWithPath: context.worktree).resolvingSymlinksInPath().standardizedFileURL.path
        guard tree == root + "/.tatwo2/wt/" + context.id.uuidString else {
            throw DispatchGitFailure(message: "子任務路徑不在專案 workdir")
        }
        let reportedRoot = try checked(["rev-parse", "--show-toplevel"], context.workdir)
        let list = try checked(["worktree", "list", "--porcelain", "-z"], context.workdir)
        let matches = list.components(separatedBy: "\0\0").contains { entry in
            let fields = entry.components(separatedBy: "\0")
            guard let location = fields.first, location.hasPrefix("worktree ") else { return false }
            let path = URL(fileURLWithPath: String(location.dropFirst(9))).resolvingSymlinksInPath().standardizedFileURL.path
            return path == tree && fields.contains("branch refs/heads/" + context.branch)
        }
        guard URL(fileURLWithPath: reportedRoot).resolvingSymlinksInPath().standardizedFileURL.path == root, matches else {
            throw DispatchGitFailure(message: "專案或子任務分支不符")
        }
    }
    static func diff(_ context: DispatchGitContext) throws -> DispatchGitDiff {
        try validate(context)
        let branch = try checked(["rev-parse", "--verify", "refs/heads/\(context.branch)"], context.workdir)
        let base = try checked(["merge-base", "HEAD", branch], context.workdir)
        let range = "\(base)..\(branch)"
        let stat = try run(["diff", "--no-ext-diff", "--no-textconv", range, "--stat", "--"], cwd: context.workdir)
        let full = try run(["diff", "--no-ext-diff", "--no-textconv", range, "--"], cwd: context.workdir)
        guard stat.status == 0, full.status == 0 else { throw DispatchGitFailure(message: String((stat.text + full.text).prefix(200))) }
        return DispatchGitDiff(stat: stat.text, text: full.text, truncated: stat.truncated || full.truncated)
    }
    static func preview(_ context: DispatchGitContext) throws -> DispatchMergePreview {
        try validate(context)
        guard try checked(["status", "--porcelain", "--untracked-files=all"], context.workdir).isEmpty else {
            throw DispatchGitFailure(message: "主分支有未提交變更，先處理再合併")
        }
        // Never abort a merge started by someone else.
        let merge = try run(["rev-parse", "--verify", "MERGE_HEAD"], cwd: context.workdir)
        guard merge.status != 0 else { throw DispatchGitFailure(message: "專案已有合併進行中") }
        for state in ["rebase-merge", "rebase-apply", "sequencer", "CHERRY_PICK_HEAD", "REVERT_HEAD"] {
            let path = try checked(["rev-parse", "--git-path", state], context.workdir)
            let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: context.workdir + "/"))
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw DispatchGitFailure(message: "專案已有 git 操作進行中，未合併")
            }
        }
        return DispatchMergePreview(head: try checked(["rev-parse", "HEAD"], context.workdir),
                                    branchHead: try checked(["rev-parse", "refs/heads/\(context.branch)"], context.workdir))
    }
    static func merge(_ context: DispatchGitContext, expected: DispatchMergePreview) throws -> String {
        let current = try preview(context)
        guard current.head == expected.head, current.branchHead == expected.branchHead else {
            throw DispatchGitFailure(message: "HEAD 或子任務分支已改變，請重新確認")
        }
        let alreadyMerged = try run(["merge-base", "--is-ancestor", current.branchHead, current.head], cwd: context.workdir)
        guard alreadyMerged.status != 0 else { throw DispatchGitFailure(message: "子任務已合併，沒有新的變更") }
        // 合入已確認的 immutable SHA（不是分支名：同名 tag 會頂替）；--commit 明確壓過 branch.<name>.mergeOptions=--no-commit。
        let result: (status: Int32, text: String, truncated: Bool)
        do {
            result = try run(["merge", "--no-ff", "--commit", "--no-edit", current.branchHead, "-m", "合併子任務 \(context.title)（\(context.branch)）"], cwd: context.workdir)
        } catch {
            try restoreAfterFailedMerge(context, expected: expected, detail: String(describing: error))
            throw error
        }
        if result.status != 0 {
            try restoreAfterFailedMerge(context, expected: expected, detail: String(result.text.prefix(100)))
            throw DispatchGitFailure(message: String(result.text.prefix(200)))
        }
        // exit 0 ≠ 已產生合併 commit：驗 MERGE_HEAD 已清、HEAD 前進、parents 正是確認過的兩端、工作樹乾淨。
        // 事後檢查本身若 throw（git 逾時／讀不到）也要走回復路徑，不能跳過。
        let mergeHead: (status: Int32, text: String, truncated: Bool)
        let head: String, parents: [String], clean: Bool
        do {
            mergeHead = try run(["rev-parse", "--verify", "MERGE_HEAD"], cwd: context.workdir)
            head = try checked(["rev-parse", "HEAD"], context.workdir)
            parents = try checked(["rev-list", "--parents", "-n", "1", "HEAD"], context.workdir).split(separator: " ").map(String.init)
            clean = try checked(["status", "--porcelain", "--untracked-files=all"], context.workdir).isEmpty
        } catch {
            try restoreAfterFailedMerge(context, expected: expected, detail: "合併後驗證失敗：\(error)")
            throw DispatchGitFailure(message: "合併後驗證失敗，已回復到 \(expected.shortHead)：\(error)")
        }
        let committed = mergeHead.status != 0 && head != expected.head && parents.count == 3 && parents[1] == expected.head && parents[2] == expected.branchHead && clean
        guard committed else {
            try restoreAfterFailedMerge(context, expected: expected, detail: "合併未產生預期的 merge commit（MERGE_HEAD=\(mergeHead.status == 0)、HEAD=\(head.prefix(8))、parents=\(parents.count)）")
            throw DispatchGitFailure(message: "合併未完成（可能是 no-commit 設定或狀態異常），已回復到 \(expected.shortHead)")
        }
        return String(head.prefix(8))
    }
    /// 失敗／逾時／未完成後把專案拉回確認時的 HEAD；做不到就明說要人工處理。
    private static func restoreAfterFailedMerge(_ context: DispatchGitContext, expected: DispatchMergePreview, detail: String) throws {
        let mergeHead = try run(["rev-parse", "--verify", "MERGE_HEAD"], cwd: context.workdir)
        if mergeHead.status == 0 { _ = try run(["merge", "--abort"], cwd: context.workdir) }
        let clean = try checked(["status", "--porcelain", "--untracked-files=all"], context.workdir).isEmpty
        let head = try checked(["rev-parse", "HEAD"], context.workdir)
        guard clean, head == expected.head else {
            throw DispatchGitFailure(message: "合併失敗，回復需人工處理：\(detail)")
        }
    }
}
