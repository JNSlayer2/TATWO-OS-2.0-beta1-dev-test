import Foundation

/// GOAL #5「Island 收合後無殘留 WebContent」驗收專用（Codex 2026-09-06 13:48 批准）：DEBUG-only、明確 flag 才生效，
/// 讓 IslandQuotesProvider 在同一條真 WKWebView 建立／delegate／release 路徑上載入固定、無外連的靜態 HTML（base＝about:blank），
/// 不改正常 widgetURL、不動 production allowlist；navigation 特判只認 exact about:blank。release 編譯永遠 false。
enum IslandQuotesTestPolicy {
    static let staticHTML = "<!doctype html><html><head><meta charset=\"utf-8\"><title>tatwo2 island test</title></head><body style=\"margin:0;background:#111;color:#eee;font:14px -apple-system\">island quotes test page（no network）</body></html>"
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        return environment["TATWO2_ISLAND_QUOTES_TEST_STATIC"] == "1"
        #else
        return false
        #endif
    }
    static func isExactAboutBlank(_ url: URL) -> Bool { url.absoluteString == "about:blank" }
}
