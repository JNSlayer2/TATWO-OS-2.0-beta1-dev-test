import Foundation

/// 使用者在「模型登入」頁對某家按了「禁用 API」：實質擋住所有送出（含派工、遙控、橋接），確保額度耗盡不會亂燒。
enum EngineDisableStore {
    private static let key = "tatwo2.disabledEngines"
    static func disabled() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func isDisabled(_ kind: ClaudeSidecar.Kind) -> Bool { disabled().contains(kind.rawValue) }
    static func set(_ kind: ClaudeSidecar.Kind, disabled: Bool) {
        var s = self.disabled()
        if disabled { s.insert(kind.rawValue) } else { s.remove(kind.rawValue) }
        UserDefaults.standard.set(Array(s).sorted(), forKey: key)
    }
    static func displayName(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind { case .codex: "OpenAI"; case .claude: "Claude"; case .grok: "Grok" }
    }
}
