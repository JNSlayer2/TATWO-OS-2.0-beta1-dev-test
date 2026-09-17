import AppKit
import Foundation
import CryptoKit
import Darwin
import Network

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
    private var requestedRange: String?
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
        requestedRange = request.value(forHTTPHeaderField: "Range")
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

    private func acceptsRangeResponse(_ response: URLResponse?, written: Int64 = 0) -> Bool {
        guard let requestedRange else { return true }
        let bounds = requestedRange.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").compactMap { Int64($0) }
        guard bounds.count == 2, bounds[1] >= bounds[0],
              let response = response as? HTTPURLResponse, response.statusCode == 206,
              let range = response.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes "),
              range.split(separator: "/").first?.split(separator: "-").last == requestedRange.split(separator: "-").last
        else { return false }
        let length = bounds[1] - bounds[0] + 1
        return written <= length && response.expectedContentLength <= length
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Reject ignored/oversized ranges while streaming, not after six full archives hit disk.
        guard acceptsRangeResponse(downloadTask.response, written: totalBytesWritten) else {
            fileResult = .failure(URLError(.badServerResponse)); downloadTask.cancel(); return
        }
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
                guard acceptsRangeResponse(downloadTask.response) else { throw URLError(.badServerResponse) }
                // location expires when this callback returns: move synchronously, fenced against cancellation.
                try FileManager.default.moveItem(at: location, to: destination)
                report(downloadTask.countOfBytesReceived, downloadTask.countOfBytesExpectedToReceive)
                return destination
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !lock.withLock({ cancelled }) else { return } // Cancellation finishes only after resume data is durable.
        if requestedRange != nil, let fileResult, case .failure = fileResult {
            // Wait for didComplete before retrying: an invalid response must not race a
            // subsequent attempt by publishing inappropriate whole-file resume data.
            try? Data().write(to: resumeURL, options: .atomic)
            finish(fileResult); return
        }
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
    var route: String = "layered"
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
    static func reasonable(_ size: Int64, appSize: Int64, runtimeReusable: Bool) -> Bool {
        !runtimeReusable && size > 0 && size < appSize / 4
    }
}

@MainActor
final class InAppUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case ready
        case starting
        case handedOff
        case failed(String)
    }

    static let shared = InAppUpdater()
    static let destinationApp = "/Applications/TATWO OS.app"
    static let helperWaitSeconds = 300

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var userStarted = false
    @Published private(set) var confirmingRestart = false
    /// 上一次更新的結果（由 helper 寫、本次啟動讀到），給更新卡顯示。
    @Published private(set) var lastResult: String?
    @Published private(set) var lastPhases = ""

    func refreshPhaseSummary() async {
        let folder = directory.appendingPathComponent("results")
        let summary = await Task.detached(priority: .utility) {
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "json" }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            if let latest = files.first,
               let data = try? Data(contentsOf: latest),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let phases = object["phases"] as? [String: Any] {
                let downloads = phases["download"] as? [[String: Any]] ?? []
                let download = downloads.map { item in
                    String(format: "%@ %.1f 秒", item["name"] as? String ?? "附件", (item["seconds"] as? NSNumber)?.doubleValue ?? 0)
                }.joined(separator: "、")
                return "下載：" + download + " · " + ["verify", "extract", "switch"].map { key in
                    let title = ["verify": "校驗", "extract": "解壓", "switch": "切換"][key]!
                    return String(format: "%@ %.1f 秒", title, ((phases[key] as? NSNumber)?.doubleValue ?? 0) + (key == "verify" ? (phases["prefetchVerify"] as? NSNumber)?.doubleValue ?? 0 : 0))
                }.joined(separator: " · ")
            }
            return ""
        }.value
        guard !Task.isCancelled else { return }
        lastPhases = summary
    }

    @Published private(set) var downloadProgress: Double?
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var downloadBytesPerSecond: Double = 0
    @Published private(set) var downloadSource = "從 GitHub 下載…"
    private var speedSamples: [(time: TimeInterval, bytes: Int64)] = []
    private var download: Task<Void, Never>?
    private var downloadID = UUID()
    private let network = NWPathMonitor()
    private var unmetered = false
    private var manualDownload = false
    private var pendingCandidate: (tag: String, repository: String)?
    private var prepared: (tag: String, repository: String, archives: UpdateArchives)?
    @Published private(set) var preparationReason = ""
    private var candidateBytes: Int64 = 0

    var updateMarkTitle: String {
        UpdateMarkState.title(phase: phase, progress: downloadProgress, userStarted: userStarted)
    }

    var updateMarkHelp: String {
        if case .failed(let reason) = phase { return reason }
        return updateMarkTitle
    }

    var updateMarkDisabled: Bool {
        confirmingRestart || phase == .handedOff || (userStarted && phase == .starting)
    }

    /// Both surfaces share intent and confirmation; downloading never dispatches the installer.
    func activateUpdateMark(to tag: String, repository: String,
                            confirm: (@MainActor () async -> Bool)? = nil) async {
        guard !updateMarkDisabled else { return }
        if !userStarted || phase != .ready {
            if phase != .ready { prefetch(to: tag, repository: repository, force: true) }
            userStarted = true
            return
        }
        confirmingRestart = true
        defer { confirmingRestart = false }
        let candidateID = downloadID
        let accepted: Bool
        if let confirm {
            accepted = await confirm()
        } else {
            accepted = await IslandNotice.shared.confirm(
                title: "重新啟動 TATWO OS 以完成更新？",
                detail: "會關閉目前所有工作，約 10 秒後自動重開",
                confirmLabel: "重開", cancelLabel: "稍後")
        }
        guard accepted, !Task.isCancelled, userStarted, downloadID == candidateID else { return }
        update(to: tag, repository: repository)
    }

    private func checkSpace() throws {
        // 待接 todo #25 治理器的磁碟保留額。
        let minimumFreeBytes: Int64 = 2_000_000_000
        // candidateBytes bounds both selected archives and the expanded App.
        // W64 named safety budget: 2× for staging/switch. W87a adds 2× for range parts + joining.
        let archiveSafetyMultiplier: Int64 = 2
        let rangePeakMultiplier: Int64 = 2
        do {
            guard candidateBytes >= 0,
                  candidateBytes <= Int64.max / (archiveSafetyMultiplier + rangePeakMultiplier) else {
                throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "無法確認更新所需空間"])
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // W24 gate (named budget) plus the W87a range-parts peak on top of it.
            let required = max(minimumFreeBytes, candidateBytes * archiveSafetyMultiplier)
                + candidateBytes * rangePeakMultiplier
            for volume in [directory, URL(fileURLWithPath: Self.destinationApp).deletingLastPathComponent()] {
                guard let free = try fileManager.attributesOfFileSystem(forPath: volume.path)[.systemFreeSize] as? NSNumber,
                      free.int64Value >= 0 else {
                    throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "無法確認目標卷可用空間"])
                }
                guard free.int64Value >= required else {
                    throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        String(format: "空間不足，請清出至少 %.1f GB", Double(required - free.int64Value) / 1_000_000_000)])
                }
            }
        } catch {
            IslandNotice.shared.info(title: "無法開始更新", detail: error.localizedDescription)
            throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
        }
    }

    func preparationTitle(_ tag: String) -> String {
        if phase == .ready, prepared?.tag == tag { return "\(tag) 已準備好" }
        if phase == .handedOff { return "正在重新啟動…" }
        if case .failed(let reason) = phase { return reason }
        if !preparationReason.isEmpty { return preparationReason }
        if phase == .idle { return "已找到 \(tag)" }
        return String(format: "正在準備 %@（%.1f / %.1f MB）", tag, Double(downloadedBytes) / 1_000_000, Double(totalBytes) / 1_000_000)
    }

    func invalidateCandidate() {
        userStarted = false
        manualDownload = false
        downloadID = UUID()
        pendingCandidate = nil; prepared = nil; preparationReason = ""
        if phase == .starting { download?.cancel() }
        else if phase != .handedOff { phase = .idle }
    }

    func prefetch(to tag: String, repository: String, force: Bool = false) {
        if prepared?.tag == tag && prepared?.repository == repository { return }
        guard phase != .handedOff else { return }
        if let candidate = prepared.map({ (tag: $0.tag, repository: $0.repository) }) ?? pendingCandidate,
           candidate.tag != tag || candidate.repository != repository {
            userStarted = false
        }
        if phase == .starting {
            if pendingCandidate?.tag != tag || pendingCandidate?.repository != repository {
                userStarted = false
                manualDownload = force
                pendingCandidate = (tag, repository); download?.cancel()
            } else if force {
                manualDownload = true
            }
            return
        }
        prepared = nil; phase = .idle; candidateBytes = 0; pendingCandidate = (tag, repository)
        guard force || unmetered else { preparationReason = "已找到 \(tag)，等 Wi‑Fi 再自動下載"; return }
        do { try checkSpace() } catch {
            preparationReason = error.localizedDescription
            phase = .failed(error.localizedDescription)
            return
        }
        manualDownload = force; preparationReason = ""
        beginPrefetch(to: tag, repository: repository)
    }

    func update(to tag: String, repository: String? = nil) {
        guard phase == .ready, let prepared, prepared.tag == tag,
              prepared.repository == (repository ?? GitHubReleaseUpdateChecker.shared.repository) else { return }
        do { try checkSpace() } catch { self.prepared = nil; phase = .failed(error.localizedDescription); return }
        manualDownload = true // Explicit restart validation must also survive a metered path change.
        phase = .starting
        let validationID = UUID(); downloadID = validationID
        download = Task {
            defer { if downloadID == validationID { download = nil } }
            let folder = directory.appendingPathComponent("download/\(prepared.repository)/\(tag)")
            do {
                try await revalidate(tag: tag, repository: prepared.repository, folder: folder)
                try Task.checkCancellation()
                guard downloadID == validationID, self.prepared?.tag == tag,
                      self.prepared?.repository == prepared.repository else { return }
                try checkSpace()
                handOff(tag: tag, repository: prepared.repository, zip: prepared.archives)
            } catch {
                if Task.isCancelled {
                    self.prepared = nil
                    phase = .idle
                    if let next = pendingCandidate {
                        prefetch(to: next.tag, repository: next.repository, force: manualDownload)
                    }
                    return
                }
                if (error as NSError).domain == "Updater", (error as NSError).code == 2 {
                    self.prepared = nil
                    phase = .failed(error.localizedDescription)
                    return
                }
                // Only cached metadata is removed; verified archives remain reusable after a fresh check.
                try? fileManager.removeItem(at: folder.appendingPathComponent("release.json"))
                self.prepared = nil; pendingCandidate = nil
                phase = .failed("版本已撤回或無法確認")
            }
        }
    }

    private func revalidate(tag: String, repository: String, folder: URL) async throws {
        let channel = UpdateChannel.current()
        if repository == UpdateChannel.privateRepository && !channel.isPrivate { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/tags/\(tag)")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        channel.authorize(&request)
        let cachedMarker = try Data(contentsOf: folder.appendingPathComponent("TATWO-OS.install-ready"))
        let data = try await UpdateReleaseRevalidation.verify(session: GitHubReleaseUpdateChecker.shared.session,
            request: request, tag: tag, cachedMarker: cachedMarker) { asset in
                guard let publicURL = URL(string: asset.browser_download_url), publicURL.scheme == "https",
                      publicURL.host == "github.com",
                      publicURL.path == "/\(repository)/releases/download/\(tag)/TATWO-OS.install-ready" else { throw URLError(.badURL) }
                var url = publicURL
                if repository == UpdateChannel.privateRepository {
                    guard let id = asset.id, id > 0 else { throw URLError(.badURL) }
                    url = URL(string: "https://api.github.com/repos/\(repository)/releases/assets/\(id)")!
                }
                var marker = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                marker.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                channel.authorize(&marker)
                return marker
            }
        try Task.checkCancellation()
        try data.write(to: folder.appendingPathComponent("release.json"), options: .atomic)
    }
    private let fileManager: FileManager
    private let directory: URL

    init(fileManager: FileManager = .default,
         directory: URL? = nil) {
        self.fileManager = fileManager
        self.directory = directory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/TATWO OS/Updater", isDirectory: true)
        network.pathUpdateHandler = { [weak self] path in
            let allowed = path.status == .satisfied && path.isExpensive == false && !path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.unmetered = allowed
                if !allowed && !self.manualDownload && self.phase == .starting {
                    self.preparationReason = "已找到 \(self.pendingCandidate?.tag ?? "新版")，等 Wi‑Fi 再自動下載"
                    self.download?.cancel()
                }
                if allowed, let candidate = self.pendingCandidate {
                    self.prefetch(to: candidate.tag, repository: candidate.repository)
                }
            }
        }
        network.start(queue: DispatchQueue(label: "tatwo.update.network"))
    }

    private var runID = UUID().uuidString
    var resultURL: URL { directory.appendingPathComponent("results/\(runID).json") }
    var pendingURL: URL { directory.appendingPathComponent("runs/\(runID).json") }
    var logURL: URL { directory.appendingPathComponent("logs/\(runID).log") }

    static func reconcileOnLaunch(destination: String = destinationApp) {
        let fm = FileManager.default, dest = URL(fileURLWithPath: destination)
        var backupDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destination + ".old", isDirectory: &backupDirectory), backupDirectory.boolValue else { return }
        func output(_ executable: String, _ arguments: [String]) -> String? {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment; environment["LC_ALL"] = "C"; process.environment = environment
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        func active(_ text: String) -> Bool {
            let fields = text.split(separator: "\n", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let first = fields.first, let pid = Int32(first), pid > 0 else { return false }
            if let start = output("/bin/ps", ["-p", String(pid), "-o", "lstart="]), !start.isEmpty {
                return fields.count == 1 || start == fields[1]
            }
            return kill(pid, 0) == 0 || errno != ESRCH
        }
        func validApp(_ app: URL) -> Bool {
            guard (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == "ai.tatwo.tatwo2" else { return false }
            return output("/usr/bin/codesign", ["--verify", "--strict", app.path]) != nil
        }
        func version(_ app: URL) -> String? {
            guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            return info["CFBundleShortVersionString"] as? String
        }
        let parent = dest.deletingLastPathComponent(), lock = parent.appendingPathComponent(".tatwo-update.lock")
        let admission = open(parent.appendingPathComponent(".tatwo-update.admission").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard admission >= 0 else { return }
        defer { close(admission) }
        guard flock(admission, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(admission, LOCK_UN) }
        guard let start = output("/bin/ps", ["-p", String(getpid()), "-o", "lstart="]), !start.isEmpty else { return }
        let identity = "\(getpid())\n\(start)\n"
        func claim(_ path: URL) -> Bool {
            let temporary = path.appendingPathExtension("tmp.\(UUID().uuidString)")
            defer {
                // Only metadata created by this failed claim; no retained transaction is removed.
                if fm.fileExists(atPath: temporary.path) {
                    try? fm.removeItem(at: temporary.appendingPathComponent("owner")); rmdir(temporary.path)
                }
            }
            do {
                try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try Data(identity.utf8).write(to: temporary.appendingPathComponent("owner"), options: .atomic)
                // macOS exclusive rename never nests into or replaces a competing lock.
                return renamex_np(temporary.path, path.path, UInt32(RENAME_EXCL)) == 0
            } catch { return false }
        }
        func owner(_ path: URL) -> String { (try? String(contentsOf: path.appendingPathComponent("owner"), encoding: .utf8)) ?? "" }
        func oldEnough(_ path: URL) -> Bool {
            let date = try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return date.map { Date().timeIntervalSince($0) > 600 } ?? false
        }
        let owned = claim(lock)
        if !owned {
            guard (try? lock.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  !active(owner(lock)), !owner(lock).isEmpty || oldEnough(lock) else { return }
        }
        let snapshot = owner(lock), guardPath = lock.appendingPathComponent("reconcile")
        var guarded = false
        defer {
            // Retirement waits for a short claimant probe rather than leaving a live-owner lock behind.
            if flock(admission, LOCK_EX) == 0 {
                if guarded {
                    try? fm.removeItem(at: guardPath.appendingPathComponent("owner")); rmdir(guardPath.path)
                }
                if owned {
                    try? fm.removeItem(at: lock.appendingPathComponent("owner")); rmdir(lock.path)
                } else if guarded {
                    try? fm.moveItem(at: lock, to: parent.appendingPathComponent(".tatwo-lock-retained.\(UUID().uuidString)"))
                }
                flock(admission, LOCK_UN)
            }
        }
        if fm.fileExists(atPath: guardPath.path) {
            guard oldEnough(guardPath), !active(owner(guardPath)) else { return }
            do { try fm.moveItem(at: guardPath, to: lock.appendingPathComponent("reconcile-orphan.\(UUID().uuidString)")) }
            catch { return }
        }
        guard claim(guardPath) else { return }
        guarded = true
        guard owner(lock) == snapshot else { return }
        // The owned lock/reconcile guard fences installers during seal verification.
        flock(admission, LOCK_UN)
        for stage in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            where stage.lastPathComponent.hasPrefix(".tatwo-update.") && stage.pathExtension == "noindex" {
            let file = stage.appendingPathComponent("transaction.json"), result = stage.appendingPathComponent("result.json")
            guard (try? stage.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  fm.fileExists(atPath: file.path) else { continue }
            func receipt(_ message: String, ok: Bool = false) {
                try? JSONSerialization.data(withJSONObject: ["ok": ok, "message": message]).write(to: result, options: .atomic)
            }
            guard let data = try? Data(contentsOf: file),
                  var record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let phase = record["phase"], let pid = record["owner"].flatMap(Int32.init), pid > 0,
                  record["backup"] == destination + ".old" else { receipt("invalid_transaction"); continue }
            guard !["committed", "recovered", "rolled_back"].contains(phase),
                  !active("\(pid)\n\(record["ownerStart"] ?? "")") else { continue }
            let backup = URL(fileURLWithPath: destination + ".old"), new = URL(fileURLWithPath: destination + ".new")
            do {
                guard (try? backup.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                      (try? dest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { receipt("restore_refused"); continue }
                if ["replacing", "replaced"].contains(phase), !fm.fileExists(atPath: new.path),
                   (try? new.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                   let next = record["nextVersion"], version(dest) == next, validApp(dest) {
                    record["phase"] = "committed"
                    try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
                    receipt("interrupted_commit_completed", ok: true); continue
                }
                guard validApp(backup) else { receipt("restore_refused"); continue }
                // Only the actual restore holds admission; codesign stays outside it.
                guard flock(admission, LOCK_EX | LOCK_NB) == 0 else { return }
                defer { flock(admission, LOCK_UN) }
                guard owner(lock) == snapshot, owner(guardPath) == identity,
                      (try? Data(contentsOf: file)) == data else { return }
                if fm.fileExists(atPath: destination) {
                    try fm.moveItem(at: dest, to: stage.appendingPathComponent("interrupted.app.disabled"))
                }
                try fm.moveItem(at: backup, to: dest)
                record["phase"] = "recovered"
                try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
                receipt("interrupted_restored_on_launch")
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
    private func beginPrefetch(to tag: String, repository: String? = nil) {
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
            defer {
                download = nil
                if Task.isCancelled, unmetered || manualDownload, let next = pendingCandidate {
                    prefetch(to: next.tag, repository: next.repository, force: manualDownload)
                }
            }
            do {
                let zip = try await prefetch(tag: tag, repository: repository, session: checker.session, id: id)
                try Task.checkCancellation()
                try checkSpace()
                prepared = (tag, repository, zip); pendingCandidate = nil
                phase = .ready
            } catch {
                phase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
                downloadProgress = nil
            }
        }
    }

    func cancelUpdate() { pendingCandidate = nil; preparationReason = "已暫停準備"; download?.cancel() }

    func resumableBytes(for tag: String) -> Int64? {
        guard PeerUpdateSource.validTag(tag),
              let files = fileManager.enumerator(at: directory.appendingPathComponent("download/\(GitHubReleaseUpdateChecker.shared.repository)/\(tag)"),
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
            let result = try await session.data(for: request, delegate: UpdateRedirectDelegate.shared); try check(result.1); return result
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
        let runtimes = release.assets.filter {
            $0.name.range(of: "^TATWO-OS-runtime-[0-9a-f]{12}[.]zip$", options: .regularExpression) != nil
        }
        guard !split || runtimes.count == 1 else { throw failure("執行環境附件缺少或不唯一") }
        let runtime = split ? try asset(runtimes[0].name) : nil
        let runtimeReusable = runtime.map {
            UpdateRuntimeLayer.canReuse(contents: URL(fileURLWithPath: Self.destinationApp).appendingPathComponent("Contents"),
                                        archiveName: $0.name)
        } ?? false
        let installed = Bundle(url: URL(fileURLWithPath: Self.destinationApp))?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let deltaName = UpdateDelta.name(installed: installed, tag: tag)
        let delta = release.assets.first { $0.name == deltaName }
        let useDelta = split && delta.map {
            UpdateDelta.reasonable($0.size, appSize: archives[0].size, runtimeReusable: runtimeReusable)
        } == true
            && [deltaName!, deltaName! + ".sha256", "TATWO-OS.manifest.json", "TATWO-OS.manifest.json.sha256"].allSatisfy { name in
                (try? asset(name)) != nil
            }
        if useDelta { archives = [try asset("TATWO-OS.manifest.json"), try asset(deltaName!)] }
        if !useDelta, !runtimeReusable, let runtime { archives.append(runtime) }
        // Use the selected delta/layered/full route's bytes before any payload download.
        // The checksum-bound uncompressed manifest below may only raise this estimate.
        candidateBytes = 0
        for archive in archives {
            guard archive.size > 0, archive.size <= 1_000_000_000_000,
                  candidateBytes <= 1_000_000_000_000 - archive.size else { throw failure("更新附件大小無效") }
            candidateBytes += archive.size
        }
        try checkSpace()
        let folder = directory.appendingPathComponent("download/\(repository)/\(tag)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(repository.utf8).write(to: folder.appendingPathComponent("repository"), options: .atomic)
        try data.write(to: folder.appendingPathComponent("release.json"), options: .atomic)
        for name in ["TATWO-OS.install-ready", "TATWO-OS.manifest.json", "TATWO-OS.manifest.json.sha256", "TATWO-OS.zip.sha256"] {
            let (bytes, response) = try await session.data(for: try assetRequest(asset(name)), delegate: UpdateRedirectDelegate.shared)
            try check(response); try bytes.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        let manifestURL = folder.appendingPathComponent("TATWO-OS.manifest.json")
        let expected = try String(contentsOf: folder.appendingPathComponent("TATWO-OS.manifest.json.sha256"), encoding: .utf8).split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        guard try await Self.digest(manifestURL) == expected?.lowercased(),
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              let files = manifest["files"] as? [[String: Any]], !files.isEmpty else { throw failure("無法確認候選 App 大小") }
        var expandedBytes: Int64 = 0
        for file in files {
            guard let size = file["size"] as? NSNumber, size.int64Value >= 0,
                  size.int64Value < 1_000_000_000_000,
                  expandedBytes <= 1_000_000_000_000 - size.int64Value else { throw failure("候選大小無效") }
            expandedBytes += size.int64Value
        }
        guard expandedBytes > 0 else { throw failure("候選大小無效") }
        candidateBytes = max(candidateBytes, expandedBytes)
        try checkSpace()
        let marker = try String(contentsOf: folder.appendingPathComponent("TATWO-OS.install-ready"), encoding: .utf8)
        let bindings = marker.split(separator: "\n").map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        func markerMatches(_ name: String, _ hash: String) -> Bool {
            guard bindings.contains(where: { $0.first?.count == 64 }) else { return false } // App preparation requires a hash-bound manifest.
            let entries = bindings.filter { $0.count == 2 && $0[1] == name }
            return entries.count == 1 && entries[0][0].lowercased() == hash.lowercased()
        }
        guard markerMatches("TATWO-OS.manifest.json", expected ?? "") else { throw failure("install-ready SHA 不符") }
        let plannedBytes = archives.reduce(Int64(0)) { $0 + max(0, $1.size) }
        totalBytes = plannedBytes
        speedSamples = [(ProcessInfo.processInfo.systemUptime, 0)]
        let deltaProgress = useDelta ? String(format: "差異更新：%.1f MB", Double(delta!.size) / 1_000_000) + " · " : ""
        var expectedHashes: [String: String] = [:]
        for archive in archives {
            let checksum = try asset(archive.name + ".sha256")
            let (sha, _) = try await retryDownload {
                let result = try await session.data(for: try assetRequest(checksum), delegate: UpdateRedirectDelegate.shared)
                try check(result.1); return result
            }
            let expected = String(decoding: sha, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            guard expected.range(of: "^[0-9A-Fa-f]{64}$", options: .regularExpression) != nil else { throw failure("校驗失敗：SHA-256 格式錯誤") }
            try sha.write(to: folder.appendingPathComponent(checksum.name), options: .atomic)
            guard markerMatches(archive.name, expected) else { throw failure("install-ready SHA 不符") }
            expectedHashes[archive.name] = expected.lowercased()
        }
        downloadSource = "詢問已配對設備…"
        let offers = await PeerUpdateSource.discover(DeviceRegistry().list())
        try Task.checkCancellation()
        var attachmentProgress: [String: Int64] = [:]
        var downloadPhases: [[String: Any]] = []
        var verifySeconds: Double = 0
        func fetch(_ archive: Asset, offset: Int64) async throws -> URL {
            let started = ProcessInfo.processInfo.systemUptime
            var source = "github", parts = 0
            let verification = UpdateVerificationTiming()
            defer {
                verifySeconds += verification.seconds
                downloadPhases.append(["name": archive.name, "source": source, "bytes": archive.size,
                    "seconds": max(0, ProcessInfo.processInfo.systemUptime - started - verification.seconds), "parts": parts])
            }
            let expected = expectedHashes[archive.name]!
            let zip = folder.appendingPathComponent(archive.name)
            var verified = false
            defer {
                // A sibling can fail after this download completes but before its SHA gate.
                if !verified { try? fileManager.removeItem(at: zip) }
                Self.removeInvalidDownloads(in: folder)
            }
            if fileManager.fileExists(atPath: zip.path) {
                let verifyStarted = ProcessInfo.processInfo.systemUptime
                let actual = try await Self.digest(zip)
                verification.add(ProcessInfo.processInfo.systemUptime - verifyStarted)
                if actual == expected.lowercased() {
                    verified = true
                    source = "prefetched"
                    downloadSource = deltaProgress + "使用已校驗快取"
                    attachmentProgress[archive.name] = archive.size
                    recordDownloadProgress(attachmentProgress.values.reduce(0, +), total: plannedBytes); return zip
                }
                try fileManager.moveItem(at: zip, to: folder.appendingPathComponent("invalid-\(UUID().uuidString).zip"))
            }
            for offer in offers {
                try Task.checkCancellation()
                downloadSource = deltaProgress + "從『\(offer.device.name)』取得…"
                if let candidate = try? await PeerUpdateSource.pull(offer, tag: tag, name: archive.name, folder: folder) {
                    let verifyStarted = ProcessInfo.processInfo.systemUptime
                    defer { verification.add(ProcessInfo.processInfo.systemUptime - verifyStarted) }
                    if let actual = try? await Self.digest(candidate), actual == expected {
                        try Task.checkCancellation()
                        verified = true
                        source = "peer"
                        attachmentProgress[archive.name] = archive.size
                        try fileManager.moveItem(at: candidate, to: zip)
                        downloadSource = deltaProgress + String(format: "從『%@』取得 %.1f MB", offer.device.name, Double(archive.size) / 1_000_000)
                        return zip
                    }
                    try Task.checkCancellation()
                    try fileManager.moveItem(at: candidate, to: folder.appendingPathComponent("invalid-\(UUID().uuidString).zip"))
                }
                // Interrupted candidates stay in peer-key; checksum-rejected downloads are removed on exit.
            }
            try Task.checkCancellation()
            let report: @Sendable (Int64, Int64) -> Void = { [weak self] written, total in
                Task { @MainActor in
                    guard let self, self.downloadID == id, self.phase == .starting else { return }
                    let written = max(0, min(archive.size, written))
                    attachmentProgress[archive.name] = written
                    let offset = attachmentProgress.values.reduce(0, +) - written
                    self.recordDownloadProgress(offset + written, total: max(plannedBytes, offset + max(0, total)))
                }
            }
            let mirror = UserDefaults.standard.string(forKey: "update-mirror-base")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let base = URL(string: mirror), base.scheme == "https", base.host != nil,
               base.user == nil, base.password == nil, base.query == nil, base.fragment == nil {
                let candidate = zip.appendingPathExtension("mirror")
                downloadSource = deltaProgress + "從鏡像下載…"
                do {
                    let mirrorRequest = URLRequest(url: base.appendingPathComponent(archive.name))
                    parts = try await UpdateParallelDownload.download(request: mirrorRequest, destination: candidate,
                        size: archive.size, expected: expected, verification: { verification.add($0) }, report: report)
                    try fileManager.moveItem(at: candidate, to: zip)
                    verified = true
                    source = "mirror"
                    return zip
                } catch {
                    try Task.checkCancellation()
                    try? fileManager.removeItem(at: candidate)
                }
            }
            try Task.checkCancellation()
            downloadSource = deltaProgress + "從 GitHub 下載…"
            parts = try await retryDownload {
                if archive.size < 20_000_000 {
                    let progress = UpdateDownloadProgress(destination: zip, rebase: { _, _ in }, report: report)
                    _ = try await progress.download(request: try assetRequest(archive))
                    return 1
                }
                return try await UpdateParallelDownload.download(request: try assetRequest(archive), destination: zip,
                    size: archive.size, expected: expected, verification: { verification.add($0) }, report: report)
            }
            try Task.checkCancellation()
            let verifyStarted = ProcessInfo.processInfo.systemUptime
            guard try await Self.digest(zip) == expected.lowercased() else {
                try fileManager.moveItem(at: zip, to: folder.appendingPathComponent("invalid-\(UUID().uuidString).zip"))
                throw failure("校驗失敗：SHA-256 不符，請重新下載")
            }
            verification.add(ProcessInfo.processInfo.systemUptime - verifyStarted)
            verified = true
            return zip
        }
        var result = UpdateArchives(), completed: Int64 = 0
        result.route = useDelta ? "delta" : "layered"
        // Verify each layer before requesting the next; ranges within a layer stay parallel.
        for archive in archives {
            let zip = try await fetch(archive, offset: completed)
            attachmentProgress[archive.name] = archive.size
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
        try JSONSerialization.data(withJSONObject: ["download": downloadPhases, "verify": verifySeconds,
            "extract": 0, "switch": 0]).write(to: folder.appendingPathComponent("download-phases.json"), options: .atomic)
        // Cache the shared, tag-pinned installer too; restart never fetches a control script.
        var scriptRequest = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/contents/install.sh?ref=\(tag)")!)
        scriptRequest.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        channel.authorize(&scriptRequest)
        let (script, response) = try await session.data(for: scriptRequest, delegate: UpdateRedirectDelegate.shared)
        try check(response)
        let local = folder.appendingPathComponent("install.sh")
        guard String(decoding: script, as: UTF8.self).contains("# OFFLINE-RELEASE-BEGIN") else {
            throw failure("此版本安裝器尚未支援背景準備，請使用進階更新")
        }
        try script.write(to: local, options: .atomic)
        result.privateInstaller = local
        downloadProgress = 1
        return result
    }

    private static func removeInvalidDownloads(in folder: URL) {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
            where file.lastPathComponent.hasPrefix("invalid-") && file.pathExtension == "zip" {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? fm.removeItem(at: file) // Our own checksum-rejected download, never user work.
        }
    }

    // PARALLEL-DOWNLOAD-BEGIN
    /// Bounded, disk-backed ranges: never materialize a runtime archive in RAM.
    private enum UpdateParallelDownload {
        static func digest(_ file: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }

        static func download(request: URLRequest, destination: URL, size: Int64, expected: String,
                             verification: @escaping @Sendable (TimeInterval) -> Void = { _ in },
                             report: @escaping @Sendable (Int64, Int64) -> Void) async throws -> Int {
            func checkedDigest() throws -> String {
                let started = ProcessInfo.processInfo.systemUptime
                defer { verification(ProcessInfo.processInfo.systemUptime - started) }
                return try digest(destination)
            }
            let configured = Int(ProcessInfo.processInfo.environment["TATWO_OS_DOWNLOAD_PARTS"] ?? "24") ?? 24
            let count = (1...32).contains(configured) ? configured : 24
            if size >= 20_000_000, count > 1 {
                var joined = false
                do {
                    try await ranges(request: request, destination: destination, size: size, count: count, report: report)
                    joined = true
                } catch {
                    try Task.checkCancellation()
                    try? FileManager.default.removeItem(at: destination)
                    // Unsupported/failed ranges may fall back, but checksum failure must not.
                }
                if joined {
                    do {
                        guard try checkedDigest() == expected else { throw URLError(.cannotDecodeContentData) }
                        return count
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        try? FileManager.default.removeItem(at: partsFolder(request, destination, size, count))
                        throw error
                    }
                }
            }
            _ = try await UpdateDownloadProgress(destination: destination, rebase: { _, _ in }, report: report).download(request: request)
            guard try checkedDigest() == expected else {
                try? FileManager.default.removeItem(at: destination)
                throw URLError(.cannotDecodeContentData)
            }
            try? FileManager.default.removeItem(at: partsFolder(request, destination, size, count))
            return 1
        }

        private static func partsFolder(_ request: URLRequest, _ destination: URL, _ size: Int64, _ count: Int) -> URL {
            let identity = SHA256.hash(data: Data((request.url?.absoluteString ?? "").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            return destination.appendingPathExtension("parts-\(identity)-\(size)-\(count)")
        }

        private static func ranges(request: URLRequest, destination: URL, size: Int64, count: Int,
                                   report: @escaping @Sendable (Int64, Int64) -> Void) async throws {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            var head = request; head.httpMethod = "HEAD"; head.timeoutInterval = 60
            head.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (_, response) = try await session.data(for: head, delegate: UpdateRedirectDelegate.shared)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.expectedContentLength == size else { throw URLError(.badServerResponse) }
            var transport = request
            if let resolved = response.url, resolved != request.url {
                guard resolved.scheme == "https" else { throw URLError(.badURL) }
                transport.url = resolved
                if resolved.host != request.url?.host || resolved.port != request.url?.port {
                    transport.setValue(nil, forHTTPHeaderField: "Authorization")
                }
            }
            let rangeRequest = transport
            let fm = FileManager.default
            // Source identity prevents a mirror's partial bytes/resume data crossing into GitHub.
            let folder = partsFolder(request, destination, size, count)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let progress = UpdateRangeProgress(count: count, total: size, report: report)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<count {
                    let start = size * Int64(index) / Int64(count), end = size * Int64(index + 1) / Int64(count) - 1
                    group.addTask {
                        let part = folder.appendingPathComponent(String(index))
                        if (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value == end - start + 1 {
                            progress.update(index, bytes: end - start + 1); return
                        }
                        try? fm.removeItem(at: part)
                        var ranged = rangeRequest
                        ranged.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                        ranged.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                        for attempt in 0..<3 {
                            do {
                                _ = try await UpdateDownloadProgress(destination: part, rebase: { _, _ in }) { bytes, _ in
                                    progress.update(index, bytes: min(end - start + 1, max(0, bytes)))
                                }.download(request: ranged)
                                guard (try fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value == end - start + 1
                                else { throw URLError(.badServerResponse) }
                                return
                            } catch {
                                try Task.checkCancellation()
                                try? fm.removeItem(at: part)
                                if attempt == 2 { throw error }
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
            let joining = destination.appendingPathExtension("joining")
            fm.createFile(atPath: joining.path, contents: nil)
            let writer = try FileHandle(forWritingTo: joining)
            defer { try? writer.close(); try? fm.removeItem(at: joining) }
            try writer.truncate(atOffset: 0)
            for index in 0..<count {
                try Task.checkCancellation()
                let reader = try FileHandle(forReadingFrom: folder.appendingPathComponent(String(index)))
                do {
                    defer { try? reader.close() }
                    while let data = try reader.read(upToCount: 1_048_576), !data.isEmpty { try writer.write(contentsOf: data) }
                }
            }
            try writer.close()
            try Task.checkCancellation()
            try fm.moveItem(at: joining, to: destination)
            try? fm.removeItem(at: folder)
        }
    }

    private final class UpdateVerificationTiming: @unchecked Sendable {
        private let lock = NSLock()
        private var elapsed: TimeInterval = 0
        var seconds: TimeInterval { lock.withLock { elapsed } }
        func add(_ seconds: TimeInterval) { lock.withLock { elapsed += seconds } }
    }

    private final class UpdateRangeProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [Int64]
        private let total: Int64
        private let report: @Sendable (Int64, Int64) -> Void
        init(count: Int, total: Int64, report: @escaping @Sendable (Int64, Int64) -> Void) {
            bytes = Array(repeating: 0, count: count); self.total = total; self.report = report
        }
        func update(_ index: Int, bytes value: Int64) {
            let written = lock.withLock { bytes[index] = value; return bytes.reduce(0, +) }
            report(written, total)
        }
    }
    // PARALLEL-DOWNLOAD-END

    private func recordDownloadProgress(_ written: Int64, total: Int64,
                                        now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        downloadedBytes = max(downloadedBytes, written)
        totalBytes = max(totalBytes, total)
        // 每 1% 才發布一次進度，避免每個 chunk 都重繪布標。
        let next: Double? = totalBytes > 0 ? min(1, Double(downloadedBytes) / Double(totalBytes)) : nil
        if next.map({ Int($0 * 100) }) != downloadProgress.map({ Int($0 * 100) }) || next == nil || next == 1 {
            downloadProgress = next
        }
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
                privateInstaller: zip.privateInstaller?.path ?? "", githubUsername: zip.username ?? "",
                prefetchedRoute: zip.route
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
            // 讓畫面先顯示「更新中」再退出；使用者已在 Island 確認過「重開」，這次退出不再問第二次。
            TatwoInterruptGate.bypassNextTerminate = true
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
            if let seconds = object["installSeconds"] as? Int, object["ok"] as? Bool == true {
                lastResult = (lastResult ?? "") + " · 上次更新用了 \(seconds) 秒"
            }
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
                             privateInstaller: String = "", githubUsername: String = "",
                             prefetchedRoute: String = "") -> String {
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
        export TATWO_OS_PREFETCHED_ROUTE=\(quoted(prefetchedRoute))
        export TATWO_OS_PREFETCHED_MANIFEST=\(quoted(prefetchedManifest))
        PRIVATE_INSTALLER=\(quoted(privateInstaller))
        export TATWO_OS_GITHUB_USERNAME=\(quoted(githubUsername))
        START_SECONDS=$SECONDS
        WAIT=$((\(helperWaitSeconds) * 5))
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        write_result() {
          local install_seconds
          install_seconds="$(if [ -f "${TATWO_OS_TIMING_FILE:-}" ]; then cat "$TATWO_OS_TIMING_FILE"; else echo "$((SECONDS - START_SECONDS))"; fi)"
          [[ "$install_seconds" =~ ^[0-9]+$ ]] || install_seconds=0
          # Canonicalize leading zeroes without arithmetic overflow; JSON numbers cannot start with 00.
          install_seconds="$(printf '%s' "$install_seconds" | sed 's/^0*//')"; install_seconds="${install_seconds:-0}"
          printf '{"ok":%s,"tag":"%s","message":"%s","runID":"%s","installSeconds":%s}\\n' "$1" "$TAG" "$2" "$RUN_ID" "$install_seconds" > "$RESULT.tmp"
          local phases='{"download":[],"verify":0,"extract":0,"switch":0}'
          if [ -f "$RESULT.phases" ]; then phases="$(cat "$RESULT.phases")"; fi
          if [ -f "$RESULT.phases" ]; then plutil -insert phases -json "$phases" "$RESULT.tmp"; fi
          local prefetch_phases="$(dirname "$PRIVATE_INSTALLER")/download-phases.json"
          if [ -f "$prefetch_phases" ]; then
            if [ ! -f "$RESULT.phases" ]; then plutil -insert phases -json "$phases" "$RESULT.tmp"; fi
            local downloads
            downloads="$(plutil -extract download json -o - "$prefetch_phases")"
            plutil -replace phases.download -json "$downloads" "$RESULT.tmp"
            plutil -insert phases.prefetchVerify -float "$(plutil -extract verify raw -o - "$prefetch_phases")" "$RESULT.tmp"
          fi
          mv "$RESULT.tmp" "$RESULT"
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
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt "$WAIT" ]; do sleep 0.2; i=$((i + 1)); done
        if kill -0 "$PID" 2>/dev/null; then
          write_result false app_still_running
          finish
        fi
        START_SECONDS=$SECONDS
        export TATWO_OS_INSTALL_STARTED_AT="$(date +%s)"
        export TATWO_OS_TIMING_FILE="$RESULT.seconds"
        export TATWO_OS_PHASES_FILE="$RESULT.phases"
        if pgrep -x tatwo2 >/dev/null; then
          write_result false app_relaunched
          finish
        fi
        if [ -n "$PRIVATE_INSTALLER" ]; then
          SCRIPT="$PRIVATE_INSTALLER"
          export TATWO_OS_OFFLINE_RELEASE="$(dirname "$SCRIPT")"
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
enum UpdateMarkState {
    static func title(phase: InAppUpdater.Phase, progress: Double?, userStarted: Bool) -> String {
        if case .failed = phase { return "更新失敗" }
        guard userStarted else { return "更新" }
        if phase == .ready || phase == .handedOff { return "重開" }
        let value = progress.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return "下載中 \(Int((min(1, max(0, value)) * 100).rounded(.down)))%"
    }
}
