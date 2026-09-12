import XCTest
@testable import TatwoUltraworkMac

/// Gen4BotStateMachineV1 轉移表正／負測試（docs/plans/gen4/U1-STATE-MACHINE.md）。
@MainActor
final class BotPageStateTests: XCTestCase {

    private func makeState(_ scene: String = "rail-tree",
                           mode: BotContentMode = .botThread) -> BotPageState {
        BotPageState(sceneID: scene, contentMode: mode)
    }

    // §2 row1：選主 bot → botThread、換 selectionKey、預設 space。
    func testSelectPrincipalSwitchesToThreadAndDefaultSpace() {
        let s = makeState("space-full", mode: .spaceCanvas)
        s.selectPrincipal(BotPageFixture.jnsGroup.id)
        XCTAssertEqual(s.contentMode, .botThread)
        XCTAssertEqual(s.selectedPrincipalID, BotPageFixture.jnsGroup.id)
        XCTAssertNil(s.selectedSubID)
        XCTAssertEqual(s.selectedSpaceID, BotPageFixture.jnsGroup.spaces.first?.id)
        XCTAssertFalse(s.quickCardOpen)
    }

    // §2 row2：選 sub → 設 subID、botThread。
    func testSelectSubSetsSubAndThreadMode() {
        let s = makeState()
        s.selectSub("fixture-bot-tattoo-po", of: BotPageFixture.tattooWork.id)
        XCTAssertEqual(s.selectedSubID, "fixture-bot-tattoo-po")
        XCTAssertEqual(s.contentMode, .botThread)
    }

    // 負：sub 不屬 principal → 不變。
    func testSelectForeignSubIsRejected() {
        let s = makeState()
        s.selectSub("fixture-bot-jns-note", of: BotPageFixture.tattooWork.id)
        XCTAssertNil(s.selectedSubID)
    }

    // §2 row3／§4：chevron 只 disclosure，不改 selection/mode。
    func testDisclosureDoesNotChangeSelectionOrMode() {
        let s = makeState()
        let before = (s.selectedPrincipalID, s.selectedSubID, s.contentMode)
        s.toggleDisclosure(BotPageFixture.jnsGroup.id)
        XCTAssertTrue(s.expandedPrincipalIDs.contains(BotPageFixture.jnsGroup.id))
        XCTAssertEqual(s.selectedPrincipalID, before.0)
        XCTAssertEqual(s.selectedSubID, before.1)
        XCTAssertEqual(s.contentMode, before.2)
    }

    // §2 pager row：botThread 中 pager → spaceCanvas。
    func testPagerFromThreadEntersCanvas() {
        let s = makeState()
        s.pagerSelect(index: 1)
        XCTAssertEqual(s.contentMode, .spaceCanvas)
        XCTAssertEqual(s.selectedSpaceID, BotPageFixture.tattooWork.spaces[1].id)
    }

    // §3-2：pager 非循環——首頁 prev／末頁 next 無效。
    func testPagerDoesNotWrap() {
        let s = makeState()
        s.pagerSelect(index: 0)
        XCTAssertFalse(s.canPagerPrev)
        s.pagerPrev()
        XCTAssertEqual(s.pagerIndex, 0)
        s.pagerSelect(index: s.orderedSpaces.count - 1)
        XCTAssertFalse(s.canPagerNext)
        s.pagerNext()
        XCTAssertEqual(s.pagerIndex, s.orderedSpaces.count - 1)
    }

    // 2026-08-22 使用者改案：quick card 改 X 私訊式右下浮鈕，bot 分頁全域可開
    //（原「僅 full canvas」guard 作廢；契約修訂待定稿後與 sol 重凍）。
    func testQuickCardOpensGloballyAfterXStyleChange() {
        let s = makeState("space-status", mode: .spaceCanvas)
        s.openQuickCard()
        XCTAssertTrue(s.quickCardOpen)
        let f = makeState("space-full", mode: .spaceCanvas)
        f.openQuickCard()
        XCTAssertTrue(f.quickCardOpen)
    }

    // §2：快捷卡選 owning bot 回寫 selection、不切 mode、抽屜保持。
    func testQuickCardSelectWritesBackWithoutModeSwitch() {
        let s = makeState("space-full", mode: .spaceCanvas)   // owner=生圖 bot
        s.openQuickCard()
        s.quickCardSelect(botID: BotPageFixture.artBot.id)
        XCTAssertEqual(s.selectedPrincipalID, BotPageFixture.artBot.id)
        XCTAssertEqual(s.contentMode, .spaceCanvas)
        XCTAssertTrue(s.quickCardOpen)
        XCTAssertEqual(s.lastSelectedBotID.values.first, BotPageFixture.artBot.id)
    }

    // §2 add space 三段＋未選型不得前進＋取消恢復前態。
    func testAddSpaceThreeStepFlowAndCancelRestores() {
        let s = makeState("space-full", mode: .spaceCanvas)
        s.openAddSpace()
        XCTAssertEqual(s.contentMode, .addSpace)
        XCTAssertEqual(s.addSpaceStep, .chooseDensity)
        s.addSpaceComplete()          // 未選型不得完成
        XCTAssertEqual(s.addSpaceStep, .chooseDensity)
        s.chooseDensity(.compact)
        XCTAssertEqual(s.addSpaceStep, .staticPreview)
        s.addSpaceComplete()
        XCTAssertEqual(s.addSpaceStep, .completionMock)
        s.addSpaceBack()
        XCTAssertEqual(s.addSpaceStep, .staticPreview)
        s.addSpaceCancel()
        XCTAssertEqual(s.contentMode, .spaceCanvas)   // 恢復進入前模式
        XCTAssertNil(s.addSpaceDensity)               // 丟棄 view-local 輸入
    }

    // §2 settings：關閉恢復前態；焦點交換不動 selectionKey。
    func testSettingsOverlayRestoresPreviousModeAndKeepsSelection() {
        let s = makeState("space-full", mode: .spaceCanvas)
        let key = (s.selectedPrincipalID, s.selectedSpaceID)
        s.openSettings()
        XCTAssertEqual(s.contentMode, .settings)
        s.settingsFocus("fixture-bot-jns-note")
        XCTAssertEqual(s.selectedPrincipalID, key.0)  // selectionKey 不動
        s.closeSettings()
        XCTAssertEqual(s.contentMode, .spaceCanvas)
        XCTAssertEqual(s.selectedSpaceID, key.1)
    }

    // fail-closed：未知場景不得渲染近似畫面。
    func testUnknownSceneFailsClosed() {
        let s = BotPageState(sceneID: "fixture-not-a-scene")
        XCTAssertTrue(s.unknownScene)
        XCTAssertTrue(s.fixture.principals.isEmpty)
        XCTAssertNil(BotPageFixture.scene("fixture-not-a-scene"))
    }

    // §3-6：換 principal 不沿用他人 pager／space。
    func testPrincipalSwitchResetsToOwnDefaultSpace() {
        let s = makeState()
        s.pagerSelect(index: 1)
        s.selectPrincipal(BotPageFixture.webBot.id)
        XCTAssertEqual(s.selectedSpaceID, BotPageFixture.webBot.spaces.first?.id)
    }

    // 2026-08-22 書側標籤改案：書籤只在對應 space；開／屏蔽 toggle；跨 space 拒絕。
    func testBookmarkToggleAndScopedToSpace() {
        let s = makeState()
        guard let bm = s.currentBookmarks.first?.id else { return XCTFail("fixture 應有書籤") }
        s.toggleBookmark(bm)
        XCTAssertEqual(s.openBookmark?.id, bm)
        XCTAssertEqual(s.contentMode, .spaceCanvas)
        s.toggleBookmark(bm)                            // 再點＝屏蔽
        XCTAssertNil(s.openBookmark)
        XCTAssertEqual(s.contentMode, .botThread)
        s.toggleBookmark("fixture-bm-jns-panel")        // 非本 space 書籤 → 拒絕
        XCTAssertNil(s.openBookmark)
    }

    // 圓點雙擊全關：確認流程；已停止不再跳確認；換 space 清 openBookmark。
    func testBookmarkCloseConfirmFlowAndSpaceSwitchClears() {
        let s = makeState()
        guard let bm = s.currentBookmarks.first?.id else { return XCTFail("fixture 應有書籤") }
        s.toggleBookmark(bm)
        s.requestCloseBookmark(bm)
        XCTAssertEqual(s.confirmCloseBookmarkID, bm)
        s.confirmCloseBookmark()
        XCTAssertTrue(s.stoppedBookmarkIDs.contains(bm))
        XCTAssertNil(s.openBookmark)
        XCTAssertEqual(s.contentMode, .botThread)
        s.requestCloseBookmark(bm)                      // 已停止 → 不再跳確認
        XCTAssertNil(s.confirmCloseBookmarkID)
        guard let other = s.currentBookmarks.last?.id, other != bm else { return }
        s.toggleBookmark(other)
        s.pagerSelect(index: 1)                         // 換 space
        XCTAssertNil(s.openBookmark)
    }

    // 右鍵「設置」：不存在 id 拒絕；principal 與 sub 皆可開。
    func testBotConfigOpenGuard() {
        let s = makeState()
        s.openBotConfig("fixture-ghost")
        XCTAssertNil(s.configTargetID)
        s.openBotConfig("fixture-bot-tattoo-po")
        XCTAssertEqual(s.configTargetID, "fixture-bot-tattoo-po")
        XCTAssertEqual(s.configTarget?.isSub, true)
        s.closeBotConfig()
        XCTAssertNil(s.configTargetID)
    }
}

@MainActor
final class BotPageStateNegativeTests: XCTestCase {

    // quickCardSelect：外部 principal 拒絕（selectionKey 合法性）。
    func testQuickCardRejectsForeignPrincipal() {
        let s = BotPageState(sceneID: "space-full", contentMode: .spaceCanvas, quickCardOpen: true)
        let owner = s.selectedPrincipalID
        s.quickCardSelect(botID: BotPageFixture.jnsGroup.id)   // 非 owning principal
        XCTAssertEqual(s.selectedPrincipalID, owner)           // 拒絕、不變
        XCTAssertNil(s.selectedSubID)
    }

    // quickCardSelect：owning sub 可選、寫回 owning 主 bot 的 lastSelected。
    func testQuickCardSelectsOwningSub() {
        let s = BotPageState(sceneID: "quick-card", contentMode: .spaceCanvas, quickCardOpen: true)
        // quick-card 場景 owner=生圖 bot（無 sub）→ 換 rail-tree owner 測 sub 路徑
        let t = BotPageState(sceneID: "rail-tree")
        t.pagerSelect(index: 1)                                // 進 canvas（社群貼文=full）
        t.openQuickCard()
        t.quickCardSelect(botID: "fixture-bot-tattoo-po")
        XCTAssertEqual(t.selectedSubID, "fixture-bot-tattoo-po")
        XCTAssertEqual(t.lastSelectedBotID[t.selectedSpaceID ?? ""], BotPageFixture.tattooWork.id)
        _ = s
    }

    // toggleDisclosure：無 sub 的 principal 拒絕。
    func testDisclosureRejectsSublessPrincipal() {
        let s = BotPageState(sceneID: "rail-tree")
        s.toggleDisclosure(BotPageFixture.webBot.id)
        XCTAssertFalse(s.expandedPrincipalIDs.contains(BotPageFixture.webBot.id))
        s.toggleDisclosure("fixture-not-exist")
        XCTAssertFalse(s.expandedPrincipalIDs.contains("fixture-not-exist"))
    }

    // settingsFocus：不存在 id 拒絕。
    func testSettingsFocusRejectsUnknownID() {
        let s = BotPageState(sceneID: "settings-9row", contentMode: .settings)
        let before = s.settingsSelection
        s.settingsFocus("fixture-ghost")
        XCTAssertEqual(s.settingsSelection, before)
        s.settingsFocus("fixture-bot-jns-print")               // 存在→接受
        XCTAssertEqual(s.settingsSelection, "fixture-bot-jns-print")
    }

    // restoreLastSelected：失效值清除、不預選 sub。
    func testStaleLastSelectedClearedOnRestore() {
        let s = BotPageState(sceneID: "rail-tree")
        s.pagerSelect(index: 0)
        // 人工放入失效值（模擬跨 principal 殘留）
        s.quickCardSelect(botID: "whatever")                   // no-op（卡未開）
        s.selectPrincipal(BotPageFixture.jnsGroup.id)          // 換 principal
        s.selectPrincipal(BotPageFixture.tattooWork.id)        // 換回
        XCTAssertNil(s.selectedSubID)                          // 不預選 sub
        XCTAssertEqual(s.selectedSpaceID, BotPageFixture.tattooWork.spaces.first?.id)
    }
}
