// engine-login 房間：只管理 Tatwo2 獨立引擎資料夾的登入狀態與登入／登出子程序。
import AppKit
import Foundation

struct EngineLoginStatus: Identifiable, Equatable {
    let kind: ClaudeSidecar.Kind
    let isLoggedIn: Bool
    let account: String?
    let detail: String

    var id: String { kind.rawValue }
}

final class EngineLogin: @unchecked Sendable {
    private let inputLock = NSLock()
    private var activeLoginInput: Pipe?

    /// 把使用者貼的認證碼送進正在跑的登入程序；沒有登入在跑就回 false。
    @discardableResult
    func submitLoginInput(_ text: String) -> Bool {
        inputLock.lock(); let pipe = activeLoginInput; inputLock.unlock()
        guard let pipe else { return false }
        pipe.fileHandleForWriting.write(Data((text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8))
        return true
    }
    static let kinds: [ClaudeSidecar.Kind] = [.codex, .claude, .grok]

    let paths: EnginePaths
    private let environment: [String: String]
    private let openURL: @Sendable (URL) -> Void
    private let fileManager: FileManager
    private let injectedPathsError: String?

    private var isolationError: String? {
        injectedPathsError ?? NativeStagingIsolation.validationError(environment)
    }

    init(
        paths: EnginePaths? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        openURL: @escaping @Sendable (URL) -> Void = {
            NSWorkspace.shared.open($0)
        }
    ) {
        let resolved = EnginePaths(environment: environment)
        let selected = paths ?? resolved
        self.paths = selected
        self.environment = environment
        self.fileManager = fileManager
        self.openURL = openURL
        let actualURLs = [selected.enginesRoot, selected.codexHome, selected.claudeConfigDirectory,
                          selected.grokHome, selected.userHome, selected.runtimeBinDirectory]
        let expectedURLs = [resolved.enginesRoot, resolved.codexHome, resolved.claudeConfigDirectory,
                            resolved.grokHome, resolved.userHome, resolved.runtimeBinDirectory]
        self.injectedPathsError = NativeStagingIsolation.isEnabled(environment)
            && zip(actualURLs, expectedURLs).contains { pair in
                pair.0.standardizedFileURL.path != pair.1.standardizedFileURL.path
            }
            ? "inconsistent injected staging paths" : nil
        if isolationError == nil {
            self.paths.createPrivateDirectories()
        }
    }

    func statuses() -> [EngineLoginStatus] {
        Self.kinds.map(status(for:))
    }

    func status(for kind: ClaudeSidecar.Kind) -> EngineLoginStatus {
        if let error = isolationError {
            return EngineLoginStatus(kind: kind, isLoggedIn: false, account: nil, detail: error)
        }
        switch kind {
        case .codex:
            return fileStatus(
                kind: kind,
                authURL: paths.codexAuth,
                missing: "未找到 Tatwo2 Codex 登入檔"
            )
        case .claude:
            let service = environment["TATWO2_LOGIN_SECURITY_SERVICE"]
                ?? "Claude Code-credentials"
            // Keychain 有主 CLI 的登入不代表獨立資料夾有登入（Claude 依 CLAUDE_CONFIG_DIR 分開存）；
            // 以 `claude auth status` 在獨立資料夾下的回答為準（2026-09-05 真機抓到）。
            let cliStatus = Self.claudeCLIStatus(
                executable: paths.claudeExecutable.path,
                configDir: paths.claudeConfigDirectory.path,
                environment: environment)
            // A failed staging CLI query means unverified login, not permission
            // to inspect the host's shared Keychain credential.
            let loggedIn = cliStatus?.loggedIn
                ?? (NativeStagingIsolation.isEnabled(environment) ? false : keychainContains(service: service))
            let account: String?
            if NativeStagingIsolation.isEnabled(environment) {
                account = cliStatus?.email
            } else {
                account = cliStatus?.email ?? Self.account(
                    from: paths.claudeAccountFile,
                    preferredKeys: ["emailAddress", "email", "account"]
                ) ?? Self.account(
                    from: paths.fallbackClaudeAccountFile,
                    preferredKeys: ["emailAddress", "email", "account"]
                )
            }
            return EngineLoginStatus(
                kind: kind,
                isLoggedIn: loggedIn,
                account: loggedIn ? account : nil,
                detail: loggedIn
                    ? "Keychain 已有 Claude Code 登入"
                    : "Keychain 尚無 Claude Code 登入"
            )
        case .grok:
            return fileStatus(
                kind: kind,
                authURL: paths.grokAuth,
                missing: "未找到 Tatwo2 Grok 登入檔"
            )
        }
    }

    @discardableResult
    func login(
        _ kind: ClaudeSidecar.Kind,
        onEvent: @escaping @Sendable (String) -> Void
    ) -> EngineLoginStatus {
        if let error = isolationError {
            onEvent(error)
            return status(for: kind)
        }
        paths.createPrivateDirectories()
        let launch = loginLaunch(for: kind)
        run(
            executable: launch.executable,
            arguments: launch.arguments,
            environment: processEnvironment(for: kind),
            onEvent: onEvent
        )
        return status(for: kind)
    }

    @discardableResult
    func logout(
        _ kind: ClaudeSidecar.Kind,
        onEvent: @escaping @Sendable (String) -> Void = { _ in }
    ) -> EngineLoginStatus {
        if let error = isolationError {
            onEvent(error)
            return status(for: kind)
        }
        switch kind {
        case .codex:
            removeAuthFile(paths.codexAuth, within: paths.codexHome, onEvent: onEvent)
        case .claude:
            let executable = fakeExecutable ?? paths.claudeExecutable
            run(
                executable: executable,
                arguments: ["auth", "logout"],
                environment: processEnvironment(for: kind),
                onEvent: onEvent
            )
        case .grok:
            removeAuthFile(paths.grokAuth, within: paths.grokHome, onEvent: onEvent)
        }
        return status(for: kind)
    }

    private var fakeExecutable: URL? {
        environment["TATWO2_LOGIN_FAKE_BIN"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0)
        }
    }

    private func loginLaunch(
        for kind: ClaudeSidecar.Kind
    ) -> (executable: URL, arguments: [String]) {
        if let fakeExecutable {
            switch kind {
            case .codex: return (fakeExecutable, ["login"])
            case .claude: return (fakeExecutable, ["auth", "login"])
            case .grok: return (fakeExecutable, ["login", "--device-auth"])
            }
        }
        switch kind {
        case .codex: return (paths.codexExecutable, ["login"])
        case .claude: return (paths.claudeExecutable, ["auth", "login"])
        case .grok: return (paths.grokExecutable, ["login", "--device-auth"])
        }
    }

    private func processEnvironment(
        for kind: ClaudeSidecar.Kind
    ) -> [String: String] {
        var child = environment
        child["PATH"] = paths.runtimeBinDirectory.path
            + ":"
            + (child["PATH"] ?? "/usr/bin:/bin")
        switch kind {
        case .codex:
            child["CODEX_HOME"] = paths.codexHome.path
        case .claude:
            child = NativeStagingIsolation.isolateClaude(
                child, configDirectory: paths.claudeConfigDirectory.path)
        case .grok:
            child["HOME"] = paths.grokHome.path
            child["TATWO2_GROK_HOME"] = paths.grokHome.path
        }
        return child
    }

    private func fileStatus(
        kind: ClaudeSidecar.Kind,
        authURL: URL,
        missing: String
    ) -> EngineLoginStatus {
        guard fileManager.fileExists(atPath: authURL.path) else {
            return EngineLoginStatus(
                kind: kind,
                isLoggedIn: false,
                account: nil,
                detail: missing
            )
        }
        let account = Self.account(
            from: authURL,
            preferredKeys: [
                "email",
                "emailAddress",
                "preferred_username",
                "account_id",
                "accountId",
                "user_id",
                "userId",
            ]
        ) ?? "已儲存登入"
        return EngineLoginStatus(
            kind: kind,
            isLoggedIn: true,
            account: account,
            detail: "已找到 Tatwo2 獨立登入檔"
        )
    }

    private func keychainContains(service: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func removeAuthFile(
        _ authURL: URL,
        within root: URL,
        onEvent: @escaping @Sendable (String) -> Void
    ) {
        let authPath = authURL.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard authPath.hasPrefix(rootPath + "/") else {
            onEvent("拒絕登出：登入檔不在 Tatwo2 獨立資料夾")
            return
        }
        guard fileManager.fileExists(atPath: authPath) else {
            onEvent("沒有 Tatwo2 獨立登入檔需要移除")
            return
        }
        do {
            try fileManager.removeItem(at: authURL)
            onEvent("已移除 Tatwo2 獨立登入檔")
        } catch {
            onEvent("登出失敗：\(error.localizedDescription)")
        }
    }

    private func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onEvent: @escaping @Sendable (String) -> Void
    ) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if NativeStagingIsolation.isEnabled(environment) { process.currentDirectoryURL = paths.userHome }
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin   // Grok 的登入會在終端機要你貼認證碼（2026-09-05 使用者截圖）

        do {
            try process.run()
        } catch {
            onEvent("無法啟動登入程序：\(error.localizedDescription)")
            return
        }
        inputLock.lock(); activeLoginInput = stdin; inputLock.unlock()
        defer { inputLock.lock(); activeLoginInput = nil; inputLock.unlock() }

        let readers = DispatchGroup()
        for handle in [
            stdout.fileHandleForReading,
            stderr.fileHandleForReading,
        ] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { readers.leave() }
                var buffered = Data()
                while true {
                    let data = handle.availableData
                    guard !data.isEmpty else { break }
                    buffered.append(data)
                    Self.emitCompleteLines(from: &buffered) { line in
                        self.emit(line, onEvent: onEvent)
                    }
                    if !buffered.isEmpty {   // 沒換行的提示（Enter code:）也要讓人看到
                        let partial = String(decoding: buffered, as: UTF8.self)
                        buffered.removeAll()
                        self.emit(partial, onEvent: onEvent)
                    }
                }
                if !buffered.isEmpty {
                    let line = String(decoding: buffered, as: UTF8.self)
                    self.emit(line, onEvent: onEvent)
                }
            }
        }

        process.waitUntilExit()
        readers.wait()
        if process.terminationStatus != 0 {
            onEvent("登入程序結束：exit \(process.terminationStatus)")
        }
    }

    private func emit(
        _ rawLine: String,
        onEvent: @escaping @Sendable (String) -> Void
    ) {
        let line = rawLine.trimmingCharacters(in: .newlines)
        guard !line.isEmpty else { return }
        onEvent(line)
        for token in line.split(whereSeparator: \.isWhitespace) {
            let candidate = token.trimmingCharacters(
                in: CharacterSet(charactersIn: "\"'()[]<>,")
            )
            guard candidate.lowercased().hasPrefix("http"),
                  let url = URL(string: candidate)
            else { continue }
            openURL(url)
            break
        }
    }

    private static func emitCompleteLines(
        from data: inout Data,
        emit: (String) -> Void
    ) {
        while let newline = data.firstIndex(of: 0x0A) {
            let lineData = data.subdata(in: data.startIndex..<newline)
            data.removeSubrange(data.startIndex...newline)
            emit(String(decoding: lineData, as: UTF8.self))
        }
    }

    private static func account(
        from url: URL,
        preferredKeys: [String]
    ) -> String? {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return account(
            in: object,
            preferredKeys: preferredKeys.map { $0.lowercased() },
            depth: 0
        )
    }

    private static func account(
        in object: Any,
        preferredKeys: [String],
        depth: Int
    ) -> String? {
        guard depth < 8 else { return nil }
        if let dictionary = object as? [String: Any] {
            for preferredKey in preferredKeys {
                if let pair = dictionary.first(where: {
                    $0.key.lowercased() == preferredKey
                }), let value = nonemptyString(pair.value) {
                    return value
                }
            }
            for (key, value) in dictionary {
                if ["id_token", "idtoken", "access_token", "accesstoken"]
                    .contains(key.lowercased()),
                   let token = value as? String,
                   let payload = jwtPayload(token),
                   let found = account(
                       in: payload,
                       preferredKeys: preferredKeys,
                       depth: depth + 1
                   ) {
                    return found
                }
            }
            for value in dictionary.values {
                if let found = account(
                    in: value,
                    preferredKeys: preferredKeys,
                    depth: depth + 1
                ) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = account(
                    in: value,
                    preferredKeys: preferredKeys,
                    depth: depth + 1
                ) {
                    return found
                }
            }
        }
        return nil
    }

    private static func nonemptyString(_ value: Any) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jwtPayload(_ token: String) -> Any? {
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return nil }
        var encoded = String(components[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

extension EngineLogin {
    struct ClaudeCLIStatus { let loggedIn: Bool; let email: String? }

    /// 跑 `claude auth status`（帶獨立 CLAUDE_CONFIG_DIR），回 JSON 裡的 loggedIn／email；跑不動回 nil。
    static func claudeCLIStatus(
        executable: String, configDir: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudeCLIStatus? {
        let effectiveEnvironment = NativeStagingIsolation.isolateClaude(environment, configDirectory: configDir)
        guard NativeStagingIsolation.validationError(environment) == nil,
              NativeStagingIsolation.validationError(effectiveEnvironment) == nil else { return nil }
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = ["auth", "status"]
        p.environment = effectiveEnvironment
        if NativeStagingIsolation.isEnabled(environment), let home = environment["HOME"] {
            p.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
        }
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(8)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let email = (obj["email"] ?? obj["emailAddress"] ?? (obj["account"] as? [String: Any])?["email"]) as? String
        return ClaudeCLIStatus(loggedIn: obj["loggedIn"] as? Bool ?? false, email: email)
    }
}
