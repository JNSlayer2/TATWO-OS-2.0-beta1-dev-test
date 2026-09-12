import Foundation
import CryptoKit

struct PullRequestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Credentials stay in memory. Only human Submit authorizes git/GitHub writes.
struct PullRequestService {
    /// Session-only, thread-scoped reservation; consume only after submission settles.
    struct PendingPR {
        private(set) var threads: Set<UUID> = []
        func contains(_ id: UUID) -> Bool { threads.contains(id) }
        mutating func begin(_ id: UUID) -> Bool { threads.insert(id).inserted }
        @discardableResult mutating func finish(_ id: UUID) -> Bool { threads.remove(id) != nil }
    }

    static func replyDraft(_ reply: String) throws -> (title: String, description: String) {
        let description = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = description.components(separatedBy: .newlines).first ?? ""
        guard !title.isEmpty else { throw PullRequestFailure(message: "引擎沒有提供 PR 說明，未開 PR。") }
        return (title, description)
    }

    static let contributionInstruction = """
    這是要送回公開倉庫的貢獻。依已確認計畫在這個專案裡實作，跑相關測試，不要 commit、不要 push、不要開 PR。
    收尾必須附完整 ```tatwo-pr 圍欄，包含以下五個標題：
    ## 標題
    一句話 PR 標題
    ## 改了什麼
    白話 3–8 行
    ## 動到的檔
    每檔一行說明
    ## 怎麼驗的
    指令＋結果；未跑的明說
    ## 風險與回滾
    風險與可執行的回滾方法
    """

    struct Snapshot: Codable, Equatable, Sendable {
        let head: String
        let status: String
        let diff: String
        let stat: String
        let origin: String
        var fingerprint: String {
            SHA256.hash(data: Data((head + "\n" + status + "\n" + diff + "\n" + origin).utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        var preview: String { stat + "\n" + diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(200).joined(separator: "\n") }
    }
    typealias HTTP = (URLRequest) async throws -> (Data, HTTPURLResponse)
    let http: HTTP
    init(http: @escaping HTTP = FeedbackHTTPTransport.shared.perform) { self.http = http }

    static var repository: String {
        UserDefaults.standard.string(forKey: "tatwo2.feedback.repository") ?? "tatwo214/TATWO-OS-2.0-beta1-dev-test"
    }
    static func validRepository(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+\z"#, options: .regularExpression) != nil
            && !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    static func originRepository(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if text.hasPrefix("git@github.com:") { path = String(text.dropFirst("git@github.com:".count)) }
        else if let url = URLComponents(string: text), url.host?.lowercased() == "github.com",
                ["https", "ssh"].contains(url.scheme ?? ""), url.password == nil,
                url.query == nil, url.fragment == nil, url.port == nil {
            path = String(url.path.drop(while: { $0 == "/" }))
        } else { return nil }
        let name = path.hasSuffix(".git") ? String(path.dropLast(4)) : path
        return validRepository(name) ? name : nil
    }
    static func preflightProblem(isGit: Bool, origin: String?, repository: String,
                                 fork: Bool, parent: String?, loggedIn: Bool,
                                 dirty: Bool, ahead: Int) -> String? {
        guard isGit else { return "目前專案不是 git 工作目錄。" }
        guard validRepository(repository), let origin,
              origin.lowercased() == repository.lowercased()
                || (fork && parent?.lowercased() == repository.lowercased()) else {
            return "origin 必須指向設定的公開倉庫或它的 fork。"
        }
        guard loggedIn else { return "請先登入 GitHub 帳號。" }
        guard dirty || ahead > 0 else { return "沒有工作樹改動，也沒有領先 origin/main 的 commit。" }
        return nil
    }
    static func branchName(title: String, date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd-HHmm"
        let slug = title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "pr/\(formatter.string(from: date))-\(slug.isEmpty ? "changes" : String(slug.prefix(48)))"
    }
    static func hasBinaryPatch(_ diff: String) -> Bool {
        // Match git's marker, not source code mentioning the marker in a +/- line.
        diff.split(separator: "\n").contains { $0 == "GIT binary patch" }
    }

    static func body(description: String) -> String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func api(_ path: String, identity: FeedbackIdentity, method: String = "GET",
             payload: [String: String]? = nil, allowMissing: Bool = false) async throws -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.httpMethod = method; request.timeoutInterval = 30
        request.setValue("Bearer " + identity.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let payload { request.httpBody = try JSONSerialization.data(withJSONObject: payload) }
        let data: Data; let response: HTTPURLResponse
        do { (data, response) = try await http(request) }
        catch { throw PullRequestFailure(message: "GitHub 結果未確認；若已送出，請先至倉庫確認，不要重送。") }
        if allowMissing && response.statusCode == 404 { return nil }
        guard (200...299).contains(response.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PullRequestFailure(message: "GitHub 請求未完成（HTTP \(response.statusCode)）。請檢查帳號權限。")
        }
        return object
    }

    /// Check repository identity independently of dirty/ahead preflight (a fresh clone is clean).
    func isContributionCheckout(_ directory: URL, repository: String,
                                identity: FeedbackIdentity) async throws -> Bool {
        guard let inside = try? await Self.git(["rev-parse", "--is-inside-work-tree"], at: directory),
              inside.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return false }
        guard let raw = try? await Self.git(["remote", "get-url", "origin"], at: directory),
              let origin = Self.originRepository(raw) else { return false }
        if origin.lowercased() == repository.lowercased() { return true }
        let metadata = try await api("/repos/" + origin, identity: identity, allowMissing: true)
        return metadata?["fork"] as? Bool == true
            && ((metadata?["parent"] as? [String: Any])?["full_name"] as? String)?.lowercased() == repository.lowercased()
    }

    func contributionCheckout(current: URL?, repository: String, identity: FeedbackIdentity) async throws -> (directory: URL, useCurrent: Bool) {
        guard Self.validRepository(repository) else { throw PullRequestFailure(message: "公開倉庫設定無效。") }
        let target = try await api("/repos/" + repository, identity: identity)
        guard target?["private"] as? Bool == false else { throw PullRequestFailure(message: "目標必須是公開倉庫。") }
        if let current, try await isContributionCheckout(current, repository: repository, identity: identity) {
            let root = try await Self.git(["rev-parse", "--show-toplevel"], at: current)
            return (URL(fileURLWithPath: root.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true), true)
        }
        let parent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tatwo2/contrib", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent(String(repository.split(separator: "/")[1]), isDirectory: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            _ = try await Self.git(["-c", "credential.helper=", "clone", "--",
                                   "https://github.com/" + repository + ".git", destination.path], at: parent)
        }
        guard try await isContributionCheckout(destination, repository: repository, identity: identity) else {
            throw PullRequestFailure(message: "貢獻資料夾已存在但不是目標倉庫或它的 fork；未覆寫。")
        }
        return (destination, false)
    }

    func preflight(directory: URL, repository: String, identity: FeedbackIdentity) async throws -> Snapshot {
        guard Self.validRepository(repository) else { throw PullRequestFailure(message: "公開倉庫設定無效。") }
        guard try await Self.git(["rev-parse", "--is-inside-work-tree"], at: directory).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else { throw PullRequestFailure(message: "目前專案不是 git 工作目錄。") }
        let originURL = try await Self.git(["remote", "get-url", "origin"], at: directory)
        guard let origin = Self.originRepository(originURL) else { throw PullRequestFailure(message: "origin 不是有效的 GitHub 倉庫網址。") }
        let user = try await api("/user", identity: identity)
        guard let login = user?["login"] as? String, login.lowercased() == identity.username.lowercased()
        else { throw PullRequestFailure(message: "GitHub 帳號與 token 不一致。") }
        let target = try await api("/repos/" + repository, identity: identity)
        guard target?["private"] as? Bool == false else { throw PullRequestFailure(message: "目標必須是公開倉庫。") }
        let metadata = origin.lowercased() == repository.lowercased() ? target : try await api("/repos/" + origin, identity: identity)
        let status = try await Self.git(["status", "--porcelain=v1", "--untracked-files=all"], at: directory)
        let aheadText = try await Self.git(["rev-list", "--count", "origin/main..HEAD"], at: directory)
        if let reason = Self.preflightProblem(isGit: true, origin: origin, repository: repository,
                    fork: metadata?["fork"] as? Bool == true,
                    parent: (metadata?["parent"] as? [String: Any])?["full_name"] as? String,
                    loggedIn: !identity.token.isEmpty, dirty: !status.isEmpty,
                    ahead: Int(aheadText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) {
            throw PullRequestFailure(message: reason)
        }
        return try await Self.snapshot(at: directory)
    }

    static func snapshot(at directory: URL) async throws -> Snapshot {
        let head = try await git(["rev-parse", "HEAD"], at: directory)
        let status = try await git(["status", "--porcelain=v1", "--untracked-files=all"], at: directory)
        let origin = try await git(["remote", "get-url", "origin"], at: directory)
        // Include staged, unstaged, outgoing commits AND untracked text. Scan full
        // content, not the 200-line UI excerpt. Binary patches are rejected.
        let history = try await git(["log", "--format=", "--patch", "--binary", "--no-ext-diff", "--no-textconv", "origin/main..HEAD", "--"], at: directory)
        var diff = history + (try await git(["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"], at: directory))
        var stat = try await git(["diff", "--stat", "HEAD", "--"], at: directory)
        stat += try await git(["diff", "--stat", "origin/main...HEAD", "--"], at: directory)
        let untracked = try await git(["ls-files", "--others", "--exclude-standard", "-z"], at: directory)
        for name in untracked.split(separator: "\0") {
            let path = directory.appendingPathComponent(String(name))
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 2_000_000 else {
                throw PullRequestFailure(message: "未追蹤檔案含連結或過大檔案；請先手動檢查。")
            }
            let bytes = try Data(contentsOf: path)
            guard !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else {
                throw PullRequestFailure(message: "未追蹤二進位檔案無法進行文字秘密掃描，未送出。")
            }
            stat += "\n\(name) (new)"
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.isEmpty || text.hasSuffix("\n") ? 1 : 0)
            diff += "\ndiff --git a/\(name) b/\(name)\nnew file mode 100644\n--- /dev/null\n+++ b/\(name)\n@@ -0,0 +1,\(lines.count) @@\n"
                + lines.map { "+" + $0 }.joined(separator: "\n") + "\n"
            guard diff.utf8.count <= 8_000_000 else { throw PullRequestFailure(message: "Diff 太大，請分批提交。") }
        }
        guard diff.utf8.count <= 8_000_000 else { throw PullRequestFailure(message: "Diff 太大，請分批提交。") }
        guard !Self.hasBinaryPatch(diff) else { throw PullRequestFailure(message: "二進位 diff 無法進行文字秘密掃描，請先手動檢查。") }
        try FeedbackService.scanSecrets(diff)
        return Snapshot(head: head, status: status, diff: diff, stat: stat, origin: origin)
    }

    func submit(directory: URL, repository: String, identity: FeedbackIdentity,
                snapshot: Snapshot, title: String, description: String) async throws -> URL {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 256, description.utf8.count <= 60_000 else {
            throw PullRequestFailure(message: "請填寫標題，並確認內容長度。")
        }
        try FeedbackService.scanSecrets(title + "\n" + description + "\n" + snapshot.diff)
        let now = try await preflight(directory: directory, repository: repository, identity: identity)
        guard snapshot.fingerprint == now.fingerprint else { throw PullRequestFailure(message: "改動已變更，請關閉並重新執行 /pr。") }
        let repoName = String(repository.split(separator: "/")[1])
        let forkName = identity.username + "/" + repoName
        guard Self.validRepository(forkName) else { throw PullRequestFailure(message: "GitHub 帳號無效。") }
        var fork = try await api("/repos/" + forkName, identity: identity, allowMissing: true)
        if fork == nil {
            _ = try await api("/repos/\(repository)/forks", identity: identity, method: "POST", payload: [:])
            for _ in 0..<10 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                fork = try await api("/repos/" + forkName, identity: identity, allowMissing: true)
                if fork != nil { break }
            }
        }
        guard fork?["fork"] as? Bool == true,
              ((fork?["parent"] as? [String: Any])?["full_name"] as? String)?.lowercased() == repository.lowercased()
        else { throw PullRequestFailure(message: "Fork 尚未就緒或同名倉庫不是目標的 fork。") }
        guard snapshot.fingerprint == (try await Self.snapshot(at: directory)).fingerprint else {
            throw PullRequestFailure(message: "等待 fork 時改動已變更，請重新執行 /pr。")
        }
        let branch = Self.branchName(title: title)
        _ = try await Self.git(["switch", "-c", branch], at: directory)
        if !snapshot.status.isEmpty {
            _ = try await Self.git(["add", "-A"], at: directory)
            let staged = try await Self.git(["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "--"], at: directory)
            try FeedbackService.scanSecrets(staged)
            guard !Self.hasBinaryPatch(staged) else { throw PullRequestFailure(message: "暫存區含二進位改動，未推送。") }
            if !staged.isEmpty {
                _ = try await Self.git(["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "commit", "-m", title], at: directory)
            }
        }
        let committed = try await Self.snapshot(at: directory)
        guard committed.status.isEmpty else {
            throw PullRequestFailure(message: "提交期間出現其他改動，未推送。請先停止引擎並檢查本機分支。")
        }
        let commitID = committed.head.trimmingCharacters(in: .whitespacesAndNewlines)
        // A command-scoped remote, NEVER git config on disk; URL and token are
        // absent from argv and errors. No credential helper or trace can persist it.
        let encoded = identity.token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let remote = "tatwo-pr-" + UUID().uuidString.lowercased()
        let environment = ["GIT_CONFIG_COUNT": "4", "GIT_CONFIG_KEY_0": "remote.\(remote).url",
                           "GIT_CONFIG_VALUE_0": "https://x-access-token:\(encoded)@github.com/\(forkName).git",
                           "GIT_CONFIG_KEY_1": "credential.helper", "GIT_CONFIG_VALUE_1": "",
                           "GIT_CONFIG_KEY_2": "http.followRedirects", "GIT_CONFIG_VALUE_2": "false",
                           "GIT_CONFIG_KEY_3": "remote.\(remote).pushurl",
                           "GIT_CONFIG_VALUE_3": "https://x-access-token:\(encoded)@github.com/\(forkName).git"]
        _ = try await Self.git(["-c", "core.hooksPath=/dev/null", "push", remote, commitID + ":refs/heads/" + branch], at: directory, environment: environment)
        // No persistent remote was added; the only durable URL remains origin.
        let result = try await api("/repos/\(repository)/pulls", identity: identity, method: "POST",
                                   payload: ["title": title, "body": Self.body(description: description),
                                             "head": identity.username + ":" + branch, "base": "main"])
        guard let raw = result?["html_url"] as? String, let url = URL(string: raw),
              url.scheme == "https", url.host == "github.com", url.user == nil,
              url.path.lowercased().hasPrefix("/\(repository.lowercased())/pull/") else {
            throw PullRequestFailure(message: "PR 網址尚未確認；請到 GitHub 檢查，不要重送。")
        }
        return url
    }

    /// Runs away from MainActor; stderr is drained but never exposed (git may
    /// echo credential URLs). No shell interpolation, inherited git tracing or logs.
    static func git(_ arguments: [String], at directory: URL,
                    environment: [String: String] = [:]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-c", "core.fsmonitor=false", "-c", "diff.external=", "-c", "core.quotePath=false"] + arguments
                process.currentDirectoryURL = directory
                var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                           "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]
                env.merge(environment) { _, new in new }; process.environment = env
                let output = Pipe(); process.standardOutput = output
                process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
                    var data = Data(); var oversized = false
                    while true {
                        let chunk = output.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        if data.count + chunk.count <= 8_000_000 { data.append(chunk) } else { oversized = true }
                    }
                    process.waitUntilExit(); timeout.cancel()
                    guard process.terminationStatus == 0, !oversized else {
                        throw PullRequestFailure(message: "Git 操作未完成或輸出過大。請檢查專案、origin/main、本機分支及 GitHub 狀態；既有檔案與 commit 均保留。")
                    }
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } catch let failure as PullRequestFailure {
                    continuation.resume(throwing: failure)
                } catch { continuation.resume(throwing: PullRequestFailure(message: "Git 操作失敗；未刪除或重設本機改動。")) }
            }
        }
    }
}
