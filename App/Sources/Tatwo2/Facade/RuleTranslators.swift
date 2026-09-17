import Foundation

protocol RuleTranslator {
    var engine: String { get }
    var injection: String { get }
    var externalFile: String? { get }
    func managedBlock(source: RuleGenerator.Sources, runtimePath: String, hash: String) -> String
}

extension RuleTranslator {
    func managedBlock(source: RuleGenerator.Sources, runtimePath: String, hash: String) -> String {
        """
        \(OSUpstreamBinding.beginMarker)
        ## TATWO OS 上游（\(engine)）
        由 OS 產生，勿手改。最上游憲法在 `~/AI/TATWO OS/os.md`（本機入口：`\(source.root)/os.md`）。
        本機：\(source.identity.name)；角色：\(source.identity.role.rawValue)；主設備：\(source.primaryName)。
        每條新對話先讀執行期上游：`\(runtimePath)`；衝突以入口憲法為準，不另建規則正本。
        <!-- constitution-sha256: \(source.constitutionHash); identity-sha256: \(source.identityHash) -->
        <!-- upstream-hash: \(hash) -->
        \(OSUpstreamBinding.endMarker)
        """
    }
}

struct ClaudeRuleTranslator: RuleTranslator {
    let engine = "claude"
    let injection = "append system prompt"
    let externalFile: String? = ".claude/CLAUDE.md"
}
struct CodexRuleTranslator: RuleTranslator {
    let engine = "codex"
    let injection = "developer_instructions"
    let externalFile: String? = ".codex/AGENTS.md"
}
struct GrokRuleTranslator: RuleTranslator {
    let engine = "grok"
    let injection = "--rules"
    // No verified global instruction-file contract for the bundled CLI. Do not guess a path.
    let externalFile: String? = nil
}

enum RuleTranslators {
    static let all: [any RuleTranslator] = [ClaudeRuleTranslator(), CodexRuleTranslator(), GrokRuleTranslator()]
    static func translator(for target: String) throws -> any RuleTranslator {
        if let translator = all.first(where: { target.contains($0.engine) }) { return translator }
        // Existing OpenClaw workspaces consume the same Markdown pointer as Codex.
        if target.hasPrefix("openclaw:") { return CodexRuleTranslator() }
        throw OSUpstreamBinding.failure("未支援的規則轉譯器：\(target)")
    }
}
