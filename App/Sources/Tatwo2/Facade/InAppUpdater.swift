import AppKit
import Foundation
import CryptoKit
import Darwin

/// 先在 App 內下載校驗，再交給 launchd 執行原安裝器；簽章、替換與回復仍由 install.sh 負責。
private final class UpdateDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Int64, Int64) -> Void
    private let destination: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?
    private var cancelled = false
    private var savedBytes: Int64 = 0
    private var authenticated = false
    private let rebase: @Sendable (Int64, Int64) -> Void
    private var resumeURL: URL { destination.appendingPathExtension("resume") }
    // Only the serial session delegate queue accesses fileResult.
    private var fileResult: Result<URL, Error>?

    init(destination: URL, rebase: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in },
         report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination; self.report = report; self.rebase = rebase
    }

    func download(from url: URL) async throws -> URL { try await download(request: URLRequest(url: url)) }

    func download(request: URLRequest) async throws -> URL {
        authenticated = request.value(forHTTPHeaderField: "Authorization") != nil
        try Task.checkCancellation()
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let resume = authenticated ? nil : try? Data(contentsOf: resumeURL)
        if resume?.isEmpty == false {
            savedBytes = Int64((try? String(contentsOf: resumeURL.appendingPathExtension("bytes"), encoding: .utf8)) ?? "") ?? 0
        }
        let task = resume.flatMap { $0.isEmpty ? nil : session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: request)
        if resume?.isEmpty != false { rebase(0, -1) }
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
            self.lock.withLock { self.cancelled = true }
            task.cancel(byProducingResumeData: { data in
                do { try self.saveResume(data); self.finish(.failure(CancellationError())) }
                catch { self.finish(.failure(error)) }
            })
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var redirected = request
        if request.url?.host != task.originalRequest?.url?.host {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }

    private func saveResume(_ data: Data?) throws {
        if let data, !authenticated {
            try Data(String(lock.withLock { savedBytes }).utf8).write(to: resumeURL.appendingPathExtension("bytes"), options: .atomic)
            try data.write(to: resumeURL, options: .atomic)
        }
    }

    static func retryable(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSURLErrorDomain && [
            URLError.networkConnectionLost, .timedOut, .cannotConnectToHost,
            .notConnectedToInternet, .secureConnectionFailed
        ].contains(URLError.Code(rawValue: error.code)))
            || (error.domain == "UpdaterHTTP" && (500...599).contains(error.code))
    }
    static func nextDelay(_ seconds: Int) -> Int { min(60, seconds * 2) }
    static func check(_ response: URLResponse?, resumed: Bool = false) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || (resumed && status == 206) else {
            throw NSError(domain: "UpdaterHTTP", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "下載失敗（HTTP \(status)）"])
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
        lock.withLock { savedBytes = totalBytesWritten }
        report(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        lock.withLock { savedBytes = fileOffset }
        rebase(fileOffset, expectedTotalBytes)
        report(fileOffset, expectedTotalBytes)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        fileResult = Result {
            try lock.withLock {
                guard outcome == nil, !cancelled else { throw CancellationError() }
                try Self.check(downloadTask.response, resumed: true)
                // location expires when this callback returns: move synchronously, fenced against cancellation.
                try FileManager.default.moveItem(at: location, to: destination)
                report(downloadTask.countOfBytesReceived, downloadTask.countOfBytesExpectedToReceive)
                return destination
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !lock.withLock({ cancelled }) else { return } // Cancellation finishes only after resume data is durable.
        do {
            try saveResume((error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
            if error == nil && !authenticated { try Data().write(to: resumeURL, options: .atomic) } // A completed HTTP response consumes the old resume request.
        } catch { finish(.failure(error)); return }
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
    var deltaZip: URL?
    var manifest: URL?
    var privateInstaller: URL?
    var username: String?
}

private enum UpdateDelta {
    static func name(installed: String?, tag: String) -> String? {
        guard let installed else { return nil }
        let from = installed.hasPrefix("v") ? installed : "v" + installed
        guard from != tag, [from, tag].allSatisfy({
            $0.range(of: #"^v[0-9]+([.][0-9]+){1,3}$"#, options: .regularExpression) != nil
        }) else { return nil }
        return "TATWO-OS-delta-\(from)-\(tag).zip"
    }
    static func reasonable(_ size: Int64, appSize: Int64) -> Bool { size > 0 && size < appSize }
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

    private var runID = UUID().uuidString
    var resultURL: URL { directory.appendingPathComponent("results/\(runID).json") }
    var pendingURL: URL { directory.appendingPathComponent("runs/\(runID).json") }
    var logURL: URL { directory.appendingPathComponent("logs/\(runID).log") }

    static func reconcileOnLaunch(destination: String = destinationApp) {
        let fm = FileManager.default, dest = URL(fileURLWithPath: destination)
        var backupDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destination + ".old", isDirectory: &backupDirectory), backupDirectory.boolValue else { return }
        let parent = dest.deletingLastPathComponent(), lock = parent.appendingPathComponent(".tatwo-update.lock")
        let owned = mkdir(lock.path, 0o700) == 0
        if owned { try? Data("\(getpid())".utf8).write(to: lock.appendingPathComponent("owner"), options: .atomic) }
        else {
            guard let text = try? String(contentsOf: lock.appendingPathComponent("owner"), encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
                  kill(pid, 0) != 0, errno == ESRCH else { return }
        }
        let guardPath = lock.appendingPathComponent("reconcile")
        guard mkdir(guardPath.path, 0o700) == 0 else { return }
        defer {
            rmdir(guardPath.path)
            if owned { try? fm.moveItem(at: lock, to: parent.appendingPathComponent(".tatwo-lock-retained.\(UUID().uuidString)")) }
        }
        for stage in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            where stage.lastPathComponent.hasPrefix(".tatwo-update.") && stage.pathExtension == "noindex" {
            let file = stage.appendingPathComponent("transaction.json")
            guard let data = try? Data(contentsOf: file),
                  var record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let phase = record["phase"], !["committed", "recovered", "rolled_back"].contains(phase),
                  let owner = record["owner"].flatMap(Int32.init), owner > 0, kill(owner, 0) != 0, errno == ESRCH,
                  record["backup"] == destination + ".old" else { continue }
            let backup = URL(fileURLWithPath: destination + ".old")
            do {
                guard (try? backup.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                      (try? stage.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
                if fm.fileExists(atPath: destination) {
                    try fm.moveItem(at: dest, to: stage.appendingPathComponent("interrupted.app.disabled"))
                }
                try fm.moveItem(at: backup, to: dest)
                record["phase"] = "recovered"
                try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
                try Data(#"{"ok":false,"message":"interrupted_restored_on_launch"}"#.utf8)
                    .write(to: stage.appendingPathComponent("result.json"), options: .atomic)
            } catch { fputs("tatwo_update_reconcile=failed\n", stderr) }
        }
    }

    private func records(_ subdirectory: String) -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: directory.appendingPathComponent(subdirectory),
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }

    static func installScriptURL(repository: String) -> String {
        "https://raw.githubusercontent.com/\(repository)/main/install.sh"
    }

    /// 由更新卡呼叫。tag 必須是檢查器剛回報的 Release tag；不接受任意輸入。
    func update(to tag: String, repository: String? = nil) {
        let checker = GitHubReleaseUpdateChecker.shared
        let repository = repository ?? checker.repository
        guard phase == .idle || { if case .failed = phase { return true }; return false }() else { return }
        guard PeerUpdateSource.validTag(tag), tag.range(of: #"^v?[0-9]+[.][0-9]+([.][0-9]+){0,2}([-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil,
              repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        else { phase = .failed("版本或倉庫格式無效"); return }
        guard !helperIsActive() else { phase = .failed("更新已在進行"); return }
        phase = .starting
        downloadProgress = nil; downloadedBytes = resumableBytes(for: tag) ?? 0; totalBytes = 0
        downloadSource = "從 GitHub 下載…"
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

    func resumableBytes(for tag: String) -> Int64? {
        guard PeerUpdateSource.validTag(tag),
              let files = fileManager.enumerator(at: directory.appendingPathComponent("download/\(tag)"),
                                                includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var bytes: [String: Int64] = [:]
        for case let file as URL in files {
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if !file.lastPathComponent.hasPrefix("peer-") { files.skipDescendants() }
                continue
            }
            let name = (file.pathExtension == "resume" ? file.deletingPathExtension() : file).lastPathComponent
            guard ["TATWO-OS.zip", "TATWO-OS-app.zip"].contains(name)
                || name.hasPrefix("TATWO-OS-delta-") && name.hasSuffix(".zip")
                || name.range(of: "^TATWO-OS-runtime-[0-9a-f]{12}[.]zip$", options: .regularExpression) != nil else { continue }
            if file.pathExtension == "resume", let data = try? Data(contentsOf: file), !data.isEmpty {
                bytes[name] = max(bytes[name] ?? 0, Int64((try? String(contentsOf: file.appendingPathExtension("bytes"), encoding: .utf8)) ?? "") ?? 0)
            } else if file.pathExtension == "zip", !file.lastPathComponent.hasPrefix("invalid-") {
                bytes[file.lastPathComponent] = max(bytes[file.lastPathComponent] ?? 0, Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            }
        }
        return bytes.isEmpty ? nil : bytes.values.reduce(0, +)
    }

    private func retryDownload<T>(_ operation: () async throws -> T) async throws -> T {
        var delay = 2
        while true {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                guard UpdateDownloadProgress.retryable(error) else { throw error }
                let source = downloadSource
                for seconds in stride(from: delay, through: 1, by: -1) {
                    downloadBytesPerSecond = 0
                    downloadSource = String(format: "連線中斷，%d 秒後自動續傳（已下載 %.1f MB）", seconds, Double(downloadedBytes) / 1_000_000)
                    try await Task.sleep(for: .seconds(1))
                }
                downloadSource = source; speedSamples = []
                delay = UpdateDownloadProgress.nextDelay(delay)
            }
        }
    }

    private func helperIsActive(launchctl: String = "/bin/launchctl") -> Bool {
        for record in records("runs") {
            let id = record.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil else { continue } // Preserve unrelated files without treating them as runs.
            let data = try? Data(contentsOf: record)
            var pending = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            let label = "ai.tatwo.tatwo2.updater.\(id)"
            pending["runID"] = id; pending["label"] = label
            if pending["state"] == "reconciled" { continue }
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: launchctl)
            process.arguments = ["list", label]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                // submit may be between persisted run creation and launchd assigning a PID.
                if pending["state"] == "submitted", let started = pending["submittedAt"].flatMap(Double.init),
                   Date().timeIntervalSince1970 - started < 30 { return true }
                guard [0, 113].contains(process.terminationStatus) else { return true }
                if process.terminationStatus == 0 {
                    let text = String(decoding: data, as: UTF8.self)
                    if text.range(of: #""PID"\s*=\s*[1-9][0-9]*"#, options: .regularExpression) != nil { return true }
                    // A loaded job without PID is not running. Remove stale launchd state.
                    let remove = Process(); remove.executableURL = process.executableURL
                    remove.arguments = ["remove", label]; try remove.run(); remove.waitUntilExit()
                    if remove.terminationStatus != 0 { return true }
                }
                if let id = pending["runID"], UUID(uuidString: id) != nil {
                    let result = directory.appendingPathComponent("results/\(id).json")
                    if !fileManager.fileExists(atPath: result.path) {
                        try JSONSerialization.data(withJSONObject: ["runID": id, "ok": false,
                            "tag": pending["tag"] ?? "", "message": "helper_exited_abnormally"])
                            .write(to: result, options: .atomic)
                    }
                }
                var reconciled = pending; reconciled["state"] = "reconciled"
                try JSONSerialization.data(withJSONObject: reconciled).write(to: record, options: .atomic)
            } catch { return true } // Unable to establish liveness: fail closed.
        }
        return false
    }

    private func prefetch(tag: String, repository: String, session: URLSession, id: UUID) async throws -> UpdateArchives {
        struct Asset: Decodable { let id: Int64?; let name: String; let browser_download_url: String; let size: Int64 }
        struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool; let assets: [Asset] }
        func failure(_ message: String) -> NSError { NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        func check(_ response: URLResponse) throws {
            try UpdateDownloadProgress.check(response)
        }
        let channel = UpdateChannel.current()
        if repository == UpdateChannel.privateRepository && !channel.isPrivate { throw failure("私人通道需要 GitHub 登入") }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/tags/\(tag)")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TATWO-OS-UpdateChecker", forHTTPHeaderField: "User-Agent")
        channel.authorize(&request)
        let (data, _) = try await retryDownload {
            let result = try await session.data(for: request); try check(result.1); return result
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.tag_name == tag, !release.draft, !release.prerelease,
              release.assets.contains(where: { $0.name == "TATWO-OS.install-ready" }) else { throw failure("此版本尚未完成安裝驗收") }
        func asset(_ name: String) throws -> Asset {
            guard let asset = release.assets.first(where: { $0.name == name }),
                  asset.browser_download_url.hasPrefix("https://github.com/\(repository)/releases/download/"),
                  URL(string: asset.browser_download_url) != nil else { throw failure("版本附件缺少或下載網址不符") }
            return asset
        }
        func assetRequest(_ asset: Asset) throws -> URLRequest {
            var url = URL(string: asset.browser_download_url)!
            if repository == UpdateChannel.privateRepository {
                guard let id = asset.id, id > 0 else { throw failure("私人附件缺少 ID") }
                url = URL(string: "https://api.github.com/repos/\(repository)/releases/assets/\(id)")!
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            channel.authorize(&request)
            return request
        }
        let split = release.assets.contains { $0.name == "TATWO-OS-app.zip" }
        var archives = [try asset(split ? "TATWO-OS-app.zip" : "TATWO-OS.zip")]
        let installed = Bundle(url: URL(fileURLWithPath: Self.destinationApp))?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let deltaName = UpdateDelta.name(installed: installed, tag: tag)
        let delta = release.assets.first { $0.name == deltaName }
        let useDelta = split && delta.map { UpdateDelta.reasonable($0.size, appSize: archives[0].size) } == true
            && [deltaName!, deltaName! + ".sha256", "TATWO-OS.manifest.json", "TATWO-OS.manifest.json.sha256"].allSatisfy { name in
                (try? asset(name)) != nil
            }
        if useDelta { archives = [try asset("TATWO-OS.manifest.json"), try asset(deltaName!)] }
        if split && !useDelta {
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
        let deltaProgress = useDelta ? String(format: "差異更新：%.1f MB", Double(delta!.size) / 1_000_000) + " · " : ""
        var expectedHashes: [String: String] = [:]
        for archive in archives {
            let checksum = try asset(archive.name + ".sha256")
            let (sha, _) = try await retryDownload {
                let result = try await session.data(for: try assetRequest(checksum))
                try check(result.1); return result
            }
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
                    downloadSource = deltaProgress + "使用已校驗快取"
                    recordDownloadProgress(offset + archive.size, total: plannedBytes); return zip
                }
                try fileManager.moveItem(at: zip, to: folder.appendingPathComponent("invalid-\(UUID().uuidString).zip"))
            }
            for offer in offers {
                try Task.checkCancellation()
                downloadSource = deltaProgress + "從『\(offer.device.name)』取得…"
                if let candidate = try? await PeerUpdateSource.pull(offer, tag: tag, name: archive.name, folder: folder) {
                    if let actual = try? await Self.digest(candidate), actual == expected {
                        try Task.checkCancellation()
                        try fileManager.moveItem(at: candidate, to: zip)
                        downloadSource = deltaProgress + String(format: "從『%@』取得 %.1f MB", offer.device.name, Double(archive.size) / 1_000_000)
                        return zip
                    }
                    try Task.checkCancellation()
                    try fileManager.moveItem(at: candidate, to: folder.appendingPathComponent("invalid-\(UUID().uuidString).zip"))
                }
                // Interrupted candidates stay in peer-key; corrupt files stay quarantined, never handed off.
            }
            try Task.checkCancellation()
            downloadSource = deltaProgress + "從 GitHub 下載…"
            _ = try await retryDownload {
                let progress = UpdateDownloadProgress(destination: zip, rebase: { [weak self] written, _ in
                    Task { @MainActor in
                        guard let self, self.downloadID == id, self.phase == .starting else { return }
                        self.downloadedBytes = offset + written; self.speedSamples = []
                    }
                }) { [weak self] written, total in
                    Task { @MainActor in
                        guard let self, self.downloadID == id, self.phase == .starting else { return }
                        self.recordDownloadProgress(offset + written, total: max(plannedBytes, offset + max(0, total)))
                    }
                }
                return try await progress.download(request: try assetRequest(archive))
            }
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
                if useDelta { $0.files[archive.name] = zip.path }
                else if archive.name.hasPrefix("TATWO-OS-runtime-") { $0.runtime = zip.path } else { $0.app = zip.path }
                $0.sha256[archive.name] = expectedHashes[archive.name]
                $0.sizes[archive.name] = (try? fileManager.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value
            }
            completed += (try fileManager.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value ?? archive.size
            recordDownloadProgress(completed, total: plannedBytes)
            if archive.name == "TATWO-OS.zip" { result.zip = zip }
            else if archive.name == "TATWO-OS-app.zip" { result.appZip = zip }
            else if archive.name == "TATWO-OS.manifest.json" { result.manifest = zip }
            else if archive.name == deltaName { result.deltaZip = zip }
            else { result.runtimeZip = zip }
        }
        if repository == UpdateChannel.privateRepository {
            // Fetch the installer at the selected tag; never serialize Authorization into the helper.
            var scriptRequest = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/contents/scripts/install-private.sh?ref=\(tag)")!)
            scriptRequest.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
            channel.authorize(&scriptRequest)
            let (script, response) = try await session.data(for: scriptRequest)
            try check(response)
            let local = folder.appendingPathComponent("install-private.sh")
            try script.write(to: local, options: .atomic)
            result.privateInstaller = local; result.username = channel.username
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
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let lock = directory.appendingPathComponent("dispatch.lock")
            let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { phase = .failed("無法取得更新派送鎖"); return }
            defer { flock(descriptor, LOCK_UN); close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { phase = .failed("更新派送中"); return }
            guard !helperIsActive() else { phase = .failed("更新已在進行"); return }
            runID = UUID().uuidString
            for folder in ["runs", "results", "logs", "acks"] {
                try fileManager.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            let label = "ai.tatwo.tatwo2.updater.\(runID)"
            let script = directory.appendingPathComponent("update-\(runID).sh")
            try Self.helperScript(
                tag: tag, pid: ProcessInfo.processInfo.processIdentifier,
                installURL: Self.installScriptURL(repository: repository),
                resultPath: resultURL.path, logPath: logURL.path,
                destination: Self.destinationApp, label: label, prefetchedZip: zip.zip?.path ?? "",
                prefetchedAppZip: zip.appZip?.path ?? "", prefetchedRuntimeZip: zip.runtimeZip?.path ?? "",
                prefetchedDeltaZip: zip.deltaZip?.path ?? "", prefetchedManifest: zip.manifest?.path ?? "",
                privateInstaller: zip.privateInstaller?.path ?? "", githubUsername: zip.username ?? ""
            ).write(to: script, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let pending = ["label": label, "tag": tag, "startedAt": stamp, "log": logURL.path, "runID": runID, "state": "submitted", "submittedAt": String(Date().timeIntervalSince1970)]
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
                // Preserve the run record for reconciliation.
                return
            }
            phase = .handedOff
            // 讓畫面先顯示「更新中」再退出；使用者取消結束時 helper 會在等待逾時後放棄。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.terminate(nil)
            }
        } catch {
            phase = .failed("無法準備更新：\(error.localizedDescription)")
            // Preserve the run record for reconciliation.
        }
    }

    /// Read immutable per-run receipts; acknowledge by run ID, never delete a result.
    func consumeResultOnLaunch() {
        Task { await PeerUpdateSource.publishInstalled(directory) }
        let active = helperIsActive()
        defer { if active { Task { try? await Task.sleep(for: .seconds(2)); consumeResultOnLaunch() } } }
        for result in records("results").prefix(1) {
            let id = result.deletingPathExtension().lastPathComponent
            let ack = directory.appendingPathComponent("acks/\(id).ack")
            guard UUID(uuidString: id) != nil, !fileManager.fileExists(atPath: ack.path),
                  let data = try? Data(contentsOf: result),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["runID"] as? String == id else { continue }
            let tag = object["tag"] as? String ?? "", message = object["message"] as? String ?? ""
            lastResult = (object["ok"] as? Bool == true) ? "已更新到 \(tag)" : "更新 \(tag) 未完成（\(Self.describe(message))）"
            try? fileManager.createDirectory(at: ack.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(id.utf8).write(to: ack, options: .atomic)
            return
        }
        if active {
            lastResult = "更新已在進行"
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
                             prefetchedAppZip: String = "", prefetchedRuntimeZip: String = "",
                             prefetchedDeltaZip: String = "", prefetchedManifest: String = "",
                             privateInstaller: String = "", githubUsername: String = "") -> String {
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
        RUN_ID="${LABEL##*.}"
        RUN="$(dirname "$(dirname "$RESULT")")/runs/$RUN_ID.json"
        PREFETCHED_ZIP=\(quoted(prefetchedZip))
        export TATWO_OS_PREFETCHED_APP_ZIP=\(quoted(prefetchedAppZip))
        export TATWO_OS_PREFETCHED_RUNTIME_ZIP=\(quoted(prefetchedRuntimeZip))
        export TATWO_OS_PREFETCHED_DELTA_ZIP=\(quoted(prefetchedDeltaZip))
        export TATWO_OS_PREFETCHED_MANIFEST=\(quoted(prefetchedManifest))
        PRIVATE_INSTALLER=\(quoted(privateInstaller))
        export TATWO_OS_GITHUB_USERNAME=\(quoted(githubUsername))
        WAIT=\(helperWaitSeconds)
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        write_result() {
          printf '{"ok":%s,"tag":"%s","message":"%s","runID":"%s"}\\n' "$1" "$TAG" "$2" "$RUN_ID" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
        }
        abnormal_exit() {
          trap - EXIT INT TERM
          write_result false helper_exited_abnormally
          if [ -f "$RUN" ]; then plutil -replace state -string abnormal_exit "$RUN"; fi
          launchctl remove "$LABEL" >/dev/null 2>&1
          exit 0
        }
        trap abnormal_exit EXIT INT TERM
        # launchd must not rerun installation after any terminal receipt.
        if [ -f "$RESULT" ]; then trap - EXIT INT TERM; launchctl remove "$LABEL" >/dev/null 2>&1; exit 0; fi
        finish() {
          trap - EXIT INT TERM
          if [ -f "$RUN" ]; then plutil -replace state -string terminal "$RUN"; fi
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
        if [ -n "$PRIVATE_INSTALLER" ]; then
          SCRIPT="$PRIVATE_INSTALLER"
        elif [ -n "${TATWO2_UPDATE_INSTALL_SCRIPT:-}" ]; then
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
