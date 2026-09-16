// 來源：房間 skills-usage.md；只讀 skills 與 MCP 設定，匯出環境固定使用 PluginsFixture
import Foundation
import CryptoKit

enum PluginsSource {
    enum MCPEngine: String, CaseIterable, Sendable { case codex, claude, grok }
    /// 使用者 2026-09-05：blender／gbrain 需要才開；預設只開 OS 自己的工具與瀏覽器橋
    static let defaultOnPatterns = ["tatwo_ultrawork", "tatwo2_os", "browser"]
    private static let githubMCPPrefix = "github-"
    private static let noneSentinel = "__tatwo_none__"
    private static let probeLock = NSLock()
    private static let livenessCache = PluginLivenessCache()

    /// 技能沿用啟動快取；MCP 不從舊磁碟快取宣稱連線，背景探測後重建卡片。
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
        // Cache only the expensive skill scan. MCP definitions and their liveness must not
        // resurrect stale registration/status text from an older App process.
        return (cached?.filter { $0.kind == .skill }
                ?? (NativeStagingIsolation.isEnabled(environment) ? [] : PluginsFixture.entries.filter { $0.kind == .skill }))
            + builtinEntries(environment: environment) + mcpEntries(environment: environment)
    }

    static func scanNow(environment: [String: String] = ProcessInfo.processInfo.environment) -> [PluginRegistryEntry] {
        guard NativeStagingIsolation.validationError(environment) == nil else { return [] }
        let skills = skillEntries(environment: environment).sorted { $0.name < $1.name }
        return skills + builtinEntries(environment: environment) + mcpEntries(environment: environment)
    }

    /// Claude has a real SDK handshake. Codex only reports configured/disabled;
    /// Grok has no status operation. Neither of those is connection evidence.
    static func refreshNow(environment: [String: String] = ProcessInfo.processInfo.environment,
                           force: Bool = false) -> [PluginRegistryEntry] {
        guard NativeStagingIsolation.validationError(environment) == nil else { return [] }
        guard !isExport(environment) else { return PluginsFixture.entries }
        probeLock.lock(); defer { probeLock.unlock() }
        for engine in MCPEngine.allCases { _ = probeStatuses(engine: engine, environment: environment, force: force) }
        let entries = scanNow(environment: environment)
        writeCache(entries, environment: environment)
        return entries
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

    static func invalidateLivenessAfterRemoval(environment: [String: String]) {
        livenessCache.invalidate()
        writeCache(scanNow(environment: environment), environment: environment)
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
        case .grok: return Array(configuredServers(engine: .grok, environment: environment).keys).sorted()
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
        MCPEngine.allCases.flatMap { engine in
            let definitions = configuredServers(engine: engine, environment: environment)
            let statuses = livenessCache.value(for: probeKey(engine: engine, environment: environment)) ?? [:]
            return mcpNames(for: engine, environment: environment).map { name in
                let enabled = definitions[name]?.enabled ?? true
                return PluginRegistryEntry(
                    id: pluginID(engine: engine, name: name), name: name, kind: .mcp,
                    purpose: "\(engine.rawValue.capitalized)・外部 MCP",
                    path: "mcp:\(engine.rawValue):\(name)",
                    trigger: "由 \(engine.rawValue) sidecar 啟動時載入。",
                    safetyLevel: .medium, installState: .installed, smokeCommand: nil,
                    publicInstallHint: "從本機設定唯讀載入",
                    liveness: enabled ? (statuses[name] ?? .init(state: .unknown)) : .init(state: .disabled),
                    availableTo: [engine.rawValue.capitalized])
            }
        }
    }

    private static func probePath(environment: [String: String]) -> String {
        let paths = EnginePaths(environment: environment)
        let runtime = environment["TATWO2_RUNTIME_BIN"] ?? paths.runtimeBinDirectory.path
        if NativeStagingIsolation.isEnabled(environment) { return runtime + ":/usr/bin:/bin:/usr/sbin:/sbin" }
        return runtime + ":/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
    }

    private static func probeKey(engine: MCPEngine, environment: [String: String]) -> String {
        // Bind results to engine + source content + executable search scope; never cross isolated homes.
        let files = configurationURLs(engine: engine, environment: environment)
        var data = Data((engine.rawValue + probePath(environment: environment)).utf8)
        for file in files {
            data.append(Data(file.path.utf8))
            if let contents = try? Data(contentsOf: file) { data.append(contents) }
        }
        data.append(Data(mcpNames(for: engine, environment: environment).joined(separator: "\n").utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    static func probeStatuses(engine: MCPEngine, environment: [String: String], force: Bool = false) -> [String: PluginLivenessResult] {
        guard NativeStagingIsolation.validationError(environment) == nil, !isExport(environment) else { return [:] }
        let names = mcpNames(for: engine, environment: environment)
        guard !names.isEmpty else { return [:] }
        return livenessCache.resolve(key: probeKey(engine: engine, environment: environment), force: force) {
            var definitions = configuredServers(engine: engine, environment: environment)
            for (name, object) in githubMCPServers(environment: environment, includeTokensFor: []) {
                if engine != .grok, let object = object as? [String: Any] { definitions[name] = .init(object) }
            }
            var results = Dictionary(uniqueKeysWithValues: names.map { name in
                let definition = definitions[name] ?? .init([:])
                return (name, PluginProbe.executableCheck(command: definition.command, args: definition.args,
                    path: definition.path ?? probePath(environment: environment),
                    cwd: EnginePaths(environment: environment).userHome, enabled: definition.enabled))
            })
            guard engine == .claude else { return results }
            let candidates = names.filter { results[$0]?.state == .unknown }
            guard !candidates.isEmpty else { return results }
            // Explicitly request every configured, enabled candidate, not the default-on subset.
            guard let config = sidecarMCPConfig(engine: engine, stored: candidates, environment: environment) else { return results }
            let process = Process()
            let paths = EnginePaths(environment: environment)
            var env = environment
            env["PATH"] = probePath(environment: environment)
            if NativeStagingIsolation.isEnabled(environment) {
                let resources = paths.runtimeBinDirectory.deletingLastPathComponent().deletingLastPathComponent()
                let node = paths.runtimeBinDirectory.appendingPathComponent("node")
                let script = resources.appendingPathComponent("claude-sidecar/sidecar.mjs")
                guard NativeStagingIsolation.allowsRead(node, within: resources),
                      NativeStagingIsolation.allowsRead(script, within: resources),
                      FileManager.default.isExecutableFile(atPath: node.path),
                      FileManager.default.fileExists(atPath: script.path) else {
                    for name in candidates { results[name] = .init(state: .unreachable, detail: "探測程序不可用", probedAt: Date()) }
                    return results
                }
                process.executableURL = node
                process.arguments = [script.path, "--cwd", paths.userHome.path, "--mcp-config", config]
                env = NativeStagingIsolation.isolateClaude(env, configDirectory: paths.claudeConfigDirectory.path)
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["node", ClaudeSidecar.scriptPath(for: .claude), "--cwd", paths.userHome.path, "--mcp-config", config]
                env["CLAUDE_CONFIG_DIR"] = paths.claudeConfigDirectory.path
                env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = NativeStagingIsolation.sidecarClaudeNamespace(
                    environment: env, configDirectory: paths.claudeConfigDirectory.path)
            }
            process.currentDirectoryURL = paths.userHome
            process.environment = env
            let reply = PluginProbe.sidecar(process)
            // Replacement, not merge: an omitted/failed reply must never retain an old green light.
            for name in candidates {
                results[name] = PluginProbe.result(named: name, in: reply)
            }
            return results
        }
    }

    static func configurationURLs(engine: MCPEngine, environment: [String: String]) -> [URL] {
        let paths = EnginePaths(environment: environment)
        let staging = NativeStagingIsolation.isEnabled(environment)
        let urls: [URL]
        switch engine {
        case .claude:
            urls = [staging ? paths.claudeAccountFile : paths.userHome.appendingPathComponent(".claude.json")]
        case .codex:
            let isolated = paths.codexHome.appendingPathComponent("config.toml")
            // Same precedence as codex-sidecar: once seeded, the isolated config is authoritative.
            if staging || (try? String(contentsOf: isolated, encoding: .utf8)).map({
                $0.contains(PluginServerConfiguration.managedMarker) || !PluginServerConfiguration.parseTOML($0).isEmpty
            }) == true {
                urls = [isolated]
            } else {
                // ClaudeSidecar.prepareEngineHomes pins the source to the original CODEX_HOME.
                let source = environment["TATWO2_CODEX_SOURCE_HOME"] ?? environment["CODEX_HOME"]
                let root = source.map { URL(fileURLWithPath: $0) } ?? paths.userHome.appendingPathComponent(".codex")
                urls = [root.appendingPathComponent("config.toml")]
            }
        case .grok:
            let root = environment["TATWO2_GROK_HOME"].map { URL(fileURLWithPath: $0) } ?? paths.grokHome
            urls = [root.appendingPathComponent(".grok/config.toml")]
        }
        return urls.filter { !staging || NativeStagingIsolation.allowsRead($0, within: paths.enginesRoot) }
    }

    static func configuredServers(engine: MCPEngine, environment: [String: String]) -> [String: PluginServerConfiguration] {
        if engine == .claude {
            return claudeConfiguredServers(environment: environment).compactMapValues { ($0 as? [String: Any]).map(PluginServerConfiguration.init) }
        }
        var servers: [String: PluginServerConfiguration] = [:]
        for file in configurationURLs(engine: engine, environment: environment) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            servers.merge(PluginServerConfiguration.parseTOML(text)) { first, _ in first }
        }
        return servers
    }

    private static func claudeConfiguredServers(environment: [String: String]) -> [String: Any] {
        guard let claude = configurationURLs(engine: .claude, environment: environment).first else { return [:] }
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
        Array(configuredServers(engine: .codex, environment: environment).keys).sorted()
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
