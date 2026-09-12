import Foundation
import Darwin
import TatwoUltraworkCore

enum ChatNativeSubscriptionEnvironment {
    private static let allowedInheritedKeys: Set<String> = [
        "PATH",
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "TERM",
        "USER",
        "LOGNAME",
        "SHELL",
        "__CF_USER_TEXT_ENCODING",
    ]

    static let forbiddenCredentialKeys: Set<String> = [
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "CODEX_ACCESS_TOKEN",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "GROK_API_KEY",
        "MINIMAX_API_KEY",
        "GOOGLE_API_KEY",
        "GEMINI_API_KEY",
        "XAI_API_KEY",
    ]

    static func scrubbed(
        _ environment: [String: String]
    ) -> [String: String] {
        var result = environment
        for key in forbiddenCredentialKeys {
            result.removeValue(forKey: key)
        }
        return result
    }

    static func isolatedProcessEnvironment(
        inheriting environment: [String: String],
        homeURL: URL
    ) -> [String: String] {
        var result: [String: String] = [:]
        for key in allowedInheritedKeys {
            if let value = environment[key] {
                result[key] = value
            }
        }
        result["HOME"] = homeURL.path
        result["CODEX_HOME"] = homeURL.path
        return result
    }

    static func scrubCurrentProcessCredentials() {
        for key in forbiddenCredentialKeys {
            unsetenv(key)
        }
    }
}

enum ChatNativeSubscriptionRuntimeError:
    Error,
    Sendable,
    Equatable,
    TatwoNativeActionableTransportFailure
{
    case runtimeUnavailable
    case subscriptionLoginRequired
    case unsupportedModel
    case modelUnavailable
    case invalidProtocol
    case modelAttestationMismatch
    case processExited
    case turnFailed

    var nativeFailureCode: String {
        switch self {
        case .runtimeUnavailable:
            "subscription_runtime_unavailable"
        case .subscriptionLoginRequired:
            "subscription_login_required"
        case .unsupportedModel:
            "unsupported_model"
        case .modelUnavailable:
            "subscription_model_unavailable"
        case .invalidProtocol:
            "subscription_protocol_error"
        case .modelAttestationMismatch:
            "model_attestation_mismatch"
        case .processExited:
            "subscription_runtime_exited"
        case .turnFailed:
            "subscription_turn_failed"
        }
    }

    var nativeSafeMessage: String {
        switch self {
        case .runtimeUnavailable:
            "TATWO 內建模型執行環境不可用；請重新安裝或更新 TATWO OS。"
        case .subscriptionLoginRequired:
            "請到 TATWO OS 設定 → 模型存取，登入 ChatGPT 訂閱帳號。"
        case .unsupportedModel:
            "這個模型不支援 TATWO 訂閱執行路線。"
        case .modelUnavailable:
            "目前的 ChatGPT 訂閱未提供所選模型。"
        case .invalidProtocol:
            "TATWO 訂閱執行環境回傳了無效資料。"
        case .modelAttestationMismatch:
            "模型路線驗證失敗，TATWO 已停止執行。"
        case .processExited:
            "TATWO 訂閱執行環境意外停止。"
        case .turnFailed:
            "訂閱模型未能完成這次工作。"
        }
    }
}

struct ChatNativeSubscriptionTokenPreflight: Sendable {
    enum Outcome: Sendable, Equatable {
        case notNeeded
        case refreshed
        case warning
    }

    static let refreshThreshold: TimeInterval = 5 * 60

    static func runIfNeeded(
        authData: Data?,
        now: Date = Date(),
        refresh: @escaping @Sendable () async -> Bool
    ) async -> Outcome {
        guard let authData,
              let expiry = estimatedExpiry(in: authData),
              expiry.timeIntervalSince(now) < refreshThreshold
        else { return .notNeeded }
        return await refresh() ? .refreshed : .warning
    }

    static func accessTokenExpiry(in authData: Data) -> Date? {
        guard let root = try? JSONSerialization.jsonObject(with: authData)
                as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String
        else { return nil }
        let pieces = token.split(
            separator: ".",
            omittingEmptySubsequences: false)
        guard pieces.count >= 2 else { return nil }
        var payload = String(pieces[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let seconds = (object["exp"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func estimatedExpiry(in authData: Data) -> Date? {
        if let expiry = accessTokenExpiry(in: authData) {
            return expiry
        }
        guard let root = try? JSONSerialization.jsonObject(with: authData)
                as? [String: Any],
              let raw = root["last_refresh"] as? String,
              let refreshedAt = ISO8601DateFormatter().date(from: raw)
        else { return nil }
        // Codex access tokens are one-hour credentials; last_refresh is the
        // only expiry signal in older auth.json variants.
        return refreshedAt.addingTimeInterval(60 * 60)
    }
}

enum ChatNativeSubscriptionJSONRPCID:
    Sendable,
    Hashable,
    Equatable
{
    case string(String)
    case integer(Int)

    init?(rawValue: Any) {
        if let value = rawValue as? String {
            self = .string(value)
        } else if let value = rawValue as? Int {
            self = .integer(value)
        } else if let value = rawValue as? NSNumber {
            self = .integer(value.intValue)
        } else {
            return nil
        }
    }

    var rawValue: Any {
        switch self {
        case .string(let value):
            value
        case .integer(let value):
            value
        }
    }
}

protocol ChatNativeSubscriptionAppServerSession: Sendable {
    func request(method: String, params: Data) async throws -> Data
    func notify(method: String, params: Data) async throws
    func nextMessage() async throws -> Data
    func respond(
        id: ChatNativeSubscriptionJSONRPCID,
        result: Data
    ) async throws
    func stop() async
}

struct ChatNativeSubscriptionRuntimeLocator: Sendable {
    static let helperName = "TatwoSubscriptionRuntime"

    let bundleURL: URL
    private let isExecutableFile: @Sendable (String) -> Bool

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        isExecutableFile: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.isExecutableFile = isExecutableFile
    }

    func resolve() -> URL? {
        let candidate = bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(Self.helperName, isDirectory: false)
            .standardizedFileURL
        guard candidate.path.hasPrefix(
            bundleURL.appendingPathComponent(
                "Contents/Helpers",
                isDirectory: true).standardizedFileURL.path + "/"),
            isExecutableFile(candidate.path)
        else {
            return nil
        }
        return candidate
    }
}

struct ChatNativeSubscriptionHomeLocator: Sendable {
    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func resolve() -> URL {
        if let injected = absoluteDirectory(
            environment["TATWO_NATIVE_SUBSCRIPTION_HOME"])
        {
            return injected
        }
        if let appSupport = absoluteDirectory(
            environment["TATWO_ULTRAWORK_APP_SUPPORT"])
        {
            return appSupport
                .appendingPathComponent(
                    "model-subscriptions/openai",
                    isDirectory: true)
        }
        let applicationSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true)
        return applicationSupport
            .appendingPathComponent(
                "Tatwo Ultrawork/model-subscriptions/openai",
                isDirectory: true)
    }

    private func absoluteDirectory(_ value: String?) -> URL? {
        guard let value,
              value.hasPrefix("/")
        else {
            return nil
        }
        return URL(fileURLWithPath: value, isDirectory: true)
            .standardizedFileURL
    }
}

enum ChatNativeSubscriptionAccountStatus:
    Sendable,
    Equatable
{
    case unavailable
    case signedOut
    case requiresReauthentication
    case signedIn(planType: String)
}

struct ChatNativeSubscriptionRateLimitSnapshot:
    Sendable,
    Equatable
{
    let planType: String?
    let primaryRemainingPercent: Int?
    let secondaryRemainingPercent: Int?
    let primaryResetsAt: Int?
    let secondaryResetsAt: Int?
    let resetCreditsAvailable: Int?
    let resetCreditExpiryDates: [Int]

    var remainingPercent: Int? {
        [primaryRemainingPercent, secondaryRemainingPercent]
            .compactMap { $0 }
            .min()
    }
}

struct ChatNativeSubscriptionAccountSnapshot:
    Sendable,
    Equatable
{
    let status: ChatNativeSubscriptionAccountStatus
    let rateLimits: ChatNativeSubscriptionRateLimitSnapshot?
    let rateLimitFailure:
        ChatNativeSubscriptionRateLimitFailure?

    init(
        status: ChatNativeSubscriptionAccountStatus,
        rateLimits: ChatNativeSubscriptionRateLimitSnapshot?,
        rateLimitFailure:
            ChatNativeSubscriptionRateLimitFailure? = nil
    ) {
        self.status = status
        self.rateLimits = rateLimits
        self.rateLimitFailure = rateLimitFailure
    }
}

enum ChatNativeSubscriptionRateLimitFailure:
    String,
    Sendable,
    Equatable
{
    case runtime = "OpenAI 額度執行環境失敗"
    case network = "OpenAI 額度網路請求失敗"
    case parsing = "OpenAI 額度回應解析失敗"
    case rateLimited = "OpenAI 額度服務限流（HTTP 429）"
}

struct ChatNativeSubscriptionAccountService: Sendable {
    private let hasStoredCredentials: @Sendable () -> Bool
    private let sessionFactory:
        @Sendable () throws ->
            any ChatNativeSubscriptionAppServerSession

    init(
        runtimeLocator: ChatNativeSubscriptionRuntimeLocator =
            ChatNativeSubscriptionRuntimeLocator(),
        homeLocator: ChatNativeSubscriptionHomeLocator =
            ChatNativeSubscriptionHomeLocator(),
        sessionFactory:
            (@Sendable () throws ->
                any ChatNativeSubscriptionAppServerSession)? = nil,
        hasStoredCredentials:
            (@Sendable () -> Bool)? = nil
    ) {
        let homeURL = homeLocator.resolve()
        self.hasStoredCredentials = hasStoredCredentials ?? {
            FileManager.default.fileExists(
                atPath: homeURL
                    .appendingPathComponent(
                        "auth.json",
                        isDirectory: false)
                    .path)
        }
        self.sessionFactory = sessionFactory ?? {
            guard let executableURL = runtimeLocator.resolve() else {
                throw ChatNativeSubscriptionRuntimeError
                    .runtimeUnavailable
            }
            let scratchURL = homeURL
                .appendingPathComponent(
                    "login-sessions",
                    isDirectory: true)
                .appendingPathComponent(
                    UUID().uuidString.lowercased(),
                    isDirectory: true)
            return try ChatNativeSubscriptionProcessSession(
                executableURL: executableURL,
                homeURL: homeURL,
                workingDirectoryURL: scratchURL)
        }
    }

    func status() async -> ChatNativeSubscriptionAccountStatus {
        await snapshot(includeRateLimits: false).status
    }

    func quotaSnapshot() async -> ChatNativeSubscriptionAccountSnapshot {
        await snapshot(includeRateLimits: true)
    }

    private func snapshot(
        includeRateLimits: Bool
    ) async -> ChatNativeSubscriptionAccountSnapshot {
        do {
            let session = try sessionFactory()
            do {
                try await initialize(session)
                let status = try await readStatus(session)
                let rateLimits:
                    ChatNativeSubscriptionRateLimitSnapshot?
                let rateLimitFailure:
                    ChatNativeSubscriptionRateLimitFailure?
                if includeRateLimits,
                   case .signedIn = status
                {
                    do {
                        rateLimits = try await readRateLimits(session)
                        rateLimitFailure = nil
                    } catch let error
                        as ChatNativeSubscriptionRuntimeError
                    {
                        rateLimits = nil
                        switch error {
                        case .invalidProtocol:
                            rateLimitFailure = .parsing
                        case .runtimeUnavailable, .processExited:
                            rateLimitFailure = .runtime
                        default:
                            rateLimitFailure = .network
                        }
                    } catch {
                        rateLimits = nil
                        rateLimitFailure = .network
                    }
                } else {
                    rateLimits = nil
                    rateLimitFailure = nil
                }
                await session.stop()
                return ChatNativeSubscriptionAccountSnapshot(
                    status: status,
                    rateLimits: rateLimits,
                    rateLimitFailure: rateLimitFailure)
            } catch {
                await session.stop()
                throw error
            }
        } catch {
            return ChatNativeSubscriptionAccountSnapshot(
                status: .unavailable,
                rateLimits: nil)
        }
    }

    func login(
        openURL: @escaping @Sendable (URL) -> Bool
    ) async -> ChatNativeSubscriptionAccountStatus {
        do {
            let session = try sessionFactory()
            do {
                try await initialize(session)
                let response = try Self.object(
                    from: await session.request(
                        method: "account/login/start",
                        params: try Self.data(from: [
                            "type": "chatgpt",
                            "appBrand": "codex",
                            "codexStreamlinedLogin": true,
                            "useHostedLoginSuccessPage": true,
                        ])))
                guard response["type"] as? String == "chatgpt",
                      let loginID = response["loginId"] as? String,
                      let authURLString = response["authUrl"] as? String,
                      let authURL = URL(string: authURLString),
                      openURL(authURL)
                else {
                    throw ChatNativeSubscriptionRuntimeError
                        .invalidProtocol
                }
                var completed = false
                while !completed {
                    let message = try Self.object(
                        from: await session.nextMessage())
                    guard message["method"] as? String
                            == "account/login/completed",
                          let params = message["params"]
                            as? [String: Any],
                          params["loginId"] as? String == loginID
                    else {
                        continue
                    }
                    guard params["success"] as? Bool == true else {
                        throw ChatNativeSubscriptionRuntimeError
                            .subscriptionLoginRequired
                    }
                    completed = true
                }
                let status = try await readStatus(session)
                await session.stop()
                return status
            } catch {
                await session.stop()
                throw error
            }
        } catch {
            return .unavailable
        }
    }

    func logout() async -> ChatNativeSubscriptionAccountStatus {
        do {
            let session = try sessionFactory()
            do {
                try await initialize(session)
                _ = try await session.request(
                    method: "account/logout",
                    params: try Self.data(from: [:]))
                let status = try await readStatus(session)
                await session.stop()
                return status
            } catch {
                await session.stop()
                throw error
            }
        } catch {
            return .unavailable
        }
    }

    private func initialize(
        _ session: any ChatNativeSubscriptionAppServerSession
    ) async throws {
        _ = try await session.request(
            method: "initialize",
            params: try Self.data(from: [
                "clientInfo": [
                    "name": "tatwo-ultrawork-settings",
                    "title": "TATWO OS",
                    "version": "1.0.0",
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "requestAttestation": false,
                    "optOutNotificationMethods": [],
                ],
            ]))
        try await session.notify(
            method: "initialized",
            params: try Self.data(from: [:]))
    }

    private func readStatus(
        _ session: any ChatNativeSubscriptionAppServerSession
    ) async throws -> ChatNativeSubscriptionAccountStatus {
        let response = try Self.object(
            from: await session.request(
                method: "account/read",
                params: try Self.data(from: [
                    "refreshToken": true,
                ])))
        guard let account = response["account"] as? [String: Any]
        else {
            return hasStoredCredentials()
                ? .requiresReauthentication
                : .signedOut
        }
        guard account["type"] as? String == "chatgpt" else {
            return .signedOut
        }
        return .signedIn(
            planType: account["planType"] as? String ?? "unknown")
    }

    private func readRateLimits(
        _ session: any ChatNativeSubscriptionAppServerSession
    ) async throws -> ChatNativeSubscriptionRateLimitSnapshot {
        let response = try Self.object(
            from: await session.request(
                method: "account/rateLimits/read",
                params: try Self.data(from: [:])))
        let rateLimitsByID =
            response["rateLimitsByLimitId"] as? [String: Any]
        let rateLimits =
            rateLimitsByID?["codex"] as? [String: Any]
            ?? response["rateLimits"] as? [String: Any]
        guard let rateLimits else {
            throw ChatNativeSubscriptionRuntimeError.invalidProtocol
        }
        let primary = rateLimits["primary"] as? [String: Any]
        let secondary = rateLimits["secondary"] as? [String: Any]
        let resetCredits =
            response["rateLimitResetCredits"] as? [String: Any]
        let credits = resetCredits?["credits"] as? [[String: Any]] ?? []
        return ChatNativeSubscriptionRateLimitSnapshot(
            planType: rateLimits["planType"] as? String,
            primaryRemainingPercent:
                Self.remainingPercent(primary?["usedPercent"]),
            secondaryRemainingPercent:
                Self.remainingPercent(secondary?["usedPercent"]),
            primaryResetsAt: Self.integer(primary?["resetsAt"]),
            secondaryResetsAt:
                Self.integer(secondary?["resetsAt"]),
            resetCreditsAvailable:
                Self.integer(resetCredits?["availableCount"]),
            resetCreditExpiryDates: credits.compactMap {
                Self.integer($0["expiresAt"])
            })
    }

    private static func remainingPercent(_ value: Any?) -> Int? {
        guard let used = integer(value) else { return nil }
        return max(0, min(100, 100 - used))
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        return (value as? NSNumber)?.intValue
    }

    private static func object(
        from data: Data
    ) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw ChatNativeSubscriptionRuntimeError.invalidProtocol
        }
        return object
    }

    private static func data(from object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ChatNativeSubscriptionRuntimeError.invalidProtocol
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

final class ChatNativeSubscriptionProcessSession:
    ChatNativeSubscriptionAppServerSession,
    @unchecked Sendable
{
    static let runtimeArguments = [
        "app-server",
        "--stdio",
        "--disable",
        "apps",
        "--disable",
        "plugins",
        "--disable",
        "remote_plugin",
        "--disable",
        "shell_tool",
        "--disable",
        "unified_exec",
        "--disable",
        "code_mode_host",
        "--disable",
        "computer_use",
        "--disable",
        "browser_use",
        "--disable",
        "multi_agent",
    ]

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
    }

    private let lock = NSLock()
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    private var outputBuffer = Data()
    private var pending: [ChatNativeSubscriptionJSONRPCID: PendingRequest] = [:]
    private var messages: [Data] = []
    private var messageWaiters: [CheckedContinuation<Data, Error>] = []
    private var stopped = false

    init(
        executableURL: URL,
        homeURL: URL,
        workingDirectoryURL: URL
    ) throws {
        guard FileManager.default.isExecutableFile(
            atPath: executableURL.path)
        else {
            throw ChatNativeSubscriptionRuntimeError.runtimeUnavailable
        }
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: workingDirectoryURL,
            withIntermediateDirectories: true)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = Self.runtimeArguments
        process.currentDirectoryURL = workingDirectoryURL
        process.environment =
            ChatNativeSubscriptionEnvironment.isolatedProcessEnvironment(
                inheriting: ProcessInfo.processInfo.environment,
                homeURL: homeURL)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        self.errorOutput = errorPipe.fileHandleForReading

        output.readabilityHandler = { [weak self] handle in
            self?.consumeOutput(handle.availableData)
        }
        errorOutput.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish(
                error: ChatNativeSubscriptionRuntimeError.processExited)
        }
        do {
            try process.run()
        } catch {
            output.readabilityHandler = nil
            errorOutput.readabilityHandler = nil
            throw ChatNativeSubscriptionRuntimeError.runtimeUnavailable
        }
    }

    func request(method: String, params: Data) async throws -> Data {
        let id = ChatNativeSubscriptionJSONRPCID.string(
            UUID().uuidString.lowercased())
        let paramsObject = try Self.object(from: params)
        let payload = try Self.data(from: [
            "id": id.rawValue,
            "method": method,
            "params": paramsObject,
        ])
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !stopped else {
                lock.unlock()
                continuation.resume(
                    throwing:
                        ChatNativeSubscriptionRuntimeError.processExited)
                return
            }
            pending[id] = PendingRequest(continuation: continuation)
            do {
                try writeLocked(payload)
                lock.unlock()
            } catch {
                pending.removeValue(forKey: id)
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    func notify(method: String, params: Data) async throws {
        let payload = try Self.data(from: [
            "method": method,
            "params": try Self.object(from: params),
        ])
        try write(payload)
    }

    func nextMessage() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !messages.isEmpty {
                let value = messages.removeFirst()
                lock.unlock()
                continuation.resume(returning: value)
            } else if stopped {
                lock.unlock()
                continuation.resume(
                    throwing:
                        ChatNativeSubscriptionRuntimeError.processExited)
            } else {
                messageWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func respond(
        id: ChatNativeSubscriptionJSONRPCID,
        result: Data
    ) async throws {
        let payload = try Self.data(from: [
            "id": id.rawValue,
            "result": try Self.object(from: result),
        ])
        try write(payload)
    }

    func stop() async {
        finish(error: CancellationError())
        if process.isRunning {
            process.terminate()
        }
    }

    private func write(_ payload: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else {
            throw ChatNativeSubscriptionRuntimeError.processExited
        }
        try writeLocked(payload)
    }

    private func writeLocked(_ payload: Data) throws {
        var line = payload
        line.append(0x0A)
        do {
            try input.write(contentsOf: line)
        } catch {
            throw ChatNativeSubscriptionRuntimeError.processExited
        }
    }

    private func consumeOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [Data] = []
        lock.lock()
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            if !line.isEmpty {
                lines.append(Data(line))
            }
        }
        lock.unlock()
        for line in lines {
            consumeLine(line)
        }
    }

    private func consumeLine(_ line: Data) {
        guard let object = try? Self.object(from: line) else {
            return
        }
        if let rawID = object["id"],
           let id = ChatNativeSubscriptionJSONRPCID(rawValue: rawID),
           object["method"] == nil
        {
            let result: Result<Data, Error>
            if let error = object["error"] {
                let description =
                    (try? Self.data(from: error))
                    .map { String(decoding: $0, as: UTF8.self) }
                    ?? "app-server error"
                result = .failure(
                    NSError(
                        domain: "TatwoSubscriptionAppServer",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: description,
                        ]))
            } else if let response = object["result"],
                      let data = try? Self.data(from: response)
            {
                result = .success(data)
            } else {
                result = .failure(
                    ChatNativeSubscriptionRuntimeError.invalidProtocol)
            }
            lock.lock()
            let request = pending.removeValue(forKey: id)
            lock.unlock()
            if let request {
                request.continuation.resume(with: result)
            }
            return
        }
        deliverMessage(line)
    }

    private func deliverMessage(_ message: Data) {
        lock.lock()
        if !messageWaiters.isEmpty {
            let waiter = messageWaiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: message)
        } else if !stopped {
            messages.append(message)
            lock.unlock()
        } else {
            lock.unlock()
        }
    }

    private func finish(error: Error) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        output.readabilityHandler = nil
        errorOutput.readabilityHandler = nil
        let pendingValues = Array(pending.values)
        pending.removeAll()
        let waiters = messageWaiters
        messageWaiters.removeAll()
        messages.removeAll()
        lock.unlock()
        pendingValues.forEach {
            $0.continuation.resume(throwing: error)
        }
        waiters.forEach { $0.resume(throwing: error) }
        try? input.close()
    }

    private static func object(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw ChatNativeSubscriptionRuntimeError.invalidProtocol
        }
        return object
    }

    private static func data(from object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ChatNativeSubscriptionRuntimeError.invalidProtocol
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

struct ChatNativeOpenAISubscriptionModelTransport:
    TatwoNativeModelTransport
{
    static let supportedModelIDs: Set<String> = [
        "gpt-5.6-sol",
    ]

    private let engine: Engine

    init(
        modelID: String,
        effort: String,
        workspaceRoot: String,
        scratchDirectoryURL: URL,
        runtimeLocator: ChatNativeSubscriptionRuntimeLocator =
            ChatNativeSubscriptionRuntimeLocator(),
        homeLocator: ChatNativeSubscriptionHomeLocator =
            ChatNativeSubscriptionHomeLocator(),
        sessionFactory:
            (@Sendable () throws ->
                any ChatNativeSubscriptionAppServerSession)? = nil,
        usageRecorder:
            @escaping @Sendable (String, Int?, Int?) -> Void = {
                provider, inputTokens, outputTokens in
                TatwoLocalUsageMeter.recordShared(
                    provider: provider,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens)
            }
    ) {
        let homeURL = homeLocator.resolve()
        let resolvedFactory: @Sendable () throws ->
            any ChatNativeSubscriptionAppServerSession = sessionFactory ?? {
                guard let executableURL = runtimeLocator.resolve() else {
                    throw ChatNativeSubscriptionRuntimeError
                        .runtimeUnavailable
                }
                return try ChatNativeSubscriptionProcessSession(
                    executableURL: executableURL,
                    homeURL: homeURL,
                    workingDirectoryURL: scratchDirectoryURL)
            }
        self.engine = Engine(
            modelID: modelID,
            effort: effort,
            workspaceRoot: workspaceRoot,
            scratchDirectoryURL: scratchDirectoryURL,
            authURL: homeURL.appendingPathComponent(
                "auth.json",
                isDirectory: false),
            sessionFactory: resolvedFactory,
            usageRecorder: usageRecorder)
    }

    func respond(
        to request: TatwoNativeModelRequest
    ) async throws -> TatwoNativeModelTurn {
        try await engine.respond(to: request)
    }

    private actor Engine {
        private let modelID: String
        private let effort: String
        private let workspaceRoot: String
        private let scratchDirectoryURL: URL
        private let authURL: URL
        private let sessionFactory:
            @Sendable () throws ->
                any ChatNativeSubscriptionAppServerSession
        private let usageRecorder:
            @Sendable (String, Int?, Int?) -> Void
        private var session:
            (any ChatNativeSubscriptionAppServerSession)?
        private var pendingToolRequests:
            [String: ChatNativeSubscriptionJSONRPCID] = [:]
        private var deliveredToolResults: Set<String> = []
        private var assistantText: String?

        init(
            modelID: String,
            effort: String,
            workspaceRoot: String,
            scratchDirectoryURL: URL,
            authURL: URL,
            sessionFactory:
                @escaping @Sendable () throws ->
                    any ChatNativeSubscriptionAppServerSession,
            usageRecorder:
                @escaping @Sendable (String, Int?, Int?) -> Void
        ) {
            self.modelID = modelID
            self.effort = effort
            self.workspaceRoot = workspaceRoot
            self.scratchDirectoryURL = scratchDirectoryURL
            self.authURL = authURL
            self.sessionFactory = sessionFactory
            self.usageRecorder = usageRecorder
        }

        func respond(
            to request: TatwoNativeModelRequest
        ) async throws -> TatwoNativeModelTurn {
            guard Self.supported(modelID) else {
                throw ChatNativeSubscriptionRuntimeError.unsupportedModel
            }
            if session == nil {
                await preflightRefreshIfNeeded()
                try await bootstrap(request: request)
            }
            try await deliverToolResults(from: request.input)
            guard let session else {
                throw ChatNativeSubscriptionRuntimeError.processExited
            }

            while true {
                if Task.isCancelled {
                    await session.stop()
                    throw CancellationError()
                }
                let messageData = try await withTaskCancellationHandler {
                    try await session.nextMessage()
                } onCancel: {
                    Task {
                        await session.stop()
                    }
                }
                let message = try Self.object(from: messageData)
                let method = message["method"] as? String
                let canonicalEvent = CanonicalVendorEventReadPath
                    .usesCanonicalAdapter()
                    ? try ChatNativeSubscriptionCanonicalAdapter.adapt(
                        messageData)
                    : nil
                switch method {
                case "item/tool/call":
                    guard let idValue = message["id"],
                          let requestID =
                            ChatNativeSubscriptionJSONRPCID(
                                rawValue: idValue),
                          let params = message["params"]
                            as? [String: Any],
                          let callID = params["callId"] as? String,
                          let tool = params["tool"] as? String,
                          request.tools.contains(where: {
                              $0.name == tool
                          }),
                          let arguments = params["arguments"],
                          let argumentsJSON =
                            Self.canonicalJSONString(arguments)
                    else {
                        await session.stop()
                        throw ChatNativeSubscriptionRuntimeError
                            .invalidProtocol
                    }
                    pendingToolRequests[callID] = requestID
                    return turn(
                        response: .toolCalls([
                            TatwoNativeToolCall(
                                id: callID,
                                name: tool,
                                argumentsJSON: argumentsJSON),
                        ]))

                case "item/completed":
                    if case .assistantMessage(let text) = canonicalEvent,
                       !text.isEmpty
                    {
                        assistantText = text
                    // DEPRECATED: rollback-only legacy UI parser. Keep until
                    // the three-evidence deletion gate is independently met.
                    } else if !CanonicalVendorEventReadPath
                        .usesCanonicalAdapter(),
                       let params = message["params"] as? [String: Any],
                       let item = params["item"] as? [String: Any],
                       item["type"] as? String == "agentMessage",
                       let text = item["text"] as? String,
                       !text.isEmpty
                    {
                        assistantText = text
                    }

                case "turn/completed":
                    guard let params = message["params"]
                            as? [String: Any],
                          let completed = params["turn"]
                            as? [String: Any],
                          completed["status"] as? String == "completed",
                          canonicalEvent == .turnCompleted
                            || !CanonicalVendorEventReadPath
                                .usesCanonicalAdapter(),
                          let assistantText,
                          !assistantText.isEmpty
                    else {
                        await session.stop()
                        throw ChatNativeSubscriptionRuntimeError.turnFailed
                    }
                    await session.stop()
                    self.session = nil
                    usageRecorder(
                        "codex-gpt",
                        Self.usageToken(
                            completed,
                            keys: ["input_tokens", "inputTokens"]),
                        Self.usageToken(
                            completed,
                            keys: ["output_tokens", "outputTokens"]))
                    return turn(response: .assistantText(assistantText))

                case "error":
                    await session.stop()
                    throw ChatNativeSubscriptionRuntimeError.turnFailed

                default:
                    continue
                }
            }
        }

        private func bootstrap(
            request: TatwoNativeModelRequest
        ) async throws {
            let session = try sessionFactory()
            self.session = session
            do {
                _ = try await session.request(
                    method: "initialize",
                    params: try Self.data(from: [
                        "clientInfo": [
                            "name": "tatwo-ultrawork",
                            "title": "TATWO OS",
                            "version": "1.0.0",
                        ],
                        "capabilities": [
                            "experimentalApi": true,
                            "requestAttestation": false,
                            "optOutNotificationMethods": [],
                        ],
                    ]))
                try await session.notify(
                    method: "initialized",
                    params: try Self.data(from: [:]))

                let account = try Self.object(
                    from: await session.request(
                        method: "account/read",
                        params: try Self.data(from: [
                            "refreshToken": true,
                        ])))
                guard let accountValue = account["account"]
                        as? [String: Any],
                      accountValue["type"] as? String == "chatgpt"
                else {
                    throw ChatNativeSubscriptionRuntimeError
                        .subscriptionLoginRequired
                }

                let modelList = try Self.object(
                    from: await session.request(
                        method: "model/list",
                        params: try Self.data(from: [:])))
                let availableModels =
                    (modelList["data"] as? [[String: Any]] ?? [])
                    .compactMap {
                        $0["model"] as? String
                            ?? $0["id"] as? String
                            ?? $0["slug"] as? String
                    }
                guard availableModels.contains(modelID) else {
                    throw ChatNativeSubscriptionRuntimeError
                        .modelUnavailable
                }

                let dynamicTools: [[String: Any]] = try request.tools.map {
                    definition in
                    let schema = try Self.object(
                        from: Data(
                            definition.inputSchemaJSON.utf8))
                    return [
                        "type": "function",
                        "name": definition.name,
                        "description": definition.description,
                        "inputSchema": schema,
                    ]
                }
                let threadStart = try Self.object(
                    from: await session.request(
                        method: "thread/start",
                        params: try Self.data(from: [
                            "cwd": workspaceRoot,
                            "model": modelID,
                            "approvalPolicy": "never",
                            "sandbox": "read-only",
                            "ephemeral": true,
                            "serviceName": "tatwo_ultrawork",
                            "config": [
                                "model_reasoning_effort": effort,
                                "features": [
                                    "apps": false,
                                    "plugins": false,
                                    "remote_plugin": false,
                                    "shell_tool": false,
                                    "unified_exec": false,
                                    "code_mode_host": false,
                                    "computer_use": false,
                                    "browser_use": false,
                                    "multi_agent": false,
                                ],
                            ],
                            "baseInstructions":
                                "You are an execution engine inside TATWO OS. Use only the supplied TATWO dynamic tools for workspace access. Never use built-in shell, file editing, web, MCP, delegation, or external CLI tools.",
                            "developerInstructions":
                                "The authoritative workspace is \(workspaceRoot). Access it only through the supplied TATWO tools. Tool results are returned by TATWO Host Executor.",
                            "dynamicTools": dynamicTools,
                        ])))
                guard threadStart["model"] as? String == modelID,
                      (threadStart["reasoningEffort"] as? String
                        ?? effort) == effort,
                      let thread = threadStart["thread"]
                        as? [String: Any],
                      let threadID = thread["id"] as? String,
                      !threadID.isEmpty
                else {
                    throw ChatNativeSubscriptionRuntimeError
                        .modelAttestationMismatch
                }

                let prompt = request.input.compactMap {
                    item -> String? in
                    guard case .userText(let text) = item else {
                        return nil
                    }
                    return text
                }.joined(separator: "\n\n")
                guard !prompt.isEmpty else {
                    throw ChatNativeSubscriptionRuntimeError
                        .invalidProtocol
                }
                _ = try await session.request(
                    method: "turn/start",
                    params: try Self.data(from: [
                        "threadId": threadID,
                        "input": [
                            [
                                "type": "text",
                                "text": prompt,
                            ],
                        ],
                        "model": modelID,
                        "effort": effort,
                        "approvalPolicy": "never",
                    ]))
            } catch {
                await session.stop()
                self.session = nil
                throw error
            }
        }

        /// `codex login status` only reports state and did not rewrite
        /// auth.json in the live verification on 2026-08-21. The app-server
        /// `account/read` request with `refreshToken: true` is the existing
        /// Codex mechanism that actually asks the runtime to refresh.
        private func preflightRefreshIfNeeded() async {
            let authData = try? Data(contentsOf: authURL)
            let outcome =
                await ChatNativeSubscriptionTokenPreflight.runIfNeeded(
                    authData: authData,
                    refresh: { [sessionFactory] in
                        do {
                            let preflight = try sessionFactory()
                            do {
                                _ = try await preflight.request(
                                    method: "initialize",
                                    params: try Self.data(from: [
                                        "clientInfo": [
                                            "name": "tatwo-ultrawork",
                                            "title": "TATWO OS",
                                            "version": "1.0.0",
                                        ],
                                        "capabilities": [
                                            "experimentalApi": true,
                                            "requestAttestation": false,
                                            "optOutNotificationMethods": [],
                                        ],
                                    ]))
                                try await preflight.notify(
                                    method: "initialized",
                                    params: try Self.data(from: [:]))
                                let account = try Self.object(
                                    from: await preflight.request(
                                        method: "account/read",
                                        params: try Self.data(from: [
                                            "refreshToken": true,
                                        ])))
                                await preflight.stop()
                                return account["account"] != nil
                            } catch {
                                await preflight.stop()
                                return false
                            }
                        } catch {
                            return false
                        }
                    })
            if outcome == .warning {
                fputs(
                    "tatwo_codex_token_pre_refresh_warning=continuing_turn\n",
                    stderr)
            }
        }

        private func deliverToolResults(
            from input: [TatwoNativeModelInput]
        ) async throws {
            guard let session else { return }
            for item in input {
                guard case .toolResult(let result) = item,
                      !deliveredToolResults.contains(result.callID),
                      let requestID =
                        pendingToolRequests.removeValue(
                            forKey: result.callID)
                else {
                    continue
                }
                try await session.respond(
                    id: requestID,
                    result: try Self.data(from: [
                        "contentItems": [
                            [
                                "type": "inputText",
                                "text": result.output,
                            ],
                        ],
                        "success": !result.isError,
                    ]))
                deliveredToolResults.insert(result.callID)
            }
        }

        private func turn(
            response: TatwoNativeModelResponse
        ) -> TatwoNativeModelTurn {
            TatwoNativeModelTurn(
                response: response,
                attestation: TatwoNativeModelAttestation(
                    modelID: modelID,
                    effort: effort,
                    fallbackCount: 0))
        }

        private static func supported(_ modelID: String) -> Bool {
            ChatNativeOpenAISubscriptionModelTransport.supportedModelIDs
                .contains(modelID)
        }

        private static func object(
            from data: Data
        ) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(
                with: data) as? [String: Any]
            else {
                throw ChatNativeSubscriptionRuntimeError.invalidProtocol
            }
            return object
        }

        private static func data(from object: Any) throws -> Data {
            guard JSONSerialization.isValidJSONObject(object) else {
                throw ChatNativeSubscriptionRuntimeError.invalidProtocol
            }
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes])
        }

        private static func usageToken(
            _ completed: [String: Any],
            keys: [String]
        ) -> Int? {
            let usage = completed["usage"] as? [String: Any]
                ?? completed["tokenUsage"] as? [String: Any]
            for key in keys {
                if let value = usage?[key] as? NSNumber {
                    return value.intValue
                }
            }
            return nil
        }

        private static func canonicalJSONString(
            _ value: Any
        ) -> String? {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(
                    withJSONObject: value,
                    options: [.sortedKeys, .withoutEscapingSlashes])
            else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
