import AppKit
import Foundation

/// 「中斷 loops」二次確認閘。
///
/// 在此之前 app 對中斷完全不設防：Cmd+Q 直接結束、關窗直接關、Esc 直接 close()、
/// 停止鍵直接 `model.stop()`。派工跑到一半被誤觸就整批消失。
///
/// 這裡把「要不要攔、攔下來要說什麼」抽成純函式決策表（可測），
/// AppKit 的彈窗只是決策的執行手。

/// 會中斷 loops 的四個入口。
enum TatwoInterruptKind: String, CaseIterable, Equatable {
    /// Cmd+Q / 選單結束 → `applicationShouldTerminate`
    case appTerminate
    /// 關閉視窗（紅燈 / Cmd+W）→ `windowShouldClose`
    case windowClose
    /// Esc → `TatwoWorkOSWindow.cancelOperation`（和關窗同一道閘，不可繞過）
    case escapeClose
    /// composer 停止鍵 → `model.stop()`
    case composerStop
}

/// 攔下來時要顯示的文案。
struct TatwoInterruptPrompt: Equatable {
    let title: String
    let message: String
    /// 確認執行中斷的按鈕字樣（破壞性動作）。
    let confirmTitle: String
    let cancelTitle: String
}

/// 閘門決策：放行，或帶著文案攔下來。
enum TatwoInterruptDecision: Equatable {
    case proceed
    case confirm(TatwoInterruptPrompt)

    var requiresConfirmation: Bool {
        if case .confirm = self { return true }
        return false
    }
}

enum TatwoInterruptGate {

    /// 決策表：
    ///
    /// | 入口              | 有 loops 在跑 | 沒有 loops |
    /// |-------------------|--------------|-----------|
    /// | appTerminate      | 確認         | 放行      |
    /// | windowClose       | 確認         | 放行      |
    /// | escapeClose       | 確認         | 放行      |
    /// | composerStop      | 確認（加註）  | 確認      |
    ///
    /// 結束 app / 關窗在沒有 loops 時放行，是刻意的：否則每次關 app 都要多按一次，
    /// 確認就會被訓練成反射動作，真正該攔的那次也一起被按掉。
    /// 停止鍵則一律確認——它本來就只在有東西在跑時才出現（`model.isRunning`），
    /// 使用者的需求也明寫「中斷的操作全部二次確認」。
    static func decision(
        kind: TatwoInterruptKind,
        snapshot: TatwoLoopsActivitySnapshot
    ) -> TatwoInterruptDecision {
        switch kind {
        case .appTerminate, .windowClose, .escapeClose:
            guard snapshot.isActive else { return .proceed }
            return .confirm(prompt(kind: kind, snapshot: snapshot))
        case .composerStop:
            return .confirm(prompt(kind: kind, snapshot: snapshot))
        }
    }

    static func prompt(
        kind: TatwoInterruptKind,
        snapshot: TatwoLoopsActivitySnapshot
    ) -> TatwoInterruptPrompt {
        let tally = activityTally(snapshot)
        switch kind {
        case .appTerminate:
            return TatwoInterruptPrompt(
                title: "還有 loops 在跑，確定要結束？",
                message: "\(tally)結束 app 會中斷這些派工，未回收的產出會遺失。",
                confirmTitle: "仍要結束",
                cancelTitle: "取消")
        case .windowClose, .escapeClose:
            return TatwoInterruptPrompt(
                title: "還有 loops 在跑，確定要關閉視窗？",
                message: "\(tally)關閉視窗會中斷這些派工，未回收的產出會遺失。",
                confirmTitle: "仍要關閉",
                cancelTitle: "取消")
        case .composerStop:
            let message =
                snapshot.isActive
                ? "\(tally)停止會中斷目前這輪回應與相關派工。"
                : "停止會中斷目前這輪回應。"
            return TatwoInterruptPrompt(
                title: "確定要停止？",
                message: message,
                confirmTitle: "停止",
                cancelTitle: "取消")
        }
    }

    /// 「3 個代理工作中（2 執行中／1 排隊）」這種一眼可讀的計數句。
    static func activityTally(_ snapshot: TatwoLoopsActivitySnapshot) -> String {
        guard snapshot.isActive else { return "" }
        var detail: [String] = []
        if snapshot.runningCount > 0 { detail.append("\(snapshot.runningCount) 執行中") }
        if snapshot.queuedCount > 0 { detail.append("\(snapshot.queuedCount) 排隊") }
        let suffix = detail.isEmpty ? "" : "（\(detail.joined(separator: "／"))）"
        return "目前有 \(snapshot.activeCount) 個代理在動\(suffix)。"
    }
}

@MainActor
enum TatwoInterruptConfirmationPresenter {

    /// 無人值守環境不得跑 modal——否則快照匯出／XCTest 會停在一個沒人按的對話框上直到逾時。
    /// 沿用 `cliRuntimeEnabled` 的偵測慣例（XCTest 環境變數），另留一個給自動化的顯式開關。
    static func isSuppressed(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["TATWO_ULTRAWORK_DISABLE_INTERRUPT_GUARD"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
    }

    /// 走一次閘：不需要確認就直接回 true；需要就跑 modal 問使用者。
    /// 回傳 true = 使用者確認中斷。
    static func confirm(
        kind: TatwoInterruptKind,
        snapshot: TatwoLoopsActivitySnapshot = TatwoLoopsActivityMonitor.loopsInProgressNow(),
        window: NSWindow? = nil
    ) -> Bool {
        guard !isSuppressed() else { return true }
        switch TatwoInterruptGate.decision(kind: kind, snapshot: snapshot) {
        case .proceed:
            return true
        case .confirm(let prompt):
            return runModal(prompt, window: window)
        }
    }

    private static func runModal(_ prompt: TatwoInterruptPrompt, window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: prompt.confirmTitle)
        alert.addButton(withTitle: prompt.cancelTitle)
        // 破壞性按鈕不吃 Return：預設鍵留給「取消」，避免連按 Enter 直接中斷派工。
        alert.buttons.first?.keyEquivalent = ""
        if alert.buttons.count > 1 {
            alert.buttons[1].keyEquivalent = "\r"
        }
        // sheet 需要非同步回呼，這裡的呼叫端（shouldTerminate / shouldClose / 按鈕）要同步答案，
        // 故一律走 app-modal。
        _ = window
        return TatwoModalPanelGate.run({ alert.runModal() }) == .alertFirstButtonReturn
    }
}
