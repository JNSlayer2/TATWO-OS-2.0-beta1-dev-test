import Foundation

// Gen-4 展示層 fixture（BotPageFixtureV1，對齊 harness-exam/g4/fixture-schema.json）。
// 全部資料只存在記憶體；禁落盤、禁接 runner/channel/sandbox（GEN4_UI_PLAN §2）。

enum BotFixtureDensity: String, CaseIterable, Identifiable {
    case full, compact, status
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: "滿 GUI"
        case .compact: "簡 GUI"
        case .status: "無 GUI"
        }
    }
    var caption: String {
        switch self {
        case .full: "完整交互畫布"
        case .compact: "精簡工作面"
        case .status: "僅狀態列"
        }
    }
    var symbol: String {
        switch self {
        case .full: "rectangle.split.2x2"
        case .compact: "list.bullet.rectangle"
        case .status: "circle.dotted"
        }
    }
}

/// 書籤健康狀態（呼吸燈語義：綠=運行中、黃=斷線/錯誤、暗=未開啟）。
enum BotBookmarkHealth: Hashable {
    case running, error, off
}

/// 使用者系統書側標籤（每個 space 自己的收納書籤；只在對應 space 出現）。
struct BotFixtureBookmark: Identifiable, Hashable {
    let id: String
    let name: String
    var health: BotBookmarkHealth = .running
}

struct BotFixtureSpace: Identifiable, Hashable {
    let id: String
    let name: String
    let density: BotFixtureDensity
    var bookmarks: [BotFixtureBookmark] = []
}

struct BotFixtureSub: Identifiable, Hashable {
    let id: String
    let name: String
    let role: String
    var emoji: String = "🤖"
    var isConsensusGroup: Bool = false   // 分類內的多 bot 共識群
    // hover 快查（展示值）。
    var permissionBrief: String = "沿用分類權限"
    var workStatus: String = "待命中"
    var initial: String { String(name.prefix(1)) }
}

/// 臨時工區的 bot（用完就丟；拖拽上去轉常駐）。
struct BotFixtureTempBot: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let task: String
}

/// skillet 技能（口袋登記用；展示資料）。
struct BotFixtureSkill: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    var source: String = "skillet 主根"
}

struct BotFixturePrincipal: Identifiable, Hashable {
    enum Kind: Hashable { case bot, group(members: [String]) }
    let id: String
    let name: String
    let kind: Kind
    let emoji: String
    let subs: [BotFixtureSub]
    let spaces: [BotFixtureSpace]
    let sharedSandbox: Bool
    // hover 快查（展示值）：權限摘要＋工作狀態。
    var permissionBrief: String = "讀取放行・寫入詢問"
    var workStatus: String = "待命中"

    var isGroup: Bool { if case .group = kind { return true }; return false }
    var groupMembers: [String] { if case .group(let m) = kind { return m }; return [] }
}

struct BotFixtureMessage: Identifiable, Hashable {
    enum Author: Hashable { case user, bot(name: String) }
    let id: String
    let author: Author
    let text: String
}

struct BotFixturePermissionRow: Identifiable, Hashable {
    let id: String
    let group: String
    let label: String
    let value: String
    let inherited: Bool
}

struct BotPageFixture {
    let principals: [BotFixturePrincipal]
    var pinnedBotIDs: [String] = []
    let selectedPrincipalID: String?
    let selectedSubID: String?
    let selectedSpaceID: String?
    let expandedPrincipalIDs: Set<String>
    let thread: [BotFixtureMessage]
    let permissionRows: [BotFixturePermissionRow]

    static let watermark = "Gen-4 UI 展示・未接入"

    // MARK: - 共用實例（手繪稿使用者實例）

    static let tattooWork = BotFixturePrincipal(
        id: "fixture-bot-tattoo-work",
        name: "刺青 work",
        kind: .bot,
        emoji: "🪡",
        subs: [
            .init(id: "fixture-bot-tattoo-po", name: "PO文 bot", role: "貼文草稿", emoji: "📝",
                  permissionBrief: "可寫草稿・發文需核准", workStatus: "草稿撰寫中"),
            .init(id: "fixture-bot-tattoo-book", name: "書籤分權 bot", role: "資料整理", emoji: "🔖",
                  permissionBrief: "唯讀素材庫", workStatus: "待命中"),
            .init(id: "fixture-bot-tattoo-ledger", name: "帳目 bot", role: "記帳彙整", emoji: "🧾",
                  permissionBrief: "帳目表讀寫・不可刪", workStatus: "月結彙整中"),
            .init(id: "fixture-group-tattoo-post", name: "貼文共識群", role: "PO文＋書籤分權", emoji: "🗂️", isConsensusGroup: true,
                  permissionBrief: "成員權限交集", workStatus: "共識輪詢中"),
        ],
        spaces: [
            .init(id: "fixture-space-tattoo-studio", name: "工作室排程", density: .compact,
                  bookmarks: [
                      .init(id: "fixture-bm-studio-shift", name: "排班表"),
                      .init(id: "fixture-bm-studio-gear", name: "器材清點", health: .error),
                  ]),
            .init(id: "fixture-space-tattoo-social", name: "社群貼文", density: .full,
                  bookmarks: [
                      .init(id: "fixture-bm-social-assets", name: "素材庫"),
                      .init(id: "fixture-bm-social-drafts", name: "草稿箱"),
                      .init(id: "fixture-bm-social-sched", name: "排程版"),
                  ]),
        ],
        sharedSandbox: false,
        permissionBrief: "讀寫 sandbox・派工需核准",
        workStatus: "運作中")

    static let webBot = BotFixturePrincipal(
        id: "fixture-bot-web",
        name: "Web bot",
        kind: .bot,
        emoji: "🌐",
        subs: [],
        spaces: [.init(id: "fixture-space-web-monitor", name: "站台巡檢", density: .status,
                       bookmarks: [.init(id: "fixture-bm-web-report", name: "巡檢報表")])],
        sharedSandbox: false,
        permissionBrief: "唯讀瀏覽・不落盤",
        workStatus: "巡檢中")

    static let artBot = BotFixturePrincipal(
        id: "fixture-bot-art",
        name: "生圖 bot",
        kind: .bot,
        emoji: "🎨",
        subs: [],
        spaces: [.init(id: "fixture-space-art-board", name: "圖版工作台", density: .full,
                       bookmarks: [
                           .init(id: "fixture-bm-art-shelf", name: "圖版收納"),
                           .init(id: "fixture-bm-art-wall", name: "靈感牆"),
                       ])],
        sharedSandbox: false,
        permissionBrief: "生圖額度 20/日・展示",
        workStatus: "待命中")

    static let jnsGroup = BotFixturePrincipal(
        id: "fixture-group-jns",
        name: "JNS 群",
        kind: .group(members: ["記事", "列印", "輪值", "識記", "JRETC"]),
        emoji: "🗂️",
        subs: [
            .init(id: "fixture-bot-jns-note", name: "記事 bot", role: "會議記錄", emoji: "📒",
                  permissionBrief: "群 sandbox 讀寫", workStatus: "記錄整理中"),
            .init(id: "fixture-bot-jns-print", name: "列印 bot", role: "文件輸出", emoji: "🖨️",
                  permissionBrief: "僅列印佇列", workStatus: "待命中"),
        ],
        spaces: [
            .init(id: "fixture-space-jns-office", name: "辦公室後台", density: .status,
                  bookmarks: [
                      .init(id: "fixture-bm-jns-panel", name: "後台面板"),
                      .init(id: "fixture-bm-jns-board", name: "公告欄"),
                  ]),
            .init(id: "fixture-space-jns-forms", name: "表單修訂", density: .compact,
                  bookmarks: [.init(id: "fixture-bm-jns-forms", name: "表單庫")]),
        ],
        sharedSandbox: true,
        permissionBrief: "群共用 sandbox・sub 上限 3",
        workStatus: "運作中")

    static let defaultPrincipals: [BotFixturePrincipal] = [tattooWork, jnsGroup, webBot, artBot]

    static let defaultTempBots: [BotFixtureTempBot] = [
        .init(id: "fixture-temp-translate", name: "臨時翻譯 bot", emoji: "🈺", task: "菜單翻譯・做完即棄"),
        .init(id: "fixture-temp-report", name: "臨時報表 bot", emoji: "📊", task: "CSV 整併・做完即棄"),
    ]

    static let defaultThread: [BotFixtureMessage] = [
        .init(id: "fixture-msg-1", author: .user, text: "幫我把這週的刺青預約整理成貼文素材"),
        .init(id: "fixture-msg-2", author: .bot(name: "刺青 work"), text: "已整理三筆預約亮點（展示資料）：週四手臂線條、週五背部滿版、週日補色回訪。要用哪一筆起草？"),
        .init(id: "fixture-msg-3", author: .user, text: "週五那筆，配兩張過程照"),
        .init(id: "fixture-msg-4", author: .bot(name: "刺青 work"), text: "草稿完成（展示資料）：文案 86 字＋兩張過程照排版建議。此為 Gen-4 UI 展示，未實際執行。"),
    ]

    static let longThread: [BotFixtureMessage] = [
        .init(id: "fixture-msg-l1", author: .user, text: "PO文 bot，這週社群貼文排三篇：週一作品集、週三保養衛教、週六閃預約"),
        .init(id: "fixture-msg-l2", author: .bot(name: "PO文 bot"), text: "收到（展示資料）。週一作品集我抓上週完成的三件：手臂線條、背部滿版、小腿補色。"),
        .init(id: "fixture-msg-l3", author: .user, text: "背部滿版那件客人同意露圖了嗎？"),
        .init(id: "fixture-msg-l4", author: .bot(name: "PO文 bot"), text: "已確認同意書（展示資料）：可露背部完成圖，不露臉。衛教文用上次的癒合期模板改寫。"),
        .init(id: "fixture-msg-l5", author: .user, text: "閃預約那篇加限時折扣標籤"),
        .init(id: "fixture-msg-l6", author: .bot(name: "PO文 bot"), text: "已加（展示資料）：週六 14:00-18:00 兩個空檔，折扣標籤套用小版型。三篇草稿都放進「社群貼文」space 等你過目。此為 Gen-4 UI 展示。"),
    ]

    static let groupThread: [BotFixtureMessage] = [
        .init(id: "fixture-msg-g1", author: .user, text: "JNS 群：今天辦公室後台有什麼要處理的？"),
        .init(id: "fixture-msg-g2", author: .bot(name: "記事"), text: "早會記錄已整理（展示資料）：三項決議、兩項待辦指派。"),
        .init(id: "fixture-msg-g3", author: .bot(name: "列印"), text: "表單修訂版已排入列印佇列（展示資料）：A4 雙面 40 份。"),
        .init(id: "fixture-msg-g4", author: .bot(name: "輪值"), text: "本週輪值表無衝突（展示資料）。群共用 sandbox 內三份草稿待覆核。此為 Gen-4 UI 展示。"),
    ]

    // MARK: - per-bot 展示對話（2026-08-22：點左列 bot 要跳到他的對話）

    static let webThread: [BotFixtureMessage] = [
        .init(id: "fixture-msg-w1", author: .user, text: "Web bot，站台今天狀態如何？"),
        .init(id: "fixture-msg-w2", author: .bot(name: "Web bot"), text: "巡檢完成（展示資料）：預約頁 200 OK、圖庫載入 1.2s、表單送出正常。無異常告警。此為 Gen-4 UI 展示。"),
    ]

    static let artThread: [BotFixtureMessage] = [
        .init(id: "fixture-msg-a1", author: .user, text: "生圖 bot，出三張背部滿版線稿參考"),
        .init(id: "fixture-msg-a2", author: .bot(name: "生圖 bot"), text: "已排入圖版工作台（展示資料）：三張線稿草圖放在「圖版收納」，等你挑一張細化。此為 Gen-4 UI 展示。"),
    ]

    static let bookmarkSubThread: [BotFixtureMessage] = [
        .init(id: "fixture-msg-b1", author: .user, text: "書籤分權 bot，把素材庫這週新增的整理一下"),
        .init(id: "fixture-msg-b2", author: .bot(name: "書籤分權 bot"), text: "整理完成（展示資料）：新增 12 項素材已歸 3 類（完成圖／過程照／閃圖），權限標籤已套。此為 Gen-4 UI 展示。"),
    ]

    static let ledgerThread: [BotFixtureMessage] = [
        .init(id: "fixture-msg-le1", author: .user, text: "帳目 bot，這個月收支先給我看"),
        .init(id: "fixture-msg-le2", author: .bot(name: "帳目 bot"), text: "月結初稿（展示資料）：收入 14 筆、耗材支出 6 筆，待你核對 2 筆現金單。此為 Gen-4 UI 展示。"),
    ]

    static let consensusThread: [BotFixtureMessage] = [
        .init(id: "fixture-msg-c1", author: .user, text: "貼文共識群：週五背部滿版那篇的文案跟圖定稿"),
        .init(id: "fixture-msg-c2", author: .bot(name: "PO文 bot"), text: "文案 A/B 兩版已出（展示資料），我推 A 版：口語開頭＋預約 CTA。"),
        .init(id: "fixture-msg-c3", author: .bot(name: "書籤分權 bot"), text: "圖已選定兩張過程照＋一張完成圖（展示資料），同意書齊。共識達成，等你過目。此為 Gen-4 UI 展示。"),
    ]

    static let noteThread: [BotFixtureMessage] = [
        .init(id: "fixture-msg-n1", author: .user, text: "記事 bot，早會決議整理好了嗎？"),
        .init(id: "fixture-msg-n2", author: .bot(name: "記事 bot"), text: "已整理（展示資料）：三項決議、兩項待辦（列印排程、表單改版），已同步到辦公室後台。此為 Gen-4 UI 展示。"),
    ]

    static let printThread: [BotFixtureMessage] = [
        .init(id: "fixture-msg-p1", author: .user, text: "列印 bot，表單修訂版印 40 份"),
        .init(id: "fixture-msg-p2", author: .bot(name: "列印 bot"), text: "已入佇列（展示資料）：A4 雙面 40 份，預估 6 分鐘。此為 Gen-4 UI 展示。"),
    ]

    // MARK: - skillet（口袋登記展示；2026-08-22 使用者設計）

    static let skilletRegistry: [BotFixtureSkill] = [
        .init(id: "fixture-skill-post", name: "貼文排版", detail: "IG/FB 貼文自動排版"),
        .init(id: "fixture-skill-asset", name: "素材歸檔", detail: "素材庫分類與標籤"),
        .init(id: "fixture-skill-ledger", name: "帳目彙整", detail: "記帳表整併與月結"),
        .init(id: "fixture-skill-form", name: "表單轉檔", detail: "表單 PDF/列印格式化"),
        .init(id: "fixture-skill-watch", name: "站台巡檢", detail: "網站健康檢查報表"),
        .init(id: "fixture-skill-board", name: "圖版排列", detail: "圖版工作台自動排列"),
        .init(id: "fixture-skill-translate", name: "菜單翻譯", detail: "多語菜單翻譯"),
        .init(id: "fixture-skill-csv", name: "CSV 整併", detail: "報表合併與清洗"),
    ]

    /// 在 bot chat 裡搭建出來的 skills（可回傳 skillet 主根；展示）。
    static let chatBuiltSkills: [BotFixtureSkill] = [
        .init(id: "fixture-skill-built-flash", name: "閃預約提醒", detail: "對話中搭建：閃預約自動提醒草稿", source: "bot chat 搭建"),
    ]

    static var allSkills: [BotFixtureSkill] { skilletRegistry + chatBuiltSkills }

    /// 訊息作者名 → 頭像 emoji（對話列小菊花位用；群訊息作者可能是成員簡名）。
    static func emoji(forBotNamed name: String) -> String {
        for principal in defaultPrincipals {
            if principal.name == name { return principal.emoji }
            for sub in principal.subs {
                if sub.name == name || sub.name.hasPrefix(name) || name.hasPrefix(sub.name) {
                    return sub.isConsensusGroup ? "🗂️" : sub.emoji
                }
            }
        }
        return "🤖"
    }

    /// selection → 專屬展示對話；查不到回 nil（由呼叫端退回場景 thread）。
    static func thread(principalID: String?, subID: String?) -> [BotFixtureMessage]? {
        if let subID {
            switch subID {
            case "fixture-bot-tattoo-po": return longThread
            case "fixture-bot-tattoo-book": return bookmarkSubThread
            case "fixture-bot-tattoo-ledger": return ledgerThread
            case "fixture-group-tattoo-post": return consensusThread
            case "fixture-bot-jns-note": return noteThread
            case "fixture-bot-jns-print": return printThread
            default: return nil
            }
        }
        switch principalID {
        case tattooWork.id: return defaultThread
        case jnsGroup.id: return groupThread
        case webBot.id: return webThread
        case artBot.id: return artThread
        default: return nil
        }
    }

    static let defaultPermissionRows: [BotFixturePermissionRow] = [
        .init(id: "fixture-perm-browser", group: "資源", label: "瀏覽器", value: "允許（展示值）", inherited: false),
        .init(id: "fixture-perm-cpu", group: "資源", label: "CPU 上限", value: "2 核（展示值）", inherited: false),
        .init(id: "fixture-perm-ssd", group: "資源", label: "SSD 路徑／上限", value: "fixture:/sandbox/jns · 4GB", inherited: true),
        .init(id: "fixture-perm-skillet", group: "能力", label: "skillet／MCP", value: "skillet 3 項・MCP 未接（展示值）", inherited: false),
        .init(id: "fixture-perm-agentsmd", group: "治理", label: "agents.md", value: "沿用群設定（展示值）", inherited: true),
        .init(id: "fixture-perm-sublimit", group: "治理", label: "sub 上限", value: "3（展示值）", inherited: false),
        .init(id: "fixture-perm-db", group: "資料", label: "sandbox 內 Database", value: "fixture-db・唯讀展示", inherited: true),
        .init(id: "fixture-perm-remote", group: "部署／通道", label: "遠端／本地", value: "本地（展示值）", inherited: false),
        .init(id: "fixture-perm-channels", group: "部署／通道", label: "Line／Discord／Telegram", value: "未接入", inherited: false),
    ]

    // MARK: - 12 凍結場景

    static func scene(_ id: String) -> BotPageFixture? {
        switch id {
        case "rail-tree":
            return BotPageFixture(
                principals: defaultPrincipals,
                pinnedBotIDs: [tattooWork.id, jnsGroup.id],
                selectedPrincipalID: tattooWork.id, selectedSubID: nil,
                selectedSpaceID: tattooWork.spaces.first?.id,
                expandedPrincipalIDs: [tattooWork.id],
                thread: defaultThread, permissionRows: defaultPermissionRows)
        case "rail-collapsed":
            return BotPageFixture(
                principals: defaultPrincipals,
                selectedPrincipalID: tattooWork.id, selectedSubID: nil,
                selectedSpaceID: tattooWork.spaces.first?.id,
                expandedPrincipalIDs: [],
                thread: defaultThread, permissionRows: defaultPermissionRows)
        case "rail-empty":
            return BotPageFixture(
                principals: [], selectedPrincipalID: nil, selectedSubID: nil,
                selectedSpaceID: nil, expandedPrincipalIDs: [],
                thread: [], permissionRows: [])
        case "thread":
            return BotPageFixture(
                principals: defaultPrincipals,
                selectedPrincipalID: tattooWork.id,
                selectedSubID: "fixture-bot-tattoo-po",
                selectedSpaceID: tattooWork.spaces.last?.id,
                expandedPrincipalIDs: [tattooWork.id],
                thread: longThread, permissionRows: defaultPermissionRows)
        case "group-sandbox":
            return BotPageFixture(
                principals: defaultPrincipals,
                selectedPrincipalID: jnsGroup.id, selectedSubID: nil,
                selectedSpaceID: jnsGroup.spaces.first?.id,
                expandedPrincipalIDs: [jnsGroup.id],
                thread: groupThread, permissionRows: defaultPermissionRows)
        case "space-full":
            return BotPageFixture(
                principals: defaultPrincipals,
                selectedPrincipalID: artBot.id, selectedSubID: nil,
                selectedSpaceID: artBot.spaces.first?.id,
                expandedPrincipalIDs: [],
                thread: [], permissionRows: defaultPermissionRows)
        case "space-compact":
            return BotPageFixture(
                principals: defaultPrincipals,
                selectedPrincipalID: jnsGroup.id, selectedSubID: nil,
                selectedSpaceID: "fixture-space-jns-forms",
                expandedPrincipalIDs: [],
                thread: [], permissionRows: defaultPermissionRows)
        case "space-status":
            return BotPageFixture(
                principals: defaultPrincipals,
                selectedPrincipalID: webBot.id, selectedSubID: nil,
                selectedSpaceID: webBot.spaces.first?.id,
                expandedPrincipalIDs: [],
                thread: [], permissionRows: defaultPermissionRows)
        case "add-space":
            return scene("rail-tree")!
        case "quick-card":
            return scene("space-full")!
        case "settings-9row":
            return BotPageFixture(
                principals: defaultPrincipals,
                selectedPrincipalID: jnsGroup.id,
                selectedSubID: "fixture-bot-jns-note",
                selectedSpaceID: jnsGroup.spaces.first?.id,
                expandedPrincipalIDs: [jnsGroup.id],
                thread: [], permissionRows: defaultPermissionRows)
        case "stress":
            let many = (1...14).map { i in
                BotFixturePrincipal(
                    id: "fixture-bot-stress-\(i)",
                    name: "超長名稱壓力測試機器人第\(i)號・附加說明文字",
                    kind: .bot, emoji: "🤖",
                    subs: (1...3).map { .init(id: "fixture-sub-stress-\(i)-\($0)", name: "sub \($0)", role: "壓力") },
                    spaces: [.init(id: "fixture-space-stress-\(i)", name: "space \(i)", density: .compact)],
                    sharedSandbox: i % 3 == 0)
            }
            return BotPageFixture(
                principals: many,
                selectedPrincipalID: many.first?.id, selectedSubID: nil,
                selectedSpaceID: many.first?.spaces.first?.id,
                expandedPrincipalIDs: [many[0].id, many[1].id],
                thread: defaultThread, permissionRows: defaultPermissionRows)
        default:
            // fail-closed：未知場景不得渲染近似畫面（Gen4BotStateMachineV1）。
            return nil
        }
    }

    var selectedPrincipal: BotFixturePrincipal? {
        principals.first { $0.id == selectedPrincipalID }
    }
    var selectedSpace: BotFixtureSpace? {
        selectedPrincipal?.spaces.first { $0.id == selectedSpaceID }
    }
}
