import Foundation
import Darwin

/// 一個常駐的 Claude Agent SDK sidecar 行程（一條討論串一個）。
/// 只做三件事：啟動、送 JSON 行、收 JSON 行。不看門、不重試、不重造 SDK。
final class ClaudeSidecar {
    enum Event {
        case sdk([String: Any])
        case permission(id: String, tool: String, input: [String: Any], title: String?, description: String?)
        case stderr(String)
        case error(String)
        case closed
    }

    enum Kind: String, CaseIterable, Hashable { case claude, codex, grok }

    static var scriptPath: String { scriptPath(for: .claude) }

    /// 三家引擎各自的 sidecar 腳本：優先 UserDefaults 覆寫，再 App bundle，最後 repo 路徑。
    static func scriptPath(for kind: Kind, allowsOverride: Bool = true) -> String {
        let dir = "\(kind.rawValue)-sidecar/sidecar.mjs"
        if allowsOverride, let p = UserDefaults.standard.string(forKey: "tatwo2.sidecarPath.\(kind.rawValue)") { return p }
        if let r = Bundle.main.resourcePath {
            let bundled = r + "/" + dir
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        return "\(NSHomeDirectory())/Library/Application Support/tatwo2/Engines/" + dir
    }

    let kind: Kind
    init(kind: Kind = .claude) { self.kind = kind }

    private var child: SidecarGroupedProcess?
    private var buffer = Data()
    private(set) var isRunning = false
    var onEvent: ((Event) -> Void)?

    var processIdentifier: Int32? { isRunning ? child?.pid : nil }

    static func engineHomeRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        // 與 EnginePaths 同一優先序：明給 TATWO2_ENGINES_ROOT 就用它（真引擎家測試），否則從 LIVE_ROOT 推，最後才是正式 App Support。
        if let explicit = environment["TATWO2_ENGINES_ROOT"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        if let liveRoot = environment["TATWO2_LIVE_ROOT"], !liveRoot.isEmpty {
            return URL(fileURLWithPath: liveRoot, isDirectory: true)
                .deletingLastPathComponent()
                .appendingPathComponent("engines", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tatwo2/engines", isDirectory: true)
    }

    private static func prepareEngineHomes(environment: inout [String: String], runtimeBin: URL) throws {
        if let error = NativeStagingIsolation.validationError(environment) {
            throw NSError(domain: "TatwoStagingIsolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
        let root = engineHomeRoot(environment: environment)
        let homes = Kind.allCases.reduce(into: [Kind: URL]()) { result, kind in
            result[kind] = root.appendingPathComponent(kind.rawValue, isDirectory: true)
        }
        for home in homes.values {
            try FileManager.default.createDirectory(
                at: home,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        }
        // 先記下使用者原本的 Codex 家（環境變數或 ~/.codex），獨立資料夾第一次用要從那裡搬 auth 與 MCP 定義
        environment["TATWO2_CODEX_SOURCE_HOME"] = NativeStagingIsolation.isEnabled(environment)
            ? homes[.codex]?.path
            : environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.codex")
        environment["CODEX_HOME"] = homes[.codex]?.path
        environment["CLAUDE_CONFIG_DIR"] = homes[.claude]?.path
        // 正式 App 維持原 namespace；staging 不得借用正式 Claude 登入。
        environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = NativeStagingIsolation.sidecarClaudeNamespace(
            environment: environment, configDirectory: homes[.claude]!.path)
        environment["TATWO2_GROK_HOME"] = homes[.grok]?.path
        // MCP endpoint 隔離（2026-09-06）：built-in MCP 一定要連「這個 App」的橋，不能退回正式預設路徑
        environment["TATWO2_OS_SOCKET"] = OSAgentBridge.resolveSocketPath(environment: environment)
        environment["TATWO2_BROWSER_SOCKET"] = BrowserAgentBridge.resolveSocketPath(environment: environment)
        let bundledGrok = runtimeBin.appendingPathComponent("grok").path
        if FileManager.default.isExecutableFile(atPath: bundledGrok) {   // 沒打包（debug）就讓 sidecar 退回舊路徑
            environment["TATWO2_GROK_BIN"] = bundledGrok
        }
    }

    /// 遠端 ssh 啟動 argv（純函式，與原本 inline 版逐字相同；第 4 個元素＝script 路徑允許 ~ 展開）。
    static func remoteLaunch(remote: RemoteDeviceRef, sidecarArgs args: [String], remoteEnvironment: [String: String] = [:]) -> (executable: String, arguments: [String]) {
        let envPairs = remoteEnvironment.keys.sorted().map { "\($0)=\(remoteEnvironment[$0]!)" }   // production 空＝與原 inline 逐字相同
        let remoteCommand = ["env"] + envPairs + ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "node"] + args
        let scriptIndex = 1 + envPairs.count + 2
        let arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-p", String(remote.sshPort), remote.sshTarget]
            + remoteCommand.enumerated().map { index, value in remoteShellQuote(value, expandHome: index == scriptIndex) }
        return ("/usr/bin/ssh", arguments)
    }

    /// remote 非 nil 時，同一套 stdin/stdout 協議改經 ssh 在另一台跑（R3）；MCP 這輪遠端不帶。
    func start(cwd: String, resume: String?, model: String?, systemPrompt: String? = nil, mcpConfig: String? = nil, permissionMode: String? = nil, remote: RemoteEngineHandle? = nil) throws {
        if permissionMode == "readOnly", kind != .claude || remote != nil {
            throw NSError(domain: "TatwoReadOnlyReviewer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "此引擎／設備不支援唯讀副審"])
        }
        let script = remote?.sidecarScript ?? Self.scriptPath(for: kind, allowsOverride: permissionMode != "readOnly")
        var args = [script, "--cwd", cwd]
        if let resume { args += ["--resume", resume] }
        if let model { args += ["--model", model] }
        if let systemPrompt, !systemPrompt.isEmpty { args += ["--system-prompt", systemPrompt] }
        let effectiveMCPConfig: String?
        if remote != nil {
            let object: [String: Any] = ["engine": kind.rawValue, "servers": [String: Any]()]
            effectiveMCPConfig = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
        } else {
            effectiveMCPConfig = mcpConfig
        }
        if let effectiveMCPConfig, !effectiveMCPConfig.isEmpty { args += ["--mcp-config", effectiveMCPConfig] }
        if let permissionMode { args += ["--permission-mode", permissionMode] }
        // 入口驗證（在 prepareEngineHomes／任何 Process 之前）：只要 remote-test／fixture 訊號存在，remote handle 必須存在、capture-only、kind 一致、
        // fixture 與所有 component 現在重新驗證仍與 handle 一致；缺 handle 一律 throw（所有 kind、包含本機），否則 fail-closed。完全沒有訊號才是原 local／production 行為。
        let startEnvironment = ProcessInfo.processInfo.environment
        #if DEBUG
        if RemoteSyncFixture.isRequested(environment: startEnvironment) {
            guard let remote else { throw RemoteEngineSyncError.fixtureBlocked("remote-test／fixture 訊號存在但沒有 session handle：不起任何 sidecar（\(kind.rawValue)）") }
            try remote.validateForStart(kind: kind, environment: startEnvironment)
            let launch = Self.remoteLaunch(remote: remote.device, sidecarArgs: args, remoteEnvironment: remote.remoteEnvironment)
            try remote.capture(stage: "sidecar", commands: [[launch.executable] + launch.arguments])
            throw RemoteCaptureOnlyError.sidecarNotStarted((remote.captureRoot ?? "") + "/capture-chain.jsonl")
        }
        if let remote, remote.isCaptureOnly { throw RemoteEngineSyncError.fixtureBlocked("沒有測試訊號卻拿到 capture-only handle") }
        #else
        if startEnvironment["TATWO2_REMOTETEST"] == "1" || startEnvironment["TATWO2_REMOTE_SYNC_FIXTURE"] != nil || startEnvironment["TATWO2_REMOTE_SYNC_TOKEN"] != nil {
            throw RemoteEngineSyncError.fixtureBlocked("release 編譯沒有測試 fixture；remote-test 訊號存在即 BLOCKED，不起 sidecar")
        }
        #endif
        var env = ProcessInfo.processInfo.environment
        // 無頭測試／debug 執行檔沒有打包的 runtime：可用 TATWO2_RUNTIME_BIN 指到正式 App 的 runtime/bin（bundled codex 0.153 才吃得下獨立 config 的 enabled=false）
        let runtimeBin = env["TATWO2_RUNTIME_BIN"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("runtime/bin", isDirectory: true)
        try Self.prepareEngineHomes(environment: &env, runtimeBin: runtimeBin)
        env["PATH"] = runtimeBin.path + ":/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        let executable: String
        let arguments: [String]
        if let remote {
            // 純函式抽出（2026-09-06，行為不變）：讓 REMOTETEST 能 0 I/O 擷取 production 遠端 argv 基線
            (executable, arguments) = Self.remoteLaunch(remote: remote.device, sidecarArgs: args, remoteEnvironment: remote.remoteEnvironment)   // production：remoteEnvironment 空＝argv 不變
        } else {
            let bundledNode = runtimeBin.appendingPathComponent("node").path
            if FileManager.default.isExecutableFile(atPath: bundledNode) {
                executable = bundledNode
                arguments = args
            } else {
                executable = "/usr/bin/env"
                arguments = ["node"] + args
            }
        }
        let grouped = try SidecarGroupedProcess.spawn(
            executable: executable,
            arguments: arguments,
            environment: env,
            currentDirectory: remote == nil ? cwd : NSHomeDirectory())
        child = grouped
        grouped.onStdout = { [weak self] data in
            DispatchQueue.main.async { self?.consume(data) }
        }
        grouped.onStderr = { [weak self] data in
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.onEvent?(.stderr(text)) }
        }
        grouped.onExit = { [weak self, weak grouped] in
            DispatchQueue.main.async {
                guard let self, self.child === grouped else { return }
                self.isRunning = false
                self.child = nil
                self.onEvent?(.closed)
            }
        }
        isRunning = true
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let ev = obj["ev"] as? String else { continue }
            switch ev {
            case "sdk":
                if let m = obj["msg"] as? [String: Any] { onEvent?(.sdk(m)) }
            case "permission_request":
                onEvent?(.permission(id: obj["id"] as? String ?? "",
                                     tool: obj["tool"] as? String ?? "?",
                                     input: obj["input"] as? [String: Any] ?? [:],
                                     title: obj["title"] as? String,
                                     description: obj["description"] as? String))
            case "stderr": onEvent?(.stderr(obj["line"] as? String ?? ""))
            case "error":
                if obj["terminal"] as? Bool == false {
                    var message: [String: Any] = ["type": "system", "subtype": "turn_error",
                        "message": obj["message"] as? String ?? "?"]
                    if let turn = obj["client_turn_id"] as? String { message["client_turn_id"] = turn }
                    onEvent?(.sdk(message))
                } else {
                    onEvent?(.error(obj["message"] as? String ?? "?"))
                }
            case "closed": onEvent?(.closed)
            default: break
            }
        }
    }

    private func write(_ obj: [String: Any]) {
        guard isRunning, let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        child?.write(d + Data([0x0A]))
    }

    func send(text: String, uuid: String, attachments: [String] = [], model: String? = nil,
              reasoningEffort: String? = nil, serviceTier: String? = nil) {
        write(Self.sendCommand(kind: kind, text: text, uuid: uuid, attachments: attachments,
                               model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier))
    }

    static func sendCommand(kind: Kind, text: String, uuid: String, attachments: [String],
                            model: String?, reasoningEffort: String?, serviceTier: String?) -> [String: Any] {
        var o: [String: Any] = ["op": "send", "text": text, "uuid": uuid]
        if !attachments.isEmpty { o["attachments"] = attachments }
        if kind == .codex {
            // Bind model/options to this queued turn, not mutable sidecar state.
            if let model { o["model"] = model }
            if let reasoningEffort { o["effort"] = reasoningEffort }
            if let serviceTier { o["serviceTier"] = serviceTier }
        }
        return o
    }
    func respondPermission(id: String, allow: Bool, message: String? = nil) {
        write(["op": "permission", "id": id, "allow": allow, "message": message ?? "使用者拒絕"])
    }
    func steer(text: String, attachments: [String], requestID: String, targetTurnUUID: String) {
        guard kind == .codex else { return }
        write(["op": "steer", "text": text, "attachments": attachments,
               "uuid": requestID, "targetTurnUUID": targetTurnUUID])
    }
    func goal(status: String?, objective: String?, requestID: String,
              model: String? = nil, effort: String? = nil, serviceTier: String? = nil) {
        guard kind == .codex else { return }
        var command: [String: Any] = ["op": status == nil ? "goal_clear" : "goal_set", "uuid": requestID]
        if let status { command["status"] = status }
        if let objective { command["objective"] = objective }
        if let model { command["model"] = model }
        if let effort { command["effort"] = effort }
        if let serviceTier { command["serviceTier"] = serviceTier }
        write(command)
    }
    func refreshGoal() {
        guard kind == .codex else { return }
        write(["op": "goal_get"])
    }
    func interrupt(pauseGoal: Bool? = nil) {
        var command: [String: Any] = ["op": "interrupt"]
        if let pauseGoal { command["pauseGoal"] = pauseGoal }
        write(command)
    }
    func setModel(_ m: String) { write(["op": "model", "model": m]) }
    func close() {
        write(["op": "close"])
        terminate()
    }
    func terminate() {
        child?.terminateGroup()
        child = nil
        isRunning = false
    }
}

/// 只管理由 Tatwo2 親自記錄的 process group。pid 與 pgid 相同，來源由 POSIX_SPAWN_SETPGROUP 保證。
final class SidecarGroupedProcess {
    struct Record: Codable, Equatable {
        let pgid: Int32
        let command: String
    }

    private static let lock = NSLock()
    private static var live: [Int32: SidecarGroupedProcess] = [:]
    private static var overrideRoot: URL?

    let pid: pid_t
    let pgid: pid_t
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var didTerminate = false
    var onStdout: ((Data) -> Void)?
    var onStderr: ((Data) -> Void)?
    var onExit: (() -> Void)?

    private init(pid: pid_t, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) {
        self.pid = pid
        self.pgid = pid
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    static func configureLiveRoot(_ root: URL? = nil) {
        overrideRoot = root
    }

    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String
    ) throws -> SidecarGroupedProcess {
        let input = Pipe(), output = Pipe(), errors = Pipe()
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0
        else { throw POSIXError(.EIO) }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, input.fileHandleForWriting.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, output.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, errors.fileHandleForReading.fileDescriptor)
        let chdirResult = currentDirectory.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        guard chdirResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: chdirResult) ?? .EIO) }

        var flags: Int16 = 0
        posix_spawnattr_getflags(&attributes, &flags)
        flags |= Int16(POSIX_SPAWN_SETPGROUP)
        posix_spawnattr_setflags(&attributes, flags)
        posix_spawnattr_setpgroup(&attributes, 0)

        let argumentStrings: [String] = [executable] + arguments
        let argv: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
        let envp: [UnsafeMutablePointer<CChar>?] = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { if let pointer = $0 { free(UnsafeMutableRawPointer(pointer)) } }
            envp.forEach { if let pointer = $0 { free(UnsafeMutableRawPointer(pointer)) } }
        }
        var argvPointers: [UnsafeMutablePointer<CChar>?] = argv + [nil]
        var envPointers: [UnsafeMutablePointer<CChar>?] = envp + [nil]
        var spawnedPID: pid_t = 0
        let result = executable.withCString { path in
            posix_spawn(&spawnedPID, path, &actions, &attributes, &argvPointers, &envPointers)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }

        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()
        let process = SidecarGroupedProcess(
            pid: spawnedPID,
            stdin: input.fileHandleForWriting,
            stdout: output.fileHandleForReading,
            stderr: errors.fileHandleForReading)
        process.installReaders()
        lock.lock(); live[spawnedPID] = process; lock.unlock()
        persistRecords()
        DispatchQueue.global(qos: .utility).async { process.waitForExit() }
        return process
    }

    func write(_ data: Data) {
        try? stdin.write(contentsOf: data)
    }

    func terminateGroup() {
        Self.lock.lock()
        if didTerminate { Self.lock.unlock(); return }
        didTerminate = true
        Self.lock.unlock()
        Self.signalGroup(pgid, signal: SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [pgid] in
            if Self.groupIsAlive(pgid) { Self.signalGroup(pgid, signal: SIGKILL) }
        }
    }

    static func reapRecordedGroups() {
        let records = readRecords()
        for record in records where groupIsAlive(record.pgid) && recordedCommandIsOurs(record) {
            signalGroup(record.pgid, signal: SIGTERM)
            let deadline = Date().addingTimeInterval(2)
            while groupIsAlive(record.pgid), Date() < deadline { usleep(50_000) }
            if groupIsAlive(record.pgid) { signalGroup(record.pgid, signal: SIGKILL) }
        }
        try? FileManager.default.removeItem(at: recordsURL)
    }

    static func terminateAll() {
        lock.lock(); let groups = Array(live.values); lock.unlock()
        groups.forEach { $0.terminateGroup() }
        let deadline = Date().addingTimeInterval(2)
        while groups.contains(where: { groupIsAlive($0.pgid) }), Date() < deadline { usleep(50_000) }
        for group in groups where groupIsAlive(group.pgid) { signalGroup(group.pgid, signal: SIGKILL) }
    }

    static func groupIsAlive(_ pgid: pid_t) -> Bool {
        if kill(-pgid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func signalGroup(_ pgid: pid_t, signal: Int32) {
        guard pgid > 1 else { return }
        _ = killpg(pgid, signal)
    }

    private func installReaders() {
        stdout.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.onStdout?(data) }
        }
        stderr.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.onStderr?(data) }
        }
    }

    private func waitForExit() {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
        try? stdin.close()
        try? stdout.close()
        try? stderr.close()
        Self.lock.lock(); Self.live[pid] = nil; Self.lock.unlock()
        Self.persistRecords()
        onExit?()
    }

    private static var recordsURL: URL {
        let root = overrideRoot
            ?? ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tatwo2", isDirectory: true)
        return root.appendingPathComponent("sidecar-pids.json")
    }

    private static func persistRecords() {
        lock.lock()
        let records = live.values.map { Record(pgid: $0.pgid, command: "Engines/sidecar pid=\($0.pid)") }
        lock.unlock()
        let url = recordsURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if records.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func readRecords() -> [Record] {
        guard let data = try? Data(contentsOf: recordsURL) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private static func recordedCommandIsOurs(_ record: Record) -> Bool {
        guard record.command.contains("Engines/") || record.command.contains("sidecar") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(record.pgid), "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run(); process.waitUntilExit()
            let command = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return command.contains("Engines/") || command.contains("sidecar") || command.contains("sleep 300")
        } catch { return false }
    }

    // REAPTEST 專用：走與正式 sidecar 完全相同的 posix_spawn process-group 路徑。
    static func spawnReapTest(root: URL, childPIDFile: URL) throws -> SidecarGroupedProcess {
        configureLiveRoot(root)
        return try spawn(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 300 & echo $! > '\(childPIDFile.path)'; wait"],
            environment: ProcessInfo.processInfo.environment,
            currentDirectory: NSTemporaryDirectory())
    }

    static func writeReapTestRecord(root: URL, pgid: pid_t) throws {
        configureLiveRoot(root)
        let data = try JSONEncoder().encode([Record(pgid: pgid, command: "sidecar reaptest sleep 300")])
        try FileManager.default.createDirectory(at: recordsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: recordsURL, options: .atomic)
    }
}
