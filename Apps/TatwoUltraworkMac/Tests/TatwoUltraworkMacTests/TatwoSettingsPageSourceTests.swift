import XCTest

final class TatwoSettingsPageSourceTests: XCTestCase {
    private var repoRoot: URL {
        ChatPageSourceScanner.repoRoot()
    }

    private var settingsSource: String {
        get throws {
            try ChatPageSourceScanner.readRelative(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageSettings.swift",
                repoRoot: repoRoot
            )
        }
    }

    func testSettingsNavigationIncludesTatwoIslandAfterIssueList() throws {
        let source = try settingsSource
        let section = try XCTUnwrap(source.slice(from: "enum Section", through: "@State private var section"))
        let issue = try XCTUnwrap(section.range(of: "case issueList"))
        let island = try XCTUnwrap(section.range(of: "case tatwoIsland"))

        XCTAssertLessThan(issue.lowerBound, island.lowerBound)
        XCTAssertTrue(section.contains("case .issueList: \"Issue List\""))
        XCTAssertTrue(section.contains("case .tatwoIsland: \"Tatwo Island\""))
        XCTAssertTrue(section.contains("case .tatwoIsland: \"capsule\""))
    }

    func testTatwoIslandSettingsPageIsBlankPlaceholderWithoutSwitches() throws {
        let source = try settingsSource
        let page = try XCTUnwrap(
            source.slice(
                from: "private var tatwoIslandContent: some View",
                through: "private func settingsRow"
            )
        )

        XCTAssertTrue(page.contains("Island 設定開關預留區"))
        XCTAssertTrue(page.contains("目前沒有設定項目"))
        XCTAssertTrue(page.contains("Tatwo Island 設定空白分頁"))
        XCTAssertFalse(page.contains("Toggle("))
        XCTAssertFalse(page.contains("Picker("))
    }

    /// 2026-08-21 使用者裁決修約：「左下角的 tatwo os 可點擊移除，只保留
    /// 左列分頁裡面的 tatwo os」——推翻舊的「無側欄也要保留浮動入口」。
    /// 新合約：浮動字標不得回來；sidebar 內那份唯一入口必須存在且可開
    /// OS 選單。
    func testChatModeTatwoOSEntryLivesOnlyInSidebar() throws {
        let source = try ChatPageSourceScanner.readRelative(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage.swift",
            repoRoot: repoRoot
        )
        let layout = try XCTUnwrap(
            source.slice(
                from: "if rightPanelLayout.showsMainContent",
                through: "// 額度 Live quota 浮層"
            )
        )
        XCTAssertFalse(
            layout.contains("chatModeOSMenuButton"),
            "左下角浮動 TATWO OS 字標已被使用者裁決移除，不得回歸")

        let sidebarEntry = try XCTUnwrap(
            source.slice(
                from: "// 左下角統一入口：TATWO OS 系統布標",
                through: "userRowTrailingControls"
            )
        )
        XCTAssertTrue(sidebarEntry.contains("showOSMenu.toggle()"))
        XCTAssertTrue(sidebarEntry.contains("TatwoOSMark("))
    }
}
