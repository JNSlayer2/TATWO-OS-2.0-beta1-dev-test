import Foundation

/// OS 上游宣告：每條討論串啟動時，把本機產生的 os-upstream.md（＋人設）注入原生指令入口。
/// Claude → Agent SDK systemPrompt 附加段；Codex → developer_instructions；Grok → --rules。
/// 來源為入口憲法＋本機身份的產物；來源不可讀時不退回另一份規則正本。
enum OSUpstream {
    // The app links the generator. Historical standalone swiftc probes link only
    // this file + TatwoEntry/resources and retain their file-reader contract.
    #if SWIFT_PACKAGE
    private static let configure: Void = RuleGenerator.registerRuntime()
    #endif
    static var overridePath: String {
        #if SWIFT_PACKAGE
        _ = configure
        #endif
        return runtimePath(environment: ProcessInfo.processInfo.environment)
    }

    static func runtimePath(environment: [String: String]) -> String {
        if let explicit = environment["TATWO2_OS_UPSTREAM_PATH"], !explicit.isEmpty {
            return explicit
        }
        if let docsRoot = environment["TATWO2_DOCS_ROOT"], !docsRoot.isEmpty {
            return URL(fileURLWithPath: docsRoot, isDirectory: true)
                .appendingPathComponent("os-upstream.md").path
        }
        let base = environment["TATWO2_LIVE_ROOT"]
            ?? (NSHomeDirectory() + "/Library/Application Support/tatwo2/live")
        return (base as NSString).deletingLastPathComponent + "/os/os-upstream.md"
    }

    static func declaration() -> String? {
        let path = overridePath
        #if SWIFT_PACKAGE
        _ = OSUpstreamRefresh.applyOnLaunch(runtimePath: path)
        return try? OSUpstreamBinding.readText(path)
        #else
        var candidates = [path]
        if let bundled = TatwoResources.url(forResource: "os-upstream", withExtension: "md") { candidates.append(bundled.path) }
        candidates.append(TatwoEntry().repoDocs.appendingPathComponent("os-upstream.md").path)
        return candidates.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.first { !$0.isEmpty }
        #endif
    }

    /// 組出要注入的完整文字：上游宣告 ＋ 討論串人設（bot）。
    static func compose(threadSystemPrompt: String?) -> String? {
        let persona = threadSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let declaration = declaration() else { return persona.isEmpty ? nil : persona }
        if persona.isEmpty { return declaration }
        return declaration + "\n\n## 這條討論串的人設\n" + persona
    }
}
