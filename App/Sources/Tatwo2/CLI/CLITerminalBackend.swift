// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/CLITerminalBackend.swift；改動 2 行（原因：加入來源標記；移除舊 Core import，改由 Facade 同名假資料型別供應）
import Foundation

/// CLI 分頁終端的後端膠合層。
///
/// 兩種後端並存：
/// - **PTY（預設）**：`TatwoNativePTYTerminalSession`，forkpty 真終端。
///   zsh 認得它是 tty → prompt、色彩、Ctrl-C、方向鍵、resize 全部是真的。
/// - **pipe（fallback，保留不刪）**：`TatwoNativeTerminalSession`，管線假終端。
///   行為受限（無 tty、無訊號、無 winsize），但不依賴 forkpty，
///   PTY 若在某些環境出問題時可用 env 一鍵切回。
///
/// ChatPage 只跟 `TatwoCLITerminalHandle` 打交道，不再直接持有任一種 session，
/// 兩者的 API 差異（sendLine 的 echo、resize 有無）都收在這裡。

enum TatwoCLITerminalBackendKind: String, Equatable, CaseIterable {
    case pty
    case pipe
}

enum TatwoCLITerminalBackendPolicy {
    /// 預設走 PTY；`TATWO_ULTRAWORK_CLI_PTY=0` 切回 pipe fallback。
    /// 用「非 0 即開」而不是「等於 1 才開」，和既有 `TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME` 同一慣例。
    static func kind(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TatwoCLITerminalBackendKind {
        environment["TATWO_ULTRAWORK_CLI_PTY"] == "0" ? .pipe : .pty
    }
}

/// 可被顯式終止的終端。抽成協定是為了讓收尾邏輯能用 spy 測試，
/// 不必在單元測試裡真的 forkpty 生子程序。
@MainActor
protocol TatwoCLITerminalTerminating: AnyObject {
    func terminate()
}

/// CLI 終端的顯式收尾。
///
/// 使用者規格「中斷不得靜默遺失或雙重執行」：確認關窗後，CLI 分頁裡正在跑的 shell
/// 不能只靠 `ChatPageModel` 的 dealloc 收屍——視窗 `isReleasedWhenClosed = false`，
/// dealloc 何時發生（甚至是否發生）從原始碼無法證明，等於靜默遺失。
/// 這裡走 sol 修好的 signal 路徑（SIGHUP → 0.15s 後補 SIGTERM，含 process group）。
@MainActor
enum TatwoCLITerminalTeardown {
    /// 收掉傳入的所有終端，回傳實際收掉的數量。
    ///
    /// 呼叫端負責在收完後清空自己的字典——清空後再呼叫一次會收到空陣列、回傳 0，
    /// 這就是「不雙重執行」的保證。
    @discardableResult
    static func terminateAll(_ handles: [any TatwoCLITerminalTerminating]) -> Int {
        for handle in handles {
            handle.terminate()
        }
        return handles.count
    }
}

/// 一個 CLI 分頁的終端把手。包住 PTY 或 pipe，對外只露出 ChatPage 需要的動作。
@MainActor
final class TatwoCLITerminalHandle: TatwoCLITerminalTerminating {
    enum Backend {
        case pty(TatwoNativePTYTerminalSession)
        case pipe(TatwoNativeTerminalSession)
    }

    let backend: Backend

    var kind: TatwoCLITerminalBackendKind {
        switch backend {
        case .pty: .pty
        case .pipe: .pipe
        }
    }

    /// PTY 專用：給 `NativeTerminalPTYView` 綁按鍵與 resize。pipe 後端回 nil。
    var ptySession: TatwoNativePTYTerminalSession? {
        switch backend {
        case .pty(let session): session
        case .pipe: nil
        }
    }

    init(backend: Backend) {
        self.backend = backend
    }

    /// 依 policy 建一個後端並接好 callback。
    ///
    /// PTY 的 onUpdate/onStatus 本來就已經切到 main queue 才回呼，
    /// 這裡仍統一包一層 `Task { @MainActor }`，讓兩種後端在呼叫端看起來一致。
    static func make(
        launch: TatwoNativeTerminalLaunch,
        kind: TatwoCLITerminalBackendKind = TatwoCLITerminalBackendPolicy.kind(),
        maxLineCount: Int = 1_500,
        throttleInterval: TimeInterval = 0.06,
        onUpdate: @escaping @Sendable ([TatwoTerminalLine]) -> Void,
        onStatus: @escaping @Sendable (TatwoNativeTerminalStatus) -> Void
    ) -> TatwoCLITerminalHandle {
        switch kind {
        case .pty:
            return TatwoCLITerminalHandle(
                backend: .pty(
                    TatwoNativePTYTerminalSession(
                        launch: launch,
                        maxLineCount: maxLineCount,
                        throttleInterval: throttleInterval,
                        onUpdate: onUpdate,
                        onStatus: onStatus)))
        case .pipe:
            return TatwoCLITerminalHandle(
                backend: .pipe(
                    TatwoNativeTerminalSession(
                        launch: launch,
                        maxLineCount: maxLineCount,
                        throttleInterval: throttleInterval,
                        onUpdate: onUpdate,
                        onStatus: onStatus)))
        }
    }

    var isRunning: Bool {
        switch backend {
        case .pty(let session): session.isRunning
        case .pipe(let session): session.isRunning
        }
    }

    func start(seedText: String?) {
        switch backend {
        case .pty(let session): session.start(seedText: seedText)
        case .pipe(let session): session.start(seedText: seedText)
        }
    }

    /// 送一行命令。
    ///
    /// echo 的差異是兩種後端最大的行為分岔：PTY 下 tty 本身就會回顯，
    /// 再自己補一次會變成雙重回顯，所以 PTY 一律不補；pipe 沒有 tty 才需要 app 代打。
    func sendLine(_ text: String) {
        switch backend {
        case .pty(let session): session.sendLine(text)
        case .pipe(let session): session.sendLine(text, echo: true)
        }
    }

    func terminate() {
        switch backend {
        case .pty(let session): session.terminate()
        case .pipe(let session): session.terminate()
        }
    }
}
