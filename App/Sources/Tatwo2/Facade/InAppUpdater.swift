import AppKit
import Foundation
import CryptoKit

/// 先在 App 內下載校驗，再交給 launchd 執行原安裝器；簽章、替換與回復仍由 install.sh 負責。
private final class UpdateDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Int64, Int64) -> Void
    private let destination: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?
    // Only the serial session delegate queue accesses fileResult.
    private var fileResult: Result<URL, Error>?

    init(destination: URL, report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination; self.report = report
    }

    func download(from url: URL) async throws -> URL {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        let polling = Task {
            while !Task.isCancelled {
                report(task.countOfBytesReceived, task.countOfBytesExpectedToReceive)
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
        defer { polling.cancel(); session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completed: Result<URL, Error>? = lock.withLock {
                    if let outcome { return outcome }
                    self.continuation = continuation
                    return nil
                }
                if let completed { continuation.resume(with: completed) } else { task.resume() }
            }
        } onCancel: {
            session.invalidateAndCancel()
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let pending = lock.withLock {
            guard outcome == nil else { return nil as CheckedContinuation<URL, Error>? }
            outcome = result
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        fileResult = Result {
            try lock.withLock {
                guard outcome == nil else { throw CancellationError() }
                guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "下載失敗，請稍後重試"])
                }
                // location expires when this callback returns: move synchronously, fenced against cancellation.
                try FileManager.default.moveItem(at: location, to: destination)
                report(downloadTask.countOfBytesReceived, downloadTask.countOfBytesExpectedToReceive)
                return destination
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error.map { .failure($0) } ?? fileResult ?? .failure(URLError(.unknown)))
    }
}

private struct UpdateRuntimeLayer: Decodable {
    let sha: String
    let paths: [String]

    static func canReuse(contents: URL, archiveName: String) -> Bool {
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Resources/runtime-layer.json")),
              let layer = try? JSONDecoder().decode(Self.self, from: data),
              layer.sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              archiveName == "TATWO-OS-runtime-\(layer.sha.prefix(12)).zip", !layer.paths.isEmpty else { return false }
        return layer.paths.allSatisfy { path in
            (path.hasPrefix("Resources/") || path.hasPrefix("Frameworks/"))
                && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
                && FileManager.default.fileExists(atPath: contents.appendingPathComponent(path).path)
        }
    }
}

private struct UpdateArchives {
    var zip: URL?
    var appZip: URL?
    var runtimeZip: URL?
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
    @Published private(set) var downloadBytesPerSecond: Double = 0
    @Published private(set) var downloadSource = "從 GitHub 下載…"
    private var speedSamples: [(time: TimeInterval, bytes: Int64)] = []
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
        guard PeerUpdateSource.validTag(tag), tag.range(of: #"^v?[0-9]+[.][0-9]+([.][0-9]+)?([-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil,
              repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        else { phase = .failed("版本或倉庫格式無效"); return }
        guard !helperIsActive() else { phase = .failed("更新已在進行"); return }
        phase = .starting
        downloadProgress = nil; downloadedBytes = 0; totalBytes = 0
        downloadBytesPerSecond = 0; speedSamples = []
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

    private func prefetch(tag: String, repository: String, session: URLSession, id: UUID) async throws -> UpdateArchives {
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
        let split = release.assets.contains { $0.name == "TATWO-OS-app.zip" }
        var archives = [try asset(split ? "TATWO-OS-app.zip" : "TATWO-OS.zip")]
        if split {
            let runtimes = release.assets.filter {
                $0.name.range(of: "^TATWO-OS-runtime-[0-9a-f]{12}[.]zip$", options: .regularExpression) != nil
            }
            guard runtimes.count == 1 else { throw failure("執行環境附件缺少或不唯一") }
            let runtime = try asset(runtimes[0].name)
            if !UpdateRuntimeLayer.canReuse(contents: URL(fileURLWithPath: Self.destinationApp).appendingPathComponent("Contents"),
                                            archiveName: runtime.name) { archives.append(runtime) }
        }
        let folder = directory.appendingPathComponent("download/\(tag)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let plannedBytes = archives.reduce(Int64(0)) { $0 + max(0, $1.size) }
        totalBytes = plannedBytes
        speedSamples = [(ProcessInfo.processInfo.systemUptime, 0)]
        var expectedHashes: [String: String] = [:]
        for archive in archives {
            let checksum = try asset(archive.name + ".sha256")
            let (sha, shaResponse) = try await session.data(for: URLRequest(url: URL(string: checksum.browser_download_url)!,
                cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            try check(shaResponse)
            let expected = String(decoding: sha, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            guard expected.range(of: "^[0-9A-Fa-f]{64}$", options: .regularExpression) != nil else { throw failure("校驗失敗：SHA-256 格式錯誤") }
            try sha.write(to: folder.appendingPathComponent(checksum.name), options: .atomic)
            expectedHashes[archive.name] = expected.lowercased()
        }
        downloadSource = "詢問已配對設備…"
        let offers = await PeerUpdateSource.discover(DeviceRegistry().list())
        try Task.checkCancellation()
        func fetch(_ archive: Asset, offset: Int64) async throws -> URL {
            let expected = expectedHashes[archive.name]!
            let zip = folder.appendingPathComponent(archive.name)
            if fileManager.fileExists(atPath: zip.path) {
                if try await Self.digest(zip) == expected.lowercased() {
                    downloadSource = "使用已校驗快取"
                    recordDownloadProgress(offset + archive.size, total: plannedBytes); return zip
                }
                try fileManager.moveItem(at: zip, to: folder.appendingPathComponent("invalid-\(UUID().uuidString).zip"))
            }
            for offer in offers {
                try Task.checkCancellation()
                downloadSource = "從『\(offer.device.name)』取得…"
                if let candidate = try? await PeerUpdateSource.pull(offer, tag: tag, name: archive.name, folder: folder),
                   let actual = try? await Self.digest(candidate), actual == expected {
                    try Task.checkCancellation()
                    try fileManager.moveItem(at: candidate, to: zip)
                    downloadSource = String(format: "從『%@』取得 %.1f MB", offer.device.name, Double(archive.size) / 1_000_000)
                    return zip
                }
                // Failed candidates stay isolated in peer-UUID; never advertised or passed to install.sh.
            }
            try Task.checkCancellation()
            downloadSource = "從 GitHub 下載…"
            let progress = UpdateDownloadProgress(destination: zip) { [weak self] written, total in
                Task { @MainActor in
                    guard let self, self.downloadID == id, self.phase == .starting else { return }
                    self.recordDownloadProgress(offset + written, total: max(plannedBytes, offset + max(0, total)))
                }
            }
            _ = try await progress.download(from: URL(string: archive.browser_download_url)!)
            try Task.checkCancellation()
            guard try await Self.digest(zip) == expected.lowercased() else {
                try fileManager.moveItem(at: zip, to: folder.appendingPathComponent("invalid-\(UUID().uuidString).zip"))
                throw failure("校驗失敗：SHA-256 不符，請重新下載")
            }
            return zip
        }
        var result = UpdateArchives(), completed: Int64 = 0
        for archive in archives {
            let zip = try await fetch(archive, offset: completed)
            try? PeerUpdateSource.publish(directory, tag: tag) {
                if archive.name.hasPrefix("TATWO-OS-runtime-") { $0.runtime = zip.path } else { $0.app = zip.path }
                $0.sha256[archive.name] = expectedHashes[archive.name]
                $0.sizes[archive.name] = (try? fileManager.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value
            }
            completed += (try fileManager.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value ?? archive.size
            recordDownloadProgress(completed, total: plannedBytes)
            if archive.name == "TATWO-OS.zip" { result.zip = zip }
            else if archive.name == "TATWO-OS-app.zip" { result.appZip = zip }
            else { result.runtimeZip = zip }
        }
        downloadProgress = 1
        return result
    }

    private func recordDownloadProgress(_ written: Int64, total: Int64,
                                        now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        downloadedBytes = max(downloadedBytes, written)
        totalBytes = max(totalBytes, total)
        downloadProgress = totalBytes > 0 ? min(1, Double(downloadedBytes) / Double(totalBytes)) : nil
        speedSamples.append((now, downloadedBytes))
        speedSamples.removeAll { $0.time < now - 5 }
        if let first = speedSamples.first, now > first.time {
            downloadBytesPerSecond = Double(downloadedBytes - first.bytes) / (now - first.time)
        } else { downloadBytesPerSecond = 0 }
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

    private func handOff(tag: String, repository: String, zip: UpdateArchives) {
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
                destination: Self.destinationApp, label: label, prefetchedZip: zip.zip?.path ?? "",
                prefetchedAppZip: zip.appZip?.path ?? "", prefetchedRuntimeZip: zip.runtimeZip?.path ?? ""
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
        Task { await PeerUpdateSource.publishInstalled(directory) }
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
                             destination: String, label: String, prefetchedZip: String,
                             prefetchedAppZip: String = "", prefetchedRuntimeZip: String = "") -> String {
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
        export TATWO_OS_PREFETCHED_APP_ZIP=\(quoted(prefetchedAppZip))
        export TATWO_OS_PREFETCHED_RUNTIME_ZIP=\(quoted(prefetchedRuntimeZip))
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
