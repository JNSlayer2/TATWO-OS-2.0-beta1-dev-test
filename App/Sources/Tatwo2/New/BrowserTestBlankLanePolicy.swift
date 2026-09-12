import Foundation
/// 穩定驗收專用（Codex 2026-09-06 13:33 批准）：DEBUG-only 固定 about:blank 初始分頁鉤子，讓 owned 測試實例不連網就能真正掛起 renderer
/// 量 WebContent 生命週期。不放寬 production address resolver／scheme 白名單、不接受任意 URL；release 編譯永遠 false。
enum EmbeddedBrowserTestBlankLanePolicy {
    static let blankURL = URL(string: "about:blank")!
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        return environment["TATWO2_BROWSER_TEST_BLANK_LANE"] == "1"
        #else
        return false
        #endif
    }
}
