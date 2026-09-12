// 來源：房間 skills-usage.md；只讀 skills 與 MCP 設定，匯出環境固定使用 PluginsFixture
import Foundation

enum PluginsSource {
    enum MCPEngine: String { case codex, claude, grok }
    /// 使用者 2026-09-05：blender／gbrain 需要才開；預設只開 OS 自己的工具與瀏覽器橋
    static let defaultOnPatterns = ["tatwo_ultrawork", "tatwo2_os", "browser"]
    private static let githubMCPPrefix = "github-"
    private static let noneSentinel = "__tatwo_none__"
    private static let statusLock = NSLock()
    private static var liveStatuses: [String: String] = [:]

    /// 啟動時不碰外接卷（會被 macOS 權限詢問卡住主執行緒）：先回快取（沒有就先回假資料），真正的掃描丟到背景，掃完寫快取，下次啟動生效。
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> [PluginRegistryEntry] {
        guard NativeStagingIsolation.validationError(environment) == nil else { return [] }
        guard !isExport(environment) else { return PluginsFixture.entries }
        if environment["TATWO2_SOURCETEST"] == "1" { return scanNow(environment: environment) }   // 無頭測試要同步看到真結果
        // Staging starts from real selected roots, never a previous host cache.
        let cached = NativeStagingIsolation.isEnabled(environment) ? nil : readCache(environment: environment)
        DispatchQueue.global(qos: .utility).async {
            let fresh = refreshNow(environment: environment)
            if !fresh.isEmpty || NativeStagingIsolation.isEnabled(environment) {
                writeCache(fresh, environment: environment)
            }
        }
        return cached ?? (NativeStagingIsolation.isEnabled(environment) ? [] : PluginsFixture.entries)
    }

    static func scanNow(environment: [String: String] = ProcessInfo.processInfo.environment) -> [PluginRegistryEntry] {
        guard NativeStagingIsolation.validationError(environment) == nil else { return [] }
        let entries = skillEntries(environment: environment) + mcpEntries(environment: environment)
        return entries.isEmpty && !NativeStagingIsolation.isEnabled(environment) ? PluginsFixture.entries : entries.sorted {
            if $0.kind == $1.kind { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.kind == .skill
        }
    }

    /// 在背景向 Claude Agent SDK sidecar 詢問一次真實 MCP 連線狀態，再重建資訊卡資料。
    static func refreshNow(environment: [String: String] = ProcessInfo.processInfo.environment) -> [PluginRegistryEntry] {
        guard NativeStagingIsolation.validationError(environment) == nil else { return [] }
        let statuses = probeClaudeStatuses(environment: environment)
        if NativeStagingIsolation.isEnabled(environment) || !(statuses ?? [:]).isEmpty {
            statusLock.lock()
            liveStatuses = statuses ?? [:]
            statusLock.unlock()
        }
        return scanNow(environment: environment)
    }

    private struct CacheRow: Codable { var id, name, kind, purpose, path, trigger, safety, install, hint: String; var smoke: String? }
    private static func cacheURL(environment: [String: String]) -> URL {
        let base = environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tatwo2/live", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("plugins-cache.json")
    }
    private static func readCache(environment: [String: String]) -> [PluginRegistryEntry]? {
        guard let data = try? Data(contentsOf: cacheURL(environment: environment)), let rows = try? JSONDecoder().decode([CacheRow].self, from: data), !rows.isEmpty else { return nil }
        return rows.map { r in
            PluginRegistryEntry(id: r.id, name: r.name, kind: RegistryKind(rawValue: r.kind) ?? .skill, purpose: r.purpose, path: r.path, trigger: r.trigger,
                                safetyLevel: PluginSafetyLevel(rawValue: r.safety) ?? .medium, installState: InstallState(rawValue: r.install) ?? .installed,
                                smokeCommand: r.smoke, publicInstallHint: r.hint)
        }
    }
    private static func writeCache(_ entries: [PluginRegistryEntry], environment: [String: String]) {
        let rows = entries.map { e in CacheRow(id: e.id, name: e.name, kind: e.kind.rawValue, purpose: e.purpose, path: e.path ?? "", trigger: e.trigger,
                                               safety: e.safetyLevel.rawValue, install: e.installState.rawValue, hint: e.publicInstallHint, smoke: e.smokeCommand) }
        if let data = try? JSONEncoder().encode(rows) { try? data.write(to: cacheURL(environment: environment), options: .atomic) }
    }

    static func sourceTestLine(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let entries = load(environment: environment)
        return "SOURCETEST plugins skills=\(entries.filter { $0.kind == .skill }.count) mcp=\(entries.filter { $0.kind == .mcp }.count) fixture=\(isExport(environment))"
    }

    private static func skillEntries(environment: [String: String]) -> [PluginRegistryEntry] {
        let manager = FileManager.default
        let staging = NativeStagingIsolation.isEnabled(environment)
        let paths = EnginePaths(environment: environment)
        let roots = staging ? [
            paths.claudeConfigDirectory.appendingPathComponent("skills", isDirectory: true),
            paths.codexHome.appendingPathComponent("skills", isDirectory: true),
        ] : [
            URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/tatwo2/skills", isDirectory: true),
            manager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true),
            manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/skills", isDirectory: true),
        ]
        var seen = Set<String>()
        var seenNames = Set<String>()
        var result: [PluginRegistryEntry] = []
        for root in roots {
            if staging && !NativeStagingIsolation.allowsRead(root, within: paths.enginesRoot) { continue }
            guard let children = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                let manifest = child.appendingPathComponent("SKILL.md")
                if staging && !NativeStagingIsolation.allowsRead(manifest, within: root) { continue }
                guard manager.fileExists(atPath: manifest.path) else { continue }
                let canonical = manifest.resolvingSymlinksInPath().path
                guard seen.insert(canonical).inserted else { continue }
                let metadata = skillMetadata(at: manifest)
                let name = metadata.name.isEmpty ? child.lastPathComponent : metadata.name
                // 輸入框的技能膠囊顯示 $<id>：使用者要的是名稱（$ai-business），不是路徑；路徑留在 path
                let chipID = seenNames.insert(name).inserted ? name : "\(name)@\(child.deletingLastPathComponent().lastPathComponent)"
                result.append(.init(
                    id: chipID, name: name, kind: .skill,
                    purpose: metadata.description.isEmpty ? "本機 skill" : metadata.description,
                    path: manifest.path, trigger: "依 SKILL.md 的觸發條件使用。",
                    safetyLevel: .medium, installState: .installed, smokeCommand: nil,
                    publicInstallHint: "本機技能目錄"))
            }
        }
        return result
    }

    static func mcpNames(
        for engine: MCPEngine,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard NativeStagingIsolation.validationError(environment) == nil else { return [] }
        let githubNames = githubMCPAccounts(environment: environment).map {
            githubMCPName(username: $0.username)
        }
        switch engine {
        case .codex: return Array(Set(codexServerNames(environment: environment) + githubNames)).sorted()
        case .claude: return Array(Set(Array(claudeConfiguredServers(environment: environment).keys) + githubNames)).sorted()
        case .grok: return []
        }
    }

    static func pluginID(engine: MCPEngine, name: String) -> String {
        "mcp:\(engine.rawValue):\(name)"
    }

    static func mcpName(from pluginID: String) -> String? {
        let parts = pluginID.split(separator: ":", maxSplits: 2).map(String.init)
        return parts.count == 3 && parts[0] == "mcp" ? parts[2] : nil
    }

    static func mcpEngine(from pluginID: String) -> MCPEngine? {
        let parts = pluginID.split(separator: ":", maxSplits: 2).map(String.init)
        return parts.count == 3 && parts[0] == "mcp" ? MCPEngine(rawValue: parts[1]) : nil
    }

    static func effectiveEnabledNames(
        stored: [String],
        engine: MCPEngine,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        effectiveEnabledNames(
            stored: stored,
            configured: mcpNames(for: engine, environment: environment),
            alwaysOnNames: githubAlwaysOnNames(environment: environment))
    }

    static func effectiveEnabledNames(
        stored: [String],
        configured: [String],
        alwaysOnNames: Set<String> = []
    ) -> [String] {
        guard !stored.contains(noneSentinel) else { return [] }
        if stored.isEmpty {
            return configured.filter { name in
                if name.hasPrefix(githubMCPPrefix) {
                    return alwaysOnNames.contains(name)
                }
                return defaultOnPatterns.contains { name.localizedCaseInsensitiveContains($0) }
            }
        }
        let configuredSet = Set(configured)
        let requested = Set(stored.compactMap { mcpName(from: $0) ?? (configuredSet.contains($0) ? $0 : nil) })
        return configured.filter(requested.contains)
    }

    static func storedSelection(
        names: [String],
        engine: MCPEngine,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let configured = mcpNames(for: engine, environment: environment)
        let selected = configured.filter(Set(names).contains)
        if selected == effectiveEnabledNames(
            stored: [],
            configured: configured,
            alwaysOnNames: githubAlwaysOnNames(environment: environment))
        { return [] }
        if selected.isEmpty { return [noneSentinel] }
        return selected.map { pluginID(engine: engine, name: $0) }
    }

    static func sidecarMCPConfig(
        engine: MCPEngine,
        stored: [String],
        threadID: UUID? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard NativeStagingIsolation.validationError(environment) == nil else { return nil }
        let enabled = effectiveEnabledNames(stored: stored, engine: engine, environment: environment)
        var object: [String: Any]
        switch engine {
        case .claude:
            let enabledSet = Set(enabled)
            var servers = claudeConfiguredServers(environment: environment)
            for (name, definition) in githubMCPServers(
                environment: environment,
                includeTokensFor: enabledSet)
            {
                servers[name] = definition
            }
            servers = servers.filter { enabledSet.contains($0.key) }
            object = ["engine": engine.rawValue, "servers": servers]
        case .codex:
            object = [
                "engine": engine.rawValue,
                "configured": mcpNames(for: engine, environment: environment),
                "enabled": enabled,
                "servers": githubMCPServers(
                    environment: environment,
                    includeTokensFor: Set(enabled)),
            ]
        case .grok:
            object = ["engine": engine.rawValue, "configured": [], "enabled": []]
        }
        if let threadID { object["threadID"] = threadID.uuidString }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func mcpEntries(environment: [String: String]) -> [PluginRegistryEntry] {
        var result: [PluginRegistryEntry] = []
        for engine in [MCPEngine.codex, .claude] {
            for name in mcpNames(for: engine, environment: environment) {
                let status: String
                if engine == .claude {
                    statusLock.lock()
                    let raw = liveStatuses[name]
                    statusLock.unlock()
                    switch raw {
                    case "connected": status = "已連線・常駐"
                    case "pending": status = "連線中"
                    case "needs-auth": status = "未連線・需登入"
                    case "failed": status = "未連線"
                    default: status = "已設定・等待狀態"
                    }
                } else {
                    status = NativeStagingIsolation.isEnabled(environment)
                        ? "已設定・尚未驗證連線" : "已設定・常駐"
                }
                result.append(.init(
                    id: pluginID(engine: engine, name: name),
                    name: name,
                    kind: .mcp,
                    purpose: "\(engine == .codex ? "Codex" : "Claude")・\(status)",
                    path: "mcp:\(engine.rawValue):\(name)",
                    trigger: "由 \(engine.rawValue) sidecar 啟動時載入。",
                    safetyLevel: .medium,
                    installState: .installed,
                    smokeCommand: nil,
                    publicInstallHint: "從本機設定唯讀載入"))
            }
        }
        return result
    }

    private static func probeClaudeStatuses(environment: [String: String]) -> [String: String]? {
        guard let config = sidecarMCPConfig(engine: .claude, stored: [], environment: environment),
              !mcpNames(for: .claude, environment: environment).isEmpty
        else { return [:] }
        let process = Process()
        var processEnvironment = environment
        if NativeStagingIsolation.isEnabled(environment) {
            let paths = EnginePaths(environment: environment)
            let resources = paths.runtimeBinDirectory.deletingLastPathComponent().deletingLastPathComponent()
            let node = paths.runtimeBinDirectory.appendingPathComponent("node")
            let script = resources.appendingPathComponent("claude-sidecar/sidecar.mjs")
            // No repo, UserDefaults, or host PATH fallback in normal staging.
            guard NativeStagingIsolation.allowsRead(node, within: resources),
                  NativeStagingIsolation.allowsRead(script, within: resources),
                  FileManager.default.isExecutableFile(atPath: node.path),
                  FileManager.default.fileExists(atPath: script.path)
            else { return nil }
            process.executableURL = node
            process.arguments = [script.path, "--cwd", paths.userHome.path, "--mcp-config", config]
            process.currentDirectoryURL = paths.userHome
            processEnvironment = NativeStagingIsolation.isolateClaude(
                processEnvironment, configDirectory: paths.claudeConfigDirectory.path)
            processEnvironment["PATH"] = paths.runtimeBinDirectory.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", ClaudeSidecar.scriptPath(for: .claude), "--cwd", NSTemporaryDirectory(), "--mcp-config", config]
            processEnvironment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (processEnvironment["PATH"] ?? "/usr/bin:/bin")
        }
        process.environment = processEnvironment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffer = Data()
        var result: [String: String]?
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["ev"] as? String == "mcp_status",
                      let servers = object["servers"] as? [[String: Any]]
                else { continue }
                result = Dictionary(uniqueKeysWithValues: servers.compactMap {
                    guard let name = $0["name"] as? String, let status = $0["status"] as? String else { return nil }
                    return (name, status)
                })
                semaphore.signal()
            }
            lock.unlock()
        }
        do {
            try process.run()
            let request = try JSONSerialization.data(withJSONObject: ["op": "mcp_status"])
            input.fileHandleForWriting.write(request + Data([0x0A]))
            _ = semaphore.wait(timeout: .now() + 12)
            let close = try JSONSerialization.data(withJSONObject: ["op": "close"])
            input.fileHandleForWriting.write(close + Data([0x0A]))
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            return nil
        }
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        lock.lock()
        let final = result
        lock.unlock()
        return final
    }

    private static func claudeConfiguredServers(environment: [String: String]) -> [String: Any] {
        let manager = FileManager.default
        let staging = NativeStagingIsolation.isEnabled(environment)
        let paths = EnginePaths(environment: environment)
        let claude = staging ? paths.claudeAccountFile
            : manager.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        if staging && !NativeStagingIsolation.allowsRead(claude, within: paths.enginesRoot) { return [:] }
        if let data = try? Data(contentsOf: claude),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = object["mcpServers"] as? [String: Any]
        { return servers }
        return [:]
    }

    private static func githubMCPName(username: String) -> String {
        githubMCPPrefix + username
    }

    private static func githubMCPAccounts(environment: [String: String]) -> [GitHubAccountRecord] {
        (try? GitHubAccountsStore(environment: environment).loadAccounts()) ?? []
    }

    private static func githubAlwaysOnNames(environment: [String: String]) -> Set<String> {
        Set(githubMCPAccounts(environment: environment).compactMap {
            $0.mcpAlwaysOn ? githubMCPName(username: $0.username) : nil
        })
    }

    private static func githubMCPServers(
        environment: [String: String],
        includeTokensFor enabledNames: Set<String>
    ) -> [String: Any] {
        let store = GitHubAccountsStore(environment: environment)
        let executable = environment["TATWO2_GITHUB_MCP_SERVER_PATH"]
            ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
                .appendingPathComponent("runtime/bin/github-mcp-server").path
        var servers: [String: Any] = [:]
        for account in githubMCPAccounts(environment: environment) {
            let name = githubMCPName(username: account.username)
            var definition: [String: Any] = [
                "command": executable,
                "args": ["stdio"],
            ]
            if enabledNames.contains(name),
               let token = try? store.mcpToken(username: account.username),
               !token.isEmpty
            {
                definition["env"] = ["GITHUB_PERSONAL_ACCESS_TOKEN": token]
            }
            servers[name] = definition
        }
        return servers
    }

    private static func codexServerNames(environment: [String: String]) -> [String] {
        var names = Set<String>()
        let manager = FileManager.default
        let staging = NativeStagingIsolation.isEnabled(environment)
        let paths = EnginePaths(environment: environment)
        let codexPaths = staging ? [paths.codexHome.appendingPathComponent("config.toml")] : [
            manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/tatwo2/CliHome/config.toml"),
        ]
        for path in codexPaths where manager.fileExists(atPath: path.path) {
            if staging && !NativeStagingIsolation.allowsRead(path, within: paths.enginesRoot) { continue }
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
            for match in text.matches(of: #/^\s*\[mcp_servers\.([A-Za-z0-9_-]+)\]\s*$/#.anchorsMatchLineEndings()) {
                names.insert(String(match.1))
            }
        }
        return names.sorted()
    }

    private static func skillMetadata(at url: URL) -> (name: String, description: String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ("", "") }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return ("", "") }
        var name = ""; var description = ""
        for line in lines.dropFirst() {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "---" { break }
            if value.hasPrefix("name:") { name = String(value.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            if value.hasPrefix("description:") { description = String(value.dropFirst(12)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        return (name, description)
    }

    static func isExport(_ environment: [String: String]) -> Bool {
        environment.keys.contains { $0.hasPrefix("TATWO_ULTRAWORK_EXPORT_") }
    }
}
