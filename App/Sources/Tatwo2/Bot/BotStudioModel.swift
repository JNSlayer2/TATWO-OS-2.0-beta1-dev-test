import Foundation
import SwiftUI

// Gen-5 bot 分頁「工作室」模型（純 UI 展示層）。
// 2026-09-09 使用者定案：
//   space（底部圓點・最上層） → 工作室（一個 space 可有多間・右緣把手切換）
//   → 資料夾（＝身份組容器・可再深一層・子層只能更嚴） → 群（共用規範）→ bot。
// 防偷渡：零 send、零 runner、零通道、零落盤；全部狀態 view-local。

// MARK: - 綁定類型

/// 工作室綁的是什麼工作環境。三種能力差很多，選的時候就要講白。
enum BotStudioKind: String, CaseIterable, Identifiable {
    case local      // 本機跑的服務（127.0.0.1）
    case foreign    // 別人家的系統（jretc 校長雲）
    case draft      // 還沒成形的專案（只有一個資料夾）

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "本機跑的服務"
        case .foreign: "別人家的系統"
        case .draft: "還沒成形的專案"
        }
    }

    var caption: String {
        switch self {
        case .local: "自己機器上跑的網站或後台"
        case .foreign: "用了多年、改不動的外部系統"
        case .draft: "只有一個資料夾，還沒有畫面"
        }
    }

    var symbol: String {
        switch self {
        case .local: "desktopcomputer"
        case .foreign: "globe.asia.australia"
        case .draft: "folder.badge.plus"
        }
    }

    /// 綁定表單要你填什麼。
    var fieldLabel: String {
        switch self {
        case .local: "網址（本機）"
        case .foreign: "網址"
        case .draft: "專案資料夾"
        }
    }

    var fieldPlaceholder: String {
        switch self {
        case .local: "127.0.0.1:5173"
        case .foreign: "cloud.jretc.com.tw"
        case .draft: "~/tattoo-cms"
        }
    }

    /// bot 在這種工作室裡能做到什麼（白話，逐條）。
    var can: [String] {
        switch self {
        case .local: ["嵌畫面", "讀寫專案資料夾", "改程式", "重開服務"]
        case .foreign: ["嵌畫面", "幫你登入後照著點"]
        case .draft: ["在裡面搭", "搭出網址之後升級成本機服務"]
        }
    }

    /// 做不到／要注意的（nil＝沒有）。
    var cannot: String? {
        switch self {
        case .local: nil
        case .foreign: "碰不到對方主機。沒有 API 就只能模擬人操作，會慢、對方改版會壞。"
        case .draft: "還沒有畫面可看。"
        }
    }
}

/// 呼吸燈語義（沿用 Gen-4：綠＝運行中、黃＝要注意、暗＝沒開）。
enum BotHealth: String, Hashable {
    case run, warn, off

    var tint: Color {
        switch self {
        case .run: Color(red: 0.502, green: 0.576, blue: 0.463)   // 鼠尾草綠
        case .warn: Color(red: 0.831, green: 0.686, blue: 0.416)  // 古金
        case .off: Color.secondary.opacity(0.45)
        }
    }

    var text: String {
        switch self {
        case .run: "運行中"
        case .warn: "要注意"
        case .off: "沒開"
        }
    }
}

// MARK: - 工作室

struct BotStudioSay: Hashable {
    let emoji: String
    let who: String
    let text: String
}

/// 一間工作室＝綁進來的一個工作環境。
struct BotStudio: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    /// 網址或專案路徑（顯示用）。
    let target: String
    let kind: BotStudioKind
    var health: BotHealth = .run
    /// 主畫面示意（展示資料，不連任何東西）。
    var canvasTitle: String = ""
    var canvasCells: [String] = []
    var say: BotStudioSay?
    /// 黃色提醒條（別人家的系統一定要有）。
    var notice: String? {
        kind == .foreign ? "這是別人家的伺服器。bot 只能幫你登入後照著點，碰不到對方主機；對方改版有可能整套操作要重錄。" : nil
    }
}

// MARK: - 身份組（權限 × 視野）

enum BotGrantState: String, Hashable {
    case on, off, inherited   // inherited＝父資料夾給的，這層只能關不能開
}

struct BotGrant: Identifiable, Hashable {
    let id: String
    let label: String
    var state: BotGrantState
}

/// 資料夾的身份組。每間工作室自己一套；新增時可從別間套一份現成的當起點（套完不連動）。
struct BotRole: Identifiable, Hashable {
    let id: String
    let name: String
    /// 能動什麼。
    var permissions: [BotGrant]
    /// 知道什麼（認知隔離）。關掉的那條，bot 連「有這份東西存在」都不知道。
    var vision: [BotGrant]
}

// MARK: - 側欄節點（多層）

struct BotUnit: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    /// 一句話職責。
    let duty: String
    var health: BotHealth = .off
    /// 跑在哪個模型上（展示值）。
    var engine: String = "Claude Opus 5"
    var permissionBrief: String = "沿用資料夾身份組"
    var visionBrief: String = "本資料夾＋工作室共同知識"
}

/// 部門（最大級別）與小組（部門底下）共用同一個型別，靠所在層決定。
/// 小組本身就是一個全員 chat：裡面的 bot 一起講話，不再分「群」這一層
/// （2026-09-09 使用者：小組裡面就是全部一起 chat，不要再分類）。
struct BotFolder: Identifiable, Hashable {
    let id: String
    let name: String
    /// 對應 BotSpace.roles 裡的一條。
    let roleID: String
    /// 小組規範：進來的 bot 自動載入，所以新進的一句話就進入狀況。
    var charter: String = ""
    var folders: [BotFolder] = []
    var bots: [BotUnit] = []
}

/// 臨時工：用完就丟，不留記憶，只能在自己的暫存區動。拖進主清單轉常駐才走六步。
struct BotTemp: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let task: String
}

// MARK: - space（最上層，維持現狀）

struct BotSpace: Identifiable, Hashable {
    let id: String
    var name: String
    var studios: [BotStudio]
    var folders: [BotFolder]
    var roles: [BotRole]
    /// 釘選＝捷徑，指向這個 space 裡的 bot 或工作室 id。
    var pinnedIDs: [String]
    var temps: [BotTemp]

    func role(_ id: String) -> BotRole? { roles.first { $0.id == id } }
}

// MARK: - 展示資料

enum BotStudioFixture {
    static let watermark = "Gen-5 UI 展示・未接入"

    // MARK: 身份組

    static let roleSiteMaintain = BotRole(
        id: "role-site", name: "部門 1 的身份組",
        permissions: [
            .init(id: "p-read", label: "讀專案檔案", state: .on),
            .init(id: "p-write", label: "改專案檔案", state: .on),
            .init(id: "p-browse", label: "開瀏覽器照著點", state: .on),
            .init(id: "p-shell", label: "執行終端指令", state: .off),
            .init(id: "p-publish", label: "對外送出（發文、寄信）", state: .off),
            .init(id: "p-delete", label: "刪除檔案", state: .off),
        ],
        vision: [
            .init(id: "v-self", label: "自己的私有記憶", state: .on),
            .init(id: "v-studio", label: "工作室共同知識（網址、帳號放哪、規矩）", state: .on),
            .init(id: "v-folder", label: "本區筆記", state: .on),
            .init(id: "v-other", label: "其他部門", state: .off),
            .init(id: "v-charter", label: "所在群的群規範", state: .on),
        ])

    /// 子資料夾：繼承父層，只能更嚴。
    static let roleFrontend = BotRole(
        id: "role-frontend", name: "小組 1 的身份組（繼承部門 1）",
        permissions: [
            .init(id: "p-read", label: "讀專案檔案", state: .inherited),
            .init(id: "p-write", label: "改專案檔案", state: .inherited),
            .init(id: "p-browse", label: "開瀏覽器照著點", state: .inherited),
            .init(id: "p-shell", label: "執行終端指令", state: .off),
            .init(id: "p-publish", label: "對外送出（發文、寄信）", state: .off),
            .init(id: "p-delete", label: "刪除檔案", state: .off),
        ],
        vision: [
            .init(id: "v-self", label: "自己的私有記憶", state: .on),
            .init(id: "v-studio", label: "工作室共同知識", state: .inherited),
            .init(id: "v-folder", label: "本區筆記", state: .on),
            .init(id: "v-other", label: "其他部門", state: .off),
            .init(id: "v-charter", label: "所在群的群規範", state: .on),
        ])

    static let roleLedger = BotRole(
        id: "role-ledger", name: "部門 2 的身份組",
        permissions: [
            .init(id: "p-read", label: "讀帳目表", state: .on),
            .init(id: "p-write", label: "改帳目表", state: .on),
            .init(id: "p-browse", label: "開瀏覽器照著點", state: .off),
            .init(id: "p-shell", label: "執行終端指令", state: .off),
            .init(id: "p-publish", label: "對外送出", state: .off),
            .init(id: "p-delete", label: "刪除檔案", state: .off),
        ],
        vision: [
            .init(id: "v-self", label: "自己的私有記憶", state: .on),
            .init(id: "v-studio", label: "工作室共同知識", state: .on),
            .init(id: "v-folder", label: "本區筆記", state: .on),
            .init(id: "v-other", label: "其他部門", state: .off),
            .init(id: "v-charter", label: "所在群的群規範", state: .off),
        ])

    static let roleSchoolOps = BotRole(
        id: "role-school", name: "部門 1 的身份組",
        permissions: [
            .init(id: "p-read", label: "讀本地表單檔", state: .on),
            .init(id: "p-write", label: "改本地表單檔", state: .on),
            .init(id: "p-browse", label: "登入校長雲照著點", state: .on),
            .init(id: "p-shell", label: "執行終端指令", state: .off),
            .init(id: "p-publish", label: "在校長雲按送出", state: .off),
            .init(id: "p-delete", label: "刪除資料", state: .off),
        ],
        vision: [
            .init(id: "v-self", label: "自己的私有記憶", state: .on),
            .init(id: "v-studio", label: "工作室共同知識（校長雲帳號放哪）", state: .on),
            .init(id: "v-folder", label: "本區筆記", state: .on),
            .init(id: "v-other", label: "其他部門", state: .off),
            .init(id: "v-charter", label: "所在群的群規範", state: .on),
        ])

    static let roleOffice = BotRole(
        id: "role-office", name: "部門 2 的身份組",
        permissions: [
            .init(id: "p-read", label: "讀文件", state: .on),
            .init(id: "p-write", label: "改文件", state: .off),
            .init(id: "p-browse", label: "開瀏覽器照著點", state: .off),
            .init(id: "p-print", label: "送進列印佇列", state: .on),
            .init(id: "p-publish", label: "對外送出", state: .off),
            .init(id: "p-delete", label: "刪除檔案", state: .off),
        ],
        vision: [
            .init(id: "v-self", label: "自己的私有記憶", state: .on),
            .init(id: "v-studio", label: "工作室共同知識", state: .on),
            .init(id: "v-folder", label: "本區筆記", state: .on),
            .init(id: "v-other", label: "其他部門", state: .off),
            .init(id: "v-charter", label: "所在群的群規範", state: .off),
        ])

    // MARK: bot

    static let poBot = BotUnit(
        id: "bot-po", name: "PO 文 bot", emoji: "🖥",
        duty: "把作品排成貼文草稿，不自己發布。", health: .run,
        permissionBrief: "可寫草稿・發布要你按",
        visionBrief: "看得到本區與群規範，看不到別的部門")

    static let artBot = BotUnit(
        id: "bot-art", name: "生圖 bot", emoji: "🖼",
        duty: "照素材規格出圖，丟進待發布區。", health: .run,
        engine: "GPT-6",
        permissionBrief: "可在 assets 底下存檔",
        visionBrief: "看不到網頁怎麼搭")

    static let bookmarkBot = BotUnit(
        id: "bot-bookmark", name: "書籤分權 bot", emoji: "🔖",
        duty: "整理素材庫並套權限標籤。", health: .off,
        permissionBrief: "唯讀素材庫",
        visionBrief: "本區筆記")

    static let proofBot = BotUnit(
        id: "bot-proof", name: "校稿 bot", emoji: "✍️",
        duty: "校對文案錯字與口氣。", health: .run,
        engine: "Grok",
        permissionBrief: "唯讀草稿",
        visionBrief: "群規範＋素材規格")

    static let ledgerBot = BotUnit(
        id: "bot-ledger", name: "帳目 bot", emoji: "🧾",
        duty: "收支彙整與月結初稿。", health: .off,
        permissionBrief: "帳目表讀寫・不可刪",
        visionBrief: "只看得到自己這個部門")

    static let enrollBot = BotUnit(
        id: "bot-enroll", name: "註冊表 bot", emoji: "📋",
        duty: "把報名表填進校長雲，退件的擱著等人看。", health: .run,
        permissionBrief: "登入校長雲照著點・送出要你按",
        visionBrief: "校務資料夾＋校長雲帳號位置")

    static let noticeBot = BotUnit(
        id: "bot-notice", name: "公告 bot", emoji: "📣",
        duty: "擬公告草稿，發布前一律停下。", health: .run,
        permissionBrief: "可寫草稿",
        visionBrief: "校務資料夾")

    static let printBot = BotUnit(
        id: "bot-print", name: "列印 bot", emoji: "🖨",
        duty: "把文件排進列印佇列。", health: .warn,
        engine: "本機模型",
        permissionBrief: "只有列印佇列",
        visionBrief: "看不到校務資料")

    // MARK: space

    static let tattooSpace = BotSpace(
        id: "space-tattoo", name: "刺青 work",
        studios: [],
        folders: [
            BotFolder(
                id: "folder-site", name: "部門 1", roleID: "role-site",
                folders: [
                    BotFolder(id: "folder-frontend", name: "小組 1", roleID: "role-frontend",
                              charter: "三隻一起出一篇：生圖出圖、PO 文排版、校稿看錯字。任何一隻說不行就退回，發布一律等人按。",
                              bots: [poBot, artBot, proofBot]),
                    BotFolder(id: "folder-backend", name: "小組 2", roleID: "role-frontend",
                              bots: [bookmarkBot]),
                ]),
            BotFolder(id: "folder-ledger", name: "部門 2", roleID: "role-ledger", bots: [ledgerBot]),
        ],
        roles: [roleSiteMaintain, roleFrontend, roleLedger],
        pinnedIDs: ["bot-ledger"],
        temps: [
            BotTemp(id: "temp-translate", name: "臨時翻譯 bot", emoji: "⚡", task: "菜單翻譯・做完即棄"),
        ])

    static let jnsSpace = BotSpace(
        id: "space-jns", name: "JNS 幼兒園",
        studios: [],
        folders: [
            BotFolder(id: "folder-school", name: "部門 1", roleID: "role-school", bots: [enrollBot, noticeBot]),
            BotFolder(id: "folder-office", name: "部門 2", roleID: "role-office", bots: [printBot]),
        ],
        roles: [roleSchoolOps, roleOffice],
        pinnedIDs: [],
        temps: [
            BotTemp(id: "temp-report", name: "臨時報表 bot", emoji: "⚡", task: "CSV 整併・做完即棄"),
        ])

    static let spaces: [BotSpace] = [tattooSpace, jnsSpace, .init(
        id: "space-blank", name: "新空間", studios: [], folders: [], roles: [], pinnedIDs: [], temps: [])]

    // MARK: 接新東西進來：bot 一律先做 plan（展示資料）

    /// bot 開口先問的，不是表單欄位——問完才知道要接成什麼形式。
    static let clarifyingQuestions = [
        "這東西現在跑在哪？你自己的機器、別人家的伺服器，還是還沒有東西？",
        "你要我做到什麼程度：只幫你看、幫你填、還是可以改裡面的東西？",
        "要不要登入？帳號放哪，每次都問你還是記著？",
        "出事的時候我先停下來等你，還是照做完再回報？",
    ]

    /// 初步 plan：一律從只讀開始，權限逐項打開。
    static let draftPlan = [
        "先接上去只讀，什麼都不動，你確認畫面是對的",
        "我把你平常在上面做的事列成清單，你勾要交給我哪幾件",
        "勾好的才開權限，其餘一律關著",
        "前三天只做草稿不送出，你看過再放行",
    ]

    // MARK: 建 bot 六步的展示值

    static let engines = ["Claude Opus 5", "GPT-6", "Grok", "本機模型"]
    static let avatarChoices = ["🖼", "🎨", "✨", "🤖"]
    static let skills = ["生圖", "圖片壓縮", "瀏覽器操作", "列印", "終端指令", "貼文排版"]

    /// 對話展示（點 bot 或小組時右邊主槽顯示）。
    static func thread(for name: String) -> [BotStudioSay] {
        switch name {
        case "小組 1":
            return [
                .init(emoji: "🖼", who: "生圖 bot", text: "三張線稿出好了（展示資料），比例照作品頁規格。"),
                .init(emoji: "🖥", who: "PO 文 bot", text: "文案 A／B 兩版，我推 A：口語開頭＋預約 CTA。"),
                .init(emoji: "✍️", who: "校稿 bot", text: "A 版有一個錯字已改。三隻都同意，等你按發布。"),
            ]
        case "帳目 bot":
            return [.init(emoji: "🧾", who: "帳目 bot", text: "月結初稿好了（展示資料）：收入 14 筆、耗材支出 6 筆，2 筆現金單要你核對。")]
        case "註冊表 bot":
            return [.init(emoji: "📋", who: "註冊表 bot", text: "校長雲那邊 12 筆填完（展示資料），2 筆被格式擋下，我沒硬送。")]
        default:
            return [.init(emoji: "🤖", who: name, text: "待命中（展示資料）。這是 Gen-5 純 UI 展示，沒有接任何執行器。")]
        }
    }
}
