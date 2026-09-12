import XCTest
@testable import Tatwo2

/// Gen-5 工作室狀態機（2026-09-09 使用者收斂的層級與規則）。
@MainActor
final class BotStudioStateTests: XCTestCase {

    private func makeState(_ index: Int = 0) -> BotStudioState { BotStudioState(spaceIndex: index) }

    // MARK: 層級：space → 工作室

    func testSpacesStartWithNoStudioSoTheUserAddsTheirOwn() {
        let s = makeState()
        XCTAssertEqual(s.space.id, "space-tattoo")
        XCTAssertTrue(s.studios.isEmpty, "2026-09-09 使用者：先清空，之後自己加")
        XCTAssertNil(s.studio)
    }

    func testSwitchingSpaceClearsSelectionAndLandsOnTheStudioSlot() {
        let s = makeState()
        s.selectBot("bot-po")
        s.selectSpace(1)
        XCTAssertEqual(s.space.id, "space-jns")
        XCTAssertNil(s.selectedBotID)
        XCTAssertEqual(s.mode, .studio)
    }

    func testEmptySpaceShowsTheEmptyStateInsteadOfForcingTheBindFlow() {
        let s = makeState()
        s.selectSpace(2)
        XCTAssertTrue(s.studios.isEmpty)
        XCTAssertEqual(s.mode, .studio, "空的就顯示空狀態卡，不要硬把人推進綁定流程")
    }

    func testOpeningAStudioLeavesTheThread() {
        let s = makeState()
        s.startBind()
        s.bindPrompt = "接一個本機後台"
        s.submitBind()
        s.bindName = "本地後台"
        s.bindTarget = "127.0.0.1:5173"
        s.finishBind()
        guard let created = s.studios.first else { return XCTFail("沒建起來") }
        s.selectBot("bot-po")
        XCTAssertEqual(s.mode, .thread)
        s.openStudio(created.id)
        XCTAssertEqual(s.mode, .studio)
        XCTAssertEqual(s.selectedStudioID, created.id)
        XCTAssertNil(s.selectedBotID)
    }

    // MARK: 綁定類型：能力要講白

    func testForeignStudioAlwaysCarriesTheNotice() {
        let foreign = BotStudio(id: "x", name: "校長雲", emoji: "🏫",
                                target: "cloud.jretc.com.tw", kind: .foreign)
        let local = BotStudio(id: "y", name: "後台", emoji: "🎨",
                              target: "127.0.0.1:5173", kind: .local)
        XCTAssertNotNil(foreign.notice, "別人家的系統一定要有黃色提醒")
        XCTAssertNil(local.notice)
        XCTAssertNotNil(BotStudioKind.foreign.cannot)
        XCTAssertNil(BotStudioKind.local.cannot)
    }

    /// 位置寫法自己看得出是哪一種，不用使用者先選形式。
    func testKindIsInferredFromWhereItLivesNotAskedUpFront() {
        let s = makeState()
        func make(_ target: String) -> BotStudio? {
            s.startBind(); s.bindPrompt = "接東西"; s.submitBind()
            s.bindName = "測試 \(target)"; s.bindTarget = target
            s.finishBind()
            return s.studios.last
        }
        XCTAssertEqual(make("127.0.0.1:5173")?.kind, .local)
        XCTAssertEqual(make("cloud.jretc.com.tw")?.kind, .foreign)
        XCTAssertEqual(make("~/tattoo-cms")?.kind, .draft)
        XCTAssertEqual(make("")?.kind, .draft)
    }

    // MARK: 資料夾：可再深一層，一隻 bot 一個資料夾

    func testFoldersNestAtLeastTwoLevelsAndPathReadsAsBreadcrumb() {
        let s = makeState()
        XCTAssertTrue(s.allFolders.contains { $0.id == "folder-frontend" })
        XCTAssertEqual(s.folderPath("folder-frontend"), "部門 1 › 小組 1")
        XCTAssertEqual(s.parentFolder(of: "folder-frontend")?.id, "folder-site")
        XCTAssertNil(s.parentFolder(of: "folder-site"))
    }

    func testEachBotBelongsToExactlyOneFolder() {
        let s = makeState()
        var owners: [String: Int] = [:]
        for folder in s.allFolders {
            for bot in folder.bots { owners[bot.id, default: 0] += 1 }
        }
        for (id, count) in owners {
            XCTAssertEqual(count, 1, "\(id) 出現在 \(count) 個資料夾，權限來源不唯一")
        }
    }

    func testATeamIsItselfTheGroupChat() {
        let s = makeState()
        let team = s.folder("folder-frontend")
        XCTAssertEqual(team?.bots.count, 3, "小組裡就是全部一起，不再分出「群」那一層")
        XCTAssertFalse(team?.charter.isEmpty ?? true, "小組規範要有內容，進來才會馬上進入狀況")
    }

    // MARK: 身份組：權限 × 視野；子層只能更嚴

    func testRoleHasBothAxes() {
        let s = makeState()
        let role = s.role(forFolder: "folder-site")
        XCTAssertEqual(role?.name, "部門 1 的身份組")
        XCTAssertFalse(role?.permissions.isEmpty ?? true)
        XCTAssertFalse(role?.vision.isEmpty ?? true)
    }

    func testChildFolderInheritsAndCannotWiden() {
        let s = makeState()
        let child = s.role(forFolder: "folder-frontend")
        let inherited = child?.permissions.filter { $0.state == .inherited } ?? []
        XCTAssertFalse(inherited.isEmpty, "子資料夾要標出哪些是繼承來的")
        guard let role = child, let grant = inherited.first else { return XCTFail("缺繼承條目") }
        s.toggleGrant(role: role, grant: grant)
        XCTAssertEqual(s.grantState(role: role, grant: grant), .off, "繼承的只能關掉")
        s.toggleGrant(role: role, grant: grant)
        XCTAssertEqual(s.grantState(role: role, grant: grant), .inherited, "關掉再點回去仍是繼承，不會變成自己打開")
    }

    func testVisionOffMeansTheBotDoesNotEvenKnowItExists() {
        let s = makeState()
        let role = s.role(forFolder: "folder-site")
        let other = role?.vision.first { $0.id == "v-other" }
        XCTAssertEqual(other?.state, .off, "認知隔離：這個部門看不到別的部門")
    }

    // MARK: create bot ＝ 生臨時工；轉常駐才走六步

    func testCreateBotProducesTempWorkerWithoutAnyForm() {
        let s = makeState()
        let before = s.space.temps.count
        s.createTempBot()
        XCTAssertEqual(s.space.temps.count, before + 1)
        XCTAssertEqual(s.mode, .studio, "隨手生一隻不該把使用者丟進表單")
    }

    func testPromotingATempWorkerOpensTheSixStepWizard() {
        let s = makeState()
        s.createTempBot()
        guard let temp = s.space.temps.last else { return XCTFail("沒有臨時工") }
        s.startWizard(tempID: temp.id)
        XCTAssertEqual(s.mode, .wizard)
        XCTAssertEqual(s.wizardStep, 0)
        XCTAssertEqual(s.wizardSourceTempID, temp.id)
    }

    func testFinishingWizardMovesTempOutOfTempAreaIntoTheChosenFolder() {
        let s = makeState()
        s.createTempBot()
        guard let temp = s.space.temps.last else { return XCTFail("沒有臨時工") }
        s.startWizard(tempID: temp.id)
        s.wizardName = "封面 bot"
        s.wizardFolderID = "folder-frontend"
        s.finishWizard()
        XCTAssertFalse(s.space.temps.contains { $0.id == temp.id }, "轉常駐後要離開臨時工區")
        XCTAssertTrue(s.allBots.contains { $0.name == "封面 bot" })
        XCTAssertEqual(s.mode, .thread)
    }

    func testCancellingWizardKeepsTheTempWorker() {
        let s = makeState()
        s.createTempBot()
        let before = s.space.temps.count
        guard let temp = s.space.temps.last else { return XCTFail("沒有臨時工") }
        s.startWizard(tempID: temp.id)
        s.cancelWizard()
        XCTAssertEqual(s.space.temps.count, before)
        XCTAssertNil(s.wizardSourceTempID)
    }

    // MARK: 小組進去看、space 設定

    func testTeamsAreOpenedNotExpanded() {
        let s = makeState()
        s.selectTeam("folder-frontend")
        XCTAssertEqual(s.mode, .team)
        XCTAssertEqual(s.selectedTeamID, "folder-frontend")
        XCTAssertNil(s.selectedBotID, "進小組先看全員，不預選 bot")
        XCTAssertFalse(s.expandedFolderIDs.contains("folder-frontend"), "小組不在側欄展開")
        XCTAssertEqual(s.teamBots("folder-frontend").count, 3)
    }

    func testTalkingInATeamGoesToTheTeamNotABot() {
        let s = makeState()
        s.selectTeam("folder-frontend")
        s.threadDraft = "這篇今天要出"
        s.sendThreadDraft()
        XCTAssertEqual(s.extraSays(for: "folder-frontend").count, 2, "你的話＋回應都掛在小組上")
        XCTAssertTrue(s.threadDraft.isEmpty)
    }

    func testOnlyDepartmentsExpandInTheSidebar() {
        let s = makeState()
        XCTAssertTrue(s.expandedFolderIDs.contains("folder-site"), "部門預設展開")
        XCTAssertFalse(s.expandedFolderIDs.contains("folder-frontend"))
    }

    func testSpaceHeaderOpensSpaceSettingsAndCanRename() {
        let s = makeState()
        s.openSpaceSettings()
        XCTAssertEqual(s.mode, .spaceSettings)
        s.renameSpace("刺青總部")
        XCTAssertEqual(s.space.name, "刺青總部")
        s.renameSpace("   ")
        XCTAssertEqual(s.space.name, "刺青總部", "空白名字不覆蓋")
    }

    // MARK: 每一層自己的 ＋（部門／小組／群／bot）

    func testAddDepartmentCreatesATopLevelBlockWithEverythingClosed() {
        let s = makeState()
        let before = s.space.folders.count
        s.addDepartment()
        XCTAssertEqual(s.space.folders.count, before + 1)
        guard let dept = s.space.folders.last else { return XCTFail("沒建起來") }
        XCTAssertTrue(s.isDepartment(dept.id))
        let role = s.role(forFolder: dept.id)
        XCTAssertNotNil(role)
        XCTAssertTrue(role?.permissions.allSatisfy { $0.state == .off } ?? false, "新部門權限一律從全關開始")
        XCTAssertEqual(s.mode, .role, "建完直接帶去設身份組")
    }

    func testAddTeamNestsUnderTheDepartment() {
        let s = makeState()
        s.addTeam(in: "folder-ledger")
        let dept = s.space.folders.first { $0.id == "folder-ledger" }
        XCTAssertEqual(dept?.folders.count, 1)
        guard let team = dept?.folders.first else { return XCTFail("沒建起來") }
        XCTAssertFalse(s.isDepartment(team.id), "小組不是最大級別")
        XCTAssertEqual(s.folderPath(team.id), "部門 2 › \(team.name)")
    }

    func testNewTeamOpensStraightAwayAndStartsEmpty() {
        let s = makeState()
        s.addTeam(in: "folder-site")
        guard let team = s.folder("folder-site")?.folders.last else { return XCTFail("沒建起來") }
        XCTAssertEqual(s.mode, .team)
        XCTAssertEqual(s.selectedTeamID, team.id)
        XCTAssertTrue(team.bots.isEmpty, "新小組先空著")
        XCTAssertFalse(team.charter.isEmpty, "先放一句規範佔位")
    }

    func testAddingABotFromALevelOpensTheWizardWithThatLevelPreselected() {
        let s = makeState()
        s.startWizardForNewBot(in: "folder-backend")
        XCTAssertEqual(s.mode, .wizard)
        XCTAssertEqual(s.wizardStep, 0)
        XCTAssertNil(s.wizardSourceTempID, "這條路不是從臨時工來的")
        XCTAssertEqual(s.wizardFolderID, "folder-backend")
        s.wizardName = "測試 bot"
        s.finishWizard()
        XCTAssertTrue(s.allBots.contains { $0.name == "測試 bot" })
    }

    // MARK: 綁工作環境三段流

    func testBindStartsAsAConversationNotAForm() {
        let s = makeState()
        s.startBind()
        XCTAssertEqual(s.mode, .bind)
        XCTAssertEqual(s.bindPhase, .compose)
        XCTAssertTrue(s.bindTranscript.isEmpty)
        XCTAssertFalse(s.bindReady, "還沒講話就不能送出")
    }

    func testSubmittingAlwaysProducesAPlanFirstAndNeverActs() {
        let s = makeState()
        let before = s.studios.count
        s.startBind()
        s.bindPrompt = "幼兒園的校長雲我用很多年了，想要有人幫我把報名表填進去"
        XCTAssertTrue(s.bindReady)
        s.submitBind()
        XCTAssertEqual(s.bindPhase, .plan)
        XCTAssertEqual(s.bindTranscript.count, 2, "你的話＋bot 的回應")
        XCTAssertFalse(s.bindQuestions.isEmpty, "bot 要先問清楚部署想像")
        XCTAssertFalse(s.bindPlan.isEmpty)
        XCTAssertTrue(s.bindPrompt.isEmpty, "送出後輸入框要清空")
        XCTAssertEqual(s.studios.count, before, "只有 plan，不真的接上任何東西")
    }

    func testTalkPartnerDefaultsToANewBotAndCanBeAnExistingOne() {
        let s = makeState()
        s.startBind()
        XCTAssertNil(s.bindPartnerID)
        XCTAssertEqual(s.bindPartnerName, "新 bot")
        s.bindPartnerID = "bot-po"
        XCTAssertEqual(s.bindPartnerName, "PO 文 bot")
    }

    func testResumingTalkKeepsThePlanOnScreen() {
        let s = makeState()
        s.startBind()
        s.bindPrompt = "想接一個本機跑的後台"
        s.submitBind()
        s.resumeBindTalk()
        XCTAssertEqual(s.bindPhase, .compose)
        XCTAssertFalse(s.bindPlan.isEmpty, "回去補充時 plan 不該消失")
        XCTAssertEqual(s.bindTranscript.count, 2)
    }

    func testFinishBindAddsTheStudioOnlyWhenItWasNamed() {
        let s = makeState()
        s.startBind(); s.bindPrompt = "測試"; s.submitBind()
        s.finishBind()
        XCTAssertTrue(s.studios.isEmpty, "沒給名字就不留下任何東西")

        s.startBind(); s.bindPrompt = "測試"; s.submitBind()
        s.bindName = "校長雲"
        s.finishBind()
        XCTAssertEqual(s.studios.count, 1)
        XCTAssertEqual(s.studios.first?.name, "校長雲")
        XCTAssertEqual(s.studios.first?.health, .off, "剛建起來還沒接上，燈是暗的")
        XCTAssertEqual(s.mode, .studio)
    }

    // MARK: 釘選

    func testPinsAreScopedToTheirOwnSpace() {
        let s = makeState()
        XCTAssertTrue(s.isPinned("bot-ledger"))
        s.selectSpace(1)
        XCTAssertFalse(s.isPinned("bot-ledger"), "釘選只在自己這個 space 有效")
    }

    func testPinnedItemsResolveBothBotsAndStudios() {
        let s = makeState()
        s.startBind(); s.bindPrompt = "接東西"; s.submitBind()
        s.bindName = "本地後台"; s.bindTarget = "127.0.0.1:5173"
        s.finishBind()
        guard let created = s.studios.first else { return XCTFail("沒建起來") }
        s.togglePin(created.id)
        let kinds = s.pinnedItems.map { item -> String in
            switch item {
            case .bot: "bot"
            case .studio: "studio"
            }
        }
        XCTAssertEqual(kinds.sorted(), ["bot", "studio"], "釘選要能同時放 bot 和工作室")
    }

    func testTogglePinAddsAndRemoves() {
        let s = makeState()
        s.togglePin("bot-art")
        XCTAssertTrue(s.isPinned("bot-art"))
        s.togglePin("bot-art")
        XCTAssertFalse(s.isPinned("bot-art"))
    }
}
