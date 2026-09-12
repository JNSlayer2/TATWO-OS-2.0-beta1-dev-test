// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/BotPageState.swift；改動 52 行（原因：匯出 fixture 不變；live BotLibrary 資料及既有送出接口最小接線，邏輯放 New）
import Foundation
import SwiftUI

// Gen4BotStateMachineV1 忠實實作（docs/plans/gen4/U1-STATE-MACHINE.md）。
// 匯出保留 view-local fixture；live 投影與非同步動作由 New/BotUIWire 提供。

enum BotAddSpaceStep: Equatable {
    case chooseDensity, staticPreview, completionMock
}

@MainActor
final class BotPageState: ObservableObject {
    private let exportFixture: BotPageFixture
    let isUIOnlyPreview: Bool
    var fixture: BotPageFixture { usesLiveBots ? liveFixture : exportFixture }
    var usesLiveBots: Bool { !isUIOnlyPreview && BotUIWire.isLive }
    private var exportLiveModel: ChatPageModel?
    func installExportModel(_ model: ChatPageModel) {
        exportLiveModel = model; CLISessionsTermination.model = model; pocketOpen = true
        refreshLiveBots()
    }

    @Published private(set) var contentMode: BotContentMode
    @Published private(set) var selectedPrincipalID: String?
    @Published private(set) var selectedSubID: String?
    @Published private(set) var selectedSpaceID: String?
    @Published var expandedPrincipalIDs: Set<String>
    @Published private(set) var quickCardOpen: Bool
    @Published private(set) var addSpaceStep: BotAddSpaceStep = .chooseDensity
    @Published private(set) var addSpaceDensity: BotFixtureDensity?
    @Published var settingsSelection: String?
    @Published var pinnedBotIDs: [String] = []
    @Published var pinnedExpandedIDs: Set<String> = []
    /// 已釘選段落收合（header chevron）。
    @Published var pinnedSectionCollapsed = false
    /// 右鍵「設置」小視窗的對象（principal 或 sub id；nil＝關閉）。
    @Published private(set) var configTargetID: String?
    /// 目前展開的使用者系統書籤（右緣書側標籤；每 space 自己的收納）。
    @Published private(set) var openBookmarkID: String?
    /// 書籤圓點雙擊後待確認全關的對象。
    @Published var confirmCloseBookmarkID: String?
    /// 已全關停止運作的書籤（圓點不再呼吸發光）。
    @Published private(set) var stoppedBookmarkIDs: Set<String> = []
    /// 臨時工區（用完就丟；拖拽上去轉常駐）。view-local 展示資料。
    @Published private(set) var tempBots: [BotFixtureTempBot] = BotPageFixture.defaultTempBots
    @Published private(set) var promotedTempBots: [BotFixtureTempBot] = []
    /// 主清單顯示順序（全域拖拽重排用；含 principal 與轉常駐的臨時工 id）。
    @Published private(set) var rowOrder: [String] = []
    /// create bot 流水號（展示）。
    private var createdBotCount = 0
    /// 封存區（二次防護：先封存進設定，設定裡再刪才是真移除）。
    @Published private(set) var archivedTempBots: [BotFixtureTempBot] = []
    @Published var confirmArchiveTempID: String?
    @Published var confirmDeleteArchivedID: String?
    /// 設置頁：換頭貼覆寫（botID → emoji）＋權限開關（"botID|permID"）。展示 view-local。
    @Published var avatarOverrides: [String: String] = [:]
    @Published var enabledPermissionKeys: Set<String> = []
    /// 設置頁左側選中的書籤（分類/群）；nil＝未選。個別 bot 編輯＝settingsSelection。
    @Published var settingsCategoryID: String?
    /// 口袋（每隻 bot 的右側資訊卡；2026-08-22 使用者設計）。
    @Published var pocketOpen = false
    /// 口袋 skillet 登記（botKey → 已登記 skill ids）。view-local 展示。
    @Published private(set) var registeredSkillIDs: [String: [String]] = [:]
    /// 已回傳 skillet 主根的對話搭建 skills。
    @Published private(set) var returnedSkillIDs: Set<String> = []
    /// 改 bot 名稱（展示 view-local）。
    @Published var nameOverrides: [String: String] = [:]
    /// 契約 §3-5：每 space 的 view-local lastSelectedBotID。
    private(set) var lastSelectedBotID: [String: String] = [:]
    /// settings/addSpace 進入前的主槽模式（契約：關閉必須恢復）。
    private(set) var previousMode: BotContentMode = .botThread
    /// 場景解析 fail-closed 旗標（未知場景時 true）。
    let unknownScene: Bool

    init(sceneID: String, contentMode: BotContentMode = .botThread, quickCardOpen: Bool = false,
         isUIOnlyPreview: Bool = false) {
        self.isUIOnlyPreview = isUIOnlyPreview
        if let fixture = BotPageFixture.scene(sceneID) {
            self.exportFixture = fixture
            self.unknownScene = false
        } else {
            // fail-closed：未知場景不得渲染近似畫面。
            self.exportFixture = BotPageFixture(
                principals: [], selectedPrincipalID: nil, selectedSubID: nil,
                selectedSpaceID: nil, expandedPrincipalIDs: [], thread: [], permissionRows: [])
            self.unknownScene = true
        }
        self.contentMode = contentMode
        self.selectedPrincipalID = self.exportFixture.selectedPrincipalID
        self.selectedSubID = self.exportFixture.selectedSubID
        self.selectedSpaceID = self.exportFixture.selectedSpaceID
        self.expandedPrincipalIDs = self.exportFixture.expandedPrincipalIDs
        self.quickCardOpen = quickCardOpen
        self.settingsSelection = self.exportFixture.selectedSubID ?? self.exportFixture.selectedPrincipalID
        self.pinnedBotIDs = self.exportFixture.pinnedBotIDs
        self.rowOrder = self.exportFixture.principals.map(\.id)
        if !isUIOnlyPreview {
            if usesLiveBots { tempBots = []; pinnedBotIDs = []; refreshLiveBots() }
            IslandExceptionsNavigation.botPage = self
        }
    }

    /// 主清單條目（照 rowOrder；principal 或已轉常駐的臨時工）。
    enum MainListEntry: Identifiable {
        case principal(BotFixturePrincipal)
        case promoted(BotFixtureTempBot)
        var id: String {
            switch self {
            case .principal(let p): p.id
            case .promoted(let t): t.id
            }
        }
    }

    var mainListEntries: [MainListEntry] {
        (usesLiveBots ? fixture.principals.map(\.id) : rowOrder).compactMap { id in
            if let p = fixture.principals.first(where: { $0.id == id }) { return .principal(p) }
            if let t = promotedTempBots.first(where: { $0.id == id }) { return .promoted(t) }
            return nil
        }
    }

    /// 全域拖拽落點（Dia 式插入）：把 draggedID 移到 targetID 的上/下。
    /// 臨時工被拖入主清單＝轉常駐＋落位；sub 屬未來權限同步目的，先不動資料。
    func moveRow(draggedID: String, near targetID: String, below: Bool) {
        guard draggedID != targetID, rowOrder.contains(targetID) else { return }
        // 臨時工 → 轉常駐並插入落點。
        if let i = tempBots.firstIndex(where: { $0.id == draggedID }) {
            let bot = tempBots.remove(at: i)
            promotedTempBots.append(bot)
            insertRow(draggedID, near: targetID, below: below)
            return
        }
        // 既有主清單列 → 重排。
        if rowOrder.contains(draggedID) {
            rowOrder.removeAll { $0 == draggedID }
            insertRow(draggedID, near: targetID, below: below)
        }
        // 其他（sub 等）：展示 no-op（權限同步屬未來底層代）。
    }

    private func insertRow(_ id: String, near targetID: String, below: Bool) {
        guard let t = rowOrder.firstIndex(of: targetID) else { rowOrder.append(id); return }
        rowOrder.insert(id, at: below ? t + 1 : t)
    }

    /// create bot（展示）：生一隻草稿臨時工並直接開設置。
    func createBot() {
        if usesLiveBots { Task { await createLiveBot() }; return }
        createdBotCount += 1
        let bot = BotFixtureTempBot(
            id: "fixture-temp-created-\(createdBotCount)",
            name: "新 bot \(createdBotCount)",
            emoji: "🤖",
            task: "草稿・未設定")
        tempBots.append(bot)
        openBotConfig(bot.id)
    }

    func refreshLiveBots() {
        guard usesLiveBots else { return }
        let principals = fixture.principals
        if !principals.contains(where: { $0.id == selectedPrincipalID }) {
            selectedPrincipalID = principals.first?.id
            selectedSubID = principals.first?.subs.first?.id
            selectedSpaceID = principals.first?.spaces.first?.id
            if let id = selectedPrincipalID { expandedPrincipalIDs.insert(id) }
        } else if let id = selectedSubID, selectedPrincipal?.subs.contains(where: { $0.id == id }) != true {
            selectedSubID = nil
        }
        consumePendingIslandTarget(principals)
        objectWillChange.send()
    }

    /// 靈動島在 Bot 分頁尚未建立時點的目標（IslandExceptionsNavigation.pendingBotID）：投影一到就選中。
    private func consumePendingIslandTarget(_ principals: [BotFixturePrincipal]) {
        guard let botID = IslandExceptionsNavigation.pendingBotID else { return }
        if principals.contains(where: { $0.id == botID }) {
            IslandExceptionsNavigation.pendingBotID = nil
            selectPrincipal(botID)
        } else if let owner = principals.first(where: { $0.subs.contains(where: { $0.id == botID }) }) {
            IslandExceptionsNavigation.pendingBotID = nil
            selectSub(botID, of: owner.id)
        }
    }

    // MARK: - 查詢

    var selectedPrincipal: BotFixturePrincipal? {
        fixture.principals.first { $0.id == selectedPrincipalID }
    }
    /// 底列＋生成的空白空間（view-local；2026-08-22 使用者：add space=生成新空白左列）。
    @Published private(set) var blankSpaces: [String: [BotFixtureSpace]] = [:]
    var orderedSpaces: [BotFixtureSpace] {
        (selectedPrincipal?.spaces ?? []) + (blankSpaces[selectedPrincipalID ?? ""] ?? [])
    }
    var selectedSpace: BotFixtureSpace? {
        orderedSpaces.first { $0.id == selectedSpaceID }
    }
    var pagerIndex: Int? {
        orderedSpaces.firstIndex { $0.id == selectedSpaceID }
    }
    var canPagerPrev: Bool { (pagerIndex ?? 0) > 0 }
    var canPagerNext: Bool {
        guard let i = pagerIndex else { return false }
        return i < orderedSpaces.count - 1
    }
    /// 書籤只在對應 space 裡出現：右緣書側標籤＝當前 space 自己的收納。
    var currentBookmarks: [BotFixtureBookmark] { selectedSpace?.bookmarks ?? [] }
    var openBookmark: BotFixtureBookmark? {
        currentBookmarks.first { $0.id == openBookmarkID }
    }
    var configTarget: (name: String, emoji: String, isSub: Bool)? {
        guard let id = configTargetID else { return nil }
        if let principal = fixture.principals.first(where: { $0.id == id }) {
            return (principal.name, principal.emoji, false)
        }
        for principal in fixture.principals {
            if let sub = principal.subs.first(where: { $0.id == id }) {
                return (sub.name, sub.isConsensusGroup ? "🗂️" : sub.emoji, true)
            }
        }
        if let temp = (tempBots + promotedTempBots).first(where: { $0.id == id }) {
            return (temp.name, temp.emoji, false)
        }
        return nil
    }

    /// sub id → (owning principal, sub)。釘選單 bot 用。
    func ownerOfSub(_ subID: String) -> (owner: BotFixturePrincipal, member: BotFixtureSub)? {
        for principal in fixture.principals {
            if let sub = principal.subs.first(where: { $0.id == subID }) {
                return (principal, sub)
            }
        }
        return nil
    }

    /// 2026-08-22 使用者：「點左列 bot 要跳到他的對話」——thread 跟著 selection
    /// 走（per-bot 展示對話），查不到專屬 thread 才退回場景 thread。
    var currentThread: [BotFixtureMessage] {
        if usesLiveBots { return liveThread }
        return BotPageFixture.thread(principalID: selectedPrincipalID, subID: selectedSubID)
            ?? fixture.thread
    }

    // MARK: - 口袋 skillet 登記（展示）

    /// 口袋歸屬鍵：sub 優先，否則主 bot。
    var pocketBotKey: String? { selectedSubID ?? selectedPrincipalID }

    var registeredSkills: [BotFixtureSkill] {
        guard let key = pocketBotKey else { return [] }
        let ids = registeredSkillIDs[key] ?? []
        return ids.compactMap { id in BotPageFixture.allSkills.first { $0.id == id } }
    }

    func isSkillRegistered(_ skillID: String) -> Bool {
        guard let key = pocketBotKey else { return false }
        return registeredSkillIDs[key]?.contains(skillID) ?? false
    }

    /// 在資訊卡搜尋並 enter → 登記到這隻 bot 的口袋。
    func registerSkill(_ skillID: String) {
        guard let key = pocketBotKey,
              BotPageFixture.allSkills.contains(where: { $0.id == skillID }) else { return }
        var list = registeredSkillIDs[key] ?? []
        guard !list.contains(skillID) else { return }
        list.append(skillID)
        registeredSkillIDs[key] = list
    }

    func unregisterSkill(_ skillID: String) {
        guard let key = pocketBotKey else { return }
        registeredSkillIDs[key]?.removeAll { $0 == skillID }
    }

    /// 反向：把 bot chat 裡搭建的 skill 回傳 skillet 主根（展示標記）。
    func returnSkillToSkillet(_ skillID: String) {
        guard BotPageFixture.chatBuiltSkills.contains(where: { $0.id == skillID }) else { return }
        returnedSkillIDs.insert(skillID)
    }

    /// 對話頂部置中名稱（LINE 式）：選中 sub 顯示 sub 名，否則主 bot 名。
    var currentThreadTitle: String? {
        if let subID = selectedSubID,
           let sub = selectedPrincipal?.subs.first(where: { $0.id == subID }) {
            return sub.name
        }
        return selectedPrincipal?.name
    }

    // MARK: - rail 選取（§2 rows 1-2、7）

    func selectPrincipal(_ id: String) {
        guard let principal = fixture.principals.first(where: { $0.id == id }) else { return }
        if !isUIOnlyPreview { SpaceWorkspaceController.shared.presentsInterface = false }
        selectedPrincipalID = id
        selectedSubID = nil
        // §3-6：換 principal 切到其預設（第一個）space；不得沿用他人 pager。
        selectedSpaceID = principal.spaces.first?.id
        restoreLastSelected(for: principal)
        quickCardOpen = false
        openBookmarkID = nil   // 書籤只屬對應 space
        contentMode = .botThread
    }

    func selectSub(_ subID: String, of principalID: String) {
        guard let principal = fixture.principals.first(where: { $0.id == principalID }),
              principal.subs.contains(where: { $0.id == subID }) else { return }
        if !isUIOnlyPreview { SpaceWorkspaceController.shared.presentsInterface = false }
        if selectedPrincipalID != principalID {
            selectedPrincipalID = principalID
            selectedSpaceID = principal.spaces.first?.id
        }
        selectedSubID = subID
        writeLastSelected(botID: principalID)
        quickCardOpen = false
        contentMode = .botThread
    }

    /// §4：chevron 只 disclosure，不得改 selection/mode。
    func toggleDisclosure(_ principalID: String) {
        guard let principal = fixture.principals.first(where: { $0.id == principalID }),
              !principal.subs.isEmpty else { return }
        if expandedPrincipalIDs.contains(principalID) { expandedPrincipalIDs.remove(principalID) }
        else { expandedPrincipalIDs.insert(principalID) }
    }

    // MARK: - pager（§3；非循環）

    func pagerSelect(index: Int) {
        guard index >= 0, index < orderedSpaces.count else { return }
        if orderedSpaces[index].id != selectedSpaceID { openBookmarkID = nil }
        selectedSpaceID = orderedSpaces[index].id
        restoreLastSelected(for: selectedPrincipal)
        quickCardOpen = false
        contentMode = .spaceCanvas
    }

    func pagerPrev() { if canPagerPrev, let i = pagerIndex { pagerSelect(index: i - 1) } }
    func pagerNext() { if canPagerNext, let i = pagerIndex { pagerSelect(index: i + 1) } }

    /// 右緣 space 鈕：指定 space 進 canvas。
    func selectSpace(_ spaceID: String) {
        guard let i = orderedSpaces.firstIndex(where: { $0.id == spaceID }) else { return }
        pagerSelect(index: i)
    }

    // MARK: - quick card（§2）

    /// X 私訊式 bot 小視窗：bot 分頁全域可開（2026-08-22 使用者改案）。
    func openQuickCard() {
        quickCardOpen = true
    }

    /// 快捷卡選 bot：回寫 rail selection＋lastSelectedBotID；不切 mode。
    /// selectionKey 合法性（§1-2）：space 必須屬 principal——僅接受目前 space
    /// 的 owning principal（或其 sub 的主 bot），拒絕外部 principal。
    func quickCardSelect(botID: String) {
        guard quickCardOpen, let owner = selectedPrincipal else { return }
        if botID == owner.id {
            selectedSubID = nil
            writeLastSelected(botID: owner.id)
        } else if owner.subs.contains(where: { $0.id == botID }) {
            selectedSubID = botID
            writeLastSelected(botID: owner.id)
        }
        // 其他 principal：拒絕（space 不屬其 selectionKey）。
    }

    func closeQuickCard() { quickCardOpen = false }

    // MARK: - 釘選（右鍵多選 pin；view-local）

    /// 釘選：分類/群/單 bot/sub bot 皆可（2026-08-22 使用者：單 bot 也要有釘選）。
    func togglePin(_ botID: String) {
        let exists = fixture.principals.contains { p in
            p.id == botID || p.subs.contains { $0.id == botID }
        }
        guard exists else { return }
        if let i = pinnedBotIDs.firstIndex(of: botID) { pinnedBotIDs.remove(at: i) }
        else { pinnedBotIDs.append(botID) }
    }

    /// 私訊小視窗選 bot：跳轉對話但保持小視窗開啟（2026-08-22 使用者）。
    func selectPrincipalKeepingQuickCard(_ id: String) {
        let wasOpen = quickCardOpen
        selectPrincipal(id)
        if wasOpen { quickCardOpen = true }
    }

    func selectSubKeepingQuickCard(_ subID: String, of principalID: String) {
        let wasOpen = quickCardOpen
        selectSub(subID, of: principalID)
        if wasOpen { quickCardOpen = true }
    }

    // MARK: - 臨時工區（用完就丟；拖拽轉常駐）

    func promoteTempBot(_ id: String) {
        guard let i = tempBots.firstIndex(where: { $0.id == id }) else { return }
        let bot = tempBots.remove(at: i)
        promotedTempBots.append(bot)
        if !rowOrder.contains(id) { rowOrder.append(id) }
    }

    func demoteTempBot(_ id: String) {
        guard let i = promotedTempBots.firstIndex(where: { $0.id == id }) else { return }
        let bot = promotedTempBots.remove(at: i)
        tempBots.append(bot)
        rowOrder.removeAll { $0 == id }
    }

    func discardTempBot(_ id: String) {
        tempBots.removeAll { $0.id == id }
        promotedTempBots.removeAll { $0.id == id }
        rowOrder.removeAll { $0 == id }
        if configTargetID == id { configTargetID = nil }
    }

    // MARK: - 封存二次防護（2026-08-22 使用者：封存進設定，設定裡才能真刪）

    func requestArchiveTempBot(_ id: String) {
        guard (tempBots + promotedTempBots).contains(where: { $0.id == id }) else { return }
        confirmArchiveTempID = id
    }

    func confirmArchiveTempBot() {
        guard let id = confirmArchiveTempID else { return }
        if let i = tempBots.firstIndex(where: { $0.id == id }) {
            archivedTempBots.append(tempBots.remove(at: i))
        } else if let i = promotedTempBots.firstIndex(where: { $0.id == id }) {
            archivedTempBots.append(promotedTempBots.remove(at: i))
        }
        rowOrder.removeAll { $0 == id }
        confirmArchiveTempID = nil
    }

    func cancelArchiveTempBot() { confirmArchiveTempID = nil }

    func requestDeleteArchived(_ id: String) {
        guard archivedTempBots.contains(where: { $0.id == id }) else { return }
        confirmDeleteArchivedID = id
    }

    func confirmDeleteArchived() {
        guard let id = confirmDeleteArchivedID else { return }
        archivedTempBots.removeAll { $0.id == id }
        if settingsSelection == id { settingsSelection = nil }
        confirmDeleteArchivedID = nil
    }

    func cancelDeleteArchived() { confirmDeleteArchivedID = nil }

    /// 封存還原回臨時工區。
    func restoreArchivedTempBot(_ id: String) {
        guard let i = archivedTempBots.firstIndex(where: { $0.id == id }) else { return }
        tempBots.append(archivedTempBots.remove(at: i))
    }

    /// 設置頁顯示用頭貼（可被「更換頭貼」覆寫）。
    func displayEmoji(for id: String, fallback: String) -> String {
        avatarOverrides[id] ?? fallback
    }

    /// 設置頁顯示名（可被「改名稱」覆寫）。
    func displayName(for id: String, fallback: String) -> String {
        let name = nameOverrides[id]?.trimmingCharacters(in: .whitespaces)
        return (name?.isEmpty == false ? name! : fallback)
    }

    /// 個別編輯的同層清單（上一隻/下一隻用）：分類內＝該分類 subs；
    /// 否則＝獨立 bot＋常駐/臨時工。
    var settingsEditSiblings: [String] {
        if let catID = settingsCategoryID,
           let category = fixture.principals.first(where: { $0.id == catID }) {
            return category.subs.map(\.id)
        }
        let standalone = fixture.principals.filter { $0.subs.isEmpty && !$0.isGroup }.map(\.id)
        return standalone + (promotedTempBots + tempBots).map(\.id)
    }

    func settingsEditStep(_ delta: Int) {
        let siblings = settingsEditSiblings
        guard !siblings.isEmpty else { return }
        guard let current = settingsSelection, let i = siblings.firstIndex(of: current) else {
            settingsSelection = siblings.first
            return
        }
        let next = i + delta
        guard next >= 0, next < siblings.count else { return }
        settingsSelection = siblings[next]
    }

    func togglePermission(botID: String, permissionID: String) {
        let key = "\(botID)|\(permissionID)"
        if enabledPermissionKeys.contains(key) { enabledPermissionKeys.remove(key) }
        else { enabledPermissionKeys.insert(key) }
    }

    func isPermissionEnabled(botID: String, permissionID: String) -> Bool {
        enabledPermissionKeys.contains("\(botID)|\(permissionID)")
    }

    func togglePinnedExpansion(_ principalID: String) {
        if pinnedExpandedIDs.contains(principalID) { pinnedExpandedIDs.remove(principalID) }
        else { pinnedExpandedIDs.insert(principalID) }
    }

    /// 已釘選展開列的 space 捷徑：跨 principal 直開某 space。
    var allSpaces: [(principal: BotFixturePrincipal, space: BotFixtureSpace)] {
        fixture.principals.flatMap { p in p.spaces.map { (p, $0) } }
    }

    func openWorkspace(principalID: String, spaceID: String) {
        guard let principal = fixture.principals.first(where: { $0.id == principalID }),
              principal.spaces.contains(where: { $0.id == spaceID }) else { return }
        selectedPrincipalID = principalID
        selectedSubID = nil
        if spaceID != selectedSpaceID { openBookmarkID = nil }
        selectedSpaceID = spaceID
        quickCardOpen = false
        contentMode = .spaceCanvas
    }

    // MARK: - 右緣書側標籤（使用者系統收納；每 space 一套，view-local）

    /// 點書籤展開工作空間；已展開再點＝屏蔽（回 bot 對話）。
    /// 全關後再點＝再啟動：呼吸燈要回亮（2026-08-22 使用者）。
    func toggleBookmark(_ bookmarkID: String) {
        guard currentBookmarks.contains(where: { $0.id == bookmarkID }) else { return }
        if openBookmarkID == bookmarkID {
            openBookmarkID = nil
            contentMode = .botThread
        } else {
            stoppedBookmarkIDs.remove(bookmarkID)   // 再啟動
            openBookmarkID = bookmarkID
            quickCardOpen = false
            contentMode = .spaceCanvas
        }
    }

    /// 圓點雙擊：跳確認關閉視窗（不直接關）。
    func requestCloseBookmark(_ bookmarkID: String) {
        guard currentBookmarks.contains(where: { $0.id == bookmarkID }),
              !stoppedBookmarkIDs.contains(bookmarkID) else { return }
        confirmCloseBookmarkID = bookmarkID
    }

    /// 確認全關：停止運作（呼吸光熄滅）；若正展開則一併屏蔽。
    func confirmCloseBookmark() {
        guard let id = confirmCloseBookmarkID else { return }
        stoppedBookmarkIDs.insert(id)
        if openBookmarkID == id {
            openBookmarkID = nil
            contentMode = .botThread
        }
        confirmCloseBookmarkID = nil
    }

    func cancelCloseBookmark() { confirmCloseBookmarkID = nil }

    // MARK: - 右鍵「設置」小視窗（背景微暗；內容之後設計）

    /// 右鍵「設置」：2026-08-22 重設計後統一導向設置頁。
    /// 分類/群 → 開該書籤（右側列成員）；bot/sub → 直接進個別編輯（帶書籤脈絡）。
    func openBotConfig(_ id: String) {
        var found = false
        if let principal = fixture.principals.first(where: { $0.id == id }) {
            found = true
            if principal.subs.isEmpty && !principal.isGroup {
                settingsCategoryID = nil
                settingsSelection = id
            } else {
                settingsCategoryID = id
                settingsSelection = nil
            }
        } else {
            for principal in fixture.principals {
                if principal.subs.contains(where: { $0.id == id }) {
                    found = true
                    settingsCategoryID = principal.id
                    settingsSelection = id
                    break
                }
            }
            if !found, (tempBots + promotedTempBots + archivedTempBots).contains(where: { $0.id == id }) {
                found = true
                settingsCategoryID = nil
                settingsSelection = id
            }
        }
        guard found else { return }
        configTargetID = id
        if contentMode != .settings {
            previousMode = (contentMode == .botThread || contentMode == .spaceCanvas)
                ? contentMode : previousMode
            contentMode = .settings
        }
    }

    func closeBotConfig() { configTargetID = nil }

    /// 底列「＋」：直接生成一個新的空白空間並切過去（不是三段流；
    /// 三段流歸外標籤的 add＝使用者工作平台搭建）。
    func addBlankSpace() {
        guard let pid = selectedPrincipalID else { return }
        let count = (blankSpaces[pid]?.count ?? 0) + 1
        let space = BotFixtureSpace(
            id: "fixture-space-blank-\(pid)-\(count)",
            name: "新空間 \(count)",
            density: .compact,
            bookmarks: [])
        blankSpaces[pid, default: []].append(space)
        selectedSpaceID = space.id
        openBookmarkID = nil
        quickCardOpen = false
        contentMode = .spaceCanvas
    }

    // MARK: - add space（§2；三段）

    func openAddSpace() {
        guard contentMode == .botThread || contentMode == .spaceCanvas else { return }
        previousMode = contentMode
        addSpaceStep = .chooseDensity
        addSpaceDensity = nil
        contentMode = .addSpace
    }

    func chooseDensity(_ density: BotFixtureDensity) {
        guard contentMode == .addSpace, addSpaceStep == .chooseDensity else { return }
        addSpaceDensity = density
        addSpaceStep = .staticPreview
    }

    func addSpaceBack() {
        guard contentMode == .addSpace else { return }
        switch addSpaceStep {
        case .chooseDensity: break
        case .staticPreview: addSpaceStep = .chooseDensity
        case .completionMock: addSpaceStep = .staticPreview
        }
    }

    func addSpaceComplete() {
        guard contentMode == .addSpace, addSpaceStep == .staticPreview,
              addSpaceDensity != nil else { return }
        addSpaceStep = .completionMock
    }

    /// 取消/Esc：丟棄 view-local 輸入、恢復進入前模式與 selection。
    func addSpaceCancel() {
        guard contentMode == .addSpace else { return }
        addSpaceDensity = nil
        addSpaceStep = .chooseDensity
        contentMode = previousMode
    }

    // MARK: - settings（§2；overlay，關閉恢復前態）

    func openSettings() {
        guard contentMode == .botThread || contentMode == .spaceCanvas else { return }
        previousMode = contentMode
        settingsSelection = selectedSubID ?? selectedPrincipalID
        contentMode = .settings
    }

    /// 只改觀看焦點；不動 selectionKey（§2 settings rows）。
    func settingsFocus(_ id: String?) {
        guard contentMode == .settings else { return }
        if let id {
            let exists = fixture.principals.contains { p in
                p.id == id || p.subs.contains { $0.id == id }
            } || (tempBots + promotedTempBots + archivedTempBots).contains { $0.id == id }
            guard exists else { return }
        }
        settingsSelection = id
    }

    func closeSettings() {
        guard contentMode == .settings else { return }
        configTargetID = nil
        contentMode = previousMode
    }

    // MARK: - lastSelectedBotID（§3-5）

    private func writeLastSelected(botID: String) {
        guard let spaceID = selectedSpaceID else { return }
        lastSelectedBotID[spaceID] = botID
    }

    /// §3-5 完整鏈：saved 可用→恢復主 bot；失效→第一個可用主 bot；
    /// 零 bot→selection nil（呈現零 bot 空態）。不預選 sub。
    private func restoreLastSelected(for principal: BotFixturePrincipal?) {
        guard let principal else { selectedSubID = nil; return }
        guard selectedSpaceID != nil else { selectedSubID = nil; return }
        let spaceID = selectedSpaceID!
        if let saved = lastSelectedBotID[spaceID], saved == principal.id {
            selectedSubID = nil
            return
        }
        // saved 缺失或失效：fixture 模型中 space 的可用主 bot＝owning principal 本身。
        if lastSelectedBotID[spaceID] != nil {
            lastSelectedBotID[spaceID] = nil
        }
        selectedSubID = nil
    }
}
