import Foundation
import CryptoKit

/// 「把所有引擎接到 OS」：在每個引擎的家寫入同一段綁定，指向入口的 os.md 與 os-upstream.md；
/// 僅替換 V2 區塊；其他位元組（包括 1.0 段）完整保留。
/// 每次啟動比對各家綁定段記的 hash 與現在 os-upstream.md 的 hash，不一致＝有代差。
struct UpstreamBindingTarget: Identifiable, Equatable {
    let id: String          // 例：claude-cli、codex-cli、openclaw:workspace-dashboard
    let label: String       // 例：Claude CLI（~/.claude/CLAUDE.md）
    let path: String
}

struct UpstreamBindingStatus: Identifiable, Equatable {
    enum State: Equatable { case bound, stale, unbound, unreachable }
    let target: UpstreamBindingTarget
    let state: State
    let detail: String
    var id: String { target.id }
}

enum OSUpstreamBinding {
    // Installed by the local generator at app launch. Nil retains the standalone W71 migration API.
    static var runtimeSource: (([String: String]) throws -> String)?
    static var translatedBlock: ((UpstreamBindingTarget, [String: String], String) throws -> String)?
    static var externalTargets: ((String) -> [UpstreamBindingTarget])?
    static let beginMarker = "<!-- TATWO_OS_UPSTREAM_V2:BEGIN -->"
    static let endMarker = "<!-- TATWO_OS_UPSTREAM_V2:END -->"
    /// 入口資料夾：使用者指定的外接卷 TATWO OS；可用環境變數或偏好覆寫。
    static func osRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        TatwoEntry(environment: environment).root.path
    }

    /// App 使用產生後的執行期上游；獨立 W71 遷移 API 保留原有讀取契約。
    static func upstreamText(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let runtimeSource { return try? runtimeSource(environment) }
        let path = osRoot(environment: environment) + "/os-upstream.md"
        if FileManager.default.fileExists(atPath: path) { return try? readText(path) }
        return try? bundled("os-upstream")
    }

    static func upstreamHash(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let text = upstreamText(environment: environment) ?? ""
        return String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// 要接的家。可用 TATWO2_BIND_TARGETS（逗號分隔 id=path）覆寫，給測試用。
    static func targets(environment: [String: String] = ProcessInfo.processInfo.environment) -> [UpstreamBindingTarget] {
        if let raw = environment["TATWO2_BIND_TARGETS"], !raw.isEmpty {
            return raw.prefix(65536).split(separator: ",").prefix(128).compactMap { pair in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return UpstreamBindingTarget(id: parts[0], label: parts[0], path: parts[1])
            }
        }
        let home = NSHomeDirectory()
        var list: [UpstreamBindingTarget] = externalTargets?(home) ?? [
            .init(id: "claude-cli", label: "Claude CLI（~/.claude/CLAUDE.md）", path: home + "/.claude/CLAUDE.md"),
            .init(id: "codex-cli", label: "Codex CLI（~/.codex/AGENTS.md）", path: home + "/.codex/AGENTS.md"),
        ]
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty,
           (codexHome as NSString).standardizingPath != (home + "/.codex" as NSString).standardizingPath {
            list.append(.init(id: "codex-home", label: "Codex 家（\(codexHome)/AGENTS.md）", path: codexHome + "/AGENTS.md"))
        }
        let paths = EnginePaths(environment: environment)
        list.append(.init(id: "app-claude", label: "OS 內的 Claude（獨立資料夾 CLAUDE.md）", path: paths.claudeConfigDirectory.appendingPathComponent("CLAUDE.md").path))
        list.append(.init(id: "app-codex", label: "OS 內的 OpenAI（獨立資料夾 AGENTS.md）", path: paths.codexHome.appendingPathComponent("AGENTS.md").path))
        list.append(.init(id: "app-grok", label: "OS 內的 Grok（獨立資料夾 GROK.md）", path: paths.grokHome.appendingPathComponent("GROK.md").path))
        // OpenClaw 每個 workspace 的 AGENTS.md（外接卷）
        let openclawData = environment["TATWO2_OPENCLAW_ROOT"] ?? "\(NSHomeDirectory())/Library/Application Support/tatwo2/openclaw-workspaces"
        if let names = FileManager.default.enumerator(atPath: openclawData) {
            var count = 0
            while let name = names.nextObject() as? String, count < 128 {
                names.skipDescendants()
                count += 1
                guard name.hasPrefix("workspace-") else { continue }
                list.append(.init(id: "openclaw:" + name, label: "OpenClaw \(name)", path: openclawData + "/" + name + "/AGENTS.md"))
            }
        }
        return list
    }

    static func block(root: String, hash: String) -> String {
        """
        \(beginMarker)
        ## TATWO OS 上游
        你的最上游是 TATWO OS。憲法：`\(root)/os.md`；每條對話開頭的規則：`\(root)/os-upstream.md`。
        跟這個檔或你自家預設指令衝突時，以 os.md 為準。不要自己重寫或另存一份。
        <!-- upstream-hash: \(hash) -->
        \(endMarker)
        """
    }

    static func statuses(environment: [String: String] = ProcessInfo.processInfo.environment) -> [UpstreamBindingStatus] {
        preview(environment: environment).items.map { item in
            .init(target: item.target, state: item.state == .unreadable ? .unreachable :
                item.state == .bound ? .bound : (item.state == .stale || item.state == .edited) ? .stale : .unbound,
                detail: item.error ?? (item.state == .edited ? "已手改（未覆蓋，可預覽套用或保留）" : item.state.rawValue))
        }
    }

    // Compatibility only: callers without an explicitly confirmed preview cannot write.
    static func install(environment: [String: String] = ProcessInfo.processInfo.environment) -> [UpstreamBindingStatus] {
        statuses(environment: environment)
    }
}
