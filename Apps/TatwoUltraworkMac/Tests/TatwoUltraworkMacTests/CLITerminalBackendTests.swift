import AppKit
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

/// 假終端，只記錄被 terminate 幾次——避免測試真的 forkpty 生子程序。
@MainActor
private final class SpyCLITerminal: TatwoCLITerminalTerminating {
    private(set) var terminateCallCount = 0
    func terminate() { terminateCallCount += 1 }
}

/// 容器關閉時 CLI shell 必須被顯式收掉。
///
/// 規格：中斷不得靜默遺失或雙重執行。靠 dealloc 收屍不可證明＝靜默遺失。
@MainActor
final class CLITerminalTeardownTests: XCTestCase {

    func testTerminateAllTerminatesEverySession() {
        let terminals = [SpyCLITerminal(), SpyCLITerminal(), SpyCLITerminal()]
        let count = TatwoCLITerminalTeardown.terminateAll(terminals)

        XCTAssertEqual(count, 3)
        for terminal in terminals {
            XCTAssertEqual(terminal.terminateCallCount, 1, "每個 session 都必須被收掉，且只收一次")
        }
    }

    func testTerminateAllOnEmptyCollectionIsNoOp() {
        XCTAssertEqual(TatwoCLITerminalTeardown.terminateAll([]), 0)
    }

    /// closeContainer 後再關一次（例如 onDisappear 又觸發）不得重複送訊號。
    /// 收尾端清空字典後，第二次拿到的是空集合。
    func testSecondTeardownAfterClearIsNotDoubleExecuted() {
        var live: [any TatwoCLITerminalTerminating] = [SpyCLITerminal(), SpyCLITerminal()]
        let spies = live.compactMap { $0 as? SpyCLITerminal }

        XCTAssertEqual(TatwoCLITerminalTeardown.terminateAll(live), 2)
        live.removeAll()
        XCTAssertEqual(TatwoCLITerminalTeardown.terminateAll(live), 0)

        for spy in spies {
            XCTAssertEqual(spy.terminateCallCount, 1, "不得雙重執行")
        }
    }

    /// 真正的鏈路證明：closeContainer() 會呼叫註冊的收尾 handler，且只呼叫一次。
    /// ChatPage 註冊的 handler 是 `model.shutdownForContainerClose()`
    /// （= stop() + terminateAllCLITerminals()）。
    func testCloseContainerInvokesRegisteredTeardownExactlyOnce() {
        let lifecycle = TatwoRetainedChatLifecycle(initiallySelectedChat: true)
        let terminals = [SpyCLITerminal(), SpyCLITerminal()]
        var stopCallCount = 0

        lifecycle.registerStopHandler {
            stopCallCount += 1
            TatwoCLITerminalTeardown.terminateAll(terminals)
        }

        XCTAssertTrue(lifecycle.closeContainer(), "第一次關閉容器應觸發收尾")
        XCTAssertEqual(stopCallCount, 1)
        for terminal in terminals {
            XCTAssertEqual(terminal.terminateCallCount, 1, "關窗後每個 CLI shell 都必須被收掉")
        }

        XCTAssertFalse(lifecycle.closeContainer(), "重複關閉不應再次收尾")
        XCTAssertEqual(stopCallCount, 1, "不得雙重執行")
        for terminal in terminals {
            XCTAssertEqual(terminal.terminateCallCount, 1)
        }
    }

    /// 活著的視窗正常使用時不得誤殺：沒有關容器就不該有任何 terminate。
    func testTerminalsSurviveWhileContainerStaysOpen() {
        let lifecycle = TatwoRetainedChatLifecycle(initiallySelectedChat: true)
        let terminal = SpyCLITerminal()
        lifecycle.registerStopHandler {
            TatwoCLITerminalTeardown.terminateAll([terminal])
        }

        lifecycle.pageSelectionChanged(isChatSelected: true)
        XCTAssertEqual(terminal.terminateCallCount, 0, "視窗還開著就不能收 shell")
    }
}

/// 終端後端選擇與配色。刻意不在測試裡真的 forkpty（會生子程序），
/// 只測純決策與配色常數。
final class CLITerminalBackendTests: XCTestCase {

    // MARK: - 後端選擇

    func testDefaultsToPTYWhenUnset() {
        XCTAssertEqual(TatwoCLITerminalBackendPolicy.kind(environment: [:]), .pty)
    }

    func testExplicitZeroFallsBackToPipe() {
        XCTAssertEqual(
            TatwoCLITerminalBackendPolicy.kind(environment: ["TATWO_ULTRAWORK_CLI_PTY": "0"]),
            .pipe)
    }

    func testExplicitOneSelectsPTY() {
        XCTAssertEqual(
            TatwoCLITerminalBackendPolicy.kind(environment: ["TATWO_ULTRAWORK_CLI_PTY": "1"]),
            .pty)
    }

    /// 「非 0 即開」——和既有 TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME 同一慣例，
    /// 亂填的值不該把使用者踢回 pipe 假終端。
    func testUnrecognisedValueStillSelectsPTY() {
        for value in ["", "true", "yes", "2", "off"] {
            XCTAssertEqual(
                TatwoCLITerminalBackendPolicy.kind(environment: ["TATWO_ULTRAWORK_CLI_PTY": value]),
                .pty,
                "value=\(value) 只有明確的 \"0\" 才該退回 pipe")
        }
    }

    func testBothBackendKindsAreReachable() {
        XCTAssertEqual(Set(TatwoCLITerminalBackendKind.allCases), [.pty, .pipe])
    }

    // MARK: - 配色

    /// terminalBlack 必須逐項等於 PTY view 改造前的原值，
    /// 否則這個 view 單獨使用時外觀會被我的淺色改造波及。
    func testTerminalBlackPaletteMatchesPreRefactorValues() {
        let palette = NativeTerminalPTYPalette.terminalBlack
        XCTAssertEqual(palette.background, .black)
        XCTAssertEqual(palette.defaultInk, .white)
        XCTAssertEqual(palette.deepDim, NSColor(calibratedWhite: 0.20, alpha: 1))
        XCTAssertEqual(palette.dim, NSColor(calibratedWhite: 0.42, alpha: 1))
        XCTAssertEqual(palette.faint, NSColor(calibratedWhite: 0.82, alpha: 1))
        XCTAssertEqual(palette.strong, .white)
        // darkening=0 → 六組彩色維持原值不被混黑。
        XCTAssertEqual(palette.chromaticDarkening, 0)
    }

    /// CLI 分頁走淺色玻璃（使用者回饋 #33）：不可有不透明背景把玻璃蓋掉。
    func testLightGlassPaletteDrawsNoOpaqueBackground() {
        let palette = NativeTerminalPTYPalette.lightGlass
        XCTAssertNil(palette.background)
        XCTAssertGreaterThan(palette.chromaticDarkening, 0)
    }

    /// 淺底的明暗階序必須相對黑底翻轉，否則字會糊在底上。
    func testLightGlassInkIsDarkerThanItsDimTones() {
        let palette = NativeTerminalPTYPalette.lightGlass
        XCTAssertLessThan(
            palette.defaultInk.whiteComponent, palette.dim.whiteComponent,
            "正文墨色必須比次要字深")
        XCTAssertLessThan(
            palette.strong.whiteComponent, palette.defaultInk.whiteComponent,
            "強調字必須比正文更深")
    }

    /// CLI 終端字級必須跟 Chat 的 meta/mono 慣例，不能比 transcript 正文還大。
    @MainActor
    func testTerminalDefaultFontMatchesChatMonoIdiom() {
        XCTAssertEqual(NativeTerminalPTYView.defaultFontSize, ChatTypography.terminalPointSize)
        XCTAssertEqual(ChatTypography.terminalPointSize, TatwoChatTranscriptVisualMetrics.transcriptMetaPointSize)
        XCTAssertLessThan(
            ChatTypography.terminalPointSize,
            TatwoChatTranscriptVisualMetrics.transcriptPointSize)
        XCTAssertEqual(NativeTerminalPTYView.defaultContentInset, ChatTypography.terminalContentInset)
        XCTAssertGreaterThanOrEqual(ChatTypography.terminalContentInset, 10)
        XCTAssertLessThanOrEqual(ChatTypography.terminalContentInset, 12)
    }
}
