import Foundation
import SwiftUI

// Gen-5 bot 分頁狀態機（純 view-local；禁落盤、禁 runner、禁通道）。

/// 接新東西進來的兩個階段：先講 → bot 給 plan。
enum BotBindPhase: Equatable {
    case compose, plan
}

enum BotStudioMode: Equatable {
    case studio        // 主槽＝某一間工作室的畫面
    case team          // 主槽＝一個小組：名稱＋成員頭像（小組在側欄不展開）
    case spaceSettings // 主槽＝這個 space 的設定
    case thread        // 主槽＝某隻 bot／某個群的對話
    case bind          // 綁一個工作環境（三段流）
    case wizard        // 臨時工轉常駐的六步
    case role          // 資料夾設定＝身份組（權限 × 視野）
}

@MainActor
final class BotStudioState: ObservableObject {
    @Published private(set) var spaces: [BotSpace]
    @Published var spaceIndex: Int

    @Published var mode: BotStudioMode = .studio
    @Published var selectedStudioID: String?
    /// 選中的 bot（thread 模式）。
    @Published var selectedBotID: String?
    /// 只有部門會展開；小組與群改成點進去看（2026-09-09 使用者：減少資料夾）。
    @Published var expandedFolderIDs: Set<String> = []
    @Published var selectedTeamID: String?
    /// 釘選 2026-09-09 先從畫面撤掉（能力保留，之後要再放回來）。
    @Published var pinnedCollapsed = false

    /// 跟 bot／群講話的輸入框（chat 分頁同款；展示，不接執行器）。
    @Published var threadDraft = ""
    /// 這一輪你打過的話（view-local，只為了讓輸入框有回饋）。
    @Published private(set) var threadSaid: [String: [BotStudioSay]] = [:]

    /// bot 私訊（沿用 Gen-4：右下 FAB＋小視窗；清單雙擊進 DM 頁）。
    @Published var dmOpen = false
    @Published var dmTargetID: String?

    /// 接一個新東西進來＝對話，不是表單（2026-09-09 使用者：不要預設工作室形式，
    /// 由 bot 先做 plan 把部署想像問清楚，才有最大的可擴展性）。
    @Published var bindPhase: BotBindPhase = .compose
    @Published var bindPrompt = ""
    /// 跟誰談：現有 bot 的 id；nil＝當場開一隻新的來談。
    @Published var bindPartnerID: String?
    @Published private(set) var bindTranscript: [BotStudioSay] = []
    @Published private(set) var bindQuestions: [String] = []
    @Published private(set) var bindPlan: [String] = []
    /// plan 談完才問的兩件事：這間叫什麼、位置在哪（位置可留空）。
    @Published var bindName = ""
    @Published var bindTarget = ""
    private var userStudioCount = 0
    private var spaceCount = 0
    private var deptCount = 0
    private var teamCount = 0

    /// 六步精靈草稿。
    @Published var wizardStep = 0
    @Published var wizardSourceTempID: String?
    @Published var wizardName = ""
    @Published var wizardEmoji = "🤖"
    @Published var wizardEngine = BotStudioFixture.engines[0]
    @Published var wizardDuty = ""
    @Published var wizardFolderID: String?
    @Published var wizardSkills: Set<String> = []

    /// 身份組設定頁看的是哪個資料夾。
    @Published var roleFolderID: String?
    /// 展示用開關覆寫（"roleID|grantID" → 新狀態）。
    @Published var grantOverrides: [String: BotGrantState] = [:]

    /// 臨時工轉常駐後落在哪個資料夾（展示：id → folderID）。
    @Published private(set) var promoted: [BotUnit] = []
    @Published private(set) var promotedFolderID: [String: String] = [:]
    private var createdCount = 0

    init(spaceIndex: Int = 0, mode: BotStudioMode = .studio) {
        let all = BotStudioFixture.spaces
        self.spaces = all
        self.spaceIndex = min(max(0, spaceIndex), max(0, all.count - 1))
        self.mode = mode
        let space = all[self.spaceIndex]
        self.selectedStudioID = space.studios.first?.id
        self.expandedFolderIDs = Set(space.folders.map(\.id))
        self.roleFolderID = space.folders.first?.id
        self.wizardFolderID = space.folders.first?.folders.first?.id ?? space.folders.first?.id
        if mode == .team {
            self.selectedTeamID = space.folders.first?.folders.first?.id
        }
        if mode == .thread {
            // 直接開在對話模式時（驗收快照／外部導覽）先選一隻，不要停在空提示。
            self.selectedBotID = space.folders.first?.folders.first?.bots.first?.id
                ?? space.folders.first?.bots.first?.id
        }
    }

    // MARK: - 取值

    /// The Bot sidebar bot space, not a top-level work space.
    var space: BotSpace { spaces[spaceIndex] }
    var studios: [BotStudio] { space.studios }
    var studio: BotStudio? { studios.first { $0.id == selectedStudioID } ?? studios.first }

    /// 這個 space 裡所有 bot（含轉常駐的臨時工），供清單與精靈查名。
    var allBots: [BotUnit] {
        var out: [BotUnit] = []
        var seen: Set<String> = []
        func add(_ unit: BotUnit) {
            guard seen.insert(unit.id).inserted else { return }
            out.append(unit)
        }
        func walk(_ f: BotFolder) {
            f.bots.forEach(add)
            f.folders.forEach(walk)
        }
        space.folders.forEach(walk)
        promoted.forEach(add)
        return out
    }

    var allFolders: [BotFolder] {
        var out: [BotFolder] = []
        func walk(_ f: BotFolder) { out.append(f); f.folders.forEach(walk) }
        space.folders.forEach(walk)
        return out
    }

    func bot(_ id: String?) -> BotUnit? { id.flatMap { bid in allBots.first { $0.id == bid } } }
    func folder(_ id: String?) -> BotFolder? { id.flatMap { fid in allFolders.first { $0.id == fid } } }

    /// 完整路徑（麵包屑：部門 › 小組）。
    func folderPath(_ id: String) -> String {
        for root in space.folders {
            if root.id == id { return root.name }
            for sub in root.folders where sub.id == id { return "\(root.name) › \(sub.name)" }
        }
        return folder(id)?.name ?? "—"
    }

    /// 父資料夾（用來說明「繼承自誰」）。
    func parentFolder(of id: String) -> BotFolder? {
        space.folders.first { $0.folders.contains(where: { $0.id == id }) }
    }

    func role(forFolder id: String?) -> BotRole? {
        guard let f = folder(id) else { return nil }
        return space.role(f.roleID)
    }

    /// 讀開關（含展示覆寫）。
    func grantState(role: BotRole, grant: BotGrant) -> BotGrantState {
        grantOverrides["\(role.id)|\(grant.id)"] ?? grant.state
    }

    /// 點開關：繼承來的只能關掉（再點回去仍是繼承）；其餘 on/off 互換。
    func toggleGrant(role: BotRole, grant: BotGrant) {
        let key = "\(role.id)|\(grant.id)"
        switch grantState(role: role, grant: grant) {
        case .on: grantOverrides[key] = .off
        case .off: grantOverrides[key] = grant.state == .inherited ? .inherited : .on
        case .inherited: grantOverrides[key] = .off
        }
    }

    // MARK: - 導覽

    func selectSpace(_ index: Int) {
        guard spaces.indices.contains(index) else { return }
        spaceIndex = index
        let s = spaces[index]
        selectedStudioID = s.studios.first?.id
        selectedBotID = nil
        expandedFolderIDs = Set(s.folders.map(\.id))
        selectedTeamID = nil
        roleFolderID = s.folders.first?.id
        mode = .studio
    }

    func stepSpace(by delta: Int) {
        selectSpace(min(max(0, spaceIndex + delta), spaces.count - 1))
    }

    func openStudio(_ id: String) {
        selectedStudioID = id
        selectedBotID = nil
        selectedTeamID = nil
        mode = .studio
    }

    func selectBot(_ id: String) {
        selectedBotID = id
        mode = .thread
    }

    /// 點小組＝進去，裡面就是全員一起講話。
    func selectTeam(_ id: String) {
        selectedTeamID = id
        selectedBotID = nil
        mode = .team
    }

    /// 這個小組的成員（頭像列與全員對話用）。
    func teamBots(_ id: String) -> [BotUnit] {
        guard let f = folder(id) else { return [] }
        return f.bots + promoted.filter { promotedFolderID[$0.id] == id }
    }

    func openSpaceSettings() { mode = .spaceSettings }

    func renameSpace(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        spaces[spaceIndex].name = trimmed
    }

    /// 送出：展示用，把你的話貼上去，bot 回一句「還沒接執行器」。
    func sendThreadDraft() {
        let text = threadDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty,
              let key = (mode == .team ? selectedTeamID : selectedBotID) else { return }
        var rows = threadSaid[key] ?? []
        rows.append(BotStudioSay(emoji: "🧑", who: "你", text: text))
        let who = bot(key)?.name ?? folder(key)?.name ?? "bot"
        let emoji = bot(key)?.emoji ?? "🤖"
        rows.append(BotStudioSay(emoji: emoji, who: who,
                                 text: "收到（展示資料）。這一代還沒接執行器，我不會真的動手。"))
        threadSaid[key] = rows
        threadDraft = ""
    }

    /// 這隻／這個群這一輪多出來的對話。
    func extraSays(for key: String?) -> [BotStudioSay] {
        guard let key else { return [] }
        return threadSaid[key] ?? []
    }

    /// 新增一個 space（switch space 那排的 ＋；view-local）。
    func addSpace() {
        spaceCount += 1
        let space = BotSpace(
            id: "space-user-\(spaceCount)", name: "新 space \(spaceCount)",
            studios: [], folders: [], roles: [], pinnedIDs: [], temps: [])
        spaces.append(space)
        selectSpace(spaces.count - 1)
    }

    func toggleFolder(_ id: String) {
        if expandedFolderIDs.contains(id) { expandedFolderIDs.remove(id) } else { expandedFolderIDs.insert(id) }
    }

    func openRoleSettings(folderID: String) {
        roleFolderID = folderID
        mode = .role
    }

    // MARK: - 建立（每一層自己的 ＋）
    // 層級用語（使用者 2026-09-09 正名）：部門＝最大區塊、小組＝部門底下、
    // 群＝幾隻 bot 共用規範一起做一件事、bot＝單獨一隻。

    /// 走訪到指定資料夾並就地修改（部門／小組都吃這條）。
    private func mutateFolder(_ id: String, _ body: (inout BotFolder) -> Void) {
        func walk(_ folders: inout [BotFolder]) -> Bool {
            for i in folders.indices {
                if folders[i].id == id { body(&folders[i]); return true }
                if walk(&folders[i].folders) { return true }
            }
            return false
        }
        _ = walk(&spaces[spaceIndex].folders)
    }

    /// 新部門／新小組的身份組：一律從全關開始，要什麼自己開。
    private func makeClosedRole(id: String, name: String) -> BotRole {
        BotRole(
            id: id, name: name,
            permissions: [
                .init(id: "p-read", label: "讀專案檔案", state: .off),
                .init(id: "p-write", label: "改專案檔案", state: .off),
                .init(id: "p-browse", label: "開瀏覽器照著點", state: .off),
                .init(id: "p-shell", label: "執行終端指令", state: .off),
                .init(id: "p-publish", label: "對外送出", state: .off),
                .init(id: "p-delete", label: "刪除檔案", state: .off),
            ],
            vision: [
                .init(id: "v-self", label: "自己的私有記憶", state: .on),
                .init(id: "v-studio", label: "工作室共同知識", state: .off),
                .init(id: "v-folder", label: "本區筆記", state: .on),
                .init(id: "v-other", label: "其他部門", state: .off),
                .init(id: "v-charter", label: "所在群的群規範", state: .on),
            ])
    }

    /// 最大級別：開一個部門（水平線隔開的那一塊）。
    func addDepartment() {
        deptCount += 1
        let roleID = "role-dept-\(deptCount)"
        let folder = BotFolder(id: "folder-dept-\(deptCount)", name: "新部門 \(deptCount)", roleID: roleID)
        spaces[spaceIndex].roles.append(makeClosedRole(id: roleID, name: folder.name))
        spaces[spaceIndex].folders.append(folder)
        expandedFolderIDs.insert(folder.id)
        openRoleSettings(folderID: folder.id)
    }

    /// 部門底下開一個小組。
    func addTeam(in departmentID: String) {
        teamCount += 1
        let roleID = "role-team-\(teamCount)"
        let folder = BotFolder(
            id: "folder-team-\(teamCount)", name: "新小組 \(teamCount)", roleID: roleID,
            charter: "還沒寫小組規範。寫好之後，進來的 bot 會自動載入。")
        spaces[spaceIndex].roles.append(makeClosedRole(id: roleID, name: folder.name))
        mutateFolder(departmentID) { $0.folders.append(folder) }
        expandedFolderIDs.insert(departmentID)
        selectTeam(folder.id)
    }

    /// 在這個部門／小組裡加一隻常駐 bot：直接走六步，資料夾先選好。
    func startWizardForNewBot(in folderID: String) {
        wizardSourceTempID = nil
        wizardStep = 0
        wizardName = ""
        wizardEmoji = "🤖"
        wizardEngine = BotStudioFixture.engines[0]
        wizardDuty = ""
        wizardFolderID = folderID
        wizardSkills = []
        mode = .wizard
    }

    /// 這個資料夾是不是最大級別（部門）。
    func isDepartment(_ id: String) -> Bool {
        space.folders.contains { $0.id == id }
    }

    // MARK: - 私訊

    func toggleDM() {
        dmOpen.toggle()
        if !dmOpen { dmTargetID = nil }
    }

    func closeDM() {
        dmOpen = false
        dmTargetID = nil
    }

    func openDM(_ id: String) { dmTargetID = id }

    // MARK: - 綁工作環境

    func startBind() {
        bindPhase = .compose
        bindPrompt = ""
        bindTranscript = []
        bindQuestions = []
        bindPlan = []
        bindName = ""
        bindTarget = ""
        mode = .bind
    }

    var bindReady: Bool { !bindPrompt.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 跟你談的那隻（nil＝當場開一隻新的）。
    var bindPartner: BotUnit? { bot(bindPartnerID) }

    var bindPartnerName: String { bindPartner?.name ?? "新 bot" }
    var bindPartnerEmoji: String { bindPartner?.emoji ?? "🤖" }

    /// 送出：bot 一律先做 plan，不動手（展示資料）。
    func submitBind() {
        let text = bindPrompt.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        bindTranscript.append(BotStudioSay(emoji: "🧑", who: "你", text: text))
        bindTranscript.append(BotStudioSay(
            emoji: bindPartnerEmoji, who: bindPartnerName,
            text: "我先不動手。有幾件事要先跟你確認，確認完我給你一份 plan，你點頭我才開始。"))
        bindQuestions = BotStudioFixture.clarifyingQuestions
        bindPlan = BotStudioFixture.draftPlan
        bindPhase = .plan
        bindPrompt = ""
    }

    /// 再談談：回到輸入框補充，plan 留著。
    func resumeBindTalk() { bindPhase = .compose }

    /// 位置寫法自己看得出是哪一種，不用你先選（本機／別人家／還沒成形）。
    private func inferKind(_ target: String) -> BotStudioKind {
        let t = target.lowercased()
        if t.isEmpty { return .draft }
        if t.contains("127.0.0.1") || t.contains("localhost") || t.hasPrefix("0.0.0.0") { return .local }
        if t.hasPrefix("~") || t.hasPrefix("/") { return .draft }
        return .foreign
    }

    /// 照這個 plan 開始：在這個 space 加一間工作室（view-local，關掉就沒了）。
    func finishBind() {
        let name = bindName.trimmingCharacters(in: .whitespaces)
        let target = bindTarget.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            userStudioCount += 1
            let studio = BotStudio(
                id: "studio-user-\(userStudioCount)",
                name: name,
                emoji: "🧩",
                target: target.isEmpty ? "還沒指定位置" : target,
                kind: inferKind(target),
                health: .off,
                canvasTitle: "\(name)・還沒接上",
                canvasCells: [],
                say: BotStudioSay(
                    emoji: bindPartnerEmoji, who: bindPartnerName,
                    text: "plan 收到了。等你把位置和權限給我，我再開始；在那之前這裡是空的。"))
            spaces[spaceIndex].studios.append(studio)
            selectedStudioID = studio.id
        }
        bindPhase = .compose
        bindName = ""
        bindTarget = ""
        mode = .studio
    }

    // MARK: - 臨時工與六步

    /// 側欄的 create bot：生一隻臨時工（不留記憶、只能動暫存區），不跳表單。
    func createTempBot() {
        createdCount += 1
        let temp = BotTemp(
            id: "temp-created-\(createdCount)",
            name: "臨時 bot \(createdCount)",
            emoji: "⚡",
            task: "還沒指定・做完即棄")
        spaces[spaceIndex].temps.append(temp)
    }

    /// 拖進主清單／右鍵轉常駐：這一刻才跳六步。
    func startWizard(tempID: String) {
        guard let temp = space.temps.first(where: { $0.id == tempID }) else { return }
        wizardSourceTempID = tempID
        wizardStep = 0
        wizardName = temp.name.replacingOccurrences(of: "臨時 ", with: "")
        wizardEmoji = temp.emoji == "⚡" ? "🤖" : temp.emoji
        wizardEngine = BotStudioFixture.engines[0]
        wizardDuty = temp.task
        wizardFolderID = wizardFolderID ?? space.folders.first?.id
        wizardSkills = []
        mode = .wizard
    }

    func wizardGo(_ step: Int) { wizardStep = min(max(0, step), 5) }

    func toggleWizardSkill(_ name: String) {
        if wizardSkills.contains(name) { wizardSkills.remove(name) } else { wizardSkills.insert(name) }
    }

    /// 六步完成（展示）：臨時工離開臨時工區，變成常駐列。
    func finishWizard() {
        if let id = wizardSourceTempID {
            spaces[spaceIndex].temps.removeAll { $0.id == id }
        }
        let unit = BotUnit(
            id: "bot-promoted-\(promoted.count + 1)",
            name: wizardName.isEmpty ? "新 bot" : wizardName,
            emoji: wizardEmoji,
            duty: wizardDuty,
            health: .run,
            engine: wizardEngine,
            permissionBrief: "沿用「\(role(forFolder: wizardFolderID)?.name ?? "—")」",
            visionBrief: "看得到 \(folderPath(wizardFolderID ?? "")) 的筆記")
        promoted.append(unit)
        if let fid = wizardFolderID { promotedFolderID[unit.id] = fid }
        wizardSourceTempID = nil
        selectBot(unit.id)
    }

    func cancelWizard() {
        wizardSourceTempID = nil
        mode = .studio
    }

    // MARK: - 釘選

    func isPinned(_ id: String) -> Bool { space.pinnedIDs.contains(id) }

    func togglePin(_ id: String) {
        if let i = spaces[spaceIndex].pinnedIDs.firstIndex(of: id) {
            spaces[spaceIndex].pinnedIDs.remove(at: i)
        } else {
            spaces[spaceIndex].pinnedIDs.append(id)
        }
    }

    /// 釘選項可以是 bot 或工作室。
    enum PinnedItem: Identifiable {
        case bot(BotUnit)
        case studio(BotStudio)
        var id: String {
            switch self {
            case .bot(let b): b.id
            case .studio(let s): s.id
            }
        }
    }

    var pinnedItems: [PinnedItem] {
        space.pinnedIDs.compactMap { id in
            if let b = allBots.first(where: { $0.id == id }) { return .bot(b) }
            if let s = studios.first(where: { $0.id == id }) { return .studio(s) }
            return nil
        }
    }
}
