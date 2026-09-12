import Foundation
import AppKit

/// TATWO2_SELFTEST=1 時無頭跑一輪：開討論串 → 送一句 → 等結果 → 印出訊息 → 退出。給腳本驗證 Swift↔sidecar 通路用。
enum SelfTest {
    @MainActor private static var headlessHostModel: ChatPageModel?

    @MainActor static func runIfRequested() {
        if ProcessInfo.processInfo.environment["TATWO2_NATIVEGOALTEST"] == "1" {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { @MainActor in
                do { exit(try await ChatNativeGoalAcceptance.run() ? 0 : 1) }
                catch { print("NATIVEGOALTEST ERROR \(error)"); exit(1) }
            }
            NSApplication.shared.run()
            return
        }
        if ProcessInfo.processInfo.environment["TATWO2_CHATSTEERINGTEST"] == "1" {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { @MainActor in
                do { exit(try await ChatSteeringAcceptance.run() ? 0 : 1) }
                catch { print("CHATSTEERINGTEST ERROR \(error)"); exit(1) }
            }
            NSApplication.shared.run()
            return
        }
        if ProcessInfo.processInfo.environment["TATWO2_CHATATTACHMENTTEST"] == "1" {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { @MainActor in
                do { exit(try await ChatAttachmentAcceptance.run() ? 0 : 1) }
                catch { print("CHATATTACHMENTTEST ERROR \(error)"); exit(1) }
            }
            NSApplication.shared.run()
            return
        }
        if ProcessInfo.processInfo.environment["TATWO2_DISCUSSIONCOMMANDTEST"] == "1" {
            exit(DiscussionCommandAcceptance.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["TATWO2_BROWSERRUNTIMETEST"] == "1" {
            setvbuf(stdout, nil, _IOLBF, 0)
            let app = TatwoCEFApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in exit(await BrowserRuntimeAcceptance.run() ? 0 : 1) }
            app.run()
            return
        }
        if ProcessInfo.processInfo.environment["TATWO2_BROWSERMETADATATEST"] == "1" {
            exit(BrowserMetadataAcceptance.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["TATWO2_BROWSERNAVIGATIONTEST"] == "1" {
            exit(BrowserNavigationAcceptance.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["TATWO2_BROWSERINPUTTEST"] == "1" {
            exit(BrowserInputAcceptance.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["TATWO2_BROWSERROUTINGTEST"] == "1" {
            exit(BrowserRoutingAcceptance.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["TATWO2_BROWSERIDENTITYTEST"] == "1" {
            do { exit(try BrowserIdentityAcceptance.run() ? 0 : 1) }
            catch { print("BROWSERIDENTITYTEST ERROR \(error)"); exit(1) }
        }
        if ProcessInfo.processInfo.environment["TATWO2_BGCOMPLETIONTEST"] == "1" {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { @MainActor in
                do { exit(try await BackgroundCompletionAcceptance.run() ? 0 : 1) }
                catch { print("BGCOMPLETIONTEST ERROR \(error)"); exit(1) }
            }
            NSApplication.shared.run()
            return
        }
        if ProcessInfo.processInfo.environment["TATWO2_TURNLIFECYCLETEST"] == "1" {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { @MainActor in
                do { exit(try await TurnLifecycleAcceptance.run() ? 0 : 1) }
                catch { print("TURNLIFECYCLETEST ERROR \(error)"); exit(1) }
            }
            NSApplication.shared.run()
            return
        }
        if ProcessInfo.processInfo.environment["TATWO2_STREAMAPPENDTEST"] == "1" {
            exit(StreamingAppendAcceptance.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["TATWO2_BROWSERSOCKETTEST"] == "1" {
            exit(BrowserSocketAcceptance.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["TATWO2_CHATSELECTIONTEST"] == "1" {
            exit(ChatSelectionAcceptance.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["TATWO2_MODELPREFERENCESTEST"] == "1" {
            exit(ModelPreferencesAcceptance.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["TATWO2_ISSUECOMMANDTEST"] == "1" {
            exit(IssueCommandAcceptance.run() ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["TATWO2_BOTUITEST"] == "1" {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task.detached {
                do { try await BotUIAcceptance.run(); exit(0) }
                catch { print("BOTUITEST FAIL \(error)"); exit(1) }
            }
            NSApplication.shared.run()
            return
        }
        if ProcessInfo.processInfo.environment["TATWO2_ISLANDTEST"] == "1" {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task { @MainActor in exit(await IslandCoreAcceptance.run() ? 0 : 1) }
            NSApplication.shared.run()
            return
        }
        if ProcessInfo.processInfo.environment["TATWO2_BOTCORETEST"] == "1" { runBotCoreTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_CLITEST"] == "1" { runCLISessionsTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_DOCSTEST"] == "1" { runDocumentsTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_GITHUBMCPTEST"] == "1" { runGitHubMCPTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_GITHUBTEST"] == "1" { runGitHubTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_HEADLESS_HOST"] == "1" { runHeadlessHost(); return }
        if ProcessInfo.processInfo.environment["TATWO2_PARALLELTEST"] == "1" { runParallelTest(prefix: "PARALLELTEST", includeTransfers: true); return }
        if ProcessInfo.processInfo.environment["TATWO2_REMOTEUITEST"] == "1" { runRemoteUITest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_MCPDEFAULTTEST"] == "1" { runMCPDefaultTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_REAPTEST"] == "1" { runReapTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_SWEEPTEST"] == "1" { runSweepTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_BROWSERTEST"] == "1" { runBrowserAgentTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_WATCHDOGTEST"] == "1" { runWatchdogTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_PTYTEST"] == "1" { runPTYTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_SWITCHTEST"] == "1" { runSwitchTest() }
        if ProcessInfo.processInfo.environment["TATWO2_ACCEPT"] == "1" { runAcceptance() }
        if ProcessInfo.processInfo.environment["TATWO2_LIVETEST"] == "1" { runLiveTest() }
        if ProcessInfo.processInfo.environment["TATWO2_COMPOSERTEST"] == "1" { runComposerTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_SOURCETEST"] == "1" { runSourceTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_DISPATCHTEST"] == "1" { runDispatchTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_BGTEST"] == "1" { runBackgroundTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_RECLAIMTEST"] == "1" { runReclaimTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_REMOTETEST"] == "1" { runRemoteTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_BINDTEST"] == "1" { runBindTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_GITHUBIMPORT"] == "1" { runGitHubImport(); return }
        if ProcessInfo.processInfo.environment["TATWO2_LOGINTEST"] == "1" { runLoginTest(); return }
        if ProcessInfo.processInfo.environment["TATWO2_ENGINEHOMETEST"] == "1" { runEngineHomeTest(); return }
        setvbuf(stdout, nil, _IOLBF, 0)   // 無頭鉤子輸出導到檔案時要逐行出來，不能等結束才吐
        if ProcessInfo.processInfo.environment["TATWO2_PAIRHOST"] == "1" { runPairHost(); return }
        if ProcessInfo.processInfo.environment["TATWO2_PAIRCLIENT"] != nil { runPairClient(); return }
        if ProcessInfo.processInfo.environment["TATWO2_REMOTEPROBE"] != nil { runRemoteProbe(); return }
        if ProcessInfo.processInfo.environment["TATWO2_PAIRTEST"] == "1" { runPairTest(); return }
        guard ProcessInfo.processInfo.environment["TATWO2_SELFTEST"] == "1" else { return }
        let store = T2ThreadStore()
        var t = T2ChatThread(); t.title = "selftest"; t.cwd = "/tmp/tatwo2-fixture/tatwo2"
        let s = T2ChatSession(thread: t, store: store)
        s.send(ProcessInfo.processInfo.environment["TATWO2_SELFTEST_PROMPT"] ?? "只回一個詞：乒")
        Task { @MainActor in
            var ticks = 0
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                ticks += 1
                if let p = s.pendingPermission { print("PERMISSION \(p.tool) -> auto deny"); s.answerPermission(allow: false) }
                if (!s.isBusy && s.thread.messages.count > 1) || ticks > 240 {
                    let timedOut = ticks > 240
                    print("STATUS \(s.status)")
                    print("SESSION \(s.thread.sessionId ?? "nil")")
                    for m in s.thread.messages { print("\(m.role.rawValue.uppercased()) \(m.toolName ?? "") | \(m.text.replacingOccurrences(of: "\n", with: "⏎"))") }
                    if let e = s.lastError { print("ERROR \(e)") }
                    // 明確判定（Codex 收尾裁決）：要有真 assistant 回覆含預期字＋回合已終（不忙）＋無 error 才 PASS；否則 FAIL 並寫原因。
                    let expected = ProcessInfo.processInfo.environment["TATWO2_SELFTEST_EXPECT"] ?? "乒"
                    let reply = s.thread.messages.last(where: { $0.role == .assistant && ($0.toolName ?? "").isEmpty })?.text ?? ""
                    let reasons = SelfTest.selfTestVerdictReasons(reply: reply, isBusy: s.isBusy, error: s.lastError.map { "\($0)" }, timedOut: timedOut, expected: expected)
                    print(reasons.isEmpty ? "SELFTEST PASS" : "SELFTEST FAIL \(reasons.joined(separator: "; "))")
                    store.delete(s.thread.id)
                    s.shutdown()
                    try? await Task.sleep(for: .milliseconds(500))
                    exit(reasons.isEmpty ? 0 : 1)
                }
            }
        }
        NSApplication.shared.run()
    }
}

extension SelfTest {
    /// TATWO2_DOCSTEST=1：只在暫存 OS/docs 根驗文件清單、備份上限與上游即時重讀。
    @MainActor static func runDocumentsTest() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("tatwo2-docstest-\(UUID().uuidString.lowercased())", isDirectory: true)
        let osRoot = base.appendingPathComponent("os", isDirectory: true)
        let docsRoot = base.appendingPathComponent("docs", isDirectory: true)
        try? fileManager.createDirectory(at: osRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: docsRoot, withIntermediateDirectories: true)
        setenv("TATWO2_OS_ROOT", osRoot.path, 1)
        setenv("TATWO2_DOCS_ROOT", docsRoot.path, 1)
        unsetenv("TATWO2_SKILLET_PATH")
        unsetenv("TATWO2_OS_UPSTREAM_PATH")

        let seeds = [
            docsRoot.appendingPathComponent("os.md"): "# os\n原始規則\n",
            osRoot.appendingPathComponent("skillet.md"): "# skillet\n常用技能\n",
            docsRoot.appendingPathComponent("todo.md"): "# todo\n施工單\n",
            docsRoot.appendingPathComponent("issue.md"): "# issue\n待拍板\n",
        ]
        for (url, text) in seeds {
            try? Data(text.utf8).write(to: url, options: .atomic)
        }

        var failed = false
        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("DOCSTEST \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }

        let documents = OSDocuments.list()
        let audiences = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.audience) })
        check(
            "五份文件與 audience",
            documents.count == 5
                && audiences["os"] == .user
                && audiences["skillet"] == .user
                && audiences["os-upstream"] == .user
                && audiences["todo"] == .engineering
                && audiences["issue"] == .engineering,
            "count=\(documents.count) user=\(audiences.filter { $0.value == .user }.count) engineering=\(audiences.filter { $0.value == .engineering }.count)")

        let osBackupsBefore = OSDocuments.backupURLs(id: "os").count
        do {
            try OSDocuments.write(id: "os", text: "# os\n更新後\n")
            let text = try OSDocuments.read(id: "os")
            let backups = OSDocuments.backupURLs(id: "os").count
            check(
                "atomic write 與先備份",
                text == "# os\n更新後\n" && backups == osBackupsBefore + 1,
                "content=\(text == "# os\n更新後\n") backups=\(backups)")
        } catch {
            check("atomic write 與先備份", false, "error=\(error.localizedDescription)")
        }

        do {
            try OSDocuments.write(id: "todo", text: "# todo\n第 0 版\n")
            let oldest = OSDocuments.backupURLs(id: "todo").first?.lastPathComponent
            for index in 1...24 {
                try OSDocuments.write(id: "todo", text: "# todo\n第 \(index) 版\n")
            }
            let backups = OSDocuments.backupURLs(id: "todo")
            check(
                "備份最多 20 份且清最舊",
                backups.count == 20
                    && oldest.map { name in !backups.contains(where: { $0.lastPathComponent == name }) } == true,
                "count=\(backups.count) oldestRemoved=\(oldest.map { name in !backups.contains(where: { $0.lastPathComponent == name }) } ?? false)")
        } catch {
            check("備份最多 20 份且清最舊", false, "error=\(error.localizedDescription)")
        }

        do {
            let updated = "# os upstream\n下一條對話的新內容\n"
            try OSDocuments.write(id: "os-upstream", text: updated)
            check(
                "os-upstream 下一次 declaration 即時重讀",
                OSUpstream.declaration() == updated,
                "overrideInTempDocs=\(OSUpstream.overridePath == docsRoot.appendingPathComponent("os-upstream.md").path) reloaded=\(OSUpstream.declaration() == updated)")
        } catch {
            check("os-upstream 下一次 declaration 即時重讀", false, "error=\(error.localizedDescription)")
        }

        try? fileManager.removeItem(at: base)
        print(failed ? "DOCSTEST FAILED" : "DOCSTEST ALL PASS")
        exit(failed ? 1 : 0)
    }
}

extension SelfTest {
    /// TATWO2_GITHUBMCPTEST=1：暫存帳號檔＋測試 Keychain，驗每帳號 MCP、常駐預設與 sidecar config；不印 token 值。
    @MainActor static func runGitHubMCPTest() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let fileManager = FileManager.default
        let runID = UUID().uuidString.lowercased()
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("tatwo2-githubmcptest-\(runID)", isDirectory: true)
        let liveRoot = base.appendingPathComponent("live", isDirectory: true)
        try? fileManager.createDirectory(at: liveRoot, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        environment["TATWO2_LIVE_ROOT"] = liveRoot.path
        environment["TATWO2_GITHUB_KEYCHAIN_SERVICE"] = "tatwo2-github-mcp-test-\(runID)"
        environment["TATWO2_GITHUB_SKIP_VERIFY"] = "1"
        environment["TATWO2_GITHUB_CREDENTIAL_FIXTURE"] = "memory"
        print("GITHUBMCPTEST NOTE memory credential fixture requested（真 Keychain 驗收 BLOCKED；不因 mapping 通過解除門檻）")
        environment["TATWO2_GITHUB_MCP_SERVER_PATH"] = base
            .appendingPathComponent("runtime/bin/github-mcp-server").path

        let store = GitHubAccountsStore(environment: environment)
        let accountA = "A"
        let accountB = "B"
        let nameA = "github-\(accountA)"
        let nameB = "github-\(accountB)"
        var failed = false

        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("GITHUBMCPTEST \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }

        func serverHasTokenEnvironment(_ config: String?, name: String) -> Bool {
            guard
                let config,
                let data = config.data(using: .utf8),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let servers = root["servers"] as? [String: Any],
                let server = servers[name] as? [String: Any],
                let env = server["env"] as? [String: Any]
            else { return false }
            return env.keys.contains("GITHUB_PERSONAL_ACCESS_TOKEN")
        }

        do {
            _ = try store.addTestAccount(
                username: accountA,
                token: "github-mcp-test-a-\(UUID().uuidString)")
            _ = try store.addTestAccount(
                username: accountB,
                token: "github-mcp-test-b-\(UUID().uuidString)")
            try store.setGitHubMCPAlwaysOn(username: accountA, on: true)
            try store.setGitHubMCPAlwaysOn(username: accountB, on: false)

            let rows = try store.loadAccounts()
            check(
                "帳號常駐欄位",
                rows.first(where: { $0.username == accountA })?.mcpAlwaysOn == true
                    && rows.first(where: { $0.username == accountB })?.mcpAlwaysOn == false,
                "A=true B=false")

            let defaults = PluginsSource.effectiveEnabledNames(
                stored: [],
                engine: .codex,
                environment: environment)
            check(
                "空 stored 套用常駐",
                defaults.contains(nameA) && !defaults.contains(nameB),
                "containsA=\(defaults.contains(nameA)) containsB=\(defaults.contains(nameB))")

            let storedB = PluginsSource.effectiveEnabledNames(
                stored: [nameB],
                engine: .codex,
                environment: environment)
            check(
                "手開 B",
                storedB == [nameB],
                "enabled=\(storedB)")

            let entries = PluginsSource.scanNow(environment: environment)
            let entryIDs = Set(entries.filter { $0.kind == .mcp }.map(\.id))
            check(
                "資訊卡 configured 清單",
                entryIDs.contains(PluginsSource.pluginID(engine: .codex, name: nameA))
                    && entryIDs.contains(PluginsSource.pluginID(engine: .codex, name: nameB))
                    && entryIDs.contains(PluginsSource.pluginID(engine: .claude, name: nameA))
                    && entryIDs.contains(PluginsSource.pluginID(engine: .claude, name: nameB)),
                "codexA=true codexB=true claudeA=true claudeB=true")

            let codexConfig = PluginsSource.sidecarMCPConfig(
                engine: .codex,
                stored: [],
                environment: environment)
            check(
                "Codex mcp-config token env",
                serverHasTokenEnvironment(codexConfig, name: nameA)
                    && !serverHasTokenEnvironment(codexConfig, name: nameB),
                "\(nameA) envKey=true \(nameB) envKey=false valuePrinted=false")

            let claudeConfig = PluginsSource.sidecarMCPConfig(
                engine: .claude,
                stored: [],
                environment: environment)
            check(
                "Claude mcp-config token env",
                serverHasTokenEnvironment(claudeConfig, name: nameA),
                "\(nameA) envKey=true valuePrinted=false")

            let grokConfig = PluginsSource.sidecarMCPConfig(
                engine: .grok,
                stored: [],
                environment: environment)
            let grokHasGitHub = grokConfig?.contains(nameA) == true || grokConfig?.contains(nameB) == true
            check(
                "Grok 本輪不接",
                !grokHasGitHub,
                "githubEntry=false")
        } catch {
            check(
                "執行",
                false,
                "error=\(error.localizedDescription.replacingOccurrences(of: "\n", with: " "))")
        }

        try? store.removeAccount(accountA)
        try? store.removeAccount(accountB)
        try? fileManager.removeItem(at: base)
        if store.usesCredentialFixture {
            print("GITHUBMCPTEST BLOCKED real-keychain integration not run（memory credential fixture；mapping 案僅供資訊，原門檻不解除）")
            exit(1)
        }
        print(failed ? "GITHUBMCPTEST FAILED" : "GITHUBMCPTEST ALL PASS")
        exit(failed ? 1 : 0)
    }
}

extension SelfTest {
    /// TATWO2_GITHUBTEST=1：只用暫存 LIVE_ROOT／gitconfig 與 tatwo2-github-test Keychain 服務驗多帳號 helper。
    @MainActor static func runGitHubTest() {
        setvbuf(stdout, nil, _IOLBF, 0)
        struct Result {
            var status: Int32
            var stdout: String
            var stderr: String
        }

        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("tatwo2-githubtest-\(UUID().uuidString.lowercased())", isDirectory: true)
        let liveRoot = base.appendingPathComponent("live", isDirectory: true)
        let gitConfig = base.appendingPathComponent("gitconfig")
        let mappedPath = URL(fileURLWithPath: "/tmp/jns-\(UUID().uuidString.lowercased())", isDirectory: true)
        try? fileManager.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: mappedPath, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        environment["TATWO2_LIVE_ROOT"] = liveRoot.path
        environment["GIT_CONFIG_GLOBAL"] = gitConfig.path
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["XDG_CONFIG_HOME"] = base.appendingPathComponent("xdg", isDirectory: true).path
        environment["TATWO2_GITHUB_KEYCHAIN_SERVICE"] = "tatwo2-github-test"
        environment["TATWO2_GITHUB_SKIP_VERIFY"] = "1"
        environment["TATWO2_GITHUB_CREDENTIAL_FIXTURE"] = "memory"   // DEBUG-only 純記憶體 fixture：只驗 mapping／隔離；本 hook 最終一律 BLOCKED
        print("GITHUBTEST NOTE memory credential fixture requested（真 Keychain 驗收 BLOCKED；不因 mapping 通過解除門檻）")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"

        func run(
            _ executable: String,
            _ arguments: [String],
            input: String? = nil,
            cwd: URL? = nil
        ) -> Result {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = cwd
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            var stdin: Pipe?
            if input != nil {
                let pipe = Pipe()
                process.standardInput = pipe
                stdin = pipe
            }
            do {
                try process.run()
                if let input, let stdin {
                    stdin.fileHandleForWriting.write(Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                }
            } catch {
                return Result(status: -1, stdout: "", stderr: error.localizedDescription)
            }
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self))
        }

        func securityDelete(_ username: String) {
            // fixture 模式（純記憶體）不得碰任何 Security 子程序：含前置清理與錯誤路徑的清理都 no-op
            if environment["TATWO2_GITHUB_CREDENTIAL_FIXTURE"] != nil {
                print("GITHUBTEST NOTE securityDelete skipped（memory credential fixture；不觸 /usr/bin/security）")
                return
            }
            _ = run(
                "/usr/bin/security",
                ["delete-generic-password", "-s", "tatwo2-github-test", "-a", username])
        }

        func fields(_ output: String) -> [String: String] {
            Dictionary(uniqueKeysWithValues: output.split(whereSeparator: \.isNewline).compactMap { line in
                guard let split = line.firstIndex(of: "=") else { return nil }
                return (String(line[..<split]), String(line[line.index(after: split)...]))
            })
        }

        func credentialFill(_ input: String, cwd: URL = base) -> Result {
            run("/usr/bin/git", ["credential", "fill"], input: input, cwd: cwd)
        }

        var failed = false
        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("GITHUBTEST \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }

        let accountA = "tatwo2-test-a"
        let accountB = "tatwo2-test-b"
        let tokenA = "test-secret-a-\(UUID().uuidString)"
        let tokenB = "test-secret-b-\(UUID().uuidString)"
        securityDelete(accountA)
        securityDelete(accountB)

        let setOriginal = run(
            "/usr/bin/git",
            ["config", "--global", "--add", "credential.helper", "cache --timeout=7"])
        _ = run("/usr/bin/git", ["config", "--global", "credential.useHttpPath", "true"])
        check(
            "暫存 gitconfig",
            setOriginal.status == 0 && gitConfig.path.hasPrefix(base.path),
            "status=\(setOriginal.status) isolated=true")

        let store = GitHubAccountsStore(environment: environment)
        do {
            _ = try store.addTestAccount(username: accountA, token: tokenA)
            _ = try store.addTestAccount(username: accountB, token: tokenB)
            let rows = try store.loadAccounts()
            check(
                "加入兩個假帳號",
                rows.count == 2 && rows.map(\.username).contains(accountA) && rows.map(\.username).contains(accountB),
                "count=\(rows.count) usernames=\(rows.map(\.username).sorted())")

            try store.setDefault(accountA)
            try store.addFolderMapping(account: accountB, path: mappedPath.path)
            let configured = try store.loadAccounts()
            check(
                "預設與資料夾對映",
                configured.first(where: { $0.username == accountA })?.isDefault == true
                    && configured.first(where: { $0.username == accountB })?.folderMappings.contains(mappedPath.path) == true,
                "default=\(configured.first(where: \.isDefault)?.username ?? "nil") mappedAccount=\(accountB)")

            if store.usesCredentialFixture {
                // fixture 模式：helper 是另一個程序、讀真 Keychain，不能也不該跑 → 在呼叫前就 BLOCKED 跳過
                print("GITHUBTEST BLOCKED real-keychain integration not run（memory credential fixture；helper 三案跳過，原門檻不解除）")
                exit(1)
            }
            try store.installHelper()
            check(
                "安裝 helper",
                store.isHelperInstalled() && fileManager.isExecutableFile(atPath: store.helperDestinationURL.path),
                "installed=\(store.isHelperInstalled()) executable=\(fileManager.isExecutableFile(atPath: store.helperDestinationURL.path))")

            let byUsername = credentialFill(
                "protocol=https\nhost=github.com\nusername=\(accountB)\n\n")
            let usernameFields = fields(byUsername.stdout)
            check(
                "帶 username 選 B",
                byUsername.status == 0
                    && usernameFields["username"] == accountB
                    && usernameFields["password"] == tokenB,
                "status=\(byUsername.status) username=\(usernameFields["username"] ?? "nil") passwordMatch=\(usernameFields["password"] == tokenB)")

            let byPath = credentialFill(
                "protocol=https\nhost=github.com\npath=\(mappedPath.path)/repo.git\n\n")
            let pathFields = fields(byPath.stdout)
            check(
                "path 對映選 B",
                byPath.status == 0
                    && pathFields["username"] == accountB
                    && pathFields["password"] == tokenB,
                "status=\(byPath.status) username=\(pathFields["username"] ?? "nil") passwordMatch=\(pathFields["password"] == tokenB)")

            let byDefault = credentialFill("protocol=https\nhost=github.com\n\n")
            let defaultFields = fields(byDefault.stdout)
            check(
                "無指定時選預設 A",
                byDefault.status == 0
                    && defaultFields["username"] == accountA
                    && defaultFields["password"] == tokenA,
                "status=\(byDefault.status) username=\(defaultFields["username"] ?? "nil") passwordMatch=\(defaultFields["password"] == tokenA)")

            let gitlab = credentialFill("protocol=https\nhost=gitlab.com\n\n")
            check(
                "非 github.com 回空",
                gitlab.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "status=\(gitlab.status) stdoutBytes=\(gitlab.stdout.utf8.count)")

            try store.restoreHelper()
            let restored = run(
                "/usr/bin/git",
                ["config", "--global", "--get-all", "credential.helper"])
            let restoredHelpers = restored.stdout.split(whereSeparator: \.isNewline).map(String.init)
            check(
                "還原原 helper",
                restored.status == 0 && restoredHelpers == ["cache --timeout=7"],
                "status=\(restored.status) helpers=\(restoredHelpers)")

            try store.removeAccount(accountA)
            try store.removeAccount(accountB)
            check(
                "移除帳號後 Keychain 查不到",
                !store.keychainContains(accountA) && !store.keychainContains(accountB),
                "A=false B=false")
        } catch {
            check(
                "執行",
                false,
                "error=\(error.localizedDescription.replacingOccurrences(of: "\n", with: " "))")
        }

        securityDelete(accountA)
        securityDelete(accountB)
        try? fileManager.removeItem(at: mappedPath)
        try? fileManager.removeItem(at: base)
        if environment["TATWO2_GITHUB_CREDENTIAL_FIXTURE"] != nil {
            print("GITHUBTEST BLOCKED real-keychain integration not run（memory credential fixture；helper 讀真 Keychain 三案本來就 FAIL；原門檻不解除）")
            exit(1)
        }
        print(failed ? "GITHUBTEST FAILED" : "GITHUBTEST ALL PASS")
        exit(failed ? 1 : 0)
    }
}

extension SelfTest {
    /// R2 驗收子行程：只起 live model＋os.sock，不建立 Tatwo 視窗。
    @MainActor static func runHeadlessHost() {
        var environment = ProcessInfo.processInfo.environment
        environment["TATWO2_HEADLESS_HOST"] = nil
        environment["TATWO2_REMOTEUITEST"] = nil
        let model = ChatPageModel(environment: environment)
        headlessHostModel = model
        print("REMOTEUIHOST READY socket=\(OSAgentBridge.shared.socketPath)")
        fflush(stdout)
        NSApplication.shared.run()
    }
}

extension SelfTest {
    /// TATWO2_REMOTEUITEST=1：同機兩個 LIVE_ROOT，經 ssh stream-local forward 驗完整 R2 遙控切換。
    @MainActor static func runRemoteUITest() {
        if ProcessInfo.processInfo.environment["TATWO2_REMOTEUITEST"] == "1" {
            runParallelTest(prefix: "REMOTEUITEST", includeTransfers: false)
            return
        }
        let fm = FileManager.default
        let runID = UUID().uuidString.lowercased()
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("t2rui-\(runID.prefix(8))", isDirectory: true)
        let hostRoot = base.appendingPathComponent("A", isDirectory: true)
        let clientRoot = base.appendingPathComponent("B", isDirectory: true)
        let hostSocket = hostRoot.appendingPathComponent("os.sock")
        let clientSocket = clientRoot.appendingPathComponent("os.sock")
        let hostBrowserSocket = hostRoot.appendingPathComponent("browser.sock")
        let clientBrowserSocket = clientRoot.appendingPathComponent("browser.sock")
        try? fm.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: clientRoot, withIntermediateDirectories: true)

        let projectID = UUID()
        let threadID = UUID()
        let hostProject = LiveProjectRecord(
            id: projectID,
            name: "A 主機專案",
            workdir: base.appendingPathComponent("missing-host-workdir").path)
        let hostThread = LiveThreadRecord(
            id: threadID,
            projectID: projectID,
            title: "A 主機討論串",
            messages: [LiveMessageRecord(ChatMessage(role: .assistant, text: "A ready"))])
        ChatLiveStore(root: hostRoot).save(
            LiveDocumentRecord(
                projects: [hostProject],
                threads: [hostThread],
                selectedThreadID: threadID))

        let device = DeviceRecord(
            id: "remoteuitest-\(runID)",
            name: "A localhost",
            host: "localhost",
            user: NSUserName(),
            sshPort: 22,
            publicKeyFingerprint: "remoteuitest",
            addedAt: Date(),
            lastSeenAt: Date(),
            workdirMap: [:])
        do {
            try DeviceRegistry(root: hostRoot).add(device)
            try DeviceRegistry(root: clientRoot).add(device)
        } catch {
            print("REMOTEUITEST FAIL 準備 devices.json — error=\(error.localizedDescription)")
            print("REMOTEUITEST FAILED")
            exit(1)
        }

        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath))
                .standardizedFileURL
        let host = Process()
        host.executableURL = executable
        var hostEnvironment = ProcessInfo.processInfo.environment
        hostEnvironment["TATWO2_REMOTEUITEST"] = nil
        hostEnvironment["TATWO2_HEADLESS_HOST"] = "1"
        hostEnvironment["TATWO2_SELFTEST"] = nil
        hostEnvironment["TATWO2_LIVE_ROOT"] = hostRoot.path
        hostEnvironment["TATWO2_OS_SOCKET"] = hostSocket.path
        hostEnvironment["TATWO2_BROWSER_SOCKET"] = hostBrowserSocket.path
        host.environment = hostEnvironment
        let hostLog = Pipe()
        host.standardOutput = hostLog
        host.standardError = hostLog

        var failed = false
        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("REMOTEUITEST \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }
        func stopHost() {
            if host.isRunning {
                host.terminate()
                host.waitUntilExit()
            }
        }

        do {
            try host.run()
        } catch {
            check("主機無頭模式", false, "launch error=\(error.localizedDescription)")
            print("REMOTEUITEST FAILED")
            exit(1)
        }

        let socketDeadline = Date().addingTimeInterval(10)
        while Date() < socketDeadline, !fm.fileExists(atPath: hostSocket.path), host.isRunning {
            usleep(50_000)
        }
        check(
            "主機無頭模式",
            host.isRunning && fm.fileExists(atPath: hostSocket.path),
            "pid=\(host.processIdentifier) socket=\(fm.fileExists(atPath: hostSocket.path))")
        guard !failed else {
            stopHost()
            let log = String(decoding: hostLog.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            print("REMOTEUITEST HOSTLOG \(log.replacingOccurrences(of: "\n", with: " | "))")
            print("REMOTEUITEST FAILED")
            exit(1)
        }

        setenv("TATWO2_LIVE_ROOT", clientRoot.path, 1)
        setenv("TATWO2_OS_SOCKET", clientSocket.path, 1)
        setenv("TATWO2_BROWSER_SOCKET", clientBrowserSocket.path, 1)
        var clientEnvironment = ProcessInfo.processInfo.environment
        clientEnvironment["TATWO2_REMOTEUITEST"] = nil
        clientEnvironment["TATWO2_SELFTEST"] = nil
        clientEnvironment["TATWO2_LIVE_ROOT"] = clientRoot.path
        clientEnvironment["TATWO2_OS_SOCKET"] = clientSocket.path
        clientEnvironment["TATWO2_BROWSER_SOCKET"] = clientBrowserSocket.path
        clientEnvironment["TATWO2_REMOTE_OS_SOCKET"] = hostSocket.path

        let model = ChatPageModel(environment: clientEnvironment)
        let localIDsBefore = Set(model.document.projects.flatMap(\.threads).map(\.id))
        let entered = model.enterRemoteMode(device)
        check(
            "enterRemoteMode",
            entered && model.remoteMode?.id == device.id && model.remoteModeLabel == "遙控：A localhost",
            "entered=\(entered) label=\(model.remoteModeLabel ?? "nil")")
        check(
            "側欄看到 A 專案與討論串",
            model.document.projects.contains(where: { $0.id == projectID })
                && model.document.projects.flatMap(\.threads).contains(where: { $0.id == threadID }),
            "projects=\(model.document.projects.map(\.name)) threads=\(model.document.projects.flatMap(\.threads).map(\.title))")

        let createdThreadID = model.live?.newThread(in: projectID, title: "B 遙控新增")
        let hostHasCreatedThread = createdThreadID.map { createdID in
            ChatLiveStore(root: hostRoot).load().threads.contains { $0.id == createdID }
        } ?? false
        check(
            "new_thread",
            hostHasCreatedThread,
            "threadID=\(createdThreadID?.uuidString.lowercased() ?? "nil") hostContains=\(hostHasCreatedThread)")

        model.selectedThreadID = threadID
        model.prompt = "ping"
        model.send()
        let sendDeadline = Date().addingTimeInterval(2)
        var hostSawPing = false
        while Date() < sendDeadline {
            let record = ChatLiveStore(root: hostRoot).load()
                .threads.first(where: { $0.id == threadID })
            hostSawPing = record?.messages.contains(where: { $0.role == "user" && $0.text == "ping" }) == true
            if hostSawPing { break }
            usleep(50_000)
        }
        check(
            "B send(\"ping\") 寫入 A document",
            hostSawPing,
            "within2s=\(hostSawPing) hostMessages=\(ChatLiveStore(root: hostRoot).load().threads.first(where: { $0.id == threadID })?.messages.count ?? -1)")

        let remoteTranscript = model.live?.transcript(for: threadID) ?? []
        let transcriptSawPing = remoteTranscript.contains { $0.role == .user && $0.text == "ping" }
        check(
            "B transcript 看到 ping",
            transcriptSawPing,
            "messages=\(remoteTranscript.count) userPing=\(transcriptSawPing)")

        model.stop()
        check(
            "stop_thread",
            model.composerHint?.contains("遙控停止失敗") != true,
            "rpcError=\(model.composerHint?.contains("遙控停止失敗") == true)")

        model.exitRemoteMode()
        let localIDsAfter = Set(model.document.projects.flatMap(\.threads).map(\.id))
        check(
            "exitRemoteMode 回 B 本機文件",
            model.remoteMode == nil
                && !model.document.projects.contains(where: { $0.id == projectID })
                && localIDsAfter == localIDsBefore,
            "remote=nil localThreads=\(localIDsAfter.count) containsA=\(localIDsAfter.contains(threadID))")

        model.shutdownForContainerClose()
        stopHost()
        try? fm.removeItem(at: base)
        print(failed ? "REMOTEUITEST FAILED" : "REMOTEUITEST ALL PASS")
        exit(failed ? 1 : 0)
    }
}

extension SelfTest {
    /// TATWO2_PARALLELTEST=1：同機 A/B 驗遠端段、遠端送出、本機切回，以及逐條併回／拉到。
    @MainActor static func runParallelTest(prefix: String, includeTransfers: Bool) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let fm = FileManager.default
        let runID = UUID().uuidString.lowercased()
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("t2parallel-\(runID.prefix(8))", isDirectory: true)
        let hostRoot = base.appendingPathComponent("A", isDirectory: true)
        let clientRoot = base.appendingPathComponent("B", isDirectory: true)
        let hostWorkdir = base.appendingPathComponent("A-work", isDirectory: true)
        let clientWorkdir = base.appendingPathComponent("B-work", isDirectory: true)
        let hostSocket = hostRoot.appendingPathComponent("os.sock")
        let clientSocket = clientRoot.appendingPathComponent("os.sock")
        let hostBrowserSocket = hostRoot.appendingPathComponent("browser.sock")
        let clientBrowserSocket = clientRoot.appendingPathComponent("browser.sock")
        for directory in [hostRoot, clientRoot, hostWorkdir, clientWorkdir] {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let hostProjectID = UUID()
        let hostThreadID = UUID()
        ChatLiveStore(root: hostRoot).save(LiveDocumentRecord(
            projects: [
                LiveProjectRecord(
                    id: hostProjectID,
                    name: "A 主機專案",
                    workdir: hostWorkdir.path),
            ],
            threads: [
                LiveThreadRecord(
                    id: hostThreadID,
                    projectID: hostProjectID,
                    title: "A 主機討論串",
                    messages: [
                        LiveMessageRecord(ChatMessage(role: .assistant, text: "A ready")),
                    ]),
            ],
            selectedThreadID: hostThreadID))

        let clientProjectID = UUID()
        let clientThreadID = UUID()
        ChatLiveStore(root: clientRoot).save(LiveDocumentRecord(
            projects: [
                LiveProjectRecord(
                    id: clientProjectID,
                    name: "B 本機專案",
                    workdir: clientWorkdir.path),
            ],
            threads: [
                LiveThreadRecord(
                    id: clientThreadID,
                    projectID: clientProjectID,
                    title: "B 要搬的討論串",
                    messages: [
                        LiveMessageRecord(ChatMessage(role: .user, text: "第一則")),
                        LiveMessageRecord(ChatMessage(role: .assistant, text: "第二則")),
                    ]),
            ],
            selectedThreadID: clientThreadID))

        let device = DeviceRecord(
            id: "parallel-\(runID)",
            name: "A localhost",
            host: "localhost",
            user: NSUserName(),
            sshPort: 22,
            publicKeyFingerprint: "paralleltest",
            addedAt: Date(),
            lastSeenAt: Date(),
            workdirMap: [:])
        do {
            try DeviceRegistry(root: clientRoot).add(device)
        } catch {
            print("\(prefix) FAIL 準備 B devices.json — error=\(error.localizedDescription)")
            print("\(prefix) FAILED")
            exit(1)
        }

        let executable = Bundle.main.executableURL
            ?? URL(
                fileURLWithPath: CommandLine.arguments[0],
                relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath))
                .standardizedFileURL
        let host = Process()
        host.executableURL = executable
        var hostEnvironment = ProcessInfo.processInfo.environment
        hostEnvironment["TATWO2_PARALLELTEST"] = nil
        hostEnvironment["TATWO2_REMOTEUITEST"] = nil
        hostEnvironment["TATWO2_HEADLESS_HOST"] = "1"
        hostEnvironment["TATWO2_SELFTEST"] = nil
        hostEnvironment["TATWO2_LIVE_ROOT"] = hostRoot.path
        hostEnvironment["TATWO2_OS_SOCKET"] = hostSocket.path
        hostEnvironment["TATWO2_BROWSER_SOCKET"] = hostBrowserSocket.path
        host.environment = hostEnvironment
        let hostLog = Pipe()
        host.standardOutput = hostLog
        host.standardError = hostLog

        var failed = false
        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("\(prefix) \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }
        func stopHost() {
            if host.isRunning {
                host.terminate()
                host.waitUntilExit()
            }
        }
        func finish(_ model: ChatPageModel?) -> Never {
            model?.shutdownForContainerClose()
            stopHost()
            // 診斷（review 2026-09-06）：主機 log 一律倒出最後幾行；失敗時保留 fixture 讓人看原始狀態（不改斷言、不延長逾時）
            let log = String(decoding: hostLog.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let tail = log.split(separator: "\n").suffix(20).joined(separator: " | ")
            print("\(prefix) HOSTLOG-TAIL \(tail)")
            if failed { print("\(prefix) FIXTURE-KEPT \(base.path)") } else { try? fm.removeItem(at: base) }
            print(failed ? "\(prefix) FAILED" : "\(prefix) ALL PASS")
            exit(failed ? 1 : 0)
        }

        do {
            try host.run()
        } catch {
            check("A 主機無頭實例", false, "launch error=\(error.localizedDescription)")
            finish(nil)
        }
        let socketDeadline = Date().addingTimeInterval(10)
        while Date() < socketDeadline, !fm.fileExists(atPath: hostSocket.path), host.isRunning {
            usleep(50_000)
        }
        check(
            "A 主機無頭實例",
            host.isRunning && fm.fileExists(atPath: hostSocket.path),
            "pid=\(host.processIdentifier) socket=\(fm.fileExists(atPath: hostSocket.path))")
        guard !failed else {
            stopHost()
            let log = String(
                decoding: hostLog.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self)
            print("\(prefix) HOSTLOG \(log.replacingOccurrences(of: "\n", with: " | "))")
            finish(nil)
        }

        do {
            try DeviceRegistry(root: hostRoot).add(device)
        } catch {
            check("A 允許遠端方法", false, "devices.json error=\(error.localizedDescription)")
            finish(nil)
        }

        setenv("TATWO2_LIVE_ROOT", clientRoot.path, 1)
        setenv("TATWO2_OS_SOCKET", clientSocket.path, 1)
        setenv("TATWO2_BROWSER_SOCKET", clientBrowserSocket.path, 1)
        var clientEnvironment = ProcessInfo.processInfo.environment
        clientEnvironment["TATWO2_PARALLELTEST"] = "1"
        clientEnvironment["TATWO2_REMOTEUITEST"] = nil
        clientEnvironment["TATWO2_SELFTEST"] = nil
        clientEnvironment["TATWO2_LIVE_ROOT"] = clientRoot.path
        clientEnvironment["TATWO2_OS_SOCKET"] = clientSocket.path
        clientEnvironment["TATWO2_BROWSER_SOCKET"] = clientBrowserSocket.path
        clientEnvironment["TATWO2_REMOTE_OS_SOCKET"] = hostSocket.path
        let model = ChatPageModel(environment: clientEnvironment)

        let section = model.remoteSidebarSections.first {
            $0.deviceID == device.id
        }
        check(
            "B 啟動後有 A 遠端段且 online",
            section?.isOnline == true
                && section?.projects.contains(where: { $0.id == hostProjectID }) == true,
            "sections=\(model.remoteSidebarSections.count) online=\(section?.isOnline == true)")

        let selectedRemote = model.selectRemote(
            deviceID: device.id,
            threadID: hostThreadID)
        model.prompt = "ping"
        model.send()
        let sendDeadline = Date().addingTimeInterval(2)
        var hostSawPing = false
        while Date() < sendDeadline {
            hostSawPing = ChatLiveStore(root: hostRoot).load().threads
                .first(where: { $0.id == hostThreadID })?
                .messages.contains(where: {
                    $0.role == "user" && $0.text == "ping"
                }) == true
            if hostSawPing { break }
            usleep(50_000)
        }
        check(
            "選 A 討論串 send(\"ping\") 寫入 A",
            selectedRemote && hostSawPing,
            "selected=\(selectedRemote) hostSawPing=\(hostSawPing)")

        model.select(projectID: clientProjectID, threadID: clientThreadID)
        let localMessages = model.transcriptMessages
        check(
            "選回本機後 transcript 是 B 本機",
            model.selectedRemote == nil
                && Array(localMessages.map(\.text).prefix(2)) == ["第一則", "第二則"],
            "selectedRemote=\(model.selectedRemote == nil ? "nil" : "set") messages=\(localMessages.map(\.text))")

        guard includeTransfers else { finish(model) }

        let hostCountBeforePush = ChatLiveStore(root: hostRoot).load().threads.count
        let pushedThreadID = model.pushThreadToDevice(clientThreadID, device.id)
        let pushedThread = pushedThreadID.flatMap { pushedID in
            ChatLiveStore(root: hostRoot).load().threads.first {
                $0.id == pushedID
            }
        }
        let pushedTexts = pushedThread?.messages.map(\.text) ?? []
        print("\(prefix) DIAG push threadID=\(pushedThreadID?.uuidString.lowercased() ?? "nil") hint=\(model.composerHint ?? "nil") hostThreads=\(ChatLiveStore(root: hostRoot).load().threads.count) before=\(hostCountBeforePush)")
        check(
            "pushThreadToDevice 在 A 建同標題串含兩則與系統訊息",
            pushedThread?.title == "B 要搬的討論串"
                && pushedTexts.contains("第一則")
                && pushedTexts.contains("第二則")
                && pushedTexts.contains(where: { $0.contains("已併回 A localhost") })
                && ChatLiveStore(root: hostRoot).load().threads.count == hostCountBeforePush + 1,
            "threadID=\(pushedThreadID?.uuidString.lowercased() ?? "nil") messages=\(pushedTexts.count)")

        let clientCountBeforePull = ChatLiveStore(root: clientRoot).load().threads.count
        let pulledThreadID = pushedThreadID.flatMap {
            model.pullThreadFromDevice(device.id, $0)
        }
        if pushedThreadID == nil { print("\(prefix) DIAG pull skipped because push returned nil（不是獨立缺陷）") }
        else { print("\(prefix) DIAG pull threadID=\(pulledThreadID?.uuidString.lowercased() ?? "nil") hint=\(model.composerHint ?? "nil")") }
        let clientAfterPull = ChatLiveStore(root: clientRoot).load()
        let pulledThread = pulledThreadID.flatMap { pulledID in
            clientAfterPull.threads.first { $0.id == pulledID }
        }
        check(
            "pullThreadFromDevice 把 A 串拉回 B",
            pulledThread != nil
                && clientAfterPull.threads.count == clientCountBeforePull + 1
                && pulledThread?.messages.contains(where: {
                    $0.text.contains("已拉到這台，來源：B 要搬的討論串")
                }) == true,
            "threadID=\(pulledThreadID?.uuidString.lowercased() ?? "nil") Bthreads=\(clientAfterPull.threads.count)")

        finish(model)
    }
}

extension SelfTest {
    /// SELFTEST 的判定規則（純函式，MCPDEFAULTTEST 內跑反例，不用付費 live call）。
    static func selfTestVerdictReasons(reply: String, isBusy: Bool, error: String?, timedOut: Bool, expected: String) -> [String] {
        var reasons: [String] = []
        if timedOut { reasons.append("timeout 120s") }
        if isBusy { reasons.append("turn not terminal") }
        if let error { reasons.append("error: \(error)") }
        if !reply.contains(expected) { reasons.append("assistant reply lacks 「\(expected)」") }
        return reasons
    }

    static func runMCPDefaultTest() {
        // SELFTEST 判定反例（Codex 要求：假缺字／error／未終態／逾時都不能過；正例才空）
        let v = selfTestVerdictReasons
        let verdictNegatives = !v("乓", false, nil, false, "乒").isEmpty
            && !v("乒", false, "sidecar exit 1", false, "乒").isEmpty
            && !v("乒", true, nil, false, "乒").isEmpty
            && !v("", false, nil, true, "乒").isEmpty
            && v("乒", false, nil, true, "乒") == ["timeout 120s"]   // timeout-only：有預期字也逾時就 FAIL（只此一條原因）
            && v("好的：乒", false, nil, false, "乒").isEmpty
        print("MCPDEFAULTTEST \(verdictNegatives ? "PASS" : "FAIL") selftest-verdict-negatives")
        // liveness failed 呈現（2026-09-06）：failed 不論有無／新舊 timestamp 都是 .failed；running／done／nil 原語意不變
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let L = { (s: String?, d: Date?) in ThreadLiveness.from(status: s, lastOutputAt: d, now: t0) }
        let livenessFailed = L("failed", nil) == .failed && L("failed", t0.addingTimeInterval(-20 * 60)) == .failed && L("failed", t0.addingTimeInterval(-1)) == .failed
            && L("running", t0.addingTimeInterval(-1)) == .active && L("running", t0.addingTimeInterval(-6 * 60)) == .idle && L("running", t0.addingTimeInterval(-16 * 60)) == .stalled
            && L("running", nil) == .idle && L("done", t0.addingTimeInterval(-1)) == .done && L(nil, t0) == nil && ThreadLiveness.failed.rawValue == "failed" && ThreadLiveness.failed.label == "已失敗"
        print("MCPDEFAULTTEST \(livenessFailed ? "PASS" : "FAIL") liveness-failed-mapping")
        let configured = ["blender", "gbrain", "tatwo2_os", "tatwo_macbook", "shopify", "browser-bridge"]
        let defaults = PluginsSource.effectiveEnabledNames(stored: [], configured: configured).sorted()
        let expectedDefaults = ["browser-bridge", "tatwo2_os"]
        print("MCPDEFAULTTEST \(defaults == expectedDefaults ? "PASS" : "FAIL") defaults=\(defaults)")

        let shopifyStored = [PluginsSource.pluginID(engine: .codex, name: "shopify")]
        let shopify = PluginsSource.effectiveEnabledNames(stored: shopifyStored, configured: configured)
        print("MCPDEFAULTTEST \(shopify == ["shopify"] ? "PASS" : "FAIL") stored-shopify=\(shopify)")

        let noneStored = ["__tatwo_none__"]
        let none = PluginsSource.effectiveEnabledNames(stored: noneStored, configured: configured)
        print("MCPDEFAULTTEST \(none.isEmpty ? "PASS" : "FAIL") stored-none=\(none)")
        exit(defaults == expectedDefaults && shopify == ["shopify"] && none.isEmpty && verdictNegatives && livenessFailed ? 0 : 1)
    }
}

extension SelfTest {
    /// TATWO2_SWEEPTEST=1：驗側欄每日操作與右側資訊卡的真水電；同一 LIVE_ROOT 第二次驗持久化。
    @MainActor static func runSweepTest() {
        var environment = ProcessInfo.processInfo.environment
        environment["TATWO2_SELFTEST"] = nil
        let root = environment["TATWO2_LIVE_ROOT"]
            ?? (NSTemporaryDirectory() + "tatwo2-sweeptest-" + UUID().uuidString)
        environment["TATWO2_LIVE_ROOT"] = root
        let store = ChatLiveStore(root: URL(fileURLWithPath: root, isDirectory: true))
        let isPersistenceRun = FileManager.default.fileExists(atPath: store.url.path)
        let expectedRepo = "https://github.com/tatwo/sweeptest"
        var failed = false

        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("SWEEPTEST \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }

        if isPersistenceRun {
            let model = ChatPageModel(environment: environment)
            let archived = model.live?.doc.threads.filter(\.isArchived) ?? []
            let repos = model.live?.doc.projects.flatMap(\.githubRepos) ?? []
            check(
                "重開保留 isArchived",
                !archived.isEmpty,
                "archived=\(archived.count) ids=\(archived.map { $0.id.uuidString.lowercased() }.joined(separator: ","))")
            check(
                "重開保留 githubRepos",
                repos.contains(expectedRepo),
                "githubRepos=\(repos.joined(separator: ","))")
            print(failed ? "SWEEPTEST FAILED" : "SWEEPTEST ALL PASS")
            model.shutdownForContainerClose()
            exit(failed ? 1 : 0)
        }

        let projectID = UUID()
        func message(_ role: ChatMessageRole, _ text: String) -> LiveMessageRecord {
            LiveMessageRecord(ChatMessage(role: role, text: text))
        }
        let first = LiveThreadRecord(
            projectID: projectID,
            title: "每日主串",
            messages: [
                message(.user, "第一個問題"),
                message(.assistant, "第一個回答"),
            ],
            createdAt: Date().addingTimeInterval(-30),
            updatedAt: Date())
        let second = LiveThreadRecord(
            projectID: projectID,
            title: "每日第二串",
            messages: [message(.assistant, "第二串回答")],
            createdAt: Date().addingTimeInterval(-20),
            updatedAt: Date().addingTimeInterval(-10))
        let third = LiveThreadRecord(
            projectID: projectID,
            title: "每日第三串",
            messages: [message(.user, "第三串問題")],
            createdAt: Date().addingTimeInterval(-10),
            updatedAt: Date().addingTimeInterval(-20))
        store.save(
            LiveDocumentRecord(
                projects: [
                    LiveProjectRecord(
                        id: projectID,
                        name: "SWEEPTEST",
                        workdir: root),
                ],
                threads: [first, second, third],
                selectedThreadID: first.id))

        let model = ChatPageModel(environment: environment)
        model.selectedThreadID = first.id
        let visibleBeforeArchive = model.document.projects.flatMap(\.threads).count
        model.archiveSelectedThread()
        let visibleAfterArchive = model.document.projects.flatMap(\.threads).count
        check(
            "封存",
            model.archivedThreadCount == 1 && visibleAfterArchive == visibleBeforeArchive - 1,
            "archived=\(model.archivedThreadCount) sidebar=\(visibleBeforeArchive)→\(visibleAfterArchive) selected=\(model.selectedThreadID?.uuidString.lowercased() ?? "nil")")

        model.restoreMostRecentArchivedThread()
        let restoredID = model.selectedThreadID
        let visibleAfterRestore = model.document.projects.flatMap(\.threads).count
        check(
            "還原最近封存",
            restoredID == first.id
                && model.live?.threadRecord(first.id)?.isArchived == false
                && visibleAfterRestore == visibleBeforeArchive,
            "restored=\(restoredID?.uuidString.lowercased() ?? "nil") sidebar=\(visibleAfterRestore)")

        let sourceMessageCount = model.live?.transcript(for: first.id).count ?? -1
        model.duplicateSelectedThread(asBranch: false)
        let copyID = model.selectedThreadID
        let copied = model.live?.threadRecord(copyID)
        let copiedMessageCount = model.live?.transcript(for: copyID).count ?? -1
        check(
            "複製討論串",
            copyID != nil
                && copyID != first.id
                && copied?.title == "\(first.title) 副本"
                && copied?.sessionIDs.isEmpty == true
                && copiedMessageCount == sourceMessageCount,
            "sourceMessages=\(sourceMessageCount) copyMessages=\(copiedMessageCount) sessionIDs=\(copied?.sessionIDs.count ?? -1)")

        let discussionParentID = copyID
        model.createDiscussionForSelectedThread()
        let discussionID = model.selectedThreadID
        let discussion = model.live?.threadRecord(discussionID)
        check(
            "建立支線",
            discussionID != nil
                && discussion?.parentThreadID == discussionParentID
                && discussion?.title == "支線 1",
            "discussion=\(discussionID?.uuidString.lowercased() ?? "nil") parent=\(discussion?.parentThreadID?.uuidString.lowercased() ?? "nil") title=\(discussion?.title ?? "nil")")

        if let discussionID, let discussionParentID {
            model.live?.appendSystemMessage(threadID: discussionID, text: "支線第一則", status: "info|sweeptest")
            model.live?.appendSystemMessage(threadID: discussionID, text: "支線第二則", status: "info|sweeptest")
            let parentCountBeforeMerge = model.live?.transcript(for: discussionParentID).count ?? -1
            model.mergeDiscussionIntoParent(discussionID)
            let parentRows = model.live?.transcript(for: discussionParentID) ?? []
            let archived = model.live?.threadRecord(discussionID)?.isArchived == true
            check(
                "合併支線",
                parentRows.count == parentCountBeforeMerge + 2
                    && archived
                    && parentRows.suffix(2).allSatisfy { $0.text.hasPrefix("〔支線 支線 1〕") },
                "parentMessages=\(parentCountBeforeMerge)→\(parentRows.count) childArchived=\(archived)")
        } else {
            check("合併支線", false, "缺 discussionID 或 parentID")
        }

        var repoBinding = TatwoGitHubRepoBinding()
        repoBinding.url = expectedRepo
        model.setGitHubRepoBindings([repoBinding], for: projectID)
        let storedRepos = model.live?.projectRecord(projectID)?.githubRepos ?? []
        check("儲存 GitHub 綁定", storedRepos == [expectedRepo], "githubRepos=\(storedRepos.joined(separator: ","))")

        NSPasteboard.general.clearContents()
        model.copySelectedThreadSummary()
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        check(
            "複製摘要",
            !clipboard.isEmpty
                && clipboard.contains("標題：")
                && clipboard.contains("system：")
                && clipboard.contains("支線第一則"),
            "clipboardChars=\(clipboard.count) hint=\(model.composerHint ?? "nil")")

        print(failed ? "SWEEPTEST FAILED" : "SWEEPTEST ALL PASS")
        model.shutdownForContainerClose()
        exit(failed ? 1 : 0)
    }
}

extension SelfTest {
    /// TATWO2_PTYTEST=1：先用 zsh -c 驗 forkpty/輸出，再啟動真正 Codex 互動 CLI，最後以 pgrep 驗證關頁後無子行程。
    @MainActor static func runPTYTest() {
        var env = ProcessInfo.processInfo.environment
        for key in [
            "TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT",
            "TATWO_ULTRAWORK_EXPORT_CHAT_SCENE",
            "TATWO_ULTRAWORK_CHAT_FIXTURE",
            "TATWO2_SELFTEST",
        ] {
            env[key] = nil
        }
        let root = env["TATWO2_PTYTEST_ROOT"]
            ?? (NSTemporaryDirectory() + "tatwo2-ptytest-" + UUID().uuidString)
        env["TATWO2_LIVE_ROOT"] = root
        let model = ChatPageModel(environment: env)
        let cwd = FileManager.default.currentDirectoryPath

        guard let shellTabID = model.openCLITestTab(
            executable: "/bin/zsh",
            arguments: ["-c", "printf 'hello-pty\\n'; sleep 0.4"],
            title: "PTY probe",
            workdir: cwd)
        else {
            print("PTYTEST FAIL unable to create zsh tab")
            exit(1)
        }

        Task { @MainActor in
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if model.cliTabLines(for: shellTabID).contains(where: { $0.plainText.contains("hello-pty") }) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let shellText = model.cliTabLines(for: shellTabID).map(\.plainText).joined(separator: "\\n")
            let shellPassed = shellText.contains("hello-pty")
            print("PTYTEST zsh-c output=\(shellPassed ? "PASS" : "FAIL") text=\(shellText.replacingOccurrences(of: "\n", with: "⏎"))")
            model.closeCLITab(shellTabID)
            try? await Task.sleep(for: .milliseconds(500))

            model.openCLITab(engine: .codex, workdir: cwd)
            guard let codexTabID = model.activeCLITabID else {
                print("PTYTEST FAIL unable to create codex tab")
                model.shutdownForContainerClose()
                exit(1)
            }
            let codexDeadline = Date().addingTimeInterval(3)
            while Date() < codexDeadline, model.cliTabProcessID(for: codexTabID) == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let codexPID = model.cliTabProcessID(for: codexTabID)
            let beforeClose = pgrepChildren()
            let targetPGID = codexPID.map { getpgid($0) } ?? -1
            let targetTree: [Int32] = codexPID.map { [$0] + descendants(of: $0) } ?? []
            print("PTYTEST target pid=\(codexPID.map(String.init) ?? "nil") pgid=\(targetPGID) descendants=\(targetTree.dropFirst().map(String.init).joined(separator: ","))")
            print("PTYTEST codex running=\(codexPID != nil ? "PASS" : "FAIL") pid=\(codexPID.map(String.init) ?? "nil")")
            print("PTYTEST pgrep-before-close=\(beforeClose.isEmpty ? "none" : beforeClose)")

            model.closeCLITab(codexTabID)
            try? await Task.sleep(for: .milliseconds(800))
            let afterClose = pgrepChildren()
            print("PTYTEST pgrep-after-close=\(afterClose.isEmpty ? "none" : afterClose)")
            // 只驗「目標 pid＋close 前快照到的子孫」全部退出（kill(pid,0)：ESRCH＝消失、EPERM＝還在但不是我們的、0＝還在）；pgid 只印出作參考，沒有做程序群組驗證；不 kill 任何無關程序
            var stillAlive: [String] = []
            for pid in targetTree {
                if kill(pid, 0) == 0 { stillAlive.append("\(pid):alive") }
                else if errno == EPERM { stillAlive.append("\(pid):EPERM") }
            }
            let targetGone = codexPID != nil && stillAlive.isEmpty
            let processPassed = targetGone
            print("PTYTEST target+snapshot-descendants-exited=\(targetGone) still=\(stillAlive.isEmpty ? "none" : stillAlive.joined(separator: ",")) baseline-children=\(beforeClose.split(separator: "\n").filter { !$0.isEmpty }.count)")
            print("PTYTEST close-process=\(processPassed ? "PASS" : "FAIL")")
            model.shutdownForContainerClose()
            exit(shellPassed && processPassed ? 0 : 1)
        }
        NSApplication.shared.run()
    }

    /// 目標程序的全部子孫（pgrep -P 遞迴），只用來驗退出，不殺任何東西
    private static func descendants(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var queue = [pid]
        while let next = queue.first {
            queue.removeFirst()
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-P", String(next)]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            let kids = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } ?? []
            result += kids; queue += kids
            if result.count > 200 { break }
        }
        return result
    }

    private static func pgrepChildren() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(getpid())]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "pgrep-error:\(error.localizedDescription)"
        }
    }
}

extension SelfTest {
    /// TATWO2_RECLAIMTEST=1：驗手動回收會 stash 並保留分支，以及封存房間會自動回收。
    @MainActor static func runReclaimTest() {
        var env = ProcessInfo.processInfo.environment
        for key in [
            "TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT",
            "TATWO_ULTRAWORK_EXPORT_CHAT_SCENE",
            "TATWO_ULTRAWORK_CHAT_FIXTURE",
            "TATWO2_SELFTEST",
        ] {
            env[key] = nil
        }
        let root = env["TATWO2_LIVE_ROOT"]
            ?? (NSTemporaryDirectory() + "tatwo2-reclaimtest-live-" + UUID().uuidString)
        env["TATWO2_LIVE_ROOT"] = root
        let workdir = NSTemporaryDirectory() + "tatwo2-reclaimtest-repo-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)

        @discardableResult
        func git(_ arguments: [String], cwd: String? = nil) -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: cwd ?? workdir, isDirectory: true)
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

        var failed = false
        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("RECLAIMTEST \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }

        _ = git(["init"])
        _ = git(["config", "user.email", "reclaimtest@tatwo2.local"])
        _ = git(["config", "user.name", "reclaimtest"])
        _ = git(["commit", "--allow-empty", "-m", "reclaimtest"])

        let model = ChatPageModel(environment: env)
        guard let projectID = model.acceptanceNewProject(name: "reclaimtest", workdir: workdir),
              let parentID = model.acceptanceNewThread(in: projectID, title: "主串")
        else {
            print("RECLAIMTEST FAIL 建立測試專案 — project/thread unavailable")
            model.shutdownForContainerClose()
            exit(1)
        }

        let first = model.dispatch(
            rooms: [RoomSpec(title: "手動回收", engine: "codex", model: nil, brief: "reclaim test")],
            parent: parentID).first
        guard let first, let firstID = UUID(uuidString: first.threadID) else {
            print("RECLAIMTEST FAIL 派工第一房 — dispatch returned empty")
            model.shutdownForContainerClose()
            exit(1)
        }
        model.stopDispatchRoom(firstID)
        check("工作樹建立", FileManager.default.fileExists(atPath: first.worktree), "path=\(first.worktree)")
        let dirtyPath = URL(fileURLWithPath: first.worktree).appendingPathComponent("未提交.txt").path
        try? Data("保留我\n".utf8).write(to: URL(fileURLWithPath: dirtyPath))
        check("寫入未提交檔", FileManager.default.fileExists(atPath: dirtyPath), "path=\(dirtyPath)")

        do {
            let result = try model.reclaimRoom(firstID)
            check("手動回收工作樹", !FileManager.default.fileExists(atPath: first.worktree), "exists=\(FileManager.default.fileExists(atPath: first.worktree))")
            let stashList = git(["stash", "list"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
            check("未提交內容進 stash", !stashList.isEmpty && result.stash != nil, "stash=\(result.stash ?? "nil") list=\(stashList)")
            let branches = git(["branch", "--format=%(refname:short)"]).1.split(whereSeparator: \.isNewline).map(String.init)
            check("分支預設保留", result.branch.map(branches.contains) == true, "branch=\(result.branch ?? "nil") branches=\(branches.joined(separator: ","))")
        } catch {
            check("手動回收工作樹", false, "error=\(error)")
            check("未提交內容進 stash", false, "回收失敗")
            check("分支預設保留", false, "回收失敗")
        }

        let second = model.dispatch(
            rooms: [RoomSpec(title: "封存回收", engine: "codex", model: nil, brief: "archive reclaim test")],
            parent: parentID).first
        guard let second, let secondID = UUID(uuidString: second.threadID) else {
            check("派工第二房", false, "dispatch returned empty")
            model.shutdownForContainerClose()
            exit(1)
        }
        model.stopDispatchRoom(secondID)
        check("第二工作樹建立", FileManager.default.fileExists(atPath: second.worktree), "path=\(second.worktree)")
        model.selectedThreadID = secondID
        model.archiveSelectedThread()
        check(
            "封存自動回收",
            model.live?.threadRecord(secondID)?.isArchived == true
                && !FileManager.default.fileExists(atPath: second.worktree),
            "archived=\(model.live?.threadRecord(secondID)?.isArchived == true) exists=\(FileManager.default.fileExists(atPath: second.worktree))")

        print(failed ? "RECLAIMTEST FAILED" : "RECLAIMTEST ALL PASS")
        model.shutdownForContainerClose()
        exit(failed ? 1 : 0)
    }
}


extension SelfTest {
    /// TATWO2_WATCHDOGTEST=1：直接寫進 store 造 1 主串＋2 子串（一條 6 分鐘前、一條 16 分鐘前，皆 running），
    /// 用 TATWO2_WATCHDOG_INTERVAL_SEC 縮短監工 timer 週期，等 5 秒後印子串 subStatus／liveness 與主串新增的 system 訊息。
    @MainActor static func runWatchdogTest() {
        let env = ProcessInfo.processInfo.environment
        let root = env["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory() + "tatwo2-watchdogtest-" + UUID().uuidString, isDirectory: true)
        let store = ChatLiveStore(root: root)
        let now = Date()
        let main = LiveThreadRecord(title: "主串")
        var idleSub = LiveThreadRecord(title: "房間A 慢郎中")
        idleSub.parentThreadID = main.id; idleSub.subStatus = "running"; idleSub.lastOutputAt = now.addingTimeInterval(-6 * 60)
        var stalledSub = LiveThreadRecord(title: "房間B 死當")
        stalledSub.parentThreadID = main.id; stalledSub.subStatus = "running"; stalledSub.lastOutputAt = now.addingTimeInterval(-16 * 60)
        var doc = LiveDocumentRecord()
        doc.threads = [main, idleSub, stalledSub]; doc.selectedThreadID = main.id
        store.save(doc)

        let engine = ChatLiveEngine(store: store)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            let idle = engine.threadRecord(idleSub.id)
            let stalled = engine.threadRecord(stalledSub.id)
            let idleLiveness = ThreadLiveness.from(status: idle?.subStatus, lastOutputAt: idle?.lastOutputAt)
            let stalledLiveness = ThreadLiveness.from(status: stalled?.subStatus, lastOutputAt: stalled?.lastOutputAt)
            print("WATCHDOGTEST idle subStatus=\(idle?.subStatus ?? "nil") liveness=\(idleLiveness.map(\.rawValue) ?? "nil")")
            print("WATCHDOGTEST stalled subStatus=\(stalled?.subStatus ?? "nil") liveness=\(stalledLiveness.map(\.rawValue) ?? "nil")")
            let mainMessages = engine.transcript(for: main.id).filter { $0.role == .system }.map(\.text)
            for text in mainMessages { print("WATCHDOGTEST mainMessage: \(text)") }
            let idleOK = mainMessages.contains { $0.contains("5 分鐘沒有輸出") }
            let stalledOK = mainMessages.contains { $0.contains("已自動停止") }
            print(idleOK && stalledOK ? "WATCHDOGTEST PASS" : "WATCHDOGTEST FAIL")
            exit(idleOK && stalledOK ? 0 : 1)
        }
        NSApplication.shared.run()
    }
}

extension SelfTest {
    @MainActor static func runSourceTest() {
        Task {
            let pluginsLine = PluginsSource.sourceTestLine()
            let usageLine = await UsageSource.sourceTestLine()
            print(pluginsLine); print(usageLine)
            // 斷言：技能與 MCP 清單都讀得到（不是假資料），額度來源那行有印出即可（登入與否另算）
            let skills = Int(pluginsLine.split(separator: " ").first { $0.hasPrefix("skills=") }?.dropFirst(7) ?? "0") ?? 0
            let mcp = Int(pluginsLine.split(separator: " ").first { $0.hasPrefix("mcp=") }?.dropFirst(4) ?? "0") ?? 0
            let sourceOK = skills > 0 && mcp > 0 && !pluginsLine.contains("fixture=true")
            print(sourceOK ? "SOURCETEST PASS skills=\(skills) mcp=\(mcp)（只驗清單來源，不驗登入／額度）" : "SOURCETEST FAIL \(pluginsLine)")
            exit(sourceOK ? 0 : 1)
        }
        NSApplication.shared.run()
    }

    /// TATWO2_LIVETEST=1：走真正的 ChatPageModel（live 模式）送一句話，印出 transcript 後退出。驗 M3 對話頁接 sidecar 的通路。
    @MainActor static func runLiveTest() {
        var env = ProcessInfo.processInfo.environment
        for k in ["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT", "TATWO_ULTRAWORK_EXPORT_CHAT_SCENE", "TATWO_ULTRAWORK_CHAT_FIXTURE", "TATWO2_SELFTEST"] { env[k] = nil }
        let root = env["TATWO2_LIVETEST_ROOT"] ?? (NSTemporaryDirectory() + "tatwo2-livetest-" + UUID().uuidString)
        env["TATWO2_LIVE_ROOT"] = root
        let model = ChatPageModel(environment: env)
        model.permissionPreset = .approveForMe
        if let rid = env["TATWO2_LIVETEST_ROUTE"], let r = ChatRouteChoice.resolveOrNil(rid) { model.setSingleModel(r.id) }
        else if let claude = ChatRouteChoice.all.first(where: { $0.brandGroup == .anthropic }) { model.setSingleModel(claude.id) }
        model.prompt = env["TATWO2_LIVETEST_PROMPT"] ?? "只回一個詞：乒"
        if let a = env["TATWO2_LIVETEST_ATTACH"] { model.appendDroppedPath(a) }
        model.send()
        Task { @MainActor in
            var ticks = 0
            while true {
                try? await Task.sleep(for: .milliseconds(500)); ticks += 1
                if !model.isRunning || ticks > 240 {
                    print("LIVE isLive=\(model.isLive) running=\(model.isRunning) threads=\(model.document.projects.flatMap(\.threads).count)")
                    for m in model.transcriptMessages { print("\(m.role.storageValue.uppercased()) [\(m.eventKind.rawValue)] [\(m.status ?? "")] \(m.text.replacingOccurrences(of: "\n", with: "⏎").prefix(160))") }
                    model.captureCurrentDiscussionIntoIssueList()
                    print("ISSUES \(model.visibleIssueListEntries.count) first=\(model.visibleIssueListEntries.first?.title ?? "-") | GIT branch=\(model.gitBranch) changed=\(model.gitChangedFileCount) +\(model.gitChangedLineAdditions)/-\(model.gitChangedLineDeletions)")
                    let saved = (try? Data(contentsOf: URL(fileURLWithPath: root + "/document.json")))?.count ?? 0
                    print("SAVED document.json bytes=\(saved)")
                    // 斷言（Codex review-6）：這次送出要有真的 assistant 回覆、回合已結束、且沒有引擎錯誤列；只有存檔不算
                    let reply = model.transcriptMessages.last { $0.role == .assistant && $0.eventKind == .message && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                    let engineErrors = model.transcriptMessages.filter { $0.role == .system && ($0.status ?? "").lowercased().hasPrefix("error") }.map(\.text)
                    let expected = env["TATWO2_LIVETEST_EXPECT"] ?? "乒"
                    let livePassed = model.isLive && saved > 0 && !model.isRunning && engineErrors.isEmpty && (reply?.text.contains(expected) ?? false)
                    if livePassed { print("LIVETEST PASS reply=\(reply?.text.prefix(40) ?? "") saved=\(saved)") }
                    else { print("LIVETEST FAIL isLive=\(model.isLive) running=\(model.isRunning) saved=\(saved) reply=\(reply?.text.prefix(60) ?? "無") errors=\(engineErrors.first?.prefix(120) ?? "無")（沒登入的引擎會回錯誤列＝人類 gate）") }
                    model.shutdownForContainerClose()
                    try? await Task.sleep(for: .milliseconds(500))
                    exit(livePassed ? 0 : 1)
                }
            }
        }
        NSApplication.shared.run()
    }
}


extension SelfTest {
    /// TATWO2_ACCEPT=1：用正式 App、真實資料夾，跑「每日十件事」，結果留在 App 的「驗收」專案裡給使用者看。
    @MainActor static func runAcceptance() {
        var env = ProcessInfo.processInfo.environment
        for k in ["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT", "TATWO_ULTRAWORK_EXPORT_CHAT_SCENE", "TATWO_ULTRAWORK_CHAT_FIXTURE", "TATWO2_SELFTEST", "TATWO2_LIVETEST"] { env[k] = nil }
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: Date()) }()
        var results: [String] = []
        func log(_ s: String) { results.append(s); print("ACCEPT " + s) }

        Task { @MainActor in
            var model = ChatPageModel(environment: env)
            model.permissionPreset = .approveForMe
            @MainActor func route(_ id: String) { if let r = ChatRouteChoice.resolveOrNil(id) { model.setSingleModel(r.id) } }
            @MainActor func waitDone(_ timeout: Double = 150) async -> Bool {
                let t0 = Date()
                while model.isRunning && Date().timeIntervalSince(t0) < timeout { try? await Task.sleep(for: .milliseconds(500)) }
                try? await Task.sleep(for: .milliseconds(300))
                return !model.isRunning
            }
            @MainActor func lastReply() -> String { model.transcriptMessages.last { $0.role == .assistant && $0.eventKind == .message }?.text ?? "" }
            @MainActor func ask(_ text: String, expect: String?) async -> (Bool, String) {
                model.prompt = text; model.send()
                let t0 = Date()
                let ok = await waitDone(); let r = lastReply()
                let secs = Int(Date().timeIntervalSince(t0))
                if !ok || (expect != nil && !r.contains(expect!)) {
                    let rows = model.transcriptMessages.suffix(4).map { "\($0.role.storageValue)/\($0.eventKind.rawValue)/\($0.status ?? "")/\($0.text.prefix(24))" }.joined(separator: " ‖ ")
                    print("ACCEPT-DIAG waited=\(secs)s running=\(model.isRunning) hint=\(model.composerHint ?? "-") rows=\(rows)")
                }
                return ((ok && (expect == nil || r.contains(expect!))), r)
            }
            guard let pid = model.acceptanceNewProject(name: "驗收 " + stamp, workdir: "/tmp/tatwo2-fixture/tatwo2") else { print("ACCEPT 無法建立專案"); exit(1) }

            // #3 Claude
            let t3 = model.acceptanceNewThread(in: pid, title: "#3 Claude 問一句")!; route("fable5")
            var (ok, r) = await ask("只回一個詞：乒", expect: "乒"); log("#3 Claude 問一句｜\(ok ? "OK" : "失敗")｜回：\(r.prefix(40))")
            // #4 同串切 GPT
            model.acceptanceRename(t3, "#3/#4/#5 同一串換三家引擎"); route("gpt-5.5")
            (ok, r) = await ask("我最早要你回哪個詞？只回那個詞", expect: "乒"); log("#4 同串切 GPT 記得前文｜\(ok ? "OK" : "失敗")｜回：\(r.prefix(40))")
            // #5 切 Grok
            route("grok-build"); (ok, r) = await ask("只回一個詞：乓", expect: "乓"); log("#5 切 Grok｜\(ok ? "OK" : "失敗")｜回：\(r.prefix(40))")
            // #7 shell 工具（Claude）
            _ = model.acceptanceNewThread(in: pid, title: "#7 跑 shell 指令"); route("fable5")
            (ok, r) = await ask("用 shell 跑 echo 驗收-ok，然後只回那個輸出", expect: "驗收-ok")
            let tools = model.transcriptMessages.filter { $0.eventKind == .toolUse }.count
            log("#7 跑 shell 指令｜\(ok && tools > 0 ? "OK" : "失敗")｜工具列 \(tools) 筆｜回：\(r.prefix(40))")
            // #8 issue
            if let tid = model.selectedThreadID { model.captureCurrentDiscussionIntoIssueList(); let n = model.visibleIssueListEntries.count; model.packIssueIntoComposer(model.visibleIssueListEntries.first!); let packed = !model.prompt.isEmpty; model.prompt = ""; log("#8 加進 issue 清單再帶回輸入框｜\(n > 0 && packed ? "OK" : "失敗")｜issue \(n) 筆（打開這串的右側資訊卡看）"); _ = tid }
            // #6 圖片
            _ = model.acceptanceNewThread(in: pid, title: "#6 丟圖片問內容"); route("fable5")
            let imgSrc = "/tmp/tatwo2-fixture/tatwo2/docs/UI定位冊/截圖/aurora/頁-usage.png"
            let imgDst = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tatwo2/live/驗收-額度頁.png")
            try? FileManager.default.removeItem(at: imgDst); try? FileManager.default.copyItem(at: URL(fileURLWithPath: imgSrc), to: imgDst)
            model.appendDroppedPath(imgDst.path)
            (ok, r) = await ask("這張圖左上角的標題是哪四個字？只回那四個字", expect: "額度用量"); log("#6 丟圖片問內容｜\(ok ? "OK" : "失敗")｜回：\(r.prefix(40))")
            // #9 CLI 終端
            _ = model.acceptanceNewThread(in: pid, title: "#9 CLI 開 codex 終端"); route("fable5")
            model.openCLITab(engine: .codex, workdir: "/tmp/tatwo2-fixture/tatwo2")
            try? await Task.sleep(for: .seconds(4))
            let tabs = model.cliTabs.count; let lines = model.cliTabs.first.map { model.cliTabLines(for: $0.id).count } ?? 0
            log("#9 CLI 開 codex 終端｜\(tabs > 0 ? "OK" : "失敗")｜分頁 \(tabs)、終端輸出 \(lines) 行（切到 CLI 看）")
            (ok, r) = await ask("這條討論串開了一個 codex 終端分頁；只回「收到」", expect: nil); _ = ok
            // #10 bot
            if let bid = model.acceptanceBotID(named: "PO文 bot") { _ = model.sendAsBot(botID: bid, text: "只回一個詞：乒"); let okb = await waitDone(); let rb = lastReply(); log("#10 Bot 模式跟 PO文 bot 講話｜\(okb && rb.contains("乒") ? "OK" : "失敗")｜回：\(rb.prefix(40))（切到 Bot 看）") } else { log("#10 Bot｜失敗｜找不到 PO文 bot") }
            // #1/#2 關掉重開續接
            let tA = model.acceptanceNewThread(in: pid, title: "#1/#2 關掉重開仍記得")!; route("fable5")
            (ok, r) = await ask("記住暗號：藍鯨。只回「好」", expect: "好"); log("#1 開 App 選舊討論串（前置）｜\(ok ? "OK" : "失敗")｜回：\(r.prefix(20))")
            model.shutdownForContainerClose()
            try? await Task.sleep(for: .seconds(2))
            model = ChatPageModel(environment: env); model.permissionPreset = .approveForMe; model.selectedThreadID = tA; route("fable5")
            (ok, r) = await ask("暗號是什麼？只回那兩個字", expect: "藍鯨"); log("#2 重開後接著問記得前文｜\(ok ? "OK" : "失敗")｜回：\(r.prefix(20))")
            // 總表
            let t0 = model.acceptanceNewThread(in: pid, title: "#0 驗收總表 " + stamp)!
            model.acceptanceAddIssue(threadID: t0, title: "驗收總表 " + stamp, body: results.joined(separator: "\n"))
            (ok, r) = await ask("這是自動驗收的總表討論串，右側資訊卡的 issue 裡有結果；只回「已記錄」", expect: nil)
            print("ACCEPT DONE\n" + results.joined(separator: "\n"))
            model.shutdownForContainerClose()
            try? await Task.sleep(for: .seconds(1))
            exit(0)
        }
        NSApplication.shared.run()
    }
}


extension SelfTest {
    /// TATWO2_SWITCHTEST=1：同一串 Claude → GPT → Grok，印每步 isRunning 與列數，抓換引擎的狀態問題。
    @MainActor static func runSwitchTest() {
        var env = ProcessInfo.processInfo.environment
        for k in ["TATWO2_ACCEPT", "TATWO2_LIVETEST"] { env[k] = nil }
        env["TATWO2_LIVE_ROOT"] = NSTemporaryDirectory() + "tatwo2-switch-" + UUID().uuidString
        let model = ChatPageModel(environment: env); model.permissionPreset = .approveForMe
        Task { @MainActor in
            var stepResults: [Bool] = []
            @MainActor func step(_ route: String, _ text: String) async {
                let resolved = ChatRouteChoice.resolveOrNil(route)
                if let r = resolved { model.setSingleModel(r.id) }
                let assistantBefore = model.transcriptMessages.filter { $0.role == .assistant && $0.eventKind == .message && !$0.text.isEmpty }.count
                model.prompt = text; model.send()
                let t0 = Date(); var ticks = 0
                while model.isRunning && Date().timeIntervalSince(t0) < 120 { try? await Task.sleep(for: .milliseconds(500)); ticks += 1 }
                let newAssistant = model.transcriptMessages.filter { $0.role == .assistant && $0.eventKind == .message && !$0.text.isEmpty }.dropFirst(assistantBefore)
                let last = newAssistant.last
                let routeMatches = last.flatMap { m in m.modelID.map { ChatRouteChoice.resolve($0).id == (resolved?.id ?? route) } } ?? false
                let errored = model.transcriptMessages.suffix(6).contains { $0.role == .system && ($0.status ?? "").lowercased().hasPrefix("error") }
                let ok = !model.isRunning && newAssistant.count >= 1 && routeMatches && !errored
                stepResults.append(ok)
                print("SWITCHSTEP \(route) \(ok ? "PASS" : "FAIL") newReplies=\(newAssistant.count) modelID=\(last?.modelID ?? "nil") routeMatch=\(routeMatches) errored=\(errored)")
                print("SWITCH \(route) running=\(model.isRunning) after \(ticks/2)s rows=\(model.transcriptMessages.count) last=\(model.transcriptMessages.last.map { "\($0.role.storageValue)/\($0.status ?? "")/\($0.text.prefix(30))" } ?? "-")")
            }
            let before = model.transcriptMessages.count
            await step("fable5", "只回一個詞：乒")
            await step("gpt-5.5", "我最早要你回哪個詞？只回那個詞")
            await step("grok-build", "只回一個詞：乓")
            _ = before
            let allOK = stepResults.count == 3 && stepResults.allSatisfy { $0 }
            print(allOK ? "SWITCHTEST PASS 3/3 steps" : "SWITCHTEST FAIL steps=\(stepResults)（每步要有該 route 的新回覆；三家沒登入就是人類 gate）")
            model.shutdownForContainerClose(); try? await Task.sleep(for: .milliseconds(500)); exit(allOK ? 0 : 1)
        }
        NSApplication.shared.run()
    }
}


extension SelfTest {
    /// TATWO2_RUNTASK=<json>：用正式 App 的真實資料夾，在指定專案／討論串對面板裡的 sol 下指令，等它做完，把結果留在 App 裡。
    /// json：{ "project": "名稱", "workdir": "/路徑", "thread": "討論串標題", "route": "gpt-5.6-sol", "prompt": "…", "timeoutMinutes": 30, "attachments": ["/路徑.png"] }
    @MainActor static func runTask(path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { print("RUNTASK 讀不到任務檔"); exit(2) }
        var env = ProcessInfo.processInfo.environment
        for k in ["TATWO2_RUNTASK", "TATWO2_ACCEPT", "TATWO2_LIVETEST", "TATWO2_SWITCHTEST"] { env[k] = nil }
        let model = ChatPageModel(environment: env); model.permissionPreset = .approveForMe
        let projectName = spec["project"] as? String ?? "任務"
        let workdir = spec["workdir"] as? String ?? NSHomeDirectory()
        let threadTitle = spec["thread"] as? String ?? projectName
        let routeID = spec["route"] as? String ?? "gpt-5.6-sol"
        let prompt = spec["prompt"] as? String ?? ""
        let timeout = (spec["timeoutMinutes"] as? Double ?? 30) * 60
        Task { @MainActor in
            // 專案：同名同路徑就沿用，否則新建
            let pid: UUID = model.document.projects.first { $0.name == projectName && $0.workdir == workdir }?.id
                ?? model.acceptanceNewProject(name: projectName, workdir: workdir)!
            // 討論串：同名沿用（可以接續下指令），否則新建
            let tid: UUID = model.document.projects.flatMap(\.threads).first { $0.title == threadTitle }?.id
                ?? model.acceptanceNewThread(in: pid, title: threadTitle)!
            model.selectedThreadID = tid
            if let r = ChatRouteChoice.resolveOrNil(routeID) { model.setSingleModel(r.id) }
            for a in (spec["attachments"] as? [String] ?? []) { model.appendDroppedPath(a) }
            model.prompt = prompt; model.send()
            let t0 = Date()
            while model.isRunning && Date().timeIntervalSince(t0) < timeout { try? await Task.sleep(for: .seconds(2)) }
            let rows = model.transcriptMessages
            let tools = rows.filter { $0.eventKind == .toolUse }
            print("RUNTASK project=\(projectName) thread=\(threadTitle) route=\(routeID) running=\(model.isRunning) secs=\(Int(Date().timeIntervalSince(t0))) rows=\(rows.count) tools=\(tools.count)")
            for t in tools.suffix(30) { print("TOOL [\(t.status ?? "")] \(t.text.prefix(140).replacingOccurrences(of: "\n", with: "⏎"))") }
            if let last = rows.last(where: { $0.role == .assistant && $0.eventKind == .message }) { print("REPLY [\(last.status ?? "")]\n" + last.text) }
            for sys in rows.filter({ $0.role == .system }).suffix(5) { print("SYSTEM [\(sys.status ?? "")] \(sys.text.prefix(200))") }
            model.shutdownForContainerClose(); try? await Task.sleep(for: .seconds(1)); exit(model.isRunning ? 3 : 0)
        }
        NSApplication.shared.run()
    }
}


extension SelfTest {
    /// TATWO2_BROWSERTEST=1：App 起本機 bridge，再由 Node 直連 socket 驗 open/read。
    @MainActor static func runBrowserAgentTest() {
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT",
            "TATWO_ULTRAWORK_EXPORT_CHAT_SCENE",
            "TATWO_ULTRAWORK_CHAT_FIXTURE",
            "TATWO2_SELFTEST",
        ] { environment[key] = nil }
        environment["TATWO2_BROWSERTEST"] = "1"
        let model = ChatPageModel(environment: environment)
        let socketPath = BrowserAgentBridge.shared.socketPath
        let probeURL = browserAgentProbeURL()
        print("BROWSERTEST socket=\(socketPath)")
        print("BROWSERTEST probe=\(probeURL.path)")

        Task.detached {
            for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: socketPath) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", probeURL.path]
            var childEnvironment = ProcessInfo.processInfo.environment
            childEnvironment["TATWO2_BROWSER_SOCKET"] = socketPath
            process.environment = childEnvironment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                process.waitUntilExit()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                await MainActor.run {
                    print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
                    model.shutdownForContainerClose()
                    exit(process.terminationStatus == 0 ? 0 : 1)
                }
            } catch {
                await MainActor.run {
                    print("BROWSERTEST FAIL node_probe_start \(error.localizedDescription)")
                    model.shutdownForContainerClose()
                    exit(1)
                }
            }
        }
        NSApplication.shared.run()
    }

    private static func browserAgentProbeURL() -> URL {
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("browser-mcp/probe.mjs")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Engines/browser-mcp/probe.mjs")
    }
}


extension SelfTest {
    #if DEBUG
    @MainActor private static func runDispatchUICases() async throws {
        final class Recorder: DispatchRoomMessaging {
            var system: [(UUID, String)] = []
            var sent: [(UUID, String, ClaudeSidecar.Kind)] = []
            var statuses: [UUID: String] = [:]
            func markSubStatus(_ id: UUID, _ status: String) { statuses[id] = status }
            func appendSystemMessage(threadID: UUID, text: String, status: String) { system.append((threadID, text)) }
            func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind, systemPrompt: String?, attachments: [String]) -> Bool {
                sent.append((threadID, text, engine))
                return true
            }
        }
        let (context, sha) = try await DispatchGit.background {
            func require(_ condition: Bool, _ name: String) throws {
                guard condition else { throw DispatchGitFailure(message: "test: " + name) }
                print("DISPATCHTEST UI PASS " + name)
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-ui-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            @discardableResult func git(_ args: [String], _ cwd: String? = nil) throws -> String {
                let result = try DispatchGit.run(args, cwd: cwd ?? root.path)
                guard result.status == 0 else { throw DispatchGitFailure(message: result.text) }
                return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try git(["init", "-b", "main"])
            try git(["config", "user.name", "Dispatch UI Test"])
            try git(["config", "user.email", "test@example.invalid"])
            try "base\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            try ".tatwo2/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try git(["add", "."]); try git(["commit", "-m", "base"])
            func room() throws -> DispatchGitContext {
                let id = UUID()
                let path = root.appendingPathComponent(".tatwo2/wt/" + id.uuidString).path
                let context = DispatchGitContext(id: id, title: "測試房間", workdir: root.path, worktree: path,
                                                 branch: "tatwo2-room-" + id.uuidString.prefix(8), deviceID: nil)
                try git(["worktree", "add", "-b", context.branch, context.worktree])
                return context
            }
            let context = try room()
            let empty = try DispatchGit.diff(context)
            try require(empty.text.isEmpty && empty.parsed.files.isEmpty, "diff-empty")
            try "child\n".write(toFile: context.worktree + "/file.txt", atomically: true, encoding: .utf8)
            try git(["add", "."], context.worktree); try git(["commit", "-m", "child"], context.worktree)
            let diff = try DispatchGit.diff(context)
            try require(diff.parsed.files.count == 1 && !diff.parsed.files[0].hunks.isEmpty && diff.stat.contains("file.txt"), "diff-hunks-stat")
            try "dirty".write(to: root.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
            do { _ = try DispatchGit.preview(context); throw DispatchGitFailure(message: "dirty accepted") }
            catch let error as DispatchGitFailure {
                try require(error.message == "主分支有未提交變更，先處理再合併", "dirty-block")
            }
            // Preserve the test artifact outside the repo rather than delete it.
            try FileManager.default.moveItem(at: root.appendingPathComponent("dirty.txt"), to: root.appendingPathComponent(".tatwo2/dirty-preserved.txt"))
            let preview = try DispatchGit.preview(context)
            let sha = try DispatchGit.merge(context, expected: preview)
            let parents = try git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ")
            try require(parents.count == 3 && !sha.isEmpty, "merge-commit")
            // Codex 審查 P1：同名 tag 指到未審過的 commit，不能頂替已確認的分支 tip
            let shadow = try room()
            try "shadow child\n".write(toFile: shadow.worktree + "/file.txt", atomically: true, encoding: .utf8)
            try git(["add", "."], shadow.worktree); try git(["commit", "-m", "shadow child"], shadow.worktree)
            try git(["branch", "evil-" + shadow.id.uuidString.prefix(8), "HEAD"])
            try git(["checkout", "-q", "evil-" + shadow.id.uuidString.prefix(8)])
            try "evil\n".write(to: root.appendingPathComponent("evil.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."]); try git(["commit", "-m", "evil unreviewed"])
            let evil = try git(["rev-parse", "HEAD"])
            try git(["checkout", "-q", "main"])
            try git(["tag", shadow.branch, evil])
            let shadowPreview = try DispatchGit.preview(shadow)
            _ = try DispatchGit.merge(shadow, expected: shadowPreview)
            let shadowParents = try git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ").map(String.init)
            try require(shadowParents.count == 3 && shadowParents[2] == shadowPreview.branchHead && shadowParents[2] != evil, "merge-ignores-same-name-tag")
            try require(try shadow.mergeCommand().contains("refs/heads/" + shadow.branch), "copy-command-full-ref")
            try git(["tag", "-d", shadow.branch])
            // Codex 審查 P1：branch.main.mergeOptions=--no-commit 下 exit 0 但沒 commit → 必須偵測並回復
            try git(["config", "branch.main.mergeOptions", "--no-commit"])
            let noCommit = try room()
            try "no-commit child\n".write(toFile: noCommit.worktree + "/file.txt", atomically: true, encoding: .utf8)
            try git(["add", "."], noCommit.worktree); try git(["commit", "-m", "no-commit child"], noCommit.worktree)
            let noCommitPreview = try DispatchGit.preview(noCommit)
            let noCommitSHA = try DispatchGit.merge(noCommit, expected: noCommitPreview)
            let noCommitParents = try git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ").map(String.init)
            let noCommitMergeHead = try DispatchGit.run(["rev-parse", "--verify", "MERGE_HEAD"], cwd: root.path)
            try require(!noCommitSHA.isEmpty && noCommitParents.count == 3 && noCommitParents[2] == noCommitPreview.branchHead && noCommitMergeHead.status != 0 && (try git(["status", "--porcelain"])).isEmpty, "merge-overrides-no-commit-config")
            try git(["config", "--unset", "branch.main.mergeOptions"])
            // 逾時（可控慢程序）：0.3 秒界線下 sleep 3 的 git alias 必逾時，且 runner 要在 1.5 秒內返回
            func timed(_ args: [String]) -> (seconds: Double, error: String) {
                let t0 = ProcessInfo.processInfo.systemUptime
                var message = ""
                do { _ = try DispatchGit.run(args, cwd: root.path, timeout: 0.3) } catch { message = String(describing: error) }
                return (ProcessInfo.processInfo.systemUptime - t0, message)
            }
            let slow = timed(["-c", "alias.review-slow=!sleep 3", "review-slow"])
            try require(slow.error.contains("逾時") && slow.seconds < 1.5, "git-run-timeout-throws-bounded")
            // Codex round 2 反例：後代程序忽略 TERM 且握著 pipe，runner 仍要在界線內返回
            let hold = timed(["-c", "alias.review-hold=!trap '' TERM; sleep 3", "review-hold"])
            try require(hold.error.contains("逾時") && hold.seconds < 1.5, "git-run-timeout-pipe-held-by-descendant")
            let conflict = try room()
            try "conflicting child\n".write(toFile: conflict.worktree + "/file.txt", atomically: true, encoding: .utf8)
            try git(["add", "."], conflict.worktree); try git(["commit", "-m", "conflict child"], conflict.worktree)
            try "conflicting main\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."]); try git(["commit", "-m", "conflict main"])
            let before = try DispatchGit.preview(conflict)
            var rejected = false
            do { _ = try DispatchGit.merge(conflict, expected: before) } catch { rejected = true }
            let clean = try git(["status", "--porcelain"]).isEmpty
            let head = try git(["rev-parse", "HEAD"])
            let mergeHead = try DispatchGit.run(["rev-parse", "--verify", "MERGE_HEAD"], cwd: root.path)
            try require(rejected && clean && head == before.head && mergeHead.status != 0, "conflict-abort-clean")
            let big = try room()
            try String(repeating: "0123456789abcdef\n", count: 40000).write(toFile: big.worktree + "/large.txt", atomically: true, encoding: .utf8)
            try git(["add", "."], big.worktree); try git(["commit", "-m", "large"], big.worktree)
            let large = try DispatchGit.diff(big)
            try require(large.truncated && large.text.utf8.count <= DispatchGit.limit && !large.parsed.files.isEmpty, "diff-truncated-512KB")
            let remote = DispatchGitContext(id: context.id, title: context.title, workdir: "/does-not-exist", worktree: "/does-not-exist", branch: context.branch, deviceID: "test-device")
            for action in 0..<3 {
                do {
                    switch action {
                    case 0: _ = try DispatchGit.diff(remote)
                    case 1: _ = try DispatchGit.merge(remote, expected: preview)
                    default: _ = try remote.mergeCommand()
                    }
                    throw DispatchGitFailure(message: "remote accepted")
                } catch let error as DispatchGitFailure {
                    try require(error.message == "遠端子任務不支援", "remote-block-\(action)")
                }
            }
            return (context, sha)
        }
        let recorder = Recorder()
        DispatchRoomActions.recordMerge(context, sha: sha, messenger: recorder)
        guard recorder.system.last?.0 == context.id, recorder.system.last?.1.contains(sha) == true else {
            throw DispatchGitFailure(message: "merge system row missing")
        }
        print("DISPATCHTEST UI PASS merge-system-row")
        try DispatchRoomActions.returnRoom(context, reason: "補測試", engine: .codex, messenger: recorder)
        guard recorder.sent.last?.0 == context.id, recorder.sent.last?.1 == "【退回重做】補測試",
              recorder.sent.last?.2 == .codex, recorder.statuses[context.id] == "running" else {
            throw DispatchGitFailure(message: "return payload/status mismatch")
        }
        print("DISPATCHTEST UI PASS return-prefix-engine-running")
        let remote = DispatchGitContext(id: context.id, title: context.title, workdir: context.workdir,
                                        worktree: context.worktree, branch: context.branch, deviceID: "test-device")
        do {
            try DispatchRoomActions.returnRoom(remote, reason: "不要送", engine: .codex, messenger: recorder)
            throw DispatchGitFailure(message: "remote return accepted")
        } catch let error as DispatchGitFailure {
            guard error.message == "遠端子任務不支援", recorder.sent.count == 1 else { throw error }
        }
        print("DISPATCHTEST UI PASS remote-return-block")
    }

    @MainActor private static func runDispatchHygieneCases() throws {
        func check(_ name: String, _ condition: Bool) throws {
            print("DISPATCHTEST HYGIENE \(condition ? "PASS" : "FAIL") \(name)")
            if !condition { throw DispatchGitFailure(message: name) }
        }
        try check("title-short", ChatPageModel.dispatchTitle("短句。下一句") == "短句")
        try check("title-long-character-boundary", ChatPageModel.dispatchTitle(String(repeating: "👩‍💻", count: 25)) == String(repeating: "👩‍💻", count: 24) + "…")
        try check("title-newline", ChatPageModel.dispatchTitle("第一行\n第二行") == "第一行")
        var record = LiveThreadRecord(model: "thread-model")
        try check("model-thread", ChatPageModel.dispatchModel(thread: record, fallback: "route-model") == "thread-model")
        record.model = ""
        try check("model-empty-fallback", ChatPageModel.dispatchModel(thread: record, fallback: "route-model") == "route-model")
        record.model = nil
        try check("model-nil-fallback", ChatPageModel.dispatchModel(thread: record, fallback: "route-model") == "route-model")
        let legacy = try JSONDecoder().decode(LiveThreadRecord.self, from: Data("{}".utf8))
        try check("requested-model-legacy-decode", legacy.requestedModel == nil)
        func git(_ args: [String], cwd: String) throws -> (status: Int32, text: String) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", cwd] + args
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-hygiene-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "base"]] {
            let result = try git(args, cwd: root.path)
            guard result.status == 0 else { throw DispatchGitFailure(message: result.text) }
        }
        let room = try ChatPageModel.prepareRoomWorktree(workdir: root.path, roomID: UUID().uuidString)
        let exclude = root.appendingPathComponent(".git/info/exclude")
        let first = try String(contentsOf: exclude, encoding: .utf8)
        try check("exclude-entry", first.components(separatedBy: .newlines).contains(".tatwo2/"))
        ChatPageModel.excludeRoomWorktrees(workdir: room)
        try check("exclude-linked-worktree-idempotent", try String(contentsOf: exclude, encoding: .utf8) == first)
        let status = try git(["status", "--porcelain"], cwd: root.path)
        try check("main-repo-clean", status.status == 0 && status.text.isEmpty)
        let branch = try git(["branch", "--show-current"], cwd: room)
        try check("branch-prefix", branch.text.hasPrefix("tatwo2-room-"))
        let store = ChatLiveStore(root: root.appendingPathComponent("live"))
        let live = ChatLiveEngine(store: store, environment: ["TATWO2_WATCHDOG_INTERVAL_SEC": "1"])
        let child = live.newThread(in: nil, title: "receipt")
        live.setRequestedModel("requested-model", threadID: child)
        try check("requested-model-live-write", live.threadRecord(child)?.requestedModel == "requested-model")
        let reloaded = ChatLiveEngine(store: store, environment: ["TATWO2_WATCHDOG_INTERVAL_SEC": "1"])
        try check("requested-model-persisted", reloaded.threadRecord(child)?.requestedModel == "requested-model")
    }

    #endif
    /// TATWO2_DISPATCHTEST=1：無頭派 2 個房間（都用 codex），驗 dispatch_rooms → 各自 worktree 真的動工 → merge_reports 貼進主串。
    @MainActor static func runDispatchTest() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TATWO2_DISPATCH_HYGIENE_CASES"] == "1" {
            do { try runDispatchHygieneCases(); exit(0) }
            catch { print("DISPATCHTEST HYGIENE FAIL \(error)"); exit(1) }
        }
        // Separate deterministic additions; no real AI calls or host repositories. DEBUG-only（release 不認這兩個旗標）。
        if ProcessInfo.processInfo.environment["TATWO2_DISPATCH_UI_CASES"] == "1" {
            Task { @MainActor in
                do { try await runDispatchUICases(); print("DISPATCHTEST UI PASS"); exit(0) }
                catch { print("DISPATCHTEST UI FAIL \(error)"); exit(1) }
            }
            NSApplication.shared.run()
            return
        }
        #endif
        setvbuf(stdout, nil, _IOLBF, 0)   // runIfRequested 在本鉤子早 return 前還沒設行緩衝；進度列要在被逾時砍掉前留下
        var env = ProcessInfo.processInfo.environment
        for k in ["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT", "TATWO_ULTRAWORK_EXPORT_CHAT_SCENE", "TATWO_ULTRAWORK_CHAT_FIXTURE", "TATWO2_SELFTEST"] { env[k] = nil }
        let root = env["TATWO2_LIVE_ROOT"] ?? (NSTemporaryDirectory() + "tatwo2-dispatchtest-" + UUID().uuidString)
        env["TATWO2_LIVE_ROOT"] = root

        let workdir = NSTemporaryDirectory() + "tatwo2-dispatchtest-repo-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
        func runGit(_ args: [String]) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: workdir)
            try? p.run(); p.waitUntilExit()
        }
        runGit(["init"])
        runGit(["config", "user.email", "dispatchtest@tatwo2.local"])
        runGit(["config", "user.name", "dispatchtest"])
        runGit(["commit", "--allow-empty", "-m", "dispatchtest"])

        let model = ChatPageModel(environment: env)
        model.permissionPreset = .approveForMe
        guard let pid = model.acceptanceNewProject(name: "dispatchtest", workdir: workdir),
              let parent = model.acceptanceNewThread(in: pid, title: "主串")
        else {
            print("DISPATCHTEST FAIL 無法建立專案／主串")
            exit(1)
        }
        let rooms = [
            RoomSpec(title: "房間A", engine: "codex", model: "gpt-5.6-sol", brief: "在工作樹裡建立 hello-房間A.txt 寫入 ok 然後回報「完成」"),
            RoomSpec(title: "房間B", engine: "codex", model: "gpt-5.6-sol", brief: "在工作樹裡建立 hello-房間B.txt 寫入 ok 然後回報「完成」"),
        ]
        let dispatched = model.dispatch(rooms: rooms, parent: parent)
        guard dispatched.count == 2 else {
            print("DISPATCHTEST FAIL dispatch_rooms 沒回 2 個房間（回了 \(dispatched.count) 個）")
            model.shutdownForContainerClose(); exit(1)
        }

        Task { @MainActor in
            // 內部 deadline 360s 大於跑器的 300s：所以每 30 秒印一次各房間狀態（逾時被砍也留得下證據），
            // 且只要全部房間到終態（done／failed）就提早結束並照原斷言判 PASS／FAIL；不放寬逾時、不改斷言。
            let deadline = Date().addingTimeInterval(360)
            let started = Date()
            var lastProgress = Date.distantPast
            while Date() < deadline {
                let states: [(String, String)] = dispatched.map { room in
                    guard let tid = UUID(uuidString: room.threadID) else { return (room.threadID, "bad-id") }
                    return (room.threadID, model.live?.threadRecord(tid)?.subStatus ?? "nil")
                }
                let allTerminal = states.allSatisfy { $0.1 == "done" || $0.1 == "failed" }
                if allTerminal { break }
                if Date().timeIntervalSince(lastProgress) >= 30 {
                    lastProgress = Date()
                    print("DISPATCHTEST progress elapsed=\(Int(Date().timeIntervalSince(started)))s " + states.map { "\($0.0.prefix(8))=\($0.1)" }.joined(separator: " "))
                }
                try? await Task.sleep(for: .seconds(2))
            }
            var allOK = true
            for (room, spec) in zip(dispatched, rooms) {
                guard let tid = UUID(uuidString: room.threadID) else { allOK = false; continue }
                let record = model.live?.threadRecord(tid)
                let liveness = ThreadLiveness.from(status: record?.subStatus, lastOutputAt: record?.lastOutputAt)
                let rows = model.live?.transcript(for: tid) ?? []
                let reply = rows.last(where: { $0.role == .assistant && $0.eventKind == .message })?.text ?? "（尚無回覆）"
                print("DISPATCHTEST room title=\(spec.title) threadID=\(room.threadID) worktree=\(room.worktree) liveness=\(liveness?.rawValue ?? "nil") reply=\(reply.prefix(80).replacingOccurrences(of: "\n", with: "⏎"))")
                let filePath = room.worktree + "/hello-\(spec.title).txt"
                let exists = FileManager.default.fileExists(atPath: filePath)
                print("DISPATCHTEST file title=\(spec.title) path=\(filePath) exists=\(exists)")
                if !exists { allOK = false }
                if liveness != .done { allOK = false }
            }
            let merged = model.mergeDispatchReports()
            let parentRows = model.live?.transcript(for: parent) ?? []
            let posted = parentRows.last(where: { $0.role == .system && $0.text.contains("合併報告") })
            print("DISPATCHTEST merge_reports posted=\(posted != nil) preview=\((posted?.text ?? "").prefix(200).replacingOccurrences(of: "\n", with: "⏎"))")
            if posted == nil || merged.isEmpty { allOK = false }
            print(allOK ? "DISPATCHTEST PASS" : "DISPATCHTEST FAIL")
            model.shutdownForContainerClose()
            try? await Task.sleep(for: .milliseconds(500))
            exit(allOK ? 0 : 1)
        }
        NSApplication.shared.run()
    }
}


extension SelfTest {
    /// TATWO2_COMPOSERTEST=1：無頭驗 `/` `$` `@` 三個快捷選單與切模型（2026-09-04 使用者回報的兩個 bug）。
    @MainActor static func runComposerTest() {
        var env = ProcessInfo.processInfo.environment
        env["TATWO2_COMPOSERTEST"] = nil
        let model = ChatPageModel(environment: env)
        var failed = false
        func check(_ label: String, _ ok: Bool, _ detail: String) {
            print("COMPOSERTEST \(ok ? "PASS" : "FAIL") \(label) — \(detail)")
            if !ok { failed = true }
        }

        // 空白輸入：三個選單都該是空的（膠囊列不該常駐）
        model.prompt = ""
        check("空輸入不出選單", model.skillSuggestions.isEmpty && model.matchingSlashCommands.isEmpty && model.issueAtMentionMatches.isEmpty,
              "skills=\(model.skillSuggestions.count) slash=\(model.matchingSlashCommands.count) mention=\(model.issueAtMentionMatches.count)")

        // $ 技能
        model.prompt = "$"
        let allSkills = model.skillSuggestions.count
        check("打 $ 出技能", allSkills > 0, "\(allSkills) 筆（上限 6）")
        model.prompt = "$zzz-不存在的技能"
        check("$ 無相符時為空", model.skillSuggestions.isEmpty, "\(model.skillSuggestions.count) 筆")
        model.prompt = "$"
        if let first = model.skillSuggestions.first {
            model.applySkillSuggestion(first)
            check("$ 選中會插入", model.prompt == "$\(first.id) ", "prompt=\(model.prompt)")
        } else { check("$ 選中會插入", false, "沒有技能可測") }
        model.prompt = "$"
        if let sample = model.skillSuggestions.first {
            let head = String(sample.id.prefix(3))
            model.prompt = "先講一句 $\(head)"
            check("$ 可接在句子後面", !model.skillSuggestions.isEmpty, "查詢 \(head) → \(model.skillSuggestions.count) 筆")
        } else { check("$ 可接在句子後面", false, "沒有技能可測") }

        // / 指令
        model.prompt = "/"
        check("打 / 出指令", model.matchingSlashCommands.count == 5, "\(model.matchingSlashCommands.count) 筆")
        model.prompt = "/pl"
        let plNames = model.matchingSlashCommands.map(\.cmd).joined(separator: ",")
        check("/pl 篩到 plg 與 plan", model.matchingSlashCommands.count == 2, plNames)
        model.prompt = "已經打了字 /pl"
        check("/ 只在行首觸發（同 1.0）", model.matchingSlashCommands.isEmpty, "\(model.matchingSlashCommands.count) 筆")
        model.prompt = "/pl"
        if let item = model.matchingSlashCommands.first {
            model.applySlashCommandSuggestion(item)
            check("/ 插入補完整指令", model.prompt == "\(item.cmd) ", "prompt=\(model.prompt)")
        } else { check("/ 插入補完整指令", false, "沒有指令可測") }
        model.prompt = "第一行\n/pl"
        check("/ 吃多行的最後一行", model.matchingSlashCommands.count == 2, "\(model.matchingSlashCommands.count) 筆")

        // @ 提及（需要 issue 資料；沒有就只驗 query 解析）
        model.prompt = "@"
        let q = model.issueAtMentionQuery
        check("@ 觸發解析", q == "", "query=\(q ?? "nil")")
        model.prompt = "@ 已經有空白"
        check("@ 後有空白不觸發", model.issueAtMentionQuery == nil || model.issueAtMentionQuery == "",
              "query=\(model.issueAtMentionQuery ?? "nil")")

        // 打字重置高亮
        model.prompt = "$"
        model.skillSuggestionSelectedIndex = 0
        model.prompt = "$a"
        check("打字重置高亮", model.skillSuggestionSelectedIndex == nil, "index=\(String(describing: model.skillSuggestionSelectedIndex))")

        // 切模型
        model.prompt = ""
        model.isRunning = false
        let before = model.routeChoice.title
        model.setSingleModel("sonnet5")
        check("切模型會生效", model.routeChoice.id == "sonnet5" && model.selectedModel == "sonnet5",
              "\(before) → \(model.routeChoice.title)（selectedModel=\(model.selectedModel)）")
        check("切模型帶動引擎", model.routeChoice.brandGroup == .anthropic, "brandGroup=\(String(describing: model.routeChoice.brandGroup))")
        model.isRunning = true
        model.setSingleModel("gpt-5.5")
        check("執行中排到下一輪", model.pendingModelID == "gpt-5.5" && model.selectedModel == "sonnet5",
              "pending=\(model.pendingModelID ?? "nil") current=\(model.selectedModel)")
        model.isRunning = false
        model.applyPendingModelSelectionIfPossible()
        check("回合結束落地", model.pendingModelID == nil && model.selectedModel == "gpt-5.5",
              "selectedModel=\(model.selectedModel)")

        print(failed ? "COMPOSERTEST FAILED" : "COMPOSERTEST ALL PASS")
        exit(failed ? 1 : 0)
    }
}


extension SelfTest {
    /// TATWO2_BGTEST=1：透過 OSAgentBridge 同一入口驗 App-owned 背景工作、狀態、停止與完成通知。
    @MainActor static func runBackgroundTest() {
        var env = ProcessInfo.processInfo.environment
        env["TATWO2_BGTEST"] = nil
        let root = env["TATWO2_LIVE_ROOT"] ?? (NSTemporaryDirectory() + "tatwo2-bgtest-" + UUID().uuidString)
        env["TATWO2_LIVE_ROOT"] = root
        let model = ChatPageModel(environment: env)
        let cwd = root + "/project"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        guard let live = model.live else { print("BGTEST FAIL 初始化 — live=nil"); exit(1) }
        let projectID = live.newProject(name: "BGTEST", workdir: cwd)
        let threadID = live.newThread(in: projectID, title: "背景房間")
        model.selectedThreadID = threadID
        let bridge = OSAgentBridge.shared
        var failed = false
        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("BGTEST \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }

        Task { @MainActor in
            do {
                let first = try bridge.callForSelfTest(method: "run_background", params: ["cmd": "sleep 2; echo done", "title": "短工作"])
                guard let firstID = first["jobID"] as? String else { throw NSError(domain: "BGTEST", code: 1) }
                let initial = try bridge.callForSelfTest(method: "background_status", params: ["jobID": firstID])
                check("先 running", initial["state"] as? String == "running", "state=\(initial["state"] ?? "nil") pid=\(initial["pid"] ?? "nil")")
                var ended: [String: Any] = [:]
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(200))
                    ended = try bridge.callForSelfTest(method: "background_status", params: ["jobID": firstID])
                    if ended["state"] as? String == "exited" { break }
                }
                check("正常結束", ended["state"] as? String == "exited" && (ended["exitCode"] as? NSNumber)?.intValue == 0,
                      "state=\(ended["state"] ?? "nil") exitCode=\(ended["exitCode"] ?? "nil")")
                check("logTail 含 done", (ended["logTail"] as? String)?.contains("done") == true, "logTail=\(ended["logTail"] ?? "nil")")
                let notified = live.transcript(for: threadID).contains { $0.role == .system && $0.text.contains("短工作") && $0.text.contains("exit=0") }
                check("討論串完成通知", notified, "systemMessages=\(live.transcript(for: threadID).filter { $0.role == .system }.count)")

                let long = try bridge.callForSelfTest(method: "run_background", params: ["cmd": "sleep 300", "title": "長工作"])
                guard let longID = long["jobID"] as? String else { throw NSError(domain: "BGTEST", code: 2) }
                let stopStart = Date()
                var stopped = try bridge.callForSelfTest(method: "stop_background", params: ["jobID": longID])
                for _ in 0..<10 where stopped["state"] as? String != "exited" {
                    try? await Task.sleep(for: .milliseconds(100))
                    stopped = try bridge.callForSelfTest(method: "background_status", params: ["jobID": longID])
                }
                let stopElapsed = Date().timeIntervalSince(stopStart)
                check("停止後 1 秒內 exited", stopped["state"] as? String == "exited" && stopElapsed <= 1.0,
                      "state=\(stopped["state"] ?? "nil") elapsed=\(String(format: "%.3f", stopElapsed))")
                let registry = root + "/bg-jobs.json"
                check("登記持久化", FileManager.default.fileExists(atPath: registry), "path=\(registry)")
            } catch {
                check("執行", false, "error=\(error)")
            }
            print(failed ? "BGTEST FAILED" : "BGTEST ALL PASS")
            model.shutdownForContainerClose()
            exit(failed ? 1 : 0)
        }
        NSApplication.shared.run()
    }

    /// TATWO2_REAPTEST=1：驗證正常 terminate 與上次殘留記錄都會收掉完整 process group。
    @MainActor static func runReapTest() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "tatwo2-reaptest-" + UUID().uuidString, isDirectory: true)
        let childFile = root.appendingPathComponent("child.pid")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var failed = false
        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("REAPTEST \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }
        func waitPIDFile(_ url: URL) async -> pid_t? {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if let text = try? String(contentsOf: url, encoding: .utf8),
                   let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
        func isDead(_ pid: pid_t) -> Bool {
            errno = 0
            return kill(pid, 0) == -1 && errno == ESRCH
        }

        Task { @MainActor in
            do {
                let grouped = try SidecarGroupedProcess.spawnReapTest(root: root, childPIDFile: childFile)
                guard let childPID = await waitPIDFile(childFile) else {
                    check("terminate 收孫程序", false, "child pid file timeout")
                    exit(1)
                }
                grouped.terminateGroup()
                try? await Task.sleep(for: .seconds(1))
                check("terminate 收孫程序", isDead(childPID), "pgid=\(grouped.pgid) child=\(childPID) kill0_errno=\(errno)")

                let orphanFile = root.appendingPathComponent("orphan-child.pid")
                let orphan = try SidecarGroupedProcess.spawnReapTest(root: root, childPIDFile: orphanFile)
                guard let orphanChild = await waitPIDFile(orphanFile) else {
                    check("啟動清理上次孤兒", false, "orphan child pid file timeout")
                    exit(1)
                }
                try SidecarGroupedProcess.writeReapTestRecord(root: root, pgid: orphan.pgid)
                SidecarGroupedProcess.reapRecordedGroups()
                try? await Task.sleep(for: .seconds(1))
                check("啟動清理上次孤兒", isDead(orphanChild), "pgid=\(orphan.pgid) child=\(orphanChild) kill0_errno=\(errno)")
            } catch {
                check("process-group setup", false, error.localizedDescription)
            }
            print(failed ? "REAPTEST FAILED" : "REAPTEST ALL PASS")
            try? FileManager.default.removeItem(at: root)
            exit(failed ? 1 : 0)
        }
        NSApplication.shared.run()
    }
}

extension SelfTest {
    /// TATWO2_REMOTETEST=1：用 localhost 驗 R3 Engines 同步、遠端 worktree、ssh sidecar 與 system/init。
    @MainActor static func runRemoteTest() {
        let fm = FileManager.default
        let runID = UUID().uuidString
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tatwo2-remotetest-\(runID)", isDirectory: true)
        let repo = root.appendingPathComponent("project", isDirectory: true)
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)

        func run(_ executable: String, _ arguments: [String], cwd: URL? = nil) -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = cwd
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            guard (try? process.run()) != nil else { return (-1, "launch failed") }
            process.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        _ = run("/usr/bin/git", ["init"], cwd: repo)
        _ = run("/usr/bin/git", ["config", "user.email", "remotetest@tatwo2.local"], cwd: repo)
        _ = run("/usr/bin/git", ["config", "user.name", "remotetest"], cwd: repo)
        _ = run("/usr/bin/git", ["commit", "--allow-empty", "-m", "remotetest"], cwd: repo)

        let deviceID = "remotetest-\(runID)"
        let user = NSUserName()
        let devices: [[String: Any]] = [[
            "id": deviceID,
            "name": "localhost",
            "host": "localhost",
            "user": user,
            "sshPort": 22,
            "publicKeyFingerprint": "remotetest",
            "addedAt": ISO8601DateFormatter().string(from: Date()),
            "lastSeenAt": ISO8601DateFormatter().string(from: Date()),
            "workdirMap": [repo.path: repo.path],
        ]]
        let devicesURL = root.appendingPathComponent("devices.json")
        if let data = try? JSONSerialization.data(withJSONObject: devices, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: devicesURL, options: .atomic)
        }
        setenv("TATWO2_LIVE_ROOT", root.path, 1)
        // 2026-09-06 r8 抓到：原本指到 cwd/Engines，在 repo 裡跑就把 claude 私態寫進 repo（Engines/claude）；改指 fixture。
        let strayBefore = fm.fileExists(atPath: fm.currentDirectoryPath + "/Engines/claude")
        setenv("TATWO2_ENGINES_ROOT", root.appendingPathComponent("engines", isDirectory: true).path, 1)
        setenv("TATWO2_ENGINES_SOURCE_ROOT", URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Engines").path, 1)   // 同步來源＝repo 的 Engines 腳本

        var failed = false
        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("REMOTETEST \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }

        // 2026-09-06（Codex 提案 v2 ＋ 11:43 六點）：REMOTETEST 的 ssh／rsync 整合是 host-mutating（真使用者 ssh localhost、rsync --delete 到固定 ~/.tatwo2/engines），
        // 改成 owned fixture 的 0 外部 I/O 擷取驗證；原真整合維持 BLOCKED（exit 1），不以 capture PASS 取代。主要證據＝capture 分支 0 次程序執行；mtime 只是弱觀察。
        #if DEBUG
        let realHomeEngines = NSHomeDirectory() + "/.tatwo2/engines"
        let homeEnginesBefore = (try? fm.attributesOfItem(atPath: realHomeEngines))?[.modificationDate] as? Date
        do {
            let ref = try RemoteDeviceLookup(root: root).device(id: deviceID)
            let fixtureRoot = root.appendingPathComponent("remote fixture", isDirectory: true)   // 含空格：驗 quoting
            try fm.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            let token = UUID().uuidString.lowercased()
            try JSONSerialization.data(withJSONObject: ["pid": Int(ProcessInfo.processInfo.processIdentifier), "token": token])
                .write(to: fixtureRoot.appendingPathComponent("owner.json"), options: .atomic)
            let realFixtureRoot = fixtureRoot.standardizedFileURL.resolvingSymlinksInPath().path   // /var → /private/var；given 必須等於 realpath 才過
            func blocked(_ env: [String: String]) -> Bool {
                do { _ = try RemoteSyncFixture.validate(environment: env); return false }
                catch RemoteEngineSyncError.fixtureBlocked { return true } catch { return false }
            }
            let runsBefore = RemoteEngineSync.debugRunCount
            check("無任何測試訊號＝nil（生產路徑不受影響）", (try RemoteSyncFixture.validate(environment: [:])) == nil, "")
            check("只有 TATWO2_REMOTETEST=1 缺 fixture → BLOCKED", blocked(["TATWO2_REMOTETEST": "1"]), "")
            check("只給 token → BLOCKED", blocked(["TATWO2_REMOTE_SYNC_TOKEN": token]), "")
            check("空字串 fixture BLOCKED", blocked(["TATWO2_REMOTE_SYNC_FIXTURE": ""]), "")
            check("缺 token BLOCKED", blocked(["TATWO2_REMOTE_SYNC_FIXTURE": realFixtureRoot]), "")
            check("token 不符 BLOCKED", blocked(["TATWO2_REMOTE_SYNC_FIXTURE": realFixtureRoot, "TATWO2_REMOTE_SYNC_TOKEN": "wrong"]), "")
            check("token 非 UUID（含 ../）BLOCKED", blocked(["TATWO2_REMOTE_SYNC_FIXTURE": realFixtureRoot, "TATWO2_REMOTE_SYNC_TOKEN": "../../x"]), "")
            check("越界（真家）BLOCKED", blocked(["TATWO2_REMOTE_SYNC_FIXTURE": NSHomeDirectory(), "TATWO2_REMOTE_SYNC_TOKEN": token]), "")
            let tmpRootReal = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
            check("TMPDIR 本身不算 owned → BLOCKED", blocked(["TATWO2_REMOTE_SYNC_FIXTURE": tmpRootReal, "TATWO2_REMOTE_SYNC_TOKEN": token]), "")
            let link = root.appendingPathComponent("link-to-fixture")
            try? fm.createSymbolicLink(at: link, withDestinationURL: fixtureRoot)
            check("symlink 根 BLOCKED", blocked(["TATWO2_REMOTE_SYNC_FIXTURE": link.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("link-to-fixture").path, "TATWO2_REMOTE_SYNC_TOKEN": token]), "")
            check("未 canonical 的 /var 路徑（祖先 symlink）BLOCKED", blocked(["TATWO2_REMOTE_SYNC_FIXTURE": fixtureRoot.path, "TATWO2_REMOTE_SYNC_TOKEN": token]) || fixtureRoot.path == realFixtureRoot, "given=\(fixtureRoot.path)")
            check("token 尾帶 newline BLOCKED（完整 UUID 逐字相等）", blocked(["TATWO2_REMOTE_SYNC_FIXTURE": realFixtureRoot, "TATWO2_REMOTE_SYNC_TOKEN": token + "\n"]), "")
            // owner.json 是 symlink → BLOCKED（另建一個 fixture 根）
            let ownerLinkRoot = root.appendingPathComponent("ownerlink-fixture", isDirectory: true)
            try fm.createDirectory(at: ownerLinkRoot, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: ownerLinkRoot.appendingPathComponent("owner.json"), withDestinationURL: fixtureRoot.appendingPathComponent("owner.json"))
            check("owner.json 是 symlink BLOCKED", blocked(["TATWO2_REMOTE_SYNC_FIXTURE": ownerLinkRoot.standardizedFileURL.resolvingSymlinksInPath().path, "TATWO2_REMOTE_SYNC_TOKEN": token]), "")
            // 衍生 destRoot 是 symlink → BLOCKED；engines 是 symlink → BLOCKED（各自獨立 fixture 根）
            for (name, linkInner) in [("destroot-link-fixture", false), ("engines-link-fixture", true)] {
                let r = root.appendingPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: r, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["token": token]).write(to: r.appendingPathComponent("owner.json"), options: .atomic)
                let destRoot = r.appendingPathComponent("remote-dest-" + token, isDirectory: true)
                let elsewhere = root.appendingPathComponent("elsewhere-" + name, isDirectory: true)
                try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
                if linkInner {
                    try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
                    try fm.createSymbolicLink(at: destRoot.appendingPathComponent("engines"), withDestinationURL: elsewhere)
                } else {
                    try fm.createSymbolicLink(at: destRoot, withDestinationURL: elsewhere)
                }
                check("衍生 \(linkInner ? "engines" : "destRoot") 是 symlink BLOCKED", blocked(["TATWO2_REMOTE_SYNC_FIXTURE": r.standardizedFileURL.resolvingSymlinksInPath().path, "TATWO2_REMOTE_SYNC_TOKEN": token]), "")
            }

            // 快取命中也不能繞過驗證：stamp 走純記憶體（不碰共享 NSTemporaryDirectory 的 last-sync 檔），再用無效 fixture 呼叫 → 仍 BLOCKED，且 0 次程序執行
            let sharedStamp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tatwo2-remote-engine-last-sync.json").path
            let sharedStampBefore = (try? Data(contentsOf: URL(fileURLWithPath: sharedStamp))) ?? Data()
            setenv("TATWO2_REMOTE_SYNC_FIXTURE", realFixtureRoot, 1)
            setenv("TATWO2_REMOTE_SYNC_TOKEN", "wrong", 1)
            RemoteEngineSync.debugRecordStamp(ref.id)
            var cachedInvalidBlocked = false
            do { _ = try RemoteEngineSync.ensureEnginesOnDevice(ref, kind: .claude) } catch RemoteEngineSyncError.fixtureBlocked { cachedInvalidBlocked = true } catch {}
            check("快取命中＋無效 fixture 仍 BLOCKED（驗證在 cache 之前）", cachedInvalidBlocked, "")

            setenv("TATWO2_REMOTE_SYNC_TOKEN", token, 1)
            var kindBlocked = false
            do { _ = try RemoteEngineSync.ensureEnginesOnDevice(ref, kind: .claude) } catch RemoteEngineSyncError.fixtureBlocked { kindBlocked = true } catch {}
            check("fixture 只允許 codex kind：claude → BLOCKED（在任何 Process 之前）", kindBlocked && RemoteEngineSync.debugRunCount == runsBefore, "")
            var captureHandle: RemoteEngineHandle?
            do { captureHandle = try RemoteEngineSync.ensureEnginesOnDevice(ref, kind: .codex) } catch { check("valid fixture ensure 不得 throw", false, "\(error)") }
            let captured: String? = captureHandle.map { _ in realFixtureRoot + "/planned-commands.json" }
            check("快取命中＋valid fixture 回 capture-only handle、不回生產 sidecar 路徑", captureHandle?.isCaptureOnly == true && captureHandle?.sidecarScript.hasPrefix(realFixtureRoot + "/") == true && fm.fileExists(atPath: captured ?? ""), "script=\(captureHandle?.sidecarScript ?? "nil")")
            check("fixture handle 衍生路徑全在 root 內", (captureHandle?.remoteEnvironment.values.allSatisfy { $0.hasPrefix(realFixtureRoot + "/") } ?? false) && captureHandle?.remoteProjectRoot?.hasPrefix(realFixtureRoot + "/") == true, "\(captureHandle?.remoteEnvironment ?? [:])")
            let planned = captured.flatMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: $0))) as? [String: Any] }
            let commands = planned?["commands"] as? [[String]] ?? []
            let dest = planned?["destination"] as? String ?? ""
            check("目的地＝owned 唯一路徑", dest == realFixtureRoot + "/remote-dest-" + token + "/engines", "dest=\(dest)")
            let mkdir = commands.first ?? []
            check("argv：ssh mkdir 目的地已 quote（含空格）", mkdir.first == "/usr/bin/ssh" && mkdir.contains("/bin/mkdir") && mkdir.last == remoteShellQuote(dest) && (mkdir.last?.hasPrefix("'") ?? false), "mkdir=\(mkdir)")
            let rsync = commands.count > 1 ? commands[1] : []
            check("argv：rsync --delete＋來源 Engines/＋目的地 quote", rsync.first == "/usr/bin/rsync" && rsync.contains("--delete") && rsync.contains(where: { $0.hasSuffix("/Engines/") }) && rsync.last == "\(ref.sshTarget):\(remoteShellQuote(dest + "/"))", "rsync=\(rsync)")
            check("真家目的地未出現在任何 argv", !commands.flatMap { $0 }.contains(where: { $0.contains("~/.tatwo2/engines") }), "")
            check("capture 分支 0 次程序執行（主要證據）", RemoteEngineSync.debugRunCount == runsBefore, "runs=\(RemoteEngineSync.debugRunCount - runsBefore)")

            // 整鏈 capture-only（14:13 批准第一階段）：App 對話派一個遠端房間 → sync／worktree／sidecar 三段都只記錄；房間明確 failed（capture-only），0 ssh／rsync／sidecar
            do {
                var environment = ProcessInfo.processInfo.environment
                environment["TATWO2_REMOTETEST"] = nil
                environment["TATWO2_LIVE_ROOT"] = root.path
                let model = ChatPageModel(environment: environment)
                model.permissionPreset = .approveForMe
                let enginesRoot = root.appendingPathComponent("engines", isDirectory: true).path
                let engineDirsBefore = (try? fm.contentsOfDirectory(atPath: enginesRoot))?.count ?? -1
                guard let projectID = model.acceptanceNewProject(name: "remotetest", workdir: repo.path),
                      let parentID = model.acceptanceNewThread(in: projectID, title: "主串") else { check("整鏈：建專案／主串", false, ""); throw RemoteEngineSyncError.fixtureBlocked("setup") }
                // kind 反例：claude 遠端房間在 fixture 下必須 BLOCKED（dispatchChecked throw），不建房間
                var chainKindBlocked = false
                do { _ = try model.dispatchChecked(rooms: [RoomSpec(title: "claude 房", engine: "claude", model: nil, brief: "x", device: deviceID)], parent: parentID) } catch RemoteEngineSyncError.fixtureBlocked { chainKindBlocked = true } catch {}
                check("整鏈：claude kind 在 fixture 下 dispatch 即 BLOCKED", chainKindBlocked, "")
                let dispatched = try model.dispatchChecked(rooms: [RoomSpec(title: "遠端房間", engine: "codex", model: "gpt-5.6-sol", brief: "只回一個詞：乒", device: deviceID)], parent: parentID)
                let room = dispatched.first
                let roomThread = room.flatMap { UUID(uuidString: $0.threadID) }
                let record = roomThread.flatMap { model.live?.threadRecord($0) }
                check("整鏈：房間建立、worktree 由同一 planner 從 owned remote-project 推導", room?.worktree.hasPrefix(realFixtureRoot + "/remote-project/.tatwo2/wt/") == true, "worktree=\(room?.worktree ?? "nil")")
                check("整鏈：房間明確 failed（capture-only），不冒充完成", record?.subStatus == "failed" && (model.live?.transcript(for: roomThread!) ?? []).contains { $0.text.contains("capture-only") }, "subStatus=\(record?.subStatus ?? "nil")")
                check("整鏈：0 個 sidecar 程序", roomThread.flatMap { model.live?.sidecarProcessID(threadID: $0) } == nil, "")
                check("整鏈：0 ssh／rsync 執行", RemoteEngineSync.debugRunCount == runsBefore, "runs=\(RemoteEngineSync.debugRunCount - runsBefore)")
                let engineDirsAfter = (try? fm.contentsOfDirectory(atPath: enginesRoot))?.count ?? -1
                check("整鏈：prepareEngineHomes 未被呼叫（引擎家目錄數不變）", engineDirsBefore == engineDirsAfter, "before=\(engineDirsBefore) after=\(engineDirsAfter)")
                let chainURL = URL(fileURLWithPath: realFixtureRoot).appendingPathComponent("capture-chain.jsonl")
                let stages = (try? String(contentsOf: chainURL, encoding: .utf8))?.split(separator: "\n").compactMap { line -> String? in
                    (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["stage"] as? String } ?? []
                check("整鏈：capture-chain 有 sync→worktree→sidecar 三段", stages.contains("sync") && stages.contains("worktree") && stages.contains("sidecar"), "stages=\(stages)")
                let sidecarLine = (try? String(contentsOf: chainURL, encoding: .utf8))?.split(separator: "\n").last(where: { $0.contains("\"sidecar\"") }).map(String.init) ?? ""
                check("整鏈：sidecar argv 用 fixture 路徑、不含真家", sidecarLine.contains(realFixtureRoot) && !sidecarLine.contains("~/.tatwo2") && !sidecarLine.contains("~/.codex") && sidecarLine.contains("CODEX_HOME="), "")
                // 缺 session handle＋fixture 訊號：直接對該遠端串再 send（模擬「重開後」）→ fail-closed、不起 sidecar
                if let roomThread { (model.live as? ChatLiveEngine)?.remoteHandles.remove(roomThread); model.live?.send(threadID: roomThread, text: "again", model: nil, engine: .codex) }
                let rows = roomThread.map { model.live?.transcript(for: $0) ?? [] } ?? []
                check("整鏈：fixture 訊號下缺 session handle → fail-closed（不 resolve 生產路徑）", rows.contains { $0.text.contains("沒有本次 session") } && RemoteEngineSync.debugRunCount == runsBefore, "")
                model.shutdownForContainerClose()
            } catch { check("整鏈 capture-only", false, "error=\(error)") }
            // 14:18 四點反例
            // (1) 同 thread 切 engine／換 device：fixture handle 不一致→fail-closed；production 不一致→依 registered device 重新 resolve 固定 handle（正常切換不判 failed）
            if let fixtureHandle = captureHandle {
                var mismatchBlocked = false
                do { _ = try RemoteEngineHandle.resolve(session: fixtureHandle, device: ref, engine: .claude, testRequested: true) } catch RemoteEngineSyncError.fixtureBlocked { mismatchBlocked = true } catch {}
                check("(1) fixture session handle 切到 claude → fail-closed", mismatchBlocked, "")
                let other = RemoteDeviceRef(id: "other-device", name: "o", host: "o.local", user: "u", workdirMap: [:])
                var deviceMismatchBlocked = false
                do { _ = try RemoteEngineHandle.resolve(session: fixtureHandle, device: other, engine: .codex, testRequested: true) } catch RemoteEngineSyncError.fixtureBlocked { deviceMismatchBlocked = true } catch {}
                check("(1) fixture session handle 換 device → fail-closed", deviceMismatchBlocked, "")
            }
            // (B) 同 id 但 registered host／port 變了：production 重 resolve 成新 endpoint；fixture fail-closed
            let movedRef = RemoteDeviceRef(id: ref.id, name: ref.name, host: "moved.local", user: ref.user, sshPort: ref.sshPort + 1, workdirMap: ref.workdirMap)
            let prodOld = RemoteEngineHandle.production(device: ref, kind: .codex)
            let prodMoved = try? RemoteEngineHandle.resolve(session: prodOld, device: movedRef, engine: .codex, testRequested: false)
            check("(B) production 同 id 改 host/port → 依當次 registered 重 resolve（新 endpoint）", prodMoved?.device.host == "moved.local" && prodMoved?.device.sshPort == ref.sshPort + 1 && prodMoved?.isCaptureOnly == false, "")
            if let fixtureHandle = captureHandle {
                var movedBlocked = false
                do { _ = try RemoteEngineHandle.resolve(session: fixtureHandle, device: movedRef, engine: .codex, testRequested: true) } catch RemoteEngineSyncError.fixtureBlocked { movedBlocked = true } catch {}
                check("(B) fixture 同 id 改 host/port → fail-closed", movedBlocked, "")
            }
            // 登記有界生命週期：兩個 engine 各持一份、互不清除；shutdownAll／stop 只清自己；engine 釋放時登記一起釋放
            do {
                let regRoot = URL(fileURLWithPath: realFixtureRoot).appendingPathComponent("registry-lifecycle", isDirectory: true)
                let handle = RemoteEngineHandle.production(device: ref, kind: .codex)
                let t1 = UUID(), t2 = UUID()
                weak var weakA: ChatLiveEngine?
                var survived = false
                autoreleasepool {
                    var engineA: ChatLiveEngine? = ChatLiveEngine(store: ChatLiveStore(root: regRoot.appendingPathComponent("a")), environment: [:])
                    let engineB = ChatLiveEngine(store: ChatLiveStore(root: regRoot.appendingPathComponent("b")), environment: [:])
                    weakA = engineA
                    engineA?.remoteHandles.set(t1, handle)
                    engineB.remoteHandles.set(t2, handle)
                    check("登記：兩個 engine 各自只看得到自己的 handle", engineA?.remoteHandles.get(t2) == nil && engineB.remoteHandles.get(t1) == nil && engineA?.remoteHandles.get(t1) != nil && engineB.remoteHandles.get(t2) != nil, "")
                    engineB.shutdownAll()
                    check("登記：engineB shutdownAll 只清自己，engineA 的 handle 仍在", engineB.remoteHandles.count == 0 && engineA?.remoteHandles.get(t1) != nil, "b=\(engineB.remoteHandles.count)")
                    engineA?.remoteHandles.set(t2, handle)
                    engineA?.stop(threadID: t1)
                    check("登記：stop(threadID) 只清該串，其他串 handle 仍在", engineA?.remoteHandles.get(t1) == nil && engineA?.remoteHandles.get(t2) != nil, "")
                    engineA?.shutdownAll()
                    survived = engineA?.remoteHandles.count == 0
                    engineA = nil
                }
                check("登記：關閉後 handle 全釋放且 engine 本體釋放（weak == nil）", survived && weakA == nil, "weakA=\(weakA == nil ? "nil" : "alive")")
            }
            let prodSession = RemoteEngineHandle.production(device: ref, kind: .codex)
            let switched = try? RemoteEngineHandle.resolve(session: prodSession, device: ref, engine: .claude, testRequested: false)
            check("(1) production session 切 engine → 重新 resolve 成該 engine 的固定 handle（不判 failed）", switched?.kind == .claude && switched?.sidecarScript == ref.sidecarPath(for: .claude) && switched?.isCaptureOnly == false, "")
            let noSession = try? RemoteEngineHandle.resolve(session: nil, device: ref, engine: .codex, testRequested: false)
            check("(1) production 無 session → 依 registered device 重新 resolve（正常恢復）", noSession?.sidecarScript == ref.sidecarPath(for: .codex) && noSession?.remoteEnvironment.isEmpty == true, "")
            // (2) start 入口：測試訊號存在但給 production handle、或 handle token 已失效 → fail-closed（純驗證函式，不起 Process）
            var startProdBlocked = false
            do { try prodSession.validateForStart(kind: .codex, environment: ["TATWO2_REMOTETEST": "1"]) } catch RemoteEngineSyncError.fixtureBlocked { startProdBlocked = true } catch {}
            check("(2) start 入口：測試訊號＋production handle → fail-closed", startProdBlocked, "")
            if let fixtureHandle = captureHandle {
                var staleBlocked = false
                do { try fixtureHandle.validateForStart(kind: .codex, environment: ["TATWO2_REMOTE_SYNC_FIXTURE": realFixtureRoot, "TATWO2_REMOTE_SYNC_TOKEN": UUID().uuidString.lowercased()]) } catch RemoteEngineSyncError.fixtureBlocked { staleBlocked = true } catch {}
                check("(2) start 入口：session handle token 已失效 → fail-closed", staleBlocked, "")
                var kindBlockedAtStart = false
                do { try fixtureHandle.validateForStart(kind: .grok, environment: ["TATWO2_REMOTE_SYNC_FIXTURE": realFixtureRoot, "TATWO2_REMOTE_SYNC_TOKEN": token]) } catch RemoteEngineSyncError.fixtureBlocked { kindBlockedAtStart = true } catch {}
                check("(2) start 入口：kind 不符 → fail-closed", kindBlockedAtStart, "")
                var noSignalCapture = false
                do { try fixtureHandle.validateForStart(kind: .codex, environment: [:]) } catch RemoteEngineSyncError.fixtureBlocked { noSignalCapture = true } catch {}
                check("(2) start 入口：沒有測試訊號卻拿 capture-only handle → fail-closed", noSignalCapture, "")
            }
            // (3) 既有 component symlink → fixture BLOCKED；capture 記錄檔 symlink → ensure throw；owned 外部 sentinel 不變
            do {
                let r3 = root.appendingPathComponent("symlink-home-fixture", isDirectory: true)
                try fm.createDirectory(at: r3, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["token": token]).write(to: r3.appendingPathComponent("owner.json"), options: .atomic)
                let elsewhere = root.appendingPathComponent("elsewhere-home", isDirectory: true); try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: r3.appendingPathComponent("home"), withDestinationURL: elsewhere)
                setenv("TATWO2_REMOTE_SYNC_FIXTURE", r3.standardizedFileURL.resolvingSymlinksInPath().path, 1)
                var homeLinkBlocked = false
                do { _ = try RemoteEngineSync.ensureEnginesOnDevice(ref, kind: .codex) } catch RemoteEngineSyncError.fixtureBlocked { homeLinkBlocked = true } catch {}
                check("(3) 衍生 home 是 symlink → BLOCKED", homeLinkBlocked && RemoteEngineSync.debugRunCount == runsBefore, "")
                let r4 = root.appendingPathComponent("symlink-capture-fixture", isDirectory: true)
                try fm.createDirectory(at: r4, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["token": token]).write(to: r4.appendingPathComponent("owner.json"), options: .atomic)
                let sentinel = root.appendingPathComponent("outside-sentinel.log"); try Data("sentinel\n".utf8).write(to: sentinel, options: .atomic)
                let sentinelBefore = (try? Data(contentsOf: sentinel)) ?? Data()
                try fm.createSymbolicLink(at: r4.appendingPathComponent("capture-chain.jsonl"), withDestinationURL: sentinel)
                setenv("TATWO2_REMOTE_SYNC_FIXTURE", r4.standardizedFileURL.resolvingSymlinksInPath().path, 1)
                var captureLinkBlocked = false
                do { _ = try RemoteEngineSync.ensureEnginesOnDevice(ref, kind: .codex) } catch RemoteEngineSyncError.fixtureBlocked { captureLinkBlocked = true } catch {}
                let sentinelAfter = (try? Data(contentsOf: sentinel)) ?? Data()
                check("(3) capture 記錄檔是 symlink → BLOCKED 且外部 sentinel 未被寫（bytes 相同）", captureLinkBlocked && sentinelBefore == sentinelAfter, "before=\(sentinelBefore.count) after=\(sentinelAfter.count)")
                setenv("TATWO2_REMOTE_SYNC_FIXTURE", realFixtureRoot, 1)
            } catch { check("(3) symlink 反例 setup", false, "\(error)") }
            // (4) 純 planner 與原 inline 公式逐字相同（production 用同一 planner）
            let plan = ChatPageModel.remoteWorktreePlan(workdir: "/remote/proj", roomID: "ROOM-1")
            let oldWorktree = ("/remote/proj" as NSString).appendingPathComponent(".tatwo2/wt/ROOM-1")
            check("(4) worktree planner＝原公式（mkdir -p parent；git -C workdir worktree add -b room/<id> <worktree>）", plan.worktree == oldWorktree && plan.commands == [["/bin/mkdir", "-p", (oldWorktree as NSString).deletingLastPathComponent], ["/usr/bin/git", "-C", "/remote/proj", "worktree", "add", "-b", "room/ROOM-1", oldWorktree]], "\(plan.commands)")
            let sshOld: [String] = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=8", "-p", String(ref.sshPort), ref.sshTarget] + ["/usr/bin/git", "-C", "/remote/proj it's", "worktree", "add", "-b", "room/x", "~/wt x"].map { remoteShellQuote($0, expandHome: $0.hasPrefix("~/")) }
            check("(4) sshArguments＝原 runSSH 公式（含空格／單引號／~ 展開）", ChatPageModel.sshArguments(ref, command: ["/usr/bin/git", "-C", "/remote/proj it's", "worktree", "add", "-b", "room/x", "~/wt x"]) == sshOld, "")
            // production handle 形狀（正常恢復語意）：不受 fixture 規則影響的純函式檢查
            let prod = RemoteEngineHandle.production(device: ref, kind: .codex)
            check("production handle：sidecar 路徑＝固定 ~/.tatwo2/engines、remoteEnvironment 空、非 capture-only", prod.sidecarScript == ref.sidecarPath(for: .codex) && prod.remoteEnvironment.isEmpty && !prod.isCaptureOnly, prod.sidecarScript)
            let sharedStampAfter = (try? Data(contentsOf: URL(fileURLWithPath: sharedStamp))) ?? Data()
            check("共享 last-sync cache 檔未被本測試寫入", sharedStampBefore == sharedStampAfter, "bytes before=\(sharedStampBefore.count) after=\(sharedStampAfter.count)")
            let homeEnginesAfter = (try? fm.attributesOfItem(atPath: realHomeEngines))?[.modificationDate] as? Date
            print("REMOTETEST NOTE 弱觀察：真家 ~/.tatwo2/engines 父目錄 mtime before=\(String(describing: homeEnginesBefore)) after=\(String(describing: homeEnginesAfter))（不等於子樹未動的證明）")
            let strayAfter = fm.fileExists(atPath: fm.currentDirectoryPath + "/Engines/claude")
            check("engines root isolated from cwd", strayBefore || !strayAfter, "cwd/Engines/claude before=\(strayBefore) after=\(strayAfter)")
            // production argv／resume 基線（0 ssh／rsync、0 額外程序）：用現 source 的真 formatter 對固定樣本產 argv，
            // 與「舊 inline 公式」逐字全量比對（table），寫到本次已 validated 的 fixture 根（不接受任意輸出路徑），同時印 stdout 由外層 owned runner 保存。
            do {
                func oldInline(_ remote: RemoteDeviceRef, _ args: [String]) -> [String] {   // 原 ClaudeSidecar.start inline 版本，逐字複製作為對照
                    let remoteCommand = ["env", "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "node"] + args
                    return ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-p", String(remote.sshPort), remote.sshTarget]
                        + remoteCommand.enumerated().map { index, value in remoteShellQuote(value, expandHome: index == 3) }
                }
                let refs = [RemoteDeviceRef(id: "s22", name: "s", host: "sample.local", user: "sampleuser", sshPort: 22, workdirMap: [:]),
                            RemoteDeviceRef(id: "s2222", name: "s", host: "sample.local", user: "sampleuser", sshPort: 2222, workdirMap: [:])]
                let cwds = ["/remote/proj/wt/plain", "/remote/proj/.tatwo2/wt/room 1", "/remote/proj/it's/wt"]
                let resumes: [String?] = [nil, "thread-abc"]
                var table: [[String: Any]] = []; var allEqual = true
                for ref in refs { for cwd in cwds { for resume in resumes {
                    var args = [ref.sidecarPath(for: .codex), "--cwd", cwd]
                    if let resume { args += ["--resume", resume] }
                    args += ["--model", "gpt-5.6-sol", "--mcp-config", "{\"engine\":\"codex\",\"servers\":{}}", "--permission-mode", "default"]
                    let launch = ClaudeSidecar.remoteLaunch(remote: ref, sidecarArgs: args)
                    let expected = oldInline(ref, args)
                    let equal = launch.executable == "/usr/bin/ssh" && launch.arguments == expected
                    allEqual = allEqual && equal
                    table.append(["port": ref.sshPort, "cwd": cwd, "resume": resume ?? NSNull(), "equal_to_old_inline": equal, "arguments": launch.arguments])
                } } }
                check("baseline: remoteLaunch 全量 argv 與舊 inline 公式逐字相同（port 22/2222 × 3 種 cwd × resume nil/值 ＝ 12 案）", allEqual, "cases=\(table.count)")
                let sync = RemoteEngineSync.plannedCommands(ref: refs[1], localEngines: URL(fileURLWithPath: "/local/Engines"), destination: .production)
                check("baseline: production sync 目的地仍是 ~/.tatwo2/engines", sync.first?.last == "~/.tatwo2/engines" && sync.last?.last == "\(refs[1].sshTarget):~/.tatwo2/engines/", "")
                let payload: [String: Any] = ["note": "0 ssh/rsync、0 額外程序；revision／binary sha 由外層 owned runner 的 meta 綁定（本測試不呼叫 git）",
                                              "resume": "本基線只是 argv 形狀（含 --resume 有無），不是恢復行為測試",
                                              "production_sync_commands_port2222": sync, "remote_launch_table": table]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                let baselineURL = URL(fileURLWithPath: realFixtureRoot).appendingPathComponent("remote-baseline.json")   // 只寫到本次已 validated 的 fixture 根
                try data.write(to: baselineURL, options: .atomic)
                print("REMOTETEST NOTE baseline written to \(baselineURL.path)")
                print("REMOTETEST BASELINE-JSON " + String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: " "))
            }
            print(failed ? "REMOTETEST FAILED" : "REMOTETEST capture checks passed")
            print("REMOTETEST BLOCKED real ssh/rsync integration not run（owned fixture capture-only；真整合維持 BLOCKED 直到 ownership 設計核過與 sidecar 路徑同源）")
            exit(1)
        } catch {
            check("執行", false, "error=\(error)")
            print("REMOTETEST FAILED")
            exit(1)
        }
        #else
        print("REMOTETEST BLOCKED release build has no test fixture（不 ssh、不 rsync）")
        exit(1)
        #endif
    }
}

extension SelfTest {
    /// TATWO2_PAIRTEST=1：用兩個暫存 LIVE_ROOT 與暫存 authorized_keys 驗 R1 限時單次配對。
    @MainActor static func runPairTest() {
        let runID = UUID().uuidString.lowercased()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tatwo2-pairtest-\(runID)", isDirectory: true)
        let hostRoot = base.appendingPathComponent("host-live", isDirectory: true)
        let clientRoot = base.appendingPathComponent("client-live", isDirectory: true)
        let authorizedKeys = base.appendingPathComponent("host-authorized_keys")
        let clientKey = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519")
        let generatedClientKey = base.appendingPathComponent("generated-client-ssh/id_ed25519")
        let knownHosts = base.appendingPathComponent("known_hosts")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let preservedLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPRESERVEDPAIRTESTLINE keep-this-line"
        try? (preservedLine + "\n").write(to: authorizedKeys, atomically: true, encoding: .utf8)
        let keyscan = Process()
        let keyscanPipe = Pipe()
        keyscan.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        keyscan.arguments = ["-T", "5", "127.0.0.1"]
        keyscan.standardOutput = keyscanPipe
        keyscan.standardError = FileHandle.nullDevice
        try? keyscan.run()
        keyscan.waitUntilExit()
        try? keyscanPipe.fileHandleForReading.readDataToEndOfFile().write(to: knownHosts, options: .atomic)

        let hostEnvironment = [
            "TATWO2_LIVE_ROOT": hostRoot.path,
            "TATWO2_AUTHORIZED_KEYS": authorizedKeys.path,
            "TATWO2_PAIRING_HOST": "127.0.0.1",
        ]
        let clientEnvironment = [
            "TATWO2_LIVE_ROOT": clientRoot.path,
            "TATWO2_SSH_KEY_PATH": clientKey.path,
            "TATWO2_SSH_KNOWN_HOSTS": knownHosts.path,
        ]
        var generatedKeyEnvironment = clientEnvironment
        generatedKeyEnvironment["TATWO2_SSH_KEY_PATH"] = generatedClientKey.path
        let hostRegistry = DeviceRegistry(environment: hostEnvironment)
        let clientRegistry = DeviceRegistry(environment: clientEnvironment)
        let host = DevicePairingHost(registry: hostRegistry, environment: hostEnvironment)
        let client = DevicePairingClient(
            registry: clientRegistry,
            privateKeyURL: clientKey,
            environment: clientEnvironment)
        let generatedKeyClient = DevicePairingClient(
            registry: clientRegistry,
            privateKeyURL: generatedClientKey,
            environment: generatedKeyEnvironment)
        var failed = false
        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("PAIRTEST \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }
        func oneLine(_ error: Error) -> String {
            error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        }

        do {
            let window = try host.startPairingWindow()
            guard let port = Int(window.listenAddress.split(separator: ":").last ?? "") else {
                check("監聽位址", false, "listenAddress=\(window.listenAddress)")
                print("PAIRTEST FAILED")
                exit(1)
            }
            let replacement = window.code.first == "A" ? "B" : "A"
            let wrongCode = replacement + window.code.dropFirst()
            do {
                _ = try generatedKeyClient.pair(host: "127.0.0.1", port: port, code: wrongCode, name: "Pairtest Client")
                check("錯碼拒絕", false, "wrongCode unexpectedly accepted")
            } catch {
                check("錯碼拒絕", true, "error=\(oneLine(error))")
            }
            check(
                "缺少 id_ed25519.pub 時自動產生",
                FileManager.default.fileExists(atPath: generatedClientKey.path)
                    && FileManager.default.fileExists(atPath: generatedClientKey.path + ".pub"),
                "privateKey=true publicKey=true")

            let paired = try client.pair(
                host: "127.0.0.1",
                port: port,
                code: window.code,
                name: "Pairtest Client")
            let hostRows = hostRegistry.list()
            let clientRows = clientRegistry.list()
            let authorizedText = (try? String(contentsOf: authorizedKeys, encoding: .utf8)) ?? ""
            let marker = "tatwo2-device:\(paired.id)"
            check(
                "對碼成功",
                hostRows.count == 1 && clientRows.count == 1 && hostRows.first?.id == paired.id,
                "deviceID=\(paired.id) sshBatchMode=passed hostDevices=\(hostRows.count) clientDevices=\(clientRows.count)")
            check(
                "authorized_keys 新增一行",
                authorizedText.split(whereSeparator: \.isNewline).filter { $0.contains(marker) }.count == 1,
                "marker=\(marker) lines=\(authorizedText.split(whereSeparator: \.isNewline).count)")
            check(
                "兩邊 devices.json 各一筆",
                hostRows.count == 1 && clientRows.count == 1
                    && FileManager.default.fileExists(atPath: hostRegistry.url.path)
                    && FileManager.default.fileExists(atPath: clientRegistry.url.path),
                "hostExists=\(FileManager.default.fileExists(atPath: hostRegistry.url.path)) clientExists=\(FileManager.default.fileExists(atPath: clientRegistry.url.path))")

            do {
                _ = try client.pair(
                    host: "127.0.0.1",
                    port: port,
                    code: window.code,
                    name: "Pairtest Replay")
                check("同碼重播拒絕", false, "replay unexpectedly accepted")
            } catch {
                check("同碼重播拒絕", true, "error=\(oneLine(error))")
            }

            var modelEnvironment = hostEnvironment
            modelEnvironment["TATWO2_SELFTEST"] = "1"
            let model = ChatPageModel(environment: modelEnvironment)
            model.removeDevice(id: paired.id)
            let afterRemove = (try? String(contentsOf: authorizedKeys, encoding: .utf8)) ?? ""
            check(
                "removeDevice 只移除自己的行",
                hostRegistry.list().isEmpty
                    && !afterRemove.contains(marker)
                    && afterRemove.contains(preservedLine),
                "devices=\(hostRegistry.list().count) tagged=\(afterRemove.contains(marker)) preserved=\(afterRemove.contains(preservedLine))")
            model.shutdownForContainerClose()
        } catch {
            check("執行", false, "error=\(oneLine(error))")
        }
        print(failed ? "PAIRTEST FAILED" : "PAIRTEST ALL PASS")
        exit(failed ? 1 : 0)
    }
}

extension SelfTest {
    /// TATWO2_PAIRHOST=1：在真實 live root 開一個配對窗（給另一台真機配對用），印出碼與位址，等到配對成功或 5 分鐘。
    @MainActor static func runPairHost() {
        let env = ProcessInfo.processInfo.environment
        let registry = DeviceRegistry(environment: env)
        let host = DevicePairingHost(registry: registry, environment: env)
        let before = registry.list().count
        var closed = false
        host.onClose = { closed = true }
        do {
            let w = try host.startPairingWindow()
            print("PAIRHOST code=\(w.code) address=\(w.listenAddress) expires=\(w.expiresAt)")
        } catch {
            print("PAIRHOST FAIL \(error.localizedDescription)"); exit(1)
        }
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let now = registry.list()
            if now.count > before {
                let d = now.last!
                print("PAIRHOST PAIRED name=\(d.name) user=\(d.user) host=\(d.host) fp=\(d.publicKeyFingerprint)")
                exit(0)
            }
            if closed { break }
        }
        print("PAIRHOST TIMEOUT_OR_CLOSED"); exit(2)
    }

    /// TATWO2_PAIRCLIENT=host:port:code:name：這台當副機，去跟主機配對。
    @MainActor static func runPairClient() {
        let env = ProcessInfo.processInfo.environment
        let parts = (env["TATWO2_PAIRCLIENT"] ?? "").split(separator: ":", maxSplits: 3).map(String.init)
        guard parts.count == 4, let port = Int(parts[1]) else { print("PAIRCLIENT FAIL bad args (host:port:code:name)"); exit(1) }
        let registry = DeviceRegistry(environment: env)
        let client = DevicePairingClient(registry: registry)
        do {
            let d = try client.pair(host: parts[0], port: port, code: parts[2], name: parts[3])
            print("PAIRCLIENT PAIRED id=\(d.id) name=\(d.name) target=\(d.user)@\(d.host):\(d.sshPort)")
            exit(0)
        } catch {
            print("PAIRCLIENT FAIL \(error.localizedDescription)"); exit(1)
        }
    }

    /// TATWO2_REMOTEPROBE=<deviceID 或 名字>[|要送的話]：從這台連到主機的 os.sock，列出主機文件，選擇性送一句話。
    @MainActor static func runRemoteProbe() {
        let env = ProcessInfo.processInfo.environment
        let arg = env["TATWO2_REMOTEPROBE"] ?? ""
        let pieces = arg.split(separator: "|", maxSplits: 1).map(String.init)
        let key = pieces[0]
        let registry = DeviceRegistry(environment: env)
        guard let device = registry.list().first(where: { $0.id == key || $0.name == key }) else {
            print("REMOTEPROBE FAIL no device \(key); have \(registry.list().map(\.name))"); exit(1)
        }
        let link = RemoteHostLink(environment: env)
        do {
            try link.connect(device: device)
            let doc = try link.call(method: "get_document")
            let result = (doc["result"] as? [String: Any]) ?? doc
            let projects = (result["document"] as? [String: Any])?["projects"] as? [[String: Any]]
                ?? result["projects"] as? [[String: Any]] ?? []
            var threadCount = 0; var firstThread: String? = nil; var firstTitle = ""
            var allThreads: [[String: Any]] = []
            for p in projects { allThreads += (p["threads"] as? [[String: Any]] ?? []) }
            allThreads += (result["document"] as? [String: Any])?["threads"] as? [[String: Any]] ?? result["threads"] as? [[String: Any]] ?? []
            for t in allThreads {
                threadCount += 1
                if firstThread == nil, let id = t["id"] as? String { firstThread = id; firstTitle = t["title"] as? String ?? "" }
            }
            print("REMOTEPROBE CONNECTED device=\(device.name) projects=\(projects.count) threads=\(threadCount) revision=\(result["revision"] ?? "?")")
            if pieces.count == 2, let tid = firstThread {
                let r = try link.call(method: "send_message", params: ["threadID": tid, "text": pieces[1]])
                print("REMOTEPROBE SENT to=\(firstTitle) ok=\(r["ok"] ?? r["result"] ?? "?")")
            }
            link.disconnect(); exit(0)
        } catch {
            print("REMOTEPROBE FAIL \(error.localizedDescription)"); link.disconnect(); exit(1)
        }
    }
}

extension SelfTest {
    /// 三家引擎使用 App 內 runtime，且登入與 session 都寫入 Tatwo2 自己的 engines 目錄。
    @MainActor static func runEngineHomeTest() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let fm = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let engineRoot = ClaudeSidecar.engineHomeRoot(environment: environment)
        let originalCodexSessions = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let baselineCodexFiles = Set(engineHomeFileSnapshot(at: originalCodexSessions).keys)
        var failed = false

        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("ENGINEHOMETEST \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }

        Task { @MainActor in
            for kind in ClaudeSidecar.Kind.allCases {
                if kind == .grok {
                    let sourceAuth = fm.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
                    if !fm.fileExists(atPath: sourceAuth.path) {
                        print("ENGINEHOMETEST SKIP grok 回覆 — 本機沒有 ~/.grok/auth.json")
                        continue
                    }
                }
                let outcome = await engineHomeTurn(kind: kind)
                check("\(kind.rawValue) 回覆", outcome.ok, outcome.evidence)

                let home = engineRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
                let files = engineHomeFileSnapshot(at: home)
                check(
                    "\(kind.rawValue) 獨立資料",
                    !files.isEmpty,
                    "home=\(home.path) files=\(files.count)")
            }

            let codexHome = engineRoot.appendingPathComponent("codex", isDirectory: true)
            let codexSessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
            let isolatedSessions = engineHomeFileSnapshot(at: codexSessions)
            check(
                "codex session 分家",
                !isolatedSessions.isEmpty,
                "isolated=\(isolatedSessions.count) path=\(codexSessions.path)")

            let afterCodexFiles = Set(engineHomeFileSnapshot(at: originalCodexSessions).keys)
            check(
                "原 ~/.codex/sessions 沒新增",
                afterCodexFiles == baselineCodexFiles,
                "before=\(baselineCodexFiles.count) after=\(afterCodexFiles.count)")

            print(failed ? "ENGINEHOMETEST FAILED" : "ENGINEHOMETEST ALL PASS")
            exit(failed ? 1 : 0)
        }
        NSApplication.shared.run()
    }

    @MainActor private static func engineHomeTurn(kind: ClaudeSidecar.Kind) async -> (ok: Bool, evidence: String) {
        let sidecar = ClaudeSidecar(kind: kind)
        var reply = ""
        var error = ""
        var stderr = ""
        var finished = false
        sidecar.onEvent = { event in
            switch event {
            case .sdk(let message):
                if message["type"] as? String == "stream_event",
                   let stream = message["event"] as? [String: Any],
                   stream["type"] as? String == "content_block_delta",
                   let delta = stream["delta"] as? [String: Any],
                   let text = delta["text"] as? String {
                    reply += text
                }
                if message["type"] as? String == "result" {
                    if reply.isEmpty, let result = message["result"] as? String { reply = result }
                    if message["is_error"] as? Bool == true { error = message["result"] as? String ?? "result error" }
                    finished = true
                }
            case .permission(let id, _, _, _, _):
                sidecar.respondPermission(id: id, allow: false, message: "ENGINEHOMETEST 不使用工具")
            case .stderr(let line):
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    stderr = String(line.prefix(500))
                    if line.contains("auth.x.ai/oauth2/authorize") || line.localizedCaseInsensitiveContains("not logged in") {
                        error = "引擎要求重新登入"
                        finished = true
                    }
                }
            case .error(let message):
                error = message
                finished = true
            case .closed:
                if !finished {
                    error = error.isEmpty ? "sidecar closed before result" : error
                    finished = true
                }
            }
        }
        do {
            try sidecar.start(
                cwd: FileManager.default.currentDirectoryPath,
                resume: nil,
                model: nil,
                permissionMode: "default")
            sidecar.send(text: "只回一個字：好", uuid: UUID().uuidString)
        } catch {
            return (false, "啟動失敗：\(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(180)
        while !finished, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        sidecar.close()
        try? await Task.sleep(for: .milliseconds(300))
        let compact = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = finished && error.isEmpty && compact.contains("好")
        let evidence = "reply=\(compact.prefix(80)) error=\(error.prefix(160)) stderr=\(stderr.prefix(160))"
        return (ok, evidence)
    }

    private static func engineHomeFileSnapshot(at root: URL) -> [String: Date] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [])
        else { return [:] }
        var result: [String: Date] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true
            else { continue }
            result[url.path] = values.contentModificationDate ?? .distantPast
        }
        return result
    }
}

extension SelfTest {
    /// TATWO2_LOGINTEST=1：只用暫存 live root／引擎家目錄驗三家狀態、Codex 登出、假登入輸出與送出前攔截。
    @MainActor static func runLoginTest() {
        let fileManager = FileManager.default
        let runID = UUID().uuidString.lowercased()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tatwo2-logintest-\(runID)", isDirectory: true)
        let liveRoot = base.appendingPathComponent("live", isDirectory: true)
        let fakeBin = base.appendingPathComponent("fake-login.sh")
        let osSocket = "/tmp/t2l-\(runID.prefix(8))-os.sock"
        let browserSocket = "/tmp/t2l-\(runID.prefix(8))-browser.sock"
        try? fileManager.createDirectory(
            at: liveRoot,
            withIntermediateDirectories: true
        )
        try? """
        #!/bin/sh
        echo https://example.test/device
        echo fake-login-stderr >&2
        exit 0
        """.write(to: fakeBin, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeBin.path
        )

        var environment = ProcessInfo.processInfo.environment
        environment["TATWO2_LOGINTEST"] = "1"
        environment["TATWO2_SELFTEST"] = nil
        environment["TATWO2_LIVE_ROOT"] = liveRoot.path
        environment["TATWO2_LOGIN_FAKE_BIN"] = fakeBin.path
        environment["TATWO2_LOGIN_SECURITY_SERVICE"] =
            "Claude Code-credentials-logintest-\(runID)"
        environment["TATWO2_OS_SOCKET"] = osSocket
        environment["TATWO2_BROWSER_SOCKET"] = browserSocket
        setenv("TATWO2_LIVE_ROOT", liveRoot.path, 1)
        setenv("TATWO2_OS_SOCKET", osSocket, 1)
        setenv("TATWO2_BROWSER_SOCKET", browserSocket, 1)

        let paths = EnginePaths(environment: environment)
        let openedURLs = LoginTestStringBuffer()
        let login = EngineLogin(
            paths: paths,
            environment: environment,
            openURL: { url in
                openedURLs.append(url.absoluteString)
            }
        )

        var failed = false
        func check(_ item: String, _ passed: Bool, _ evidence: String) {
            print("LOGINTEST \(passed ? "PASS" : "FAIL") \(item) — \(evidence)")
            if !passed { failed = true }
        }

        let empty = login.statuses()
        check(
            "三家空資料夾皆未登入",
            empty.count == 3 && empty.allSatisfy { !$0.isLoggedIn },
            empty.map { "\($0.kind.rawValue)=\($0.isLoggedIn)" }.joined(separator: " ")
        )

        let sourceCodexAuth = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        do {
            try fileManager.copyItem(at: sourceCodexAuth, to: paths.codexAuth)
            let status = login.status(for: .codex)
            check(
                "Codex 複製登入檔後已登入",
                status.isLoggedIn && !(status.account ?? "").isEmpty,
                "authExists=\(fileManager.fileExists(atPath: paths.codexAuth.path)) accountNonempty=\(!(status.account ?? "").isEmpty)"
            )
        } catch {
            check(
                "Codex 複製登入檔後已登入",
                false,
                "copy error=\(error.localizedDescription)"
            )
        }

        let loggedOut = login.logout(.codex)
        check(
            "Codex 登出只移除獨立登入檔",
            !fileManager.fileExists(atPath: paths.codexAuth.path)
                && !loggedOut.isLoggedIn,
            "authExists=\(fileManager.fileExists(atPath: paths.codexAuth.path)) status=\(loggedOut.isLoggedIn)"
        )

        let events = LoginTestStringBuffer()
        _ = login.login(.codex) { line in
            events.append(line)
        }
        let eventSnapshot = events.snapshot()
        let openedSnapshot = openedURLs.snapshot()
        check(
            "假登入第一行轉送並辨識網址",
            eventSnapshot.contains("https://example.test/device")
                && openedSnapshot.contains("https://example.test/device"),
            "events=\(eventSnapshot.joined(separator: " | ")) opened=\(openedSnapshot)"
        )

        let model = ChatPageModel(environment: environment)
        model.selectedModel = "gpt-5.5"
        model.prompt = "這句不應送出"
        let before = model.live?
            .threadRecord(model.selectedThreadID)?
            .messages.count ?? -1
        model.send()
        let after = model.live?
            .threadRecord(model.selectedThreadID)?
            .messages.count ?? -1
        check(
            "未登入時 send 被擋",
            before == after
                && model.prompt == "這句不應送出"
                && model.composerHint?.contains("還沒登入") == true,
            "messages=\(before)->\(after) promptKept=\(model.prompt == "這句不應送出") hint=\(model.composerHint ?? "nil")"
        )
        model.shutdownForContainerClose()

        _ = unlink(osSocket)
        _ = unlink(browserSocket)
        try? fileManager.removeItem(at: base)
        print(failed ? "LOGINTEST FAILED" : "LOGINTEST ALL PASS")
        exit(failed ? 1 : 0)
    }
}

private final class LoginTestStringBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

extension SelfTest {
    /// TATWO2_GITHUBIMPORT=1：把這台 gh 已登入的帳號匯進 OS（真實 store），列出結果；可選 TATWO2_GITHUB_MCP_ON=<帳號> 開常駐。
    @MainActor static func runGitHubImport() {
        let model = ChatPageModel()
        model.importGitHubAccountsFromGH()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && model.gitHubAccounts.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        if let on = ProcessInfo.processInfo.environment["TATWO2_GITHUB_MCP_ON"],
           let acct = model.gitHubAccounts.first(where: { $0.username == on }), !acct.mcpAlwaysOn {
            model.toggleGitHubMCPAlwaysOn(on)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        for a in model.gitHubAccounts { print("GITHUBIMPORT account=\(a.username) default=\(a.isDefault) mcpAlwaysOn=\(a.mcpAlwaysOn) scopes=\(a.scopes)") }
        for line in model.gitHubLoginLog { print("GITHUBIMPORT log: \(line)") }
        exit(model.gitHubAccounts.isEmpty ? 1 : 0)
    }
}

extension SelfTest {
    /// TATWO2_BINDTEST=1：用暫存的三個「家」驗接入 OS：舊 1.0 段被移除、新段寫入、hash 一致＝bound、一頁改了＝stale、資料夾不在＝unreachable。
    @MainActor static func runBindTest() {
        let root = NSTemporaryDirectory() + "tatwo2-bindtest-" + UUID().uuidString
        let fm = FileManager.default
        try? fm.createDirectory(atPath: root + "/os", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: root + "/claude", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: root + "/codex", withIntermediateDirectories: true)
        try? "# 一頁規則 v1\n".write(toFile: root + "/os/os-upstream.md", atomically: true, encoding: .utf8)
        let legacy = "# CLAUDE.md\n規則 A\n\n<!-- TATWO_OS_UPSTREAM_BINDING_V1:BEGIN -->\n## TATWO Work OS upstream\n舊的\n<!-- TATWO_OS_UPSTREAM_BINDING_V1:END -->\n\n<!-- TATWO-ULTRAWORK-MODES v1 (舊) -->\n## 模式\n<!-- /TATWO-ULTRAWORK-MODES v1 -->\n"
        try? legacy.write(toFile: root + "/claude/CLAUDE.md", atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env["TATWO2_OS_ROOT"] = root + "/os"
        env["TATWO2_BIND_TARGETS"] = "claude=\(root)/claude/CLAUDE.md,codex=\(root)/codex/AGENTS.md,missing=\(root)/nope/GROK.md"
        var failed = false
        func check(_ item: String, _ ok: Bool, _ ev: String) { print("BINDTEST \(ok ? "PASS" : "FAIL") \(item) — \(ev)"); if !ok { failed = true } }
        let before = OSUpstreamBinding.statuses(environment: env)
        check("接之前：舊綁定被認出", before.first { $0.id == "claude" }?.detail.contains("1.0") == true, "detail=\(before.first { $0.id == "claude" }?.detail ?? "")")
        let after = OSUpstreamBinding.install(environment: env)
        let claude = (try? String(contentsOfFile: root + "/claude/CLAUDE.md", encoding: .utf8)) ?? ""
        check("舊 1.0 段被移除", !claude.contains("TATWO_OS_UPSTREAM_BINDING_V1") && !claude.contains("TATWO-ULTRAWORK-MODES") && claude.contains("規則 A"), "len=\(claude.count)")
        check("新段寫入且指向入口", claude.contains(OSUpstreamBinding.beginMarker) && claude.contains("\(root)/os/os.md"), "hasV2=\(claude.contains(OSUpstreamBinding.beginMarker))")
        check("claude／codex 都是 bound", after.filter { $0.id != "missing" }.allSatisfy { $0.state == .bound }, "\(after.map { "\($0.id)=\($0.state)" })")
        check("資料夾不在＝unreachable", after.first { $0.id == "missing" }?.state == .unreachable, "state=\(String(describing: after.first { $0.id == "missing" }?.state))")
        try? "# 一頁規則 v2（改了）\n".write(toFile: root + "/os/os-upstream.md", atomically: true, encoding: .utf8)
        let stale = OSUpstreamBinding.statuses(environment: env)
        check("一頁改了 → stale（有代差）", stale.first { $0.id == "claude" }?.state == .stale, "state=\(String(describing: stale.first { $0.id == "claude" }?.state))")
        let realigned = OSUpstreamBinding.install(environment: env)
        check("重新對齊後 bound", realigned.first { $0.id == "claude" }?.state == .bound, "")
        try? fm.removeItem(atPath: root)
        print(failed ? "BINDTEST FAILED" : "BINDTEST ALL PASS")
        exit(failed ? 1 : 0)
    }
}

extension SelfTest {
    @MainActor static func runCLISessionsTest() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let root = ProcessInfo.processInfo.environment["TATWO2_CLI_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tatwo2-clitest-\(UUID().uuidString)")
        var environment = ProcessInfo.processInfo.environment
        environment["TATWO2_LIVE_ROOT"] = root.path
        environment["TATWO2_SELFTEST"] = nil
        // The shared bridges read ProcessInfo, not the model's injected dictionary.
        // Keep every test socket inside the same owned acceptance root.
        environment["TATWO2_OS_SOCKET"] = root.appendingPathComponent("os.sock").path
        environment["TATWO2_BROWSER_SOCKET"] = root.appendingPathComponent("browser.sock").path
        setenv("TATWO2_LIVE_ROOT", root.path, 1)
        setenv("TATWO2_OS_SOCKET", environment["TATWO2_OS_SOCKET"]!, 1)
        setenv("TATWO2_BROWSER_SOCKET", environment["TATWO2_BROWSER_SOCKET"]!, 1)
        let model = ChatPageModel(environment: environment)
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ passed: Bool, _ evidence: String) {
                print("CLITEST \(passed ? "PASS" : "FAIL") \(name) — \(evidence)")
                if !passed { failures += 1 }
            }
            func wait(_ predicate: () -> Bool) async -> Bool {
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    if predicate() { return true }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return predicate()
            }
            // Exercise the exact UI drop handler against a separate three-row store.
            var dropEnvironment = environment
            dropEnvironment["TATWO2_LIVE_ROOT"] = root.appendingPathComponent("drop-handler").path
            let dropModel = ChatPageModel(environment: dropEnvironment)
            // Space preferences now load before CLI initialization. Test the ready
            // workbench rather than manufacturing UI-only tabs before startup.
            let dropReady = await wait { dropModel.cliRuntime != nil }
            check("drop_runtime_ready", dropReady, "Space preferences loaded before CLI test actions")
            let dropIDs = (1...3).compactMap { index in
                dropModel.openCLITestTab(executable: "/bin/zsh", arguments: ["-f", "-i"], title: "drop-\(index)", workdir: root.path)
            }
            if dropIDs.count == 3, let dropStore = dropModel.cliSessionStore {
                let accepted = dropModel.handleCLIRailDrop([dropModel.cliRailDragProvider(dropIDs[2])], before: dropIDs[0])
                let expected = [dropIDs[2], dropIDs[0], dropIDs[1]]
                let moved = await wait { dropModel.cliRailTabs.map(\.id) == expected }
                check("drop_third_before_first", accepted && moved && expected.enumerated().allSatisfy { index, id in
                    dropStore.sessions.first(where: { $0.id == id })?.order == index
                }, "handler accepted=\(accepted), rail/store order=3,1,2: \(moved)")
                check("drop_reject_type", !dropModel.handleCLIRailDrop([NSItemProvider()], before: dropIDs[0]), "provider without text rejected")
                check("drop_self", !dropModel.moveCLIRailTab(dropIDs[0], before: dropIDs[0]), "self drop is a no-op")
                let downward = dropModel.moveCLIRailTab(dropIDs[2], before: dropIDs[1])
                check("drop_downward_before", downward && dropModel.cliRailTabs.map(\.id) == [dropIDs[0], dropIDs[2], dropIDs[1]], "downward insertion is before destination, not after")
                dropModel.pinCLITab(dropIDs[0])
                check("drop_pin_boundary", !dropModel.moveCLIRailTab(dropIDs[1], before: dropIDs[0]), "pinned group boundary preserved")
                await dropStore.flush()
                let saved = (try? Data(contentsOf: root.appendingPathComponent("drop-handler/cli-sessions.json")))
                    .flatMap { try? JSONDecoder().decode([CLISessionStore.Record].self, from: $0) } ?? []
                check("drop_persisted", [dropIDs[0], dropIDs[2], dropIDs[1]].enumerated().allSatisfy { index, id in saved.first(where: { $0.id == id })?.order == index }, "reordered IDs persisted to isolated store")
            } else { check("drop_setup", false, "could not open three shell tabs") }
            dropModel.terminateAllCLITabs()
            _ = await wait { dropIDs.allSatisfy { dropModel.cliTabStatus($0) == .exited } }
            await dropModel.cliSessionStore?.flush()
            guard let store = model.cliSessionStore,
                  let a = model.openCLITestTab(executable: "/bin/zsh", arguments: ["-f", "-i"], title: "one", workdir: root.path),
                  let b = model.openCLITestTab(executable: "/bin/zsh", arguments: ["-f", "-i"], title: "two", workdir: root.path) else {
                print("CLITEST FAIL setup — no model/store/tab"); exit(1)
            }
            check("two_sessions", await wait { model.cliTabPTYSession(for: a)?.isRunning == true && model.cliTabPTYSession(for: b)?.isRunning == true }, "two /bin/zsh PTYs")
            for id in [a, b] {
                try? await model.cliTabPTYSession(for: id)?.sendLineAwaited("PS1='test$ '; printf 'CLI_OUTPUT_繁體中文🙂\\n'")
            }
            try? await Task.sleep(for: .milliseconds(400))
            let tails = await [model.cliWorkbenchTail(a), model.cliWorkbenchTail(b)]
            check("utf8_tail", tails.allSatisfy { $0.contains("CLI_OUTPUT_繁體中文🙂") }, "both tmux captures preserve CJK/emoji")
            check("short_tail", tails.allSatisfy { CLISessionStore.textTail($0, lines: 5).contains("CLI_OUTPUT_繁體中文🙂") },
                  "screen bottom blanks do not hide recent output")
            check("empty_tail", CLISessionStore.textTail("\n \n", lines: 5).isEmpty &&
                  CLISessionStore.textTail("one\n\n", lines: 0).isEmpty, "empty and zero-line requests remain empty")
            check("quiet_not_success", model.cliTabStatus(a) == .unknown, "unattached quiet shell is unknown, not task success/waiting")
            await store.flush()
            let diskHasHi = await Task.detached {
                [a, b].allSatisfy { ((try? String(contentsOf: store.logURL($0), encoding: .utf8)) ?? "").contains("CLI_OUTPUT_") }
            }.value
            check("scrollback", diskHasHi, "both bounded snapshots contain output")
            check("close_confirm", await wait { model.cliTabsNeedingCloseConfirm.contains { $0.id == a } }, "busy PTY included in close confirmation")
            model.sendCLITabOutputToChat(a)
            check("chat_transfer", await wait { model.prompt.contains("CLI_OUTPUT_") }, "fresh output copied to draft only")
            let pid = model.cliTabProcessID(for: a)
            model.removeCLIWorkbenchPane(a)
            try? await model.cliTabPTYSession(for: a)?.sendLineAwaited("printf 'BACKGROUND_OK\\n'")
            try? await Task.sleep(for: .milliseconds(250))
            check("background_read_write", await model.cliWorkbenchTail(a).contains("BACKGROUND_OK"), "detached session accepts existing tool transport")
            let options = CLIWorkbenchEditingOptions(deleteToLineStart: true, deletePreviousWord: false)
            model.sendCLIWorkbench(.setEditingOptions(options))
            check("editing_defaults", !CLIWorkbenchEditingOptions().deleteToLineStart && !CLIWorkbenchEditingOptions().deletePreviousWord, "both default off")
            check("editing_independent", NativeTerminalPTYNSView.editingByte(keyCode: 51, flags: .command, marked: false, options: options) == 0x15 &&
                  NativeTerminalPTYNSView.editingByte(keyCode: 51, flags: .option, marked: false, options: options) == nil, "command enabled does not enable option")
            check("editing_ime_bypass", NativeTerminalPTYNSView.editingByte(keyCode: 51, flags: .command, marked: true, options: options) == nil, "marked composition never intercepted")
            check("zhuyin_interrupt", NativeTerminalPTYNSView.inputSourceInterruptByte(keyCode: 8, flags: .control, characters: "ㄏ", marked: false) == 3, "physical Ctrl-C survives a non-ASCII input source")
            check("interrupt_composition_bypass", NativeTerminalPTYNSView.inputSourceInterruptByte(keyCode: 8, flags: .control, characters: "ㄏ", marked: true) == nil, "active composition remains owned by AppKit")
            check("interrupt_latin_passthrough", ["c", "C", "j"].allSatisfy {
                NativeTerminalPTYNSView.inputSourceInterruptByte(keyCode: 8, flags: .control, characters: $0, marked: false) == nil
            }, "Latin and remapped layouts keep SwiftTerm's native keyboard path")
            check("interrupt_exact_chord", NativeTerminalPTYNSView.inputSourceInterruptByte(keyCode: 8, flags: [.control, .shift], characters: "ㄏ", marked: false) == nil &&
                  NativeTerminalPTYNSView.inputSourceInterruptByte(keyCode: 9, flags: .control, characters: "ㄒ", marked: false) == nil &&
                  NativeTerminalPTYNSView.inputSourceInterruptByte(keyCode: 8, flags: .command, characters: "ㄏ", marked: false) == nil,
                  "no interception of modified shortcuts, another key or copy")
            check("editing_live_option", model.cliTabPTYSession(for: a)?.editingOptions == options, "existing background pane receives new setting")
            var wheel = CLIWorkbenchScrollAccumulator()
            check("scroll_fractional", wheel.consume(delta: 6, precise: true, lineHeight: 18) == 0 &&
                  wheel.consume(delta: 12, precise: true, lineHeight: 18) == 1,
                  "trackpad sub-line deltas accumulate rather than being lost")
            check("scroll_wheel_bounds", wheel.consume(delta: -0.2, precise: false, lineHeight: 18) == -1 &&
                  wheel.consume(delta: 10000, precise: false, lineHeight: 18) == 256 &&
                  wheel.consume(delta: 0, precise: false, lineHeight: 18) == 0,
                  "wheel notch, event bound and zero-delta behavior")
            if let runtime = model.cliRuntime {
                do {
                    try await model.cliTabPTYSession(for: a)?.sendLineAwaited("printf 'SCROLL_TEST_%03d\\n' {1..160}")
                    try await Task.sleep(for: .milliseconds(250))
                    try await runtime.scrollHistory(a, lines: 24)
                    let mode = try await runtime.run(["display-message", "-p", "-t", CLITmuxRuntime.name(a),
                                                     "#{pane_mode}:#{scroll_position}:#{pane_height}"])
                    let fields = mode.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: ":", omittingEmptySubsequences: false)
                    let offset = fields.count == 3 ? Int(fields[1]) ?? 0 : 0
                    let height = fields.count == 3 ? Int(fields[2]) ?? 0 : 0
                    check("scroll_enters_history", mode.status == 0 && fields.first == "copy-mode" &&
                          offset == 24 && height > 0,
                          "wheel transport enters tmux history, not shell arrow-key history")
                    // tmux 3.6a -M exposes copy-mode's backing grid, not its
                    // visible viewport. Sample that grid at the reported offset.
                    let screen = try await runtime.run(["capture-pane", "-p", "-M", "-t", CLITmuxRuntime.name(a),
                                                        "-S", String(-offset), "-E", String(height - 1 - offset)])
                    check("scroll_earlier_output", screen.status == 0 && screen.text.contains("SCROLL_TEST_100") &&
                          !screen.text.contains("SCROLL_TEST_160"), "copy-mode viewport shows earlier output")
                    try await runtime.scrollHistory(a, lines: -256)
                    // A further downward wheel at the live prompt is a no-op.
                    try await runtime.scrollHistory(a, lines: -4)
                    let live = try await runtime.run(["display-message", "-p", "-t", CLITmuxRuntime.name(a), "#{pane_in_mode}"])
                    check("scroll_returns_live", live.status == 0 && live.text.trimmingCharacters(in: .whitespacesAndNewlines) == "0",
                          "bottom exits history; downward wheel cannot inject shell keys")
                } catch { check("scroll_runtime", false, error.localizedDescription) }
            } else { check("scroll_runtime", false, "missing runtime") }
            model.renameCLITab(a, title: "renamed")
            model.pinCLITab(a)
            model.reorderCLITabs([b, a])
            await store.flush()
            let diskRecords = await Task.detached { () -> [CLISessionStore.Record] in
                guard let data = try? Data(contentsOf: root.appendingPathComponent("cli-sessions.json")) else { return [] }
                return (try? JSONDecoder().decode([CLISessionStore.Record].self, from: data)) ?? []
            }.value
            check("metadata", diskRecords.first(where: { $0.id == a }).map { $0.title == "renamed" && $0.pinned && $0.order == 1 } == true && diskRecords.first(where: { $0.id == b })?.order == 0, "JSON renamed/pinned/order=1,0")
            // Close only the App-side attachments/model. The command remains owned by tmux.
            model.shutdownForContainerClose()
            await store.flush()
            let reopened = ChatPageModel(environment: environment)
            let reopenedReady = await wait { reopened.cliRuntime != nil }
            check("reopen_runtime_ready", reopenedReady, "Space preferences loaded before restored-process verification")
            await reopened.refreshCLIWorkbenchSessions()
            await reopened.cliSessionStore?.flush()
            check("restart_same_pid", pid != nil && reopened.cliTabProcessID(for: a) == pid, "same OS process after model shutdown/recreate")
            check("editing_persisted", reopened.cliWorkbenchDocument.editingOptions == options, "settings survive reopen")
            if let restored = await reopened.restoreCLITab(a) {
                check("restore_same_session", restored == a && reopened.cliTabProcessID(for: a) == pid, "same UUID and PID; no command replay")
                try? await reopened.cliTabPTYSession(for: restored)?.sendLineAwaited("printf 'AFTER_REOPEN\\n'")
                try? await Task.sleep(for: .milliseconds(250))
                let tail = await reopened.cliWorkbenchTail(restored)
                check("restore_continuity", tail.contains("BACKGROUND_OK") && tail.contains("AFTER_REOPEN"), "output continues through detach/reopen")
            } else { check("restore", false, "restoreCLITab returned nil") }
            for id in [a, b] { try? await reopened.cliTabPTYSession(for: id)?.sendLineAwaited("exit") }
            check("exited", await wait { reopened.cliSessionStore?.sessions.allSatisfy { $0.status == .exited && $0.exitCode == 0 } == true },
                  "natural shell exits reconciled from tmux dead status")
            let deadRestored = await reopened.restoreCLITab(a)
            check("dead_no_replay", deadRestored == a && reopened.cliTabPTYSession(for: a)?.isRunning == false &&
                  reopened.cliTabProcessID(for: a) == nil, "dead record opens history, never relaunches")
            for id in [a, b] { try? await reopened.terminateCLIWorkbenchPane(id) }
            check("terminate", (try? await reopened.cliRuntime?.list().isEmpty) == true, "owned tmux sessions removed by cli_close semantics")
            reopened.shutdownForContainerClose()
            await reopened.cliSessionStore?.flush()
            // Bound test uses a separate UUID, without altering session metadata.
            let probe = UUID()
            store.append(Data(repeating: 120, count: CLISessionStore.limit + 4096), to: probe)
            await store.flush()
            let size = await Task.detached { (try? Data(contentsOf: store.logURL(probe)).count) ?? -1 }.value
            check("scrollback_bound", size == CLISessionStore.limit, "bytes=\(size), cap=\(CLISessionStore.limit)")
            let corruptPreserved = await Task.detached { () -> Bool in
                let directory = root.appendingPathComponent("corrupt-probe")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("cli-sessions.json")
                    let original = Data("not-json".utf8)
                    try original.write(to: url)
                    let broken = CLISessionStore(root: directory)
                    await broken.flush()
                    let retained = try Data(contentsOf: url)
                    return broken.lastError != nil && retained == original
                } catch { return false }
            }.value
            check("corrupt_preserved", corruptPreserved, "invalid JSON is not overwritten")
            check("persistence_errors", store.lastError == nil, store.lastError ?? "none")
            print("CLITEST RESULT failures=\(failures) root=\(root.path)")
            exit(failures == 0 ? 0 : 1)
        }
        NSApplication.shared.run()
    }
}

extension SelfTest {
    @MainActor static func runBotCoreTest() {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task.detached {
            do {
                guard let path = ProcessInfo.processInfo.environment["TATWO2_BOTCORE_ROOT"] else {
                    throw BotLibraryError.invalid("TATWO2_BOTCORE_ROOT must name a new isolated fixture directory")
                }
                let root = URL(fileURLWithPath: path)
                let fm = FileManager.default
                guard !fm.fileExists(atPath: root.path) else { throw BotLibraryError.invalid("fixture_root_already_exists") }
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                func check(_ name: String, _ condition: Bool) throws {
                    print("BOTCORETEST \(condition ? "PASS" : "FAIL") \(name)")
                    if !condition { throw BotLibraryError.invalid("test_failed:\(name)") }
                }
                let legacyBots = ["legacy-one", "legacy-two"].map {
                    BotRecord(id: $0, name: $0, emoji: "🤖", role: "general", systemPrompt: "instructions-" + $0,
                        defaultEngine: "claude", defaultModel: nil, workdir: root.path, parentBotID: nil, spaceIDs: [], isTemporary: false)
                }
                let legacy = BotStoreDocument(spaces: [], bots: legacyBots, threadIDsByBotID: [:])
                try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent("bots.json"))
                let skills = URL(fileURLWithPath: "/tmp/tatwo2-fixture/skills")
                let skill = try fm.contentsOfDirectory(at: skills, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .first { url in
                        url.lastPathComponent.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
                            && fm.fileExists(atPath: url.appendingPathComponent("SKILL.md").path)
                    }
                guard let skill else { throw BotLibraryError.invalid("no_real_skill_fixture") }
                let library = BotLibrary(root: root); await library.ready()
                try check("migration_two_bots", library.list().count == 2)
                let names = try fm.contentsOfDirectory(atPath: root.path)
                try check("legacy_renamed_preserved", !names.contains("bots.json") && names.contains(where: { $0.hasPrefix("bots.json.migrated-") }))
                let record = BotLibraryRecord(id: "general-bot", name: "General", emoji: "🤖", role: "general", engine: "claude", workdir: root.path,
                    permissions: .init(approval: "ask", mcp: ["registered", "missing"], folders: [], network: false), skills: [skill.lastPathComponent])
                let bot = try await library.create(record, instructions: "instruction-fixture")
                try check("workdir_auto_added", bot.permissions.folders == [root.path])
                let memory = BotMemory(library: library)
                let profileURL = root.appendingPathComponent("bots/general-bot/memory/profile.md")
                let original = try Data(contentsOf: profileURL)
                let pending = try await memory.remember(botID: bot.id, text: "confirmed-fact-fixture", threadID: "fixture-thread")
                try check("remember_pending_profile_unchanged", library.snapshot.pending[bot.id]?.count == 1 && (try Data(contentsOf: profileURL)) == original)
                do {
                    _ = try await memory.remember(botID: bot.id, text: "-----BEGIN PRIVATE KEY-----", threadID: "fixture-thread")
                    try check("secret_material_rejected", false)
                } catch { try check("secret_material_rejected", library.lastError == "secret_material_rejected") }
                let beforeEvents = memory.events(botID: bot.id, last: 100).count
                try await memory.confirm(botID: bot.id, pendingID: pending)
                try check("confirm_profile_and_event", memory.profile(botID: bot.id).count == 1 && memory.events(botID: bot.id, last: 100).count == beforeEvents + 1)
                try await memory.updateState(botID: bot.id, patch: .init(currentTask: "task-fixture", nextSteps: ["step-fixture"], openQuestions: ["question-fixture"]))
                let state = try JSONDecoder().decode(BotMemoryState.self, from: Data(contentsOf: root.appendingPathComponent("bots/general-bot/memory/state.json")))
                try check("state_json", state.currentTask == "task-fixture" && state.nextSteps == ["step-fixture"] && state.openQuestions == ["question-fixture"])
                let prompt = memory.systemPrompt(botID: bot.id)
                setenv("TATWO2_OS_UPSTREAM_PATH", URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("docs/os-upstream.md").path, 1)
                let composed = OSUpstream.compose(threadSystemPrompt: prompt) ?? ""
                try check("prompt_instructions_profile_state_upstream", composed.contains("instruction-fixture") && composed.contains("confirmed-fact-fixture") && composed.contains("上次做到：task-fixture") && composed.contains("bot_remember"))
                let liveStore = ChatLiveStore(root: root.appendingPathComponent("chat-fixture"))
                let threadID = try await MainActor.run { () throws -> UUID in
                    let engine = ChatLiveEngine(store: liveStore)
                    let threadID = try engine.prepareBotThread(existing: nil, bot: bot, registeredMCP: ["registered"])
                    let thread = engine.threadRecord(threadID)
                    try check("prepare_thread_mcp_approval_cwd", thread?.enabledMCP == ["registered"] && thread?.botPermissionPreset == .askFirst && thread?.cwdOverride == bot.workdir)
                    try check("bot_thread_visible_in_document", engine.document.projects.contains { $0.threads.contains { $0.id == threadID } })
                    var none = bot; none.permissions.mcp = []
                    let emptyID = try engine.prepareBotThread(existing: nil, bot: none, registeredMCP: ["registered"])
                    try check("empty_mcp_deny_all", engine.threadRecord(emptyID)?.enabledMCP == ["__tatwo_none__"])
                    return threadID
                }
                try await library.recordSession(botID: bot.id, threadID: threadID.uuidString, engine: bot.engine)
                try await memory.forget(botID: bot.id, memoryID: pending)
                try check("forget_before_image", memory.profile(botID: bot.id).isEmpty && memory.events(botID: bot.id, last: 1).first?.before?.contains("confirmed-fact-fixture") == true)
                let rejectID = try await memory.remember(botID: bot.id, text: "reject-fixture", threadID: "fixture-thread")
                try await memory.reject(botID: bot.id, pendingID: rejectID)
                try check("reject_pending", library.snapshot.pending[bot.id]?.isEmpty == true)
                let link = root.appendingPathComponent("bots/general-bot/skills/" + skill.lastPathComponent)
                try check("real_skill_symlink", try fm.destinationOfSymbolicLink(atPath: link.path) == skill.path)
                var invalid = bot; invalid.skills = ["nonexistent-bot-core-skill-" + UUID().uuidString]
                do { try await library.update(invalid); try check("missing_skill_rejected", false) }
                catch { try check("missing_skill_rejected", library.lastError?.contains("missing_skill") == true) }
                try check("folder_prefix_escape_rejected", !bot.permissions.allows(path: root.path + "-escape/file"))
                do { _ = try library.directory("../escape"); try check("path_traversal_rejected", false) }
                catch { print("BOTCORETEST PASS path_traversal_rejected") }
                try await library.archive(id: "legacy-one")
                try check("archive_moved_not_deleted", !fm.fileExists(atPath: root.appendingPathComponent("bots/legacy-one").path) && (try fm.contentsOfDirectory(atPath: root.appendingPathComponent("bots-archive").path)).contains(where: { $0.hasPrefix("legacy-one-") }))
                let broken = root.appendingPathComponent("bots/broken")
                try fm.createDirectory(at: broken, withIntermediateDirectories: true)
                let corrupt = Data("{broken".utf8); try corrupt.write(to: broken.appendingPathComponent("bot.json"))
                let reopened = BotLibrary(root: root); await reopened.ready()
                try check("corrupt_preserved_and_error", reopened.lastError != nil && (try Data(contentsOf: broken.appendingPathComponent("bot.json"))) == corrupt)
                try check("reopen_persistence", reopened.list().count == 2 && reopened.snapshot.states[bot.id] == state && reopened.snapshot.sessions[bot.id]?.count == 1)
                let permissions = try fm.attributesOfItem(atPath: profileURL.path)[.posixPermissions] as? NSNumber
                try check("file_mode_0600", permissions?.intValue == 0o600)
                // Actual stdio MCP -> actual OSAgentBridge -> actual BotLibrary, not a mocked socket.
                let socket = root.appendingPathComponent("os.sock").path
                setenv("TATWO2_OS_SOCKET", socket, 1)
                OSAgentBridge.shared.startBotCoreTest(library: reopened)
                for _ in 0..<100 {
                    if fm.fileExists(atPath: socket) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["node", "Engines/os-mcp/server.mjs"]
                var environment = ProcessInfo.processInfo.environment
                environment["TATWO2_OS_SOCKET"] = socket; environment["TATWO2_BOT_THREAD_ID"] = threadID.uuidString
                environment.removeValue(forKey: "TATWO2_BOT_THREAD_ID") // legacy line retained: this file is add-only
                environment["TATWO2_THREAD_ID"] = threadID.uuidString
                process.environment = environment
                let input = Pipe(); let output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = output
                try process.run()
                let requests: [[String: Any]] = [
                    ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "bot_list", "arguments": [:]]],
                    ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "bot_state_update", "arguments": ["currentTask": "stdio-task"]]],
                    ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "bot_remember", "arguments": ["text": "stdio-pending"]]],
                    ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "bot_confirm", "arguments": [:]]],
                ]
                for request in requests { try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10])) }
                try input.fileHandleForWriting.close()
                let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                let response = String(decoding: bytes, as: UTF8.self); print(response, terminator: "")
                let replies = try response.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
                try check("stdio_three_tools", process.terminationStatus == 0 && replies.count == 4 && replies.prefix(3).allSatisfy { ($0["result"] as? [String: Any])?["isError"] as? Bool != true })
                try check("stdio_pending_not_confirmed", response.contains("pendingID") && reopened.snapshot.pending[bot.id]?.count == 1 && reopened.snapshot.profiles[bot.id]?.isEmpty == true)
                try check("stdio_confirm_tool_absent", response.contains("unknown_tool:bot_confirm"))
                let finalReopen = BotLibrary(root: root); await finalReopen.ready()
                try check("stdio_changes_survive_reopen", finalReopen.snapshot.pending[bot.id]?.count == 1 && finalReopen.snapshot.states[bot.id]?.currentTask == "stdio-task")
                try await BotCore2Acceptance.run(root: root, threadID: threadID, socket: socket)
                print("BOTCORETEST NOTE following legacy note is superseded by send_as_bot_end_to_end above (add-only file)")
                print("BOTCORETEST NOTE sendAsBot hook end-to-end: 未跑; prepareBotThread tested directly")
                print("BOTCORETEST PASS core fixture suite (not full application acceptance)")
                exit(0)
            } catch { print("BOTCORETEST FAIL \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }
}
