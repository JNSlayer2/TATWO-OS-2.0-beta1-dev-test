import Foundation
import Combine
import AppKit

/// One App-owned process per entrance. Engines receive adapters, never the helper.
final class GBrainService: ObservableObject {
    static let shared = GBrainService()
    @Published private(set) var status = "未設定"
    @Published private(set) var healthy = false
    @Published private(set) var pageCount: Int?
    @Published private(set) var lastWrite = "尚無寫入資訊"
    @Published private(set) var openAIConfigured = false
    @Published private(set) var anthropicConfigured = false
    @Published private(set) var semanticEnabled = false
    @Published private(set) var mode = "unconfigured"
    @Published private(set) var primaryName = "未設定"
    @Published private(set) var message = ""
    private let queue = DispatchQueue(label: "tatwo.gbrain.service")
    private var process: Process?
    private var input: Pipe?
    private var monitor: DispatchSourceTimer?
    private var terminationObserver: NSObjectProtocol?
    private var outputBuffer = Data()
    let entry: TatwoEntry
    private let keychain: GBrainSecretStore
    var isPrimary: Bool { (try? DeviceIdentityStore.readLocal(entry: entry))?.role == .primary }
    var directory: String { entry.gbrainDir.path }

    init(entry: TatwoEntry = TatwoEntry(), secrets: GBrainSecretStore? = nil) {
        self.entry = entry
        self.keychain = secrets ?? GBrainKeychain(root: entry.root.path)
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in self?.stop() }
    }
    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        monitor?.cancel()
        try? input?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }
    }
    static func definition(environment: [String: String]) -> [String: Any]? {
        guard environment["TATWO2_SOURCETEST"] != "1",
              !NativeStagingIsolation.isEnabled(environment),
              let identity = try? DeviceIdentityStore.readLocal(entry: TatwoEntry(environment: environment)),
              identity.role == .primary || identity.primaryDeviceID != nil
        else { return nil }
        let paths = EnginePaths(environment: environment)
        let script = URL(fileURLWithPath: ClaudeSidecar.scriptPath(for: .claude))
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("gbrain-adapter/server.mjs")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        let node = paths.runtimeBinDirectory.appendingPathComponent("node").path
        return ["command": FileManager.default.isExecutableFile(atPath: node) ? node : "/usr/bin/env",
                "args": (FileManager.default.isExecutableFile(atPath: node) ? [] : ["node"]) + [script.path, TatwoEntry(environment: environment).root.path]]
    }
    /// Reuse an already registered legacy wrapper, never copy its environment / DB URL.
    /// Only known wrapper names are adopted; a direct new gbrain binary is not legacy.
    static func adoptLegacy(_ definition: [String: Any]?, environment: [String: String]) {
        guard environment["TATWO2_SOURCETEST"] != "1", !NativeStagingIsolation.isEnabled(environment),
              let definition, let command = definition["command"] as? String,
              command.hasPrefix("/"),
              ["gbrain-unified", "gbrain-allai"].contains(URL(fileURLWithPath: command).lastPathComponent)
        else { return }
        let entry = TatwoEntry(environment: environment)
        guard entry.exists, let identity = try? DeviceIdentityStore.readLocal(entry: entry) else { return }
        let config = entry.gbrainDir.appendingPathComponent("connection.json")
        guard !FileManager.default.fileExists(atPath: config.path) else { return }
        let args = definition["args"] as? [String] ?? []
        guard args.allSatisfy({ ["serve", "stdio", "--stdio"].contains($0) }) else { return }
        // Old wrapper must own credentials itself; never transfer inline secrets.
        let text = ([command] + args).joined(separator: " ")
        guard !text.contains("sk-"), !text.contains("://"), !text.lowercased().contains("token"),
              !text.lowercased().contains("password"), !text.contains("--key") else { return }
        let object: [String: Any] = ["mode": identity.role == .primary ? "legacy" : "ssh-stdio",
                                     "wrapper": true, "command": command, "args": args]
        do {
            try FileManager.default.createDirectory(at: entry.gbrainDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: config, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        } catch { /* Fail closed; startup will report that setup is still required. */ }
    }
    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }
    private func startOnQueue() {
        guard process?.isRunning != true, entry.exists,
              (try? DeviceIdentityStore.readLocal(entry: entry)) != nil else { return }
        let environment = ProcessInfo.processInfo.environment
        guard environment["TATWO2_SOURCETEST"] != "1", !NativeStagingIsolation.isEnabled(environment) else { return }
        configureSecondaryIfNeeded()
        let script = URL(fileURLWithPath: ClaudeSidecar.scriptPath(for: .claude))
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("gbrain-adapter/service.mjs")
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gbrain")
        let node = EnginePaths().runtimeBinDirectory.appendingPathComponent("node")
        guard FileManager.default.isExecutableFile(atPath: node.path), FileManager.default.fileExists(atPath: script.path) else {
            publishFailure("內建 GBrain runtime 尚未安裝"); return
        }
        do {
            let p = Process(), incoming = Pipe(), outgoing = Pipe()
            var env = ["PATH": node.deletingLastPathComponent().path + ":/usr/bin:/bin",
                       "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
            if let tmp = environment["TMPDIR"] { env["TMPDIR"] = tmp }
            if let token = try keychain.read("bearer") { env["TATWO_GBRAIN_TOKEN"] = token }
            // Only a primary can read provider credentials. Secondary never probes them.
            if isPrimary {
                if let key = try keychain.read("openai") { env["OPENAI_API_KEY"] = key }
                if let key = try keychain.read("anthropic") { env["ANTHROPIC_API_KEY"] = key }
            }
            p.executableURL = node; p.arguments = [script.path, entry.root.path, helper.path]
            p.environment = env; p.standardInput = incoming; p.standardOutput = outgoing
            p.standardError = FileHandle.nullDevice
            outputBuffer = Data()
            outgoing.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                guard !bytes.isEmpty else { handle.readabilityHandler = nil; return }
                self?.queue.async {
                    guard self?.process === p, p.isRunning else { return }
                    self?.receive(bytes, input: incoming)
                }
            }
            p.terminationHandler = { [weak self] _ in self?.publishFailure("GBrain 已停止；請檢查設定") }
            try p.run()
            process = p; input = incoming
            monitor?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 5)
            timer.setEventHandler { [weak self] in self?.refreshOnQueue() }
            timer.resume(); monitor = timer
        } catch { publishFailure("GBrain 啟動失敗；金鑰與錯誤內容不記錄") }
    }
    private func configureSecondaryIfNeeded() {
        let config = entry.gbrainDir.appendingPathComponent("connection.json")
        guard !FileManager.default.fileExists(atPath: config.path),
              let identity = try? DeviceIdentityStore.readLocal(entry: entry),
              identity.role == .secondary, let primary = identity.primaryDeviceID,
              let record = DeviceStatusReader.registry().first(where: { $0.id.lowercased() == primary.lowercased() && $0.role == .primary })
        else { return }
        let object: [String: Any] = ["mode": "remote", "host": record.host, "user": record.user,
                                     "sshPort": record.sshPort, "primary": record.name, "primaryID": primary]
        do {
            try FileManager.default.createDirectory(at: entry.gbrainDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: config, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        } catch { /* No fallback local database on a secondary. */ }
    }
    private func receive(_ bytes: Data, input: Pipe) {
        outputBuffer.append(bytes)
        guard outputBuffer.count < 65536 else { outputBuffer.removeAll(); process?.terminate(); return }
        while let end = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer[..<end]; outputBuffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: String],
                  let token = object["token"] else { continue }
            do {
                let credentialName = "bearer"
                try keychain.save(token, name: credentialName)
                try input.fileHandleForWriting.write(contentsOf: Data("stored\n".utf8))
            } catch { process?.terminate(); publishFailure("無法儲存服務憑證到鑰匙圈") }
        }
    }
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            monitor?.cancel(); monitor = nil
            try? input?.fileHandleForWriting.close()
            if process?.isRunning == true { process?.terminate() }
        }
    }
    private func restartOnQueue() {
        if process?.isRunning == true {
            try? input?.fileHandleForWriting.close()
            process?.terminate()
            let deadline = Date().addingTimeInterval(60)
            while process?.isRunning == true && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            guard process?.isRunning != true else { publishFailure("服務尚未停止，不會另開資料庫"); return }
        }
        startOnQueue()
    }
    func refresh() { queue.async { [weak self] in self?.refreshOnQueue() } }
    private func refreshOnQueue() {
        // An unpaired secondary can finish onboarding without a database. Once pairing
        // assigns its primary, reuse W80's trusted connection setup and the single service.
        let environment = ProcessInfo.processInfo.environment
        let connection = entry.gbrainDir.appendingPathComponent("connection.json")
        if process?.isRunning != true,
           environment["TATWO2_SOURCETEST"] != "1", !NativeStagingIsolation.isEnabled(environment),
           !FileManager.default.fileExists(atPath: connection.path),
           let identity = try? DeviceIdentityStore.readLocal(entry: entry),
           identity.role == .secondary, identity.primaryDeviceID != nil {
            configureSecondaryIfNeeded()
            if FileManager.default.fileExists(atPath: connection.path) { startOnQueue() }
        }
        let field = GBrainHealth.read(entry: entry)
        let data = try? Data(contentsOf: entry.gbrainDir.appendingPathComponent("state.json"))
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let primary = isPrimary
        let openAI = primary && keychain.contains("openai"), anthropic = primary && keychain.contains("anthropic")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            healthy = field.reason == nil
            let reasons = ["not_configured": "未設定", "starting": "啟動中", "stopped": "已停止",
                           "stale": "狀態過期", "secret_on_disk": "偵測到金鑰落檔；已停止"]
            status = field.value.map { label in
                field.reason.map { label + " · " + (reasons[$0] ?? "無法連線") } ?? label
            } ?? "未設定"
            mode = object?["mode"] as? String ?? "unconfigured"
            primaryName = object?["primary"] as? String ?? "未設定"
            pageCount = object?["pageCount"] as? Int
            lastWrite = [object?["lastWriteAt"] as? String, object?["lastWriteDevice"] as? String].compactMap { $0 }.joined(separator: " · ")
            openAIConfigured = openAI; anthropicConfigured = anthropic
            semanticEnabled = object?["semanticEnabled"] as? Bool == true && openAI
        }
    }
    private func publishFailure(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.healthy = false; self?.status = text }
    }
    func saveKey(_ value: String, provider: String) {
        guard isPrimary, ["openai", "anthropic"].contains(provider) else { return }
        queue.async { [weak self] in
            guard let self, isPrimary else { return }
            do { try keychain.save(value, name: provider); setMessage("已儲存到鑰匙圈"); restartOnQueue() }
            catch { setMessage("無法儲存到鑰匙圈") }
            refreshOnQueue()
        }
    }
    func removeKey(provider: String) {
        guard isPrimary, ["openai", "anthropic"].contains(provider) else { return }
        queue.async { [weak self] in
            guard let self, isPrimary else { return }
            do {
                try keychain.remove(provider)
                // Stop first: a preference-write failure must not leave the old key live.
                try? input?.fileHandleForWriting.close()
                if process?.isRunning == true { process?.terminate() }
                if provider == "openai" { try writeSemanticPreference(false) }
                // Restart without the removed credential; no credential stays in a child environment.
                restartOnQueue()
                setMessage("已移除")
            } catch { setMessage("無法移除金鑰") }
            refreshOnQueue()
        }
    }
    func testKey(provider: String) {
        guard isPrimary, ["openai", "anthropic"].contains(provider) else { return }
        queue.async { [weak self] in
            guard let self, isPrimary else { return }
            do {
                guard let key = try keychain.read(provider) else { setMessage("尚未設定"); return }
                let url = URL(string: provider == "openai" ? "https://api.openai.com/v1/models" : "https://api.anthropic.com/v1/models")!
                var request = URLRequest(url: url); request.timeoutInterval = 10
                if provider == "openai" { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
                else { request.setValue(key, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
                let session = URLSession(configuration: .ephemeral, delegate: GBrainKeyTestDelegate(), delegateQueue: nil)
                session.dataTask(with: request) { [weak self] _, response, _ in
                    self?.setMessage((response as? HTTPURLResponse)?.statusCode == 200 ? "金鑰測試成功（未驗證 embedding）" : "金鑰測試失敗")
                    session.finishTasksAndInvalidate()
                }.resume()
            } catch { setMessage("無法讀取鑰匙圈") }
        }
    }
    func setSemantic(_ enabled: Bool) {
        guard isPrimary, !enabled || openAIConfigured else { return }
        queue.async { [weak self] in
            guard let self, isPrimary, !enabled || keychain.contains("openai") else { return }
            do {
                // Legacy Postgres is never reconfigured by this App's new helper.
                let config = try Data(contentsOf: entry.gbrainDir.appendingPathComponent("connection.json"))
                let object = try JSONSerialization.jsonObject(with: config) as? [String: Any]
                guard object?["mode"] as? String == "pglite" else { setMessage("既有 Postgres 沿用原服務的搜尋設定"); return }
                try writeSemanticPreference(enabled)
                setMessage(enabled ? "正在驗證並啟用語意搜尋；既有資料不重建索引" : "目前只有關鍵字搜尋")
                restartOnQueue()
            } catch { setMessage("無法套用語意搜尋設定") }
        }
    }
    private func writeSemanticPreference(_ enabled: Bool) throws {
        try FileManager.default.createDirectory(at: entry.gbrainDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = entry.gbrainDir.appendingPathComponent("preferences.json")
        let data = try JSONSerialization.data(withJSONObject: ["semanticEnabled": enabled])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func setMessage(_ text: String) { DispatchQueue.main.async { [weak self] in self?.message = text } }
}

/// Do not forward credential-bearing test requests to a redirect destination.
private final class GBrainKeyTestDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
