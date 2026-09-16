import Foundation

/// OS 上游宣告：每條討論串啟動時，把 docs/os-upstream.md（＋這條討論串的人設）塞給引擎的原生系統指令入口。
/// Claude → Agent SDK systemPrompt 附加段；Codex → developer_instructions；Grok → --rules。
/// 來源順序：使用者覆寫檔 → App 內建資源 → 專案 docs/。都沒有就只給人設。
enum OSUpstream {
    static var overridePath: String {
        let environment = ProcessInfo.processInfo.environment
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
        var candidates = [overridePath]
        if let bundled = TatwoResources.url(forResource: "os-upstream", withExtension: "md") { candidates.append(bundled.path) }
        candidates.append("\(NSHomeDirectory())/Library/Application Support/tatwo2/docs/os-upstream.md")
        for path in candidates {
            if let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty { return text }
        }
        return nil
    }

    /// 組出要注入的完整文字：上游宣告 ＋ 討論串人設（bot）。
    static func compose(threadSystemPrompt: String?) -> String? {
        let persona = threadSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let declaration = declaration() else { return persona.isEmpty ? nil : persona }
        if persona.isEmpty { return declaration }
        return declaration + "\n\n## 這條討論串的人設\n" + persona
    }
}
