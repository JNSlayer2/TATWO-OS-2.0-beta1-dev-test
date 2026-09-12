import Foundation
import TatwoUltraworkCore

enum ChatNativeGrokSubscriptionRuntimeError:
    Error,
    Sendable,
    Equatable,
    TatwoNativeActionableTransportFailure
{
    case runtimeUnavailable
    case subscriptionLoginRequired
    case unsupportedModel
    case invalidProtocol
    case modelAttestationMismatch
    case processExited
    case turnFailed

    var nativeFailureCode: String {
        switch self {
        case .runtimeUnavailable:
            "grok_subscription_runtime_unavailable"
        case .subscriptionLoginRequired:
            "grok_subscription_login_required"
        case .unsupportedModel:
            "unsupported_model"
        case .invalidProtocol:
            "grok_subscription_protocol_error"
        case .modelAttestationMismatch:
            "model_attestation_mismatch"
        case .processExited:
            "grok_subscription_runtime_exited"
        case .turnFailed:
            "grok_subscription_turn_failed"
        }
    }

    var nativeSafeMessage: String {
        switch self {
        case .runtimeUnavailable:
            "TATWO 內建 Grok 執行環境不可用；請重新安裝或更新 TATWO OS。"
        case .subscriptionLoginRequired:
            "請到 TATWO OS 設定 → 模型存取，登入 Grok 訂閱帳號。"
        case .unsupportedModel:
            "這個模型不支援 Grok 訂閱執行路線。"
        case .invalidProtocol:
            "TATWO 內建 Grok 執行環境回傳了無效資料。"
        case .modelAttestationMismatch:
            "Grok 模型路線驗證失敗，TATWO 已停止執行。"
        case .processExited:
            "TATWO 內建 Grok 執行環境意外停止。"
        case .turnFailed:
            "Grok 訂閱模型未能完成這次工作。"
        }
    }
}

struct ChatNativeGrokSubscriptionRuntimeLocator: Sendable {
    static let helperName = "TatwoGrokSubscriptionRuntime"

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
        let helpers = bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .standardizedFileURL
        let candidate = helpers
            .appendingPathComponent(Self.helperName, isDirectory: false)
            .standardizedFileURL
        guard candidate.path.hasPrefix(helpers.path + "/"),
              isExecutableFile(candidate.path)
        else {
            return nil
        }
        return candidate
    }
}

struct ChatNativeGrokSubscriptionHomeLocator: Sendable {
    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func resolve() -> URL {
        if let injected = absoluteDirectory(
            environment["TATWO_NATIVE_GROK_SUBSCRIPTION_HOME"])
        {
            return injected
        }
        if let appSupport = absoluteDirectory(
            environment["TATWO_ULTRAWORK_APP_SUPPORT"])
        {
            return appSupport.appendingPathComponent(
                "model-subscriptions/grok",
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
        return applicationSupport.appendingPathComponent(
            "Tatwo Ultrawork/model-subscriptions/grok",
            isDirectory: true)
    }

    private func absoluteDirectory(_ value: String?) -> URL? {
        guard let value, value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
            .standardizedFileURL
    }
}

struct ChatNativeGrokSubscriptionAuthSourceLocator: Sendable {
    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func resolve(homeURL: URL) -> URL {
        if let injected = absoluteFile(
            environment["TATWO_GROK_AUTH_SOURCE"])
        {
            return injected
        }
        return homeURL
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
            .standardizedFileURL
    }

    private func absoluteFile(_ value: String?) -> URL? {
        guard let value, value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: false)
            .standardizedFileURL
    }
}

struct ChatNativeGrokProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

protocol ChatNativeGrokInteractiveProcessSession: Sendable {
    var isRunning: Bool { get }
    func send(line: String) async throws
    func waitForExit() async throws -> ChatNativeGrokProcessResult
    func terminate()
}

protocol ChatNativeGrokProcessRunning: Sendable {
    func run(
        arguments: [String],
        standardInput: Data?,
        environment: [String: String],
        currentDirectoryURL: URL,
        outputHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> ChatNativeGrokProcessResult
    func startInteractive(
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        outputHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> any ChatNativeGrokInteractiveProcessSession
    func stop()
}

extension ChatNativeGrokProcessRunning {
    func run(
        arguments: [String],
        standardInput: Data?,
        environment: [String: String],
        currentDirectoryURL: URL
    ) async throws -> ChatNativeGrokProcessResult {
        try await run(
            arguments: arguments,
            standardInput: standardInput,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            outputHandler: { _ in })
    }
}

private final class ChatNativeGrokLockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ value: Data) {
        guard !value.isEmpty else { return }
        lock.withLock { data.append(value) }
    }

    var value: Data {
        lock.withLock { data }
    }
}

private final class ChatNativeGrokProcessSession:
    ChatNativeGrokInteractiveProcessSession,
    @unchecked Sendable
{
    private let process: Process
    private let inputHandle: FileHandle
    private let resultWaiter: ChatNativeGrokProcessResultWaiter
    private let writeLock = NSLock()

    init(
        process: Process,
        inputHandle: FileHandle,
        resultWaiter: ChatNativeGrokProcessResultWaiter
    ) {
        self.process = process
        self.inputHandle = inputHandle
        self.resultWaiter = resultWaiter
    }

    var isRunning: Bool {
        process.isRunning
    }

    func send(line: String) async throws {
        guard process.isRunning else {
            throw ChatNativeGrokSubscriptionRuntimeError.processExited
        }
        var payload = Data(line.utf8)
        payload.append(0x0A)
        try writeLock.withLock {
            try inputHandle.write(contentsOf: payload)
        }
    }

    func waitForExit() async throws -> ChatNativeGrokProcessResult {
        await resultWaiter.wait()
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}

private final class ChatNativeGrokProcessResultWaiter:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var result: ChatNativeGrokProcessResult?
    private var continuation:
        CheckedContinuation<ChatNativeGrokProcessResult, Never>?

    func wait() async -> ChatNativeGrokProcessResult {
        await withCheckedContinuation { continuation in
            let readyResult: ChatNativeGrokProcessResult? =
                lock.withLock {
                if let result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let readyResult {
                continuation.resume(returning: readyResult)
            }
        }
    }

    func resolve(_ result: ChatNativeGrokProcessResult) {
        let continuation:
            CheckedContinuation<
                ChatNativeGrokProcessResult,
                Never
            >? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

final class ChatNativeGrokProcessRunner:
    ChatNativeGrokProcessRunning,
    @unchecked Sendable
{
    private let executableURL: URL
    private let lock = NSLock()
    private var currentProcess: Process?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func run(
        arguments: [String],
        standardInput: Data?,
        environment: [String: String],
        currentDirectoryURL: URL,
        outputHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> ChatNativeGrokProcessResult {
        guard FileManager.default.isExecutableFile(
            atPath: executableURL.path)
        else {
            throw ChatNativeGrokSubscriptionRuntimeError
                .runtimeUnavailable
        }
        try FileManager.default.createDirectory(
            at: currentDirectoryURL,
            withIntermediateDirectories: true)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputBuffer = ChatNativeGrokLockedDataBuffer()
        let errorBuffer = ChatNativeGrokLockedDataBuffer()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = {
            let data = $0.availableData
            outputBuffer.append(data)
            outputHandler(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = {
            let data = $0.availableData
            errorBuffer.append(data)
            outputHandler(data)
        }

        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation {
                (continuation:
                    CheckedContinuation<
                        ChatNativeGrokProcessResult,
                        Error
                    >) in
                process.terminationHandler = { [weak self] terminated in
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    outputBuffer.append(
                        outputPipe.fileHandleForReading.availableData)
                    errorBuffer.append(
                        errorPipe.fileHandleForReading.availableData)
                    self?.lock.withLock {
                        if self?.currentProcess === terminated {
                            self?.currentProcess = nil
                        }
                    }
                    continuation.resume(returning:
                        ChatNativeGrokProcessResult(
                            exitCode: terminated.terminationStatus,
                            stdout: outputBuffer.value,
                            stderr: errorBuffer.value))
                }
                lock.withLock { currentProcess = process }
                do {
                    try process.run()
                    if let standardInput {
                        try inputPipe.fileHandleForWriting.write(
                            contentsOf: standardInput)
                    }
                    try inputPipe.fileHandleForWriting.close()
                } catch {
                    lock.withLock {
                        if currentProcess === process {
                            currentProcess = nil
                        }
                    }
                    process.terminationHandler = nil
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(
                        throwing:
                            ChatNativeGrokSubscriptionRuntimeError
                                .runtimeUnavailable)
                }
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            return result
        } onCancel: {
            self.stop()
        }
    }

    func startInteractive(
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        outputHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> any ChatNativeGrokInteractiveProcessSession {
        guard FileManager.default.isExecutableFile(
            atPath: executableURL.path)
        else {
            throw ChatNativeGrokSubscriptionRuntimeError
                .runtimeUnavailable
        }
        try FileManager.default.createDirectory(
            at: currentDirectoryURL,
            withIntermediateDirectories: true)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputBuffer = ChatNativeGrokLockedDataBuffer()
        let errorBuffer = ChatNativeGrokLockedDataBuffer()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = {
            let data = $0.availableData
            outputBuffer.append(data)
            outputHandler(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = {
            let data = $0.availableData
            errorBuffer.append(data)
            outputHandler(data)
        }

        let resultWaiter = ChatNativeGrokProcessResultWaiter()
        process.terminationHandler = { [weak self] terminated in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            outputBuffer.append(
                outputPipe.fileHandleForReading.availableData)
            errorBuffer.append(
                errorPipe.fileHandleForReading.availableData)
            try? inputPipe.fileHandleForWriting.close()
            self?.lock.withLock {
                if self?.currentProcess === terminated {
                    self?.currentProcess = nil
                }
            }
            resultWaiter.resolve(
                ChatNativeGrokProcessResult(
                    exitCode: terminated.terminationStatus,
                    stdout: outputBuffer.value,
                    stderr: errorBuffer.value))
        }
        lock.withLock { currentProcess = process }
        do {
            try process.run()
        } catch {
            lock.withLock {
                if currentProcess === process {
                    currentProcess = nil
                }
            }
            process.terminationHandler = nil
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw ChatNativeGrokSubscriptionRuntimeError
                .runtimeUnavailable
        }
        return ChatNativeGrokProcessSession(
            process: process,
            inputHandle: inputPipe.fileHandleForWriting,
            resultWaiter: resultWaiter)
    }

    func stop() {
        let process = lock.withLock { currentProcess }
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private final class ChatNativeGrokOAuthURLStreamOpener:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let openURL: @Sendable (URL) -> Bool
    private let onOpenFailure: @Sendable () -> Void
    private let onAwaitingVerificationCode: @Sendable () -> Void
    private var buffer = Data()
    private var openedURL: URL?
    private var publishedAwaitingVerificationCode = false

    init(
        openURL: @escaping @Sendable (URL) -> Bool,
        onOpenFailure: @escaping @Sendable () -> Void,
        onAwaitingVerificationCode:
            @escaping @Sendable () -> Void
    ) {
        self.openURL = openURL
        self.onOpenFailure = onOpenFailure
        self.onAwaitingVerificationCode = onAwaitingVerificationCode
    }

    var didOpenAuthorizationURL: Bool {
        lock.withLock { openedURL != nil }
    }

    func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        let update = lock.withLock { () -> (URL?, Bool) in
            buffer.append(data)
            if buffer.count > 65_536 {
                buffer = Data(buffer.suffix(65_536))
            }
            var authorizationURL: URL?
            if openedURL == nil,
               let candidate = Self.authorizationURL(in: buffer)
            {
                openedURL = candidate
                authorizationURL = candidate
            }
            let shouldPublishAwaiting =
                !publishedAwaitingVerificationCode
                && openedURL != nil
                && Self.containsVerificationCodePrompt(in: buffer)
            if shouldPublishAwaiting {
                publishedAwaitingVerificationCode = true
            }
            return (authorizationURL, shouldPublishAwaiting)
        }
        if let authorizationURL = update.0 {
            if openURL(authorizationURL) {
                publishAwaitingVerificationCodeIfNeeded()
            } else {
                onOpenFailure()
                return
            }
        }
        if update.1 {
            onAwaitingVerificationCode()
        }
    }

    private static func authorizationURL(in data: Data) -> URL? {
        // URL 可能被切在兩個輸出 chunk 中間（實測：`https://auth.x.ai/` 先到、
        // 路徑後到）。只掃「已被換行終結」的部分，未完行等下一個 chunk 補齊
        // 再判，避免開到半截 URL。
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return nil
        }
        let output = String(
            decoding: data[data.startIndex...lastNewline],
            as: UTF8.self)
        let trimCharacters = CharacterSet(
            charactersIn: "<>\"'()[]{}.,")
        for token in output.split(whereSeparator: \.isWhitespace) {
            let candidate = String(token)
                .trimmingCharacters(in: trimCharacters)
            guard let components = URLComponents(string: candidate),
                  components.scheme?.lowercased() == "https",
                  let host = components.host?.lowercased(),
                  ["auth.x.ai", "accounts.x.ai", "x.ai"].contains(host),
                  let url = components.url
            else {
                continue
            }
            return url
        }
        return nil
    }

    private func publishAwaitingVerificationCodeIfNeeded() {
        let shouldPublish = lock.withLock {
            guard !publishedAwaitingVerificationCode else {
                return false
            }
            publishedAwaitingVerificationCode = true
            return true
        }
        if shouldPublish {
            onAwaitingVerificationCode()
        }
    }

    private static func containsVerificationCodePrompt(
        in data: Data
    ) -> Bool {
        let output = String(decoding: data, as: UTF8.self).lowercased()
        return [
            "verification code",
            "驗證碼",
            "paste",
            "enter code",
            "enter the code",
            "input code",
        ].contains(where: output.contains)
    }
}

enum ChatNativeGrokSubscriptionAccountStatus:
    Sendable,
    Equatable
{
    case unavailable
    case signedOut
    case signedIn
}

enum ChatNativeGrokSubscriptionLoginOutcome: Sendable, Equatable {
    case completed(ChatNativeGrokSubscriptionAccountStatus)
    case timedOut
}

struct ChatNativeGrokSubscriptionAccountService: Sendable {
    private let homeURL: URL
    private let authSourceURL: URL
    private let workingDirectoryURL: URL
    private let runnerFactory:
        @Sendable () throws -> any ChatNativeGrokProcessRunning
    private let loginTimeoutNanoseconds: UInt64

    init(
        runtimeLocator: ChatNativeGrokSubscriptionRuntimeLocator =
            ChatNativeGrokSubscriptionRuntimeLocator(),
        homeLocator: ChatNativeGrokSubscriptionHomeLocator =
            ChatNativeGrokSubscriptionHomeLocator(),
        authSourceLocator: ChatNativeGrokSubscriptionAuthSourceLocator =
            ChatNativeGrokSubscriptionAuthSourceLocator(),
        runnerFactory:
            (@Sendable () throws ->
                any ChatNativeGrokProcessRunning)? = nil,
        loginTimeoutNanoseconds: UInt64 = 180_000_000_000
    ) {
        let homeURL = homeLocator.resolve().standardizedFileURL
        self.homeURL = homeURL
        self.authSourceURL = authSourceLocator.resolve(
            homeURL: homeURL)
        self.workingDirectoryURL = homeURL.appendingPathComponent(
            "login-sessions",
            isDirectory: true)
        self.loginTimeoutNanoseconds = loginTimeoutNanoseconds
        self.runnerFactory = runnerFactory ?? {
            guard let executableURL = runtimeLocator.resolve() else {
                throw ChatNativeGrokSubscriptionRuntimeError
                    .runtimeUnavailable
            }
            return ChatNativeGrokProcessRunner(
                executableURL: executableURL)
        }
    }

    func status() async -> ChatNativeGrokSubscriptionAccountStatus {
        do {
            return try await readStatus(using: runnerFactory())
        } catch ChatNativeGrokSubscriptionRuntimeError.runtimeUnavailable {
            return .unavailable
        } catch {
            return .signedOut
        }
    }

    func login(
        openURL: @escaping @Sendable (URL) -> Bool,
        onSessionStarted:
            @escaping @Sendable (
                any ChatNativeGrokInteractiveProcessSession
            ) -> Void = { _ in },
        onAwaitingVerificationCode:
            @escaping @Sendable () -> Void = {}
    ) async -> ChatNativeGrokSubscriptionLoginOutcome {
        do {
            let runner = try runnerFactory()
            let streamOpener = ChatNativeGrokOAuthURLStreamOpener(
                openURL: openURL,
                onOpenFailure: {
                    runner.stop()
                },
                onAwaitingVerificationCode:
                    onAwaitingVerificationCode)
            let session = try await runner.startInteractive(
                arguments: ["login", "--oauth"],
                environment: environment(),
                currentDirectoryURL: workingDirectoryURL,
                outputHandler: streamOpener.receive)
            onSessionStarted(session)
            let result = try await waitForLoginExit(session: session)
            if result == nil {
                session.terminate()
                return .timedOut
            }
            guard let result else {
                return .timedOut
            }
            guard result.exitCode == 0,
                  streamOpener.didOpenAuthorizationURL
            else {
                return .completed(.signedOut)
            }
            return .completed(try await readStatus(using: runner))
        } catch ChatNativeGrokSubscriptionRuntimeError.runtimeUnavailable {
            return .completed(.unavailable)
        } catch {
            return .completed(.signedOut)
        }
    }

    func logout() async -> ChatNativeGrokSubscriptionAccountStatus {
        do {
            let runner = try runnerFactory()
            let result = try await runner.run(
                arguments: ["logout"],
                standardInput: nil,
                environment: environment(),
                currentDirectoryURL: workingDirectoryURL)
            guard result.exitCode == 0 else {
                return .unavailable
            }
            return .signedOut
        } catch {
            return .unavailable
        }
    }

    private func readStatus(
        using runner: any ChatNativeGrokProcessRunning
    ) async throws -> ChatNativeGrokSubscriptionAccountStatus {
        let result = try await runner.run(
            arguments: ["models"],
            standardInput: nil,
            environment: environment(),
            currentDirectoryURL: workingDirectoryURL)
        return Self.accountStatus(from: result)
    }

    private func waitForLoginExit(
        session: any ChatNativeGrokInteractiveProcessSession
    ) async throws -> ChatNativeGrokProcessResult? {
        enum WaitResult: Sendable {
            case process(ChatNativeGrokProcessResult?)
            case timeout
        }
        return await withTaskGroup(
            of: WaitResult.self
        ) { group in
            group.addTask {
                .process(try? await session.waitForExit())
            }
            group.addTask {
                do {
                    try await Task.sleep(
                        nanoseconds: loginTimeoutNanoseconds)
                    return .timeout
                } catch {
                    return .process(nil)
                }
            }
            let first = await group.next() ?? .process(nil)
            if case .timeout = first {
                session.terminate()
            }
            group.cancelAll()
            switch first {
            case .process(let result):
                return result
            case .timeout:
                return nil
            }
        }
    }

    static func accountStatus(
        from result: ChatNativeGrokProcessResult
    ) -> ChatNativeGrokSubscriptionAccountStatus {
        guard result.exitCode == 0 else { return .signedOut }
        let output = (
            String(decoding: result.stdout, as: UTF8.self)
                + "\n"
                + String(decoding: result.stderr, as: UTF8.self)
        ).lowercased()
        guard ![
            "you are not authenticated",
            "re-authentication required",
            "invalid_grant",
            "no auth credentials",
        ].contains(where: output.contains)
        else {
            return .signedOut
        }
        guard output.contains("grok-build")
                || output.contains("grok-4.6")
        else {
            return .signedOut
        }
        return .signedIn
    }

    private func environment() -> [String: String] {
        var result = ChatNativeSubscriptionEnvironment.scrubbed(
            ProcessInfo.processInfo.environment)
        result["HOME"] = homeURL.path
        result["GROK_HOME"] = homeURL
            .appendingPathComponent(".grok", isDirectory: true).path
        result["XDG_CONFIG_HOME"] = homeURL
            .appendingPathComponent(".config", isDirectory: true).path
        result["XDG_CACHE_HOME"] = homeURL
            .appendingPathComponent(".cache", isDirectory: true).path
        result["GROK_AUTH_SOURCE"] = authSourceURL.path
        for key in [
            "CLAUDE_CONFIG_DIR",
            "CLAUDE_HOME",
            "CLAUDE_PLUGIN_ROOT",
            "CLAUDE_PLUGIN_DATA",
            "CLAUDE_PROJECT_DIR",
        ] {
            result.removeValue(forKey: key)
        }
        return result
    }
}

struct ChatNativeGrokSessionEvidence: Sendable, Equatable {
    let configuredModelID: String
    let turnModelID: String
    let assistantModelID: String
    let requestID: String
}

struct ChatNativeGrokSubscriptionModelTransport:
    TatwoNativeModelTransport
{
    static let supportedModelIDs: Set<String> = ["grok-build"]
    static let vendorModelID = "grok-4.6"

    private let engine: Engine

    init(
        modelID: String,
        effort: String,
        workspaceRoot: String,
        scratchDirectoryURL: URL,
        homeURL: URL? = nil,
        authSourceURL: URL? = nil,
        homeLocator: ChatNativeGrokSubscriptionHomeLocator =
            ChatNativeGrokSubscriptionHomeLocator(),
        authSourceLocator: ChatNativeGrokSubscriptionAuthSourceLocator =
            ChatNativeGrokSubscriptionAuthSourceLocator(),
        runtimeLocator: ChatNativeGrokSubscriptionRuntimeLocator =
            ChatNativeGrokSubscriptionRuntimeLocator(),
        runnerFactory:
            (@Sendable () throws ->
                any ChatNativeGrokProcessRunning)? = nil,
        evidenceLoader:
            (@Sendable (String, String, URL) throws ->
                ChatNativeGrokSessionEvidence)? = nil,
        usageRecorder:
            @escaping @Sendable (String, Int?, Int?) -> Void = {
                provider, inputTokens, outputTokens in
                TatwoLocalUsageMeter.recordShared(
                    provider: provider,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens)
            }
    ) {
        let resolvedFactory = runnerFactory ?? {
            guard let executableURL = runtimeLocator.resolve() else {
                throw ChatNativeGrokSubscriptionRuntimeError
                    .runtimeUnavailable
            }
            return ChatNativeGrokProcessRunner(
                executableURL: executableURL)
        }
        let resolvedHomeURL =
            (homeURL ?? homeLocator.resolve()).standardizedFileURL
        let resolvedAuthSourceURL =
            (authSourceURL ?? authSourceLocator.resolve(
                homeURL: resolvedHomeURL)).standardizedFileURL
        self.engine = Engine(
            modelID: modelID,
            effort: effort,
            workspaceRoot: workspaceRoot,
            scratchDirectoryURL: scratchDirectoryURL,
            homeURL: resolvedHomeURL,
            authSourceURL: resolvedAuthSourceURL,
            runnerFactory: resolvedFactory,
            evidenceLoader: evidenceLoader ?? Self.loadEvidence,
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
        private let homeURL: URL
        private let authSourceURL: URL
        private let runnerFactory:
            @Sendable () throws -> any ChatNativeGrokProcessRunning
        private let evidenceLoader:
            @Sendable (String, String, URL) throws ->
                ChatNativeGrokSessionEvidence
        private let usageRecorder:
            @Sendable (String, Int?, Int?) -> Void
        private var subscriptionVerified = false

        init(
            modelID: String,
            effort: String,
            workspaceRoot: String,
            scratchDirectoryURL: URL,
            homeURL: URL,
            authSourceURL: URL,
            runnerFactory:
                @escaping @Sendable () throws ->
                    any ChatNativeGrokProcessRunning,
            evidenceLoader:
                @escaping @Sendable (String, String, URL) throws ->
                    ChatNativeGrokSessionEvidence,
            usageRecorder:
                @escaping @Sendable (String, Int?, Int?) -> Void
        ) {
            self.modelID = modelID
            self.effort = effort
            self.workspaceRoot = workspaceRoot
            self.scratchDirectoryURL = scratchDirectoryURL
            self.homeURL = homeURL
            self.authSourceURL = authSourceURL
            self.runnerFactory = runnerFactory
            self.evidenceLoader = evidenceLoader
            self.usageRecorder = usageRecorder
        }

        func respond(
            to request: TatwoNativeModelRequest
        ) async throws -> TatwoNativeModelTurn {
            guard modelID == "grok-build", effort == "high" else {
                throw ChatNativeGrokSubscriptionRuntimeError
                    .unsupportedModel
            }
            let runner = try runnerFactory()
            if !subscriptionVerified {
                try await verifySubscription(using: runner)
                subscriptionVerified = true
            }
            let result = try await runner.run(
                arguments: [
                    "--model", ChatNativeGrokSubscriptionModelTransport
                        .vendorModelID,
                    "--effort", effort,
                    "--reasoning-effort", effort,
                    "--no-memory",
                    "--no-subagents",
                    "--disable-web-search",
                    "--permission-mode", "dontAsk",
                    "--tools", "",
                    "--output-format", "json",
                    "--prompt-file", "/dev/stdin",
                ],
                standardInput: Data(
                    try Self.prompt(
                        request: request,
                        workspaceRoot: workspaceRoot).utf8),
                environment: environment(),
                currentDirectoryURL: scratchDirectoryURL)
            guard result.exitCode == 0 else {
                throw ChatNativeGrokSubscriptionRuntimeError.processExited
            }
            let turn = try Self.turn(
                from: result.stdout,
                modelID: modelID,
                effort: effort,
                allowedTools: Set(request.tools.map(\.name)),
                homeURL: homeURL,
                evidenceLoader: evidenceLoader)
            if case .assistantText = turn.response {
                usageRecorder("grok", nil, nil)
            }
            return turn
        }

        private func verifySubscription(
            using runner: any ChatNativeGrokProcessRunning
        ) async throws {
            let result = try await runner.run(
                arguments: ["models"],
                standardInput: nil,
                environment: environment(),
                currentDirectoryURL: scratchDirectoryURL)
            guard ChatNativeGrokSubscriptionAccountService.accountStatus(
                from: result) == .signedIn
            else {
                throw ChatNativeGrokSubscriptionRuntimeError
                    .subscriptionLoginRequired
            }
        }

        private func environment() -> [String: String] {
            var result = ChatNativeSubscriptionEnvironment.scrubbed(
                ProcessInfo.processInfo.environment)
            result["HOME"] = homeURL.path
            result["GROK_HOME"] = homeURL
                .appendingPathComponent(".grok", isDirectory: true).path
            result["XDG_CONFIG_HOME"] = homeURL
                .appendingPathComponent(".config", isDirectory: true).path
            result["XDG_CACHE_HOME"] = homeURL
                .appendingPathComponent(".cache", isDirectory: true).path
            result["GROK_AUTH_SOURCE"] = authSourceURL.path
            for key in [
                "CLAUDE_CONFIG_DIR",
                "CLAUDE_HOME",
                "CLAUDE_PLUGIN_ROOT",
                "CLAUDE_PLUGIN_DATA",
                "CLAUDE_PROJECT_DIR",
            ] {
                result.removeValue(forKey: key)
            }
            return result
        }

        private static func prompt(
            request: TatwoNativeModelRequest,
            workspaceRoot: String
        ) throws -> String {
            let tools: [[String: Any]] = try request.tools.map {
                [
                    "name": $0.name,
                    "description": $0.description,
                    "inputSchema": try JSONSerialization.jsonObject(
                        with: Data($0.inputSchemaJSON.utf8)),
                ]
            }
            let transcript: [[String: Any]] = try request.input.map {
                switch $0 {
                case .userText(let text):
                    return ["type": "user_text", "text": text]
                case .toolCall(let call):
                    return [
                        "type": "tool_call",
                        "id": call.id,
                        "name": call.name,
                        "arguments": try JSONSerialization.jsonObject(
                            with: Data(call.argumentsJSON.utf8)),
                    ]
                case .toolResult(let result):
                    return [
                        "type": "tool_result",
                        "callID": result.callID,
                        "output": result.output,
                        "isError": result.isError,
                    ]
                }
            }
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "workspaceRoot": workspaceRoot,
                    "modelStep": request.modelStep,
                    "tools": tools,
                    "transcript": transcript,
                ],
                options: [.sortedKeys, .withoutEscapingSlashes])
            return """
            You are the exact Grok 4.6 execution engine inside TATWO OS.
            Do not use Grok built-in tools, shell, files, web, MCP, skills, \
            plugins, memory, delegation, or external agents. TATWO Host \
            Executor owns every workspace action. Return only one JSON object. \
            Use {"kind":"assistant_text","text":"..."} when complete, or \
            {"kind":"tool_calls","toolCalls":[{"id":"...","name":"...",\
            "arguments":{}}]} using only tools in the payload.

            TATWO_NATIVE_REQUEST_JSON:
            \(String(decoding: data, as: UTF8.self))
            """
        }

        private static func turn(
            from data: Data,
            modelID: String,
            effort: String,
            allowedTools: Set<String>,
            homeURL: URL,
            evidenceLoader:
                @Sendable (String, String, URL) throws ->
                    ChatNativeGrokSessionEvidence
        ) throws -> TatwoNativeModelTurn {
            guard let envelope = try JSONSerialization.jsonObject(
                with: data) as? [String: Any],
                  envelope["stopReason"] as? String == "EndTurn",
                  let sessionID = envelope["sessionId"] as? String,
                  !sessionID.isEmpty,
                  let requestID = envelope["requestId"] as? String,
                  !requestID.isEmpty,
                  let text = envelope["text"] as? String,
                  let outputData = text.data(using: .utf8),
                  let output = try JSONSerialization.jsonObject(
                    with: outputData) as? [String: Any],
                  let kind = output["kind"] as? String
            else {
                throw ChatNativeGrokSubscriptionRuntimeError.invalidProtocol
            }
            let evidence = try evidenceLoader(
                sessionID,
                requestID,
                homeURL)
            guard evidence.configuredModelID == "grok-4.6",
                  evidence.turnModelID == "grok-4.6",
                  evidence.assistantModelID == "grok-4.6-build",
                  evidence.requestID == requestID
            else {
                throw ChatNativeGrokSubscriptionRuntimeError
                    .modelAttestationMismatch
            }

            let response: TatwoNativeModelResponse
            switch kind {
            case "assistant_text":
                let canonicalText: String?
                if CanonicalVendorEventReadPath.usesCanonicalAdapter() {
                    guard case .assistantMessage(let text) =
                        try GrokRuntimeCanonicalAdapter.adapt(data)
                    else {
                        throw ChatNativeGrokSubscriptionRuntimeError
                            .invalidProtocol
                    }
                    canonicalText = text
                } else {
                    // DEPRECATED: rollback-only legacy UI parser. Keep until
                    // the three-evidence deletion gate is independently met.
                    canonicalText = output["text"] as? String
                }
                guard let value = canonicalText,
                      !value.isEmpty
                else {
                    throw ChatNativeGrokSubscriptionRuntimeError
                        .invalidProtocol
                }
                response = .assistantText(value)
            case "tool_calls":
                guard let values = output["toolCalls"]
                        as? [[String: Any]],
                      !values.isEmpty
                else {
                    throw ChatNativeGrokSubscriptionRuntimeError
                        .invalidProtocol
                }
                let calls = try values.map { value in
                    guard let id = value["id"] as? String,
                          !id.isEmpty,
                          let name = value["name"] as? String,
                          allowedTools.contains(name),
                          let arguments = value["arguments"],
                          JSONSerialization.isValidJSONObject(arguments)
                    else {
                        throw ChatNativeGrokSubscriptionRuntimeError
                            .invalidProtocol
                    }
                    let argumentData = try JSONSerialization.data(
                        withJSONObject: arguments,
                        options: [.sortedKeys, .withoutEscapingSlashes])
                    return TatwoNativeToolCall(
                        id: id,
                        name: name,
                        argumentsJSON:
                            String(decoding: argumentData, as: UTF8.self))
                }
                response = .toolCalls(calls)
            default:
                throw ChatNativeGrokSubscriptionRuntimeError.invalidProtocol
            }
            return TatwoNativeModelTurn(
                response: response,
                attestation: TatwoNativeModelAttestation(
                    modelID: modelID,
                    effort: effort,
                    fallbackCount: 0))
        }
    }

    private static func loadEvidence(
        sessionID: String,
        requestID: String,
        homeURL: URL
    ) throws -> ChatNativeGrokSessionEvidence {
        let sessionsURL = homeURL
            .appendingPathComponent(".grok/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else {
            throw ChatNativeGrokSubscriptionRuntimeError
                .modelAttestationMismatch
        }
        var sessionURL: URL?
        for case let candidate as URL in enumerator
        where candidate.lastPathComponent == "summary.json"
            && candidate.deletingLastPathComponent().lastPathComponent
                == sessionID
        {
            sessionURL = candidate.deletingLastPathComponent()
            break
        }
        guard let sessionURL,
              let summary = try JSONSerialization.jsonObject(
                with: Data(contentsOf:
                    sessionURL.appendingPathComponent("summary.json")))
                as? [String: Any],
              let configuredModelID =
                summary["current_model_id"] as? String,
              (summary["request_id"] as? String) == requestID
        else {
            throw ChatNativeGrokSubscriptionRuntimeError
                .modelAttestationMismatch
        }
        let events = try readJSONLines(
            sessionURL.appendingPathComponent("events.jsonl"))
        let history = try readJSONLines(
            sessionURL.appendingPathComponent("chat_history.jsonl"))
        guard let turnModelID = events.reversed().first(where: {
            $0["type"] as? String == "turn_started"
                && $0["session_id"] as? String == sessionID
        })?["model_id"] as? String,
              let assistantModelID = history.reversed().first(where: {
                  $0["type"] as? String == "assistant"
              })?["model_id"] as? String
        else {
            throw ChatNativeGrokSubscriptionRuntimeError
                .modelAttestationMismatch
        }
        return ChatNativeGrokSessionEvidence(
            configuredModelID: configuredModelID,
            turnModelID: turnModelID,
            assistantModelID: assistantModelID,
            requestID: requestID)
    }

    private static func readJSONLines(
        _ url: URL
    ) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap {
                try JSONSerialization.jsonObject(
                    with: Data($0.utf8)) as? [String: Any]
            }
    }
}
