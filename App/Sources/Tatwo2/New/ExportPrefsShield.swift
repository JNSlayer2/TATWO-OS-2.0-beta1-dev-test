import Foundation

/// 金樣匯出程序的偏好隔離（2026-09-06 r7 兩張金樣 FAIL 真因）。
/// cfprefsd 不看假 HOME：debug 執行檔的 UserDefaults 網域（`Tatwo2`）被隔離驗收的真人點擊寫進
/// `tatwo.sidebar.pinned=1`，之後同一執行檔的所有匯出都預設左列打開。
/// 做法：匯出模式把所有 `@AppStorage` 鍵的出廠值灌進 argument domain（搜尋順序最高、只在記憶體），
/// 匯出只看 env 覆寫（`TATWO_ULTRAWORK_CHAT_RAIL_PINNED` 等）。
/// 範圍限定：只覆蓋「讀值」；@AppStorage 的 setter 仍寫 persistent domain（匯出程序沒有手勢，不會寫）。
/// 互動 lab（真人點擊 debug 執行檔）不在此隔離內，仍會寫進 debug 網域——那是驗收流程要另外處理的事。
/// 驗證：`shots/regress-20260906-r7/debug-prefs-pollution.txt`（污染網域存在下匯出 PASS，匯出前後該網域值不變）。
enum ExportPrefsShield {
    /// 全 App 的 @AppStorage 鍵與出廠值；新增 @AppStorage 時要一起登記（scripts/check-appstorage-registry.sh 對照原始碼）。
    static let factoryDefaults: [String: Any] = [
        "tatwo.sidebar.pinned": false,
        "tatwo.cli.visibleProjectIDs": "",
        "tatwo.chat.browserPanelWidth": 480.0,
        "tatwo.chat.browserOverlayOpen": false,
        "tatwo.plugins.selectedTab": "skills",
        "tatwo2.note.stage": 1,
    ]

    static func isExportProcess(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
            || env["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"] != nil
            || env["TATWO_ULTRAWORK_EXPORT_CHAT_SCENE"] != nil
    }

    /// 只加進 argument domain（不寫檔、不動 persistent domain）；已由命令列 `-key value` 指定者保留。
    static func apply(to defaults: UserDefaults = .standard) {
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        for (key, value) in factoryDefaults where domain[key] == nil { domain[key] = value }
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    @discardableResult
    static func applyIfExporting() -> Bool {
        guard isExportProcess() else { return false }
        apply()
        return true
    }
}
