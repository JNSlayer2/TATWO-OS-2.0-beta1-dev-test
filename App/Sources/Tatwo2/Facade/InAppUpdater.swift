import AppKit
import Foundation
import CryptoKit

/// 先在 App 內下載校驗，再交給 launchd 執行原安裝器；簽章、替換與回復仍由 install.sh 負責。
private final class UpdateDownloadProgress: NSObject, URLSessionDownloadDelegate {
    let report: @Sendable (Int64, Int64) -> Void
    init(report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

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

    @Published private(set) var downloadProgress: Double?
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    private var download: Task<Void, Never>?
    private var downloadID = UUID()
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
    func update(to tag: String, repository: String? = nil) {
        let checker = GitHubReleaseUpdateChecker.shared
        let repository = repository ?? checker.repository
        guard phase == .idle || { if case .failed = phase { return true }; return false }() else { return }
        guard tag.range(of: #"^v?[0-9]+[.][0-9]+([.][0-9]+)?([-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil,
              repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        else { phase = .failed("版本或倉庫格式無效"); return }
        guard !helperIsActive() else { phase = .failed("更新已在進行"); return }
        phase = .starting
        downloadProgress = nil; downloadedBytes = 0; totalBytes = 0
        let id = UUID(); downloadID = id
        download = Task {
            defer { download = nil }
            do {
                let zip = try await prefetch(tag: tag, repository: repository, session: checker.session, id: id)
                try Task.checkCancellation()
                handOff(tag: tag, repository: repository, zip: zip)
            } catch {
                phase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
                downloadProgress = nil
            }
        }
    }

    func cancelUpdate() { download?.cancel() }

    private func helperIsActive() -> Bool {
        guard let data = try? Data(contentsOf: pendingURL),
              let pending = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let label = pending["label"], label.hasPrefix("ai.tatwo.tatwo2.updater.") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list", label]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return true } // 無法確認時不重派。
    }

    private func prefetch(tag: String, repository: String, session: URLSession, id: UUID) async throws -> URL {
        struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int64 }
        struct Release: Decodable { let tag_name: String; let draft: Bool; let assets: [Asset] }
        func failure(_ message: String) -> NSError { NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        func check(_ response: URLResponse) throws {
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw failure("下載失敗，請稍後重試") }
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/tags/\(tag)")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TATWO-OS-UpdateChecker", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try check(response)
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.tag_name == tag, !release.draft,
              release.assets.contains(where: { $0.name == "TATWO-OS.install-ready" }) else { throw failure("此版本尚未完成安裝驗收") }
        func asset(_ name: String) throws -> Asset {
            guard let asset = release.assets.first(where: { $0.name == name }),
                  asset.browser_download_url.hasPrefix("https://github.com/\(repository)/releases/download/"),
                  URL(string: asset.browser_download_url) != nil else { throw failure("版本附件缺少或下載網址不符") }
            return asset
        }
        let archive = try asset("TATWO-OS.zip"), checksum = try asset("TATWO-OS.zip.sha256")
        let folder = directory.appendingPathComponent("download/\(tag)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let zip = folder.appendingPathComponent(archive.name)
        let (sha, shaResponse) = try await session.data(from: URL(string: checksum.browser_download_url)!)
        try check(shaResponse)
        let expected = String(decoding: sha, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard expected.range(of: "^[0-9A-Fa-f]{64}$", options: .regularExpression) != nil else { throw failure("校驗失敗：SHA-256 格式錯誤") }
        try sha.write(to: folder.appendingPathComponent(checksum.name), options: .atomic)
        totalBytes = archive.size
        if fileManager.fileExists(atPath: zip.path) {
            if try await Self.digest(zip) == expected.lowercased() {
                downloadedBytes = totalBytes; downloadProgress = 1; return zip
            }
            try fileManager.removeItem(at: zip) // 僅刪除已證實校驗失敗的下載快取。
        }
        let progress = UpdateDownloadProgress { [weak self] written, total in
            Task { @MainActor in
                guard let self, self.downloadID == id, self.phase == .starting else { return }
                self.downloadedBytes = written
                if total > 0 { self.totalBytes = total }
                self.downloadProgress = self.totalBytes > 0 ? min(1, Double(written) / Double(self.totalBytes)) : nil
            }
        }
        let (temp, zipResponse) = try await session.download(from: URL(string: archive.browser_download_url)!, delegate: progress)
        try check(zipResponse)
        try Task.checkCancellation()
        try fileManager.moveItem(at: temp, to: zip)
        guard try await Self.digest(zip) == expected.lowercased() else {
            try fileManager.removeItem(at: zip)
            throw failure("校驗失敗：SHA-256 不符，請重新下載")
        }
        downloadProgress = 1
        return zip
    }

    private nonisolated static func digest(_ url: URL) async throws -> String {
        let task = Task.detached {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation(); hash.update(data: chunk)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func handOff(tag: String, repository: String, zip: URL) {
        guard !helperIsActive() else { phase = .failed("更新已在進行"); return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try? fileManager.removeItem(at: resultURL)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let label = "ai.tatwo.tatwo2.updater.\(stamp).\(UUID().uuidString)"
            let script = directory.appendingPathComponent("update-\(stamp).sh")
            try Self.helperScript(
                tag: tag, pid: ProcessInfo.processInfo.processIdentifier,
                installURL: Self.installScriptURL(repository: repository),
                resultPath: resultURL.path, logPath: logURL.path,
                destination: Self.destinationApp, label: label, prefetchedZip: zip.path
            ).write(to: script, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let pending = ["label": label, "tag": tag, "startedAt": stamp, "log": logURL.path]
            try JSONSerialization.data(withJSONObject: pending).write(to: pendingURL, options: .atomic)

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
            if !helperIsActive() { try? fileManager.removeItem(at: pendingURL) }
            return
        }
        // 有 pending 但沒 result：helper 還在等，或 App 被人手動重開。不擋使用者，只提示。
        if helperIsActive() { lastResult = "更新已在進行"; return }
        if let data = try? Data(contentsOf: pendingURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tag = object["tag"] as? String {
            lastResult = "上次更新 \(tag) 沒有留下結果；若沒有自動完成，請再按一次更新。"
            try? fileManager.removeItem(at: pendingURL)
        }
    }

    static func describe(_ code: String) -> String {
        switch code {
        case "app_relaunched": return "App 在安裝前被重新開啟，未安裝；再按一次即可（不用重新下載）"
        case "app_still_running": return "App 沒有退出"
        case "download_install_script_failed": return "無法下載安裝腳本"
        case let value where value.hasPrefix("install_failed_exit_"): return "安裝腳本失敗，代碼 \(value.dropFirst("install_failed_exit_".count))"
        default: return code
        }
    }

    private static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // UPDATE-HELPER-BEGIN
    /// helper 本體。只用 macOS 內建指令；所有判斷都交給 install.sh，這裡不重做校驗。
    /// `TATWO2_UPDATE_INSTALL_SCRIPT`（本機檔案路徑）只給測試用，跳過下載。
    static func helperScript(tag: String, pid: Int32, installURL: String,
                             resultPath: String, logPath: String,
                             destination: String, label: String, prefetchedZip: String) -> String {
        """
        #!/bin/bash
        set -u
        PID=\(pid)
        TAG=\(quoted(tag))
        INSTALL_URL=\(quoted(installURL))
        RESULT=\(quoted(resultPath))
        LOG=\(quoted(logPath))
        DEST=\(quoted(destination))
        LABEL=\(quoted(label))
        PREFETCHED_ZIP=\(quoted(prefetchedZip))
        WAIT=\(helperWaitSeconds)
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        write_result() {
          printf '{"ok":%s,"tag":"%s","message":"%s"}\\n' "$1" "$TAG" "$2" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
        }
        finish() {
          # 同步移除，允許 launchd 結束自己；若 remove 返回也只 exit 0，絕不觸發失敗重跑。
          launchctl remove "$LABEL" >/dev/null 2>&1
          exit 0
        }
        reopen_if_stopped() { pgrep -x tatwo2 >/dev/null || { [ ! -d "$DEST" ] || open "$DEST"; }; }
        printf '[%s] 等待 TATWO OS（pid %s）退出…\\n' "$(date '+%F %T')" "$PID" >> "$LOG"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt "$WAIT" ]; do sleep 1; i=$((i + 1)); done
        if kill -0 "$PID" 2>/dev/null; then
          write_result false app_still_running
          finish
        fi
        if pgrep -x tatwo2 >/dev/null; then
          write_result false app_relaunched
          finish
        fi
        if [ -n "${TATWO2_UPDATE_INSTALL_SCRIPT:-}" ]; then
          SCRIPT="$TATWO2_UPDATE_INSTALL_SCRIPT"
        else
          SCRIPT="$(mktemp "${TMPDIR:-/tmp}/tatwo-install.XXXXXX")" || {
            write_result false download_install_script_failed
            reopen_if_stopped
            finish
          }
          if ! curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 15 --max-time 60 -o "$SCRIPT" "$INSTALL_URL"; then
            write_result false download_install_script_failed
            reopen_if_stopped
            finish
          fi
        fi
        printf '[%s] 執行 install.sh（%s）\\n' "$(date '+%F %T')" "$TAG" >> "$LOG"
        if pgrep -x tatwo2 >/dev/null; then
          write_result false app_relaunched
          finish
        fi
        TATWO_OS_PREFETCHED_ZIP="$PREFETCHED_ZIP" TATWO_OS_VERSION="$TAG" bash "$SCRIPT" >> "$LOG" 2>&1
        STATUS=$?
        if [ "$STATUS" -eq 0 ]; then
          write_result true installed
          finish
        fi
        write_result false "install_failed_exit_$STATUS"
        reopen_if_stopped
        finish
        """
    }
    // UPDATE-HELPER-END
}
