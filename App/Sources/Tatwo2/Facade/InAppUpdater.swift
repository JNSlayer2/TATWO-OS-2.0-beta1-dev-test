import AppKit
import Foundation

/// 一鍵更新：App 內按一下就完成，不需要終端機。
///
/// 憲法第一條——不自己造：真正的下載、校驗、簽章連續性、替換、備份、回復全部仍由
/// 公開倉的 `install.sh` 負責（與一行安裝指令走同一份腳本、同一套信任模型）。
/// 這裡只補 `install.sh` 做不到的一件事：它要求 App 已退出。所以流程是——
///   1. 把一支小 helper 交給 launchd（脫離 App 進程樹），
///   2. App 自己退出，
///   3. helper 等 App 進程消失後執行 `install.sh`（版本釘在使用者看到的那個 tag），
///   4. 成功時 `install.sh` 會開啟新版；失敗時 helper 把舊版開回來，
///   5. 下次啟動讀 `result.json`，把結果顯示在更新卡上。
@MainActor
final class InAppUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case handedOff
        case failed(String)
    }

    static let shared = InAppUpdater()
    static let destinationApp = "/Applications/TATWO OS.app"
    static let helperWaitSeconds = 300

    @Published private(set) var phase: Phase = .idle
    /// 上一次更新的結果（由 helper 寫、本次啟動讀到），給更新卡顯示。
    @Published private(set) var lastResult: String?

    private let fileManager: FileManager
    private let directory: URL

    init(fileManager: FileManager = .default,
         directory: URL? = nil) {
        self.fileManager = fileManager
        self.directory = directory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/TATWO OS/Updater", isDirectory: true)
    }

    var resultURL: URL { directory.appendingPathComponent("result.json") }
    var pendingURL: URL { directory.appendingPathComponent("pending.json") }
    var logURL: URL { directory.appendingPathComponent("update.log") }

    static func installScriptURL(repository: String) -> String {
        "https://raw.githubusercontent.com/\(repository)/main/install.sh"
    }

    /// 由更新卡呼叫。tag 必須是檢查器剛回報的 Release tag；不接受任意輸入。
    func update(to tag: String, repository: String = GitHubReleaseUpdateChecker.defaultRepository) {
        guard phase == .idle || { if case .failed = phase { return true }; return false }() else { return }
        guard tag.range(of: #"^v?[0-9]+[.][0-9]+([.][0-9]+)?([-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil,
              repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        else { phase = .failed("版本或倉庫格式無效"); return }
        phase = .starting
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try? fileManager.removeItem(at: resultURL)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let label = "ai.tatwo.tatwo2.updater.\(stamp)"
            let script = directory.appendingPathComponent("update-\(stamp).sh")
            try Self.helperScript(
                tag: tag, pid: ProcessInfo.processInfo.processIdentifier,
                installURL: Self.installScriptURL(repository: repository),
                resultPath: resultURL.path, logPath: logURL.path,
                destination: Self.destinationApp, label: label
            ).write(to: script, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let pending = ["tag": tag, "startedAt": stamp, "log": logURL.path]
            try JSONSerialization.data(withJSONObject: pending).write(to: pendingURL)

            // launchd 接手：不是 App 的子進程，App 退出後仍存活。
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            launch.arguments = ["submit", "-l", label, "-o", logURL.path, "-e", logURL.path,
                                "--", "/bin/bash", script.path]
            launch.standardInput = FileHandle.nullDevice
            try launch.run()
            launch.waitUntilExit()
            guard launch.terminationStatus == 0 else {
                phase = .failed("無法啟動更新程序（launchctl \(launch.terminationStatus)）")
                try? fileManager.removeItem(at: pendingURL)
                return
            }
            phase = .handedOff
            // 讓畫面先顯示「更新中」再退出；使用者取消結束時 helper 會在等待逾時後放棄。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.terminate(nil)
            }
        } catch {
            phase = .failed("無法準備更新：\(error.localizedDescription)")
            try? fileManager.removeItem(at: pendingURL)
        }
    }

    /// 啟動時呼叫一次：把上一輪 helper 的結果搬進 UI，並清掉檔案。
    func consumeResultOnLaunch() {
        defer { try? fileManager.removeItem(at: resultURL) }
        if let data = try? Data(contentsOf: resultURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ok = object["ok"] as? Bool ?? false
            let tag = object["tag"] as? String ?? ""
            let message = object["message"] as? String ?? ""
            lastResult = ok
                ? "已更新到 \(tag)"
                : "更新 \(tag) 未完成（\(Self.describe(message))）；原版已保留。紀錄：\(logURL.path)"
            try? fileManager.removeItem(at: pendingURL)
            return
        }
        // 有 pending 但沒 result：helper 還在等，或 App 被人手動重開。不擋使用者，只提示。
        if let data = try? Data(contentsOf: pendingURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tag = object["tag"] as? String {
            lastResult = "上次更新 \(tag) 沒有留下結果；若沒有自動完成，請再按一次更新。"
            try? fileManager.removeItem(at: pendingURL)
        }
    }

    static func describe(_ code: String) -> String {
        switch code {
        case "app_still_running": return "App 沒有退出"
        case "download_install_script_failed": return "無法下載安裝腳本"
        case let value where value.hasPrefix("install_failed_exit_"): return "安裝腳本失敗，代碼 \(value.dropFirst("install_failed_exit_".count))"
        default: return code
        }
    }

    // UPDATE-HELPER-BEGIN
    /// helper 本體。只用 macOS 內建指令；所有判斷都交給 install.sh，這裡不重做校驗。
    /// `TATWO2_UPDATE_INSTALL_SCRIPT`（本機檔案路徑）只給測試用，跳過下載。
    static func helperScript(tag: String, pid: Int32, installURL: String,
                             resultPath: String, logPath: String,
                             destination: String, label: String) -> String {
        """
        #!/bin/bash
        set -u
        PID=\(pid)
        TAG='\(tag)'
        INSTALL_URL='\(installURL)'
        RESULT='\(resultPath)'
        LOG='\(logPath)'
        DEST='\(destination)'
        LABEL='\(label)'
        WAIT=\(helperWaitSeconds)
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        write_result() {
          printf '{"ok":%s,"tag":"%s","message":"%s"}\\n' "$1" "$TAG" "$2" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
        }
        finish() {
          # 結果寫完才解除 launchd 登記；remove 會結束自己，所以放到背景。
          ( sleep 1; launchctl remove "$LABEL" ) >/dev/null 2>&1 &
          exit "$1"
        }
        printf '[%s] 等待 TATWO OS（pid %s）退出…\\n' "$(date '+%F %T')" "$PID" >> "$LOG"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt "$WAIT" ]; do sleep 1; i=$((i + 1)); done
        if kill -0 "$PID" 2>/dev/null; then
          write_result false app_still_running
          finish 1
        fi
        if [ -n "${TATWO2_UPDATE_INSTALL_SCRIPT:-}" ]; then
          SCRIPT="$TATWO2_UPDATE_INSTALL_SCRIPT"
        else
          SCRIPT="$(mktemp "${TMPDIR:-/tmp}/tatwo-install.XXXXXX.sh")"
          if ! curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 15 --max-time 60 -o "$SCRIPT" "$INSTALL_URL"; then
            write_result false download_install_script_failed
            [ -d "$DEST" ] && open "$DEST"
            finish 1
          fi
        fi
        printf '[%s] 執行 install.sh（%s）\\n' "$(date '+%F %T')" "$TAG" >> "$LOG"
        TATWO_OS_VERSION="$TAG" bash "$SCRIPT" >> "$LOG" 2>&1
        STATUS=$?
        if [ "$STATUS" -eq 0 ]; then
          write_result true installed
          finish 0
        fi
        write_result false "install_failed_exit_$STATUS"
        [ -d "$DEST" ] && open "$DEST"
        finish 1
        """
    }
    // UPDATE-HELPER-END
}
