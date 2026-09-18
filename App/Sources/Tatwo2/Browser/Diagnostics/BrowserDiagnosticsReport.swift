import Foundation

struct BrowserRendererTermination: Identifiable, Sendable {
    let id: Int
    let time: Date
    let status: String
    let code: Int
    let host: String
    let mountGeneration: UInt64

    var text: String {
        "\(time.formatted(.iso8601)) | \(status) (\(code)) | \(host) | mount \(mountGeneration)"
    }
}

struct BrowserProcessHealth: Sendable {
    var launchCounts: [String: UInt64] = [:]
    var terminationCallbackCount: UInt64 = 0
    var recentTerminations: [BrowserRendererTermination] = []
    // CEF does not identify a renderer PID in OnRenderProcessTerminated.
    // Site isolation, navigation and sleeping all legitimately launch helpers.
    static let restartCountText = "未知（未建立 PID 重啟關聯）"
    static let countExplanation = "啟動數按角色累計，不是重啟數；終止回呼可能包含同程序的多個分頁"
    static let codecLimitation = "編解碼器：v2.0.9.001 起內建自建 CEF（含 H.264／AAC）；若影片仍無法播放，Island 會提示改用系統瀏覽器，並在此記錄"
    static let touchIDLimitation = "WebAuthn Touch ID：需 keychain-access-group entitlement，目前不可用"

    init(_ snapshot: [String: Any] = [:]) {
        launchCounts = (snapshot["launchCounts"] as? [String: NSNumber] ?? [:]).mapValues(\.uint64Value)
        terminationCallbackCount = (snapshot["terminationCallbackCount"] as? NSNumber)?.uint64Value ?? 0
        recentTerminations = (snapshot["recentTerminations"] as? [[String: Any]] ?? []).suffix(10).enumerated().compactMap { index, row in
            guard let status = row["status"] as? String, status.hasPrefix("TS_"),
                  let timestamp = row["time"] as? Double, timestamp.isFinite,
                  let mount = row["mountGeneration"] as? NSNumber else { return nil }
            return BrowserRendererTermination(id: index, time: Date(timeIntervalSince1970: timestamp),
                status: BrowserDiagnosticsPrivacy.text(status), code: (row["code"] as? NSNumber)?.intValue ?? 0,
                host: BrowserDiagnosticsPrivacy.host(row["host"] as? String), mountGeneration: mount.uint64Value)
        }
    }

    func latestReason(for role: String) -> String {
        role == "renderer" ? recentTerminations.last.map { "\($0.status)（角色最近；非此 PID）" } ?? "尚無終止回呼"
            : "無終止回呼來源"
    }
}

struct BrowserDiagnosticsTab: Identifiable, Sendable {
    let id: UUID
    let owner: String
    let title: String
    let host: String
    let sleeping: Bool
    let lastActive: Date
    let tools: [String]
}

struct BrowserDiagnosticsReport: Sendable {
    var timestamp = Date()
    var engine = "未啟動"
    var version = "未知"
    var startupMilliseconds: Double?
    var sleepSeconds: Double = 300
    var liveTabLimit: Int?
    var memoryPressure = "尚未監看"
    var nativeBrowserCount = 0
    var memoryWarningMB: Double = 1200
    var processes: [BrowserProcessSample] = []
    var processStatus = "尚未量測"
    var processHealth = BrowserProcessHealth()
    var tabs: [BrowserDiagnosticsTab] = []
    var audit = BrowserDiagnosticsAudit.Snapshot()
    var aiLogins = BrowserDiagnosticsAudit.Snapshot()
    var policies: [BrowserPolicyLog.Entry] = []

    var sleepingCount: Int { tabs.filter(\.sleeping).count }
    var liveTabCount: Int { tabs.count - sleepingCount }
    var sleepText: String { sleepSeconds.isFinite ? "\(String(format: "%.0f", sleepSeconds)) 秒" : "不睡眠" }
    var memoryStatusText: String {
        "存活分頁 \(liveTabCount)／上限 \(liveTabLimit.map(String.init) ?? "不限制")；睡眠 \(sleepingCount)；記憶體壓力狀態：\(memoryPressure)"
    }
    var helperMB: Double { processes.filter(\.isHelper).compactMap(\.megabytes).reduce(0, +) }
    var totalMB: Double { processes.compactMap(\.megabytes).reduce(0, +) }
    var startupText: String { startupMilliseconds.map { String(format: "%.0f ms", $0) } ?? "尚無 ready 紀錄" }
    static func memory(_ value: Double?) -> String { value.map { String(format: "%.1f MB", $0) } ?? "無法讀取" }

    var text: String {
        var lines = [
            "瀏覽器診斷 | \(timestamp.formatted(.iso8601))",
            "【引擎】", "版本：\(version)", "狀態：\(engine)",
            "DRM 影片（Widevine）：不支援",
            BrowserProcessHealth.codecLimitation, BrowserProcessHealth.touchIDLimitation,
            "第一個 lease → 引擎 ready：\(startupText)",
            "背景睡眠門檻：\(sleepText)；記憶體警告：\(String(format: "%.0f", memoryWarningMB)) MB",
            "【程序】RSS MB（口徑：ri_phys_footprint / 1048576）", processStatus,
            memoryStatusText,
            "原生根分頁名額 \(nativeBrowserCount)（含關閉中）；不含 AI 登入彈窗；不等於 renderer 程序數",
            BrowserProcessHealth.countExplanation,
            "renderer 終止回呼：\(processHealth.terminationCallbackCount)",
            "PID | 角色 | RSS | 角色啟動數 | restartCount | 最近終止原因"
        ]
        lines += processes.map {
            "\($0.pid) | \($0.role) | \(Self.memory($0.megabytes)) | \(processHealth.launchCounts[$0.role].map(String.init) ?? "—") | \(BrowserProcessHealth.restartCountText) | \(processHealth.latestReason(for: $0.role))"
        }
        lines.append("最近 \(processHealth.recentTerminations.count) 次 renderer 終止（本次 App 執行）")
        lines += processHealth.recentTerminations.map(\.text)
        lines += ["已讀程序總和：\(Self.memory(totalMB))；helper：\(Self.memory(helperMB))",
                  "【分頁】總數 \(tabs.count)；睡眠 \(sleepingCount)", "owner | title | host | 睡眠 | 最後活動"]
        lines += tabs.map { "\($0.owner) | \($0.title) | \($0.host) | \($0.sleeping ? "是" : "否") | \($0.lastActive.formatted(.iso8601))" }
        lines.append("【WebMCP】")
        for (index, tab) in tabs.enumerated() {
            lines.append("分頁 \(index + 1) | \(tab.owner) | \(tab.title) | \(tab.host)")
            lines += tab.tools.isEmpty ? ["無工具"] : tab.tools
        }
        lines.append("審計：\(audit.status)")
        lines += audit.lines
        lines.append("【AI 登入紀錄】\(aiLogins.status)")
        lines += aiLogins.lines
        lines.append("【政策】最近 \(policies.count) 條 | host | 決定 | actor")
        lines += policies.map { "\($0.time.formatted(.iso8601)) | \($0.host) | \($0.decision) | \($0.actor)" }
        // Scrub per column: truncating a whole row could lose host/sleep/time
        // after a long page title, or omit the outcome of a long audit record.
        return lines.map {
            $0.components(separatedBy: " | ").map(BrowserDiagnosticsPrivacy.text).joined(separator: " | ")
        }.joined(separator: "\n")
    }
}
