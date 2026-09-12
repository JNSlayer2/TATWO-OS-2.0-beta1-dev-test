import Foundation
import TatwoUltraworkCore

enum ChatNativeClaudeSubscriptionRuntimeError:
    Error,
    Sendable,
    Equatable,
    TatwoNativeActionableTransportFailure
{
    case runtimeUnavailable
    case subscriptionLoginRequired
    case subscriptionSessionLimit
    case unsupportedModel
    case invalidProtocol
    case modelAttestationMismatch
    case processExited
    case turnFailed

    var nativeFailureCode: String {
        switch self {
        case .runtimeUnavailable:
            "claude_subscription_runtime_unavailable"
        case .subscriptionLoginRequired:
            "claude_subscription_login_required"
        case .subscriptionSessionLimit:
            "claude_subscription_session_limit"
        case .unsupportedModel:
            "unsupported_model"
        case .invalidProtocol:
            "claude_subscription_protocol_error"
        case .modelAttestationMismatch:
            "model_attestation_mismatch"
        case .processExited:
            "claude_subscription_runtime_exited"
        case .turnFailed:
            "claude_subscription_turn_failed"
        }
    }

    var nativeSafeMessage: String {
        switch self {
        case .runtimeUnavailable:
            "TATWO 內建 Claude 執行環境不可用；請重新安裝或更新 TATWO OS。"
        case .subscriptionLoginRequired:
            "請到 TATWO OS 設定 → 模型存取，登入 Claude 訂閱帳號。"
        case .subscriptionSessionLimit:
            "Claude 訂閱本輪已達使用上限；請等待供應商顯示的重設時間後再試。"
        case .unsupportedModel:
            "這個模型不支援 Claude 訂閱執行路線。"
        case .invalidProtocol:
            "TATWO 內建 Claude 執行環境回傳了無效資料。"
        case .modelAttestationMismatch:
            "Claude 模型路線驗證失敗，TATWO 已停止執行。"
        case .processExited:
            "TATWO 內建 Claude 執行環境意外停止。"
        case .turnFailed:
            "Claude 訂閱模型未能完成這次工作。"
        }
    }
}

struct ChatNativeClaudeSubscriptionRuntimeLocator: Sendable {
    static let helperName = "TatwoClaudeSubscriptionRuntime"

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

/// 2026-08-21「登入一直失效」根治。
///
/// 病理：macOS claude CLI 的 OAuth 憑證存 Keychain **使用者全域單槽**
/// （service=Claude Code-credentials／acct 固定，不分 HOME）——app 內
/// 登入會和桌面 Claude Code 搶同一個 OAuth session，任一邊刷新 token，
/// 另一邊的 access token 就被撤銷；staging binary 又因 Keychain ACL 綁
/// cdhash，每次重建都讀不到。快照憑證檔同樣是死叉（主端一刷新即
/// revoked，已實測）。
///
/// 根治：Claude lane 改用 profile 自有的 `claude setup-token` 長效
/// 憑證（獨立授權、不輪替、專為 headless 設計），落在
/// `<profile>/claude-oauth-token`（0600），啟動時以
/// `CLAUDE_CODE_OAUTH_TOKEN` 注入——與桌面 Claude Code 完全脫鉤。
/// 注意：env scrub 仍然剝掉**外部繼承**的同名變數；這裡注入的是
/// profile 自有憑證，語意不同，注入必須在 scrub 之後。
enum ChatNativeClaudeProfileToken {
    static let filename = "claude-oauth-token"

    static func load(profileHomeURL: URL) -> String? {
        let url = profileHomeURL.appendingPathComponent(filename)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// scrub 之後呼叫；沒有 token 檔＝維持原行為（Keychain／credentials 檔）。
    static func inject(
        into environment: inout [String: String],
        profileHomeURL: URL
    ) {
        guard let token = load(profileHomeURL: profileHomeURL) else { return }
        environment["CLAUDE_CODE_OAUTH_TOKEN"] = token
    }
}

struct ChatNativeClaudeSubscriptionHomeLocator: Sendable {
    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func resolve() -> URL {
        if let injected = absoluteDirectory(
            environment["TATWO_NATIVE_CLAUDE_SUBSCRIPTION_HOME"])
        {
            return injected
        }
        if let appSupport = absoluteDirectory(
            environment["TATWO_ULTRAWORK_APP_SUPPORT"])
        {
            return appSupport.appendingPathComponent(
                "model-subscriptions/claude",
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
            "Tatwo Ultrawork/model-subscriptions/claude",
            isDirectory: true)
    }

    private func absoluteDirectory(_ value: String?) -> URL? {
        guard let value, value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
            .standardizedFileURL
    }
}

struct ChatNativeClaudeProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

protocol ChatNativeClaudeProcessRunning: Sendable {
    func run(
        arguments: [String],
        standardInput: Data?,
        environment: [String: String],
        currentDirectoryURL: URL
    ) async throws -> ChatNativeClaudeProcessResult
    func stop()
}

private final class ChatNativeLockedDataBuffer: @unchecked Sendable {
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

final class ChatNativeClaudeProcessRunner:
    ChatNativeClaudeProcessRunning,
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
        currentDirectoryURL: URL
    ) async throws -> ChatNativeClaudeProcessResult {
        guard FileManager.default.isExecutableFile(
            atPath: executableURL.path)
        else {
            throw ChatNativeClaudeSubscriptionRuntimeError
                .runtimeUnavailable
        }
        try FileManager.default.createDirectory(
            at: currentDirectoryURL,
            withIntermediateDirectories: true)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputBuffer = ChatNativeLockedDataBuffer()
        let errorBuffer = ChatNativeLockedDataBuffer()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = {
            outputBuffer.append($0.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = {
            errorBuffer.append($0.availableData)
        }

        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation {
                (continuation:
                    CheckedContinuation<
                        ChatNativeClaudeProcessResult,
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
                        ChatNativeClaudeProcessResult(
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
                            ChatNativeClaudeSubscriptionRuntimeError
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

    func stop() {
        let process = lock.withLock { currentProcess }
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

enum ChatNativeClaudeSubscriptionAccountStatus:
    Sendable,
    Equatable
{
    case unavailable
    case signedOut
    case signedIn(subscriptionType: String)
}

struct ChatNativeClaudeSubscriptionAccountService: Sendable {
    private let homeURL: URL
    private let profileHomeURL: URL
    private let workingDirectoryURL: URL
    private let runnerFactory:
        @Sendable () throws -> any ChatNativeClaudeProcessRunning

    init(
        runtimeLocator: ChatNativeClaudeSubscriptionRuntimeLocator =
            ChatNativeClaudeSubscriptionRuntimeLocator(),
        homeLocator: ChatNativeClaudeSubscriptionHomeLocator =
            ChatNativeClaudeSubscriptionHomeLocator(),
        profileHomeURL: URL? = nil,
        runnerFactory:
            (@Sendable () throws ->
                any ChatNativeClaudeProcessRunning)? = nil
    ) {
        let homeURL = homeLocator.resolve()
        self.homeURL = homeURL
        self.profileHomeURL = (profileHomeURL ?? homeURL).standardizedFileURL
        self.workingDirectoryURL = homeURL.appendingPathComponent(
            "login-sessions",
            isDirectory: true)
        self.runnerFactory = runnerFactory ?? {
            guard let executableURL = runtimeLocator.resolve() else {
                throw ChatNativeClaudeSubscriptionRuntimeError
                    .runtimeUnavailable
            }
            return ChatNativeClaudeProcessRunner(
                executableURL: executableURL)
        }
    }

    func status() async -> ChatNativeClaudeSubscriptionAccountStatus {
        do {
            return try await readStatus(using: runnerFactory())
        } catch {
            return .unavailable
        }
    }

    func login() async -> ChatNativeClaudeSubscriptionAccountStatus {
        do {
            let runner = try runnerFactory()
            let result = try await runner.run(
                arguments: ["auth", "login", "--claudeai"],
                standardInput: nil,
                environment: environment(),
                currentDirectoryURL: workingDirectoryURL)
            guard result.exitCode == 0 else {
                return .signedOut
            }
            return try await readStatus(using: runner)
        } catch {
            return .unavailable
        }
    }

    func logout() async -> ChatNativeClaudeSubscriptionAccountStatus {
        do {
            let runner = try runnerFactory()
            let result = try await runner.run(
                arguments: ["auth", "logout"],
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
        using runner: any ChatNativeClaudeProcessRunning
    ) async throws -> ChatNativeClaudeSubscriptionAccountStatus {
        let result = try await runner.run(
            arguments: ["auth", "status", "--json"],
            standardInput: nil,
            environment: environment(),
            currentDirectoryURL: workingDirectoryURL)
        guard result.exitCode == 0,
              let object = try JSONSerialization.jsonObject(
                with: result.stdout) as? [String: Any]
        else {
            return .signedOut
        }
        guard object["loggedIn"] as? Bool == true,
              object["authMethod"] as? String == "claude.ai",
              object["apiProvider"] as? String == "firstParty"
        else {
            return .signedOut
        }
        return .signedIn(
            subscriptionType:
                object["subscriptionType"] as? String ?? "unknown")
    }

    private func environment() -> [String: String] {
        var result = ChatNativeSubscriptionEnvironment.scrubbed(
            ProcessInfo.processInfo.environment)
        result["HOME"] = profileHomeURL.path
        result.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        result.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        ChatNativeClaudeProfileToken.inject(
            into: &result,
            profileHomeURL: profileHomeURL)
        return result
    }
}

struct ChatNativeClaudeSubscriptionModelTransport:
    TatwoNativeModelTransport
{
    static let supportedModelIDs: Set<String> = ["opus-5", "fable-5"]
    static let vendorModelID = "claude-opus-5"

    static func vendorModelID(for modelID: String) -> String? {
        ClaudeSpawnAuthority.vendorModelID(for: modelID)
    }

    private let engine: Engine

    init(
        modelID: String,
        effort: String,
        workspaceRoot: String,
        scratchDirectoryURL: URL,
        runtimeLocator: ChatNativeClaudeSubscriptionRuntimeLocator =
            ChatNativeClaudeSubscriptionRuntimeLocator(),
        homeLocator: ChatNativeClaudeSubscriptionHomeLocator =
            ChatNativeClaudeSubscriptionHomeLocator(),
        profileHomeURL: URL? = nil,
        runnerFactory:
            (@Sendable () throws ->
                any ChatNativeClaudeProcessRunning)? = nil,
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
        let resolvedFactory = runnerFactory ?? {
            guard let executableURL = runtimeLocator.resolve() else {
                throw ChatNativeClaudeSubscriptionRuntimeError
                    .runtimeUnavailable
            }
            return ChatNativeClaudeProcessRunner(
                executableURL: executableURL)
        }
        self.engine = Engine(
            modelID: modelID,
            effort: effort,
            workspaceRoot: workspaceRoot,
            scratchDirectoryURL: scratchDirectoryURL,
            homeURL: homeURL,
            profileHomeURL: profileHomeURL ?? homeURL,
            runnerFactory: resolvedFactory,
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
        private let profileHomeURL: URL
        private let runnerFactory:
            @Sendable () throws -> any ChatNativeClaudeProcessRunning
        private let usageRecorder:
            @Sendable (String, Int?, Int?) -> Void
        private var subscriptionVerified = false

        init(
            modelID: String,
            effort: String,
            workspaceRoot: String,
            scratchDirectoryURL: URL,
            homeURL: URL,
            profileHomeURL: URL,
            runnerFactory:
                @escaping @Sendable () throws ->
                    any ChatNativeClaudeProcessRunning,
            usageRecorder:
                @escaping @Sendable (String, Int?, Int?) -> Void
        ) {
            self.modelID = modelID
            self.effort = effort
            self.workspaceRoot = workspaceRoot
            self.scratchDirectoryURL = scratchDirectoryURL
            self.homeURL = homeURL
            self.profileHomeURL = profileHomeURL.standardizedFileURL
            self.runnerFactory = runnerFactory
            self.usageRecorder = usageRecorder
        }

        func respond(
            to request: TatwoNativeModelRequest
        ) async throws -> TatwoNativeModelTurn {
            guard Self.supported(modelID),
                  ["low", "medium", "high", "xhigh"].contains(effort),
                  let vendorModelID =
                    ChatNativeClaudeSubscriptionModelTransport
                        .vendorModelID(for: modelID)
            else {
                throw ChatNativeClaudeSubscriptionRuntimeError
                    .unsupportedModel
            }
            let runner = try runnerFactory()
            if !subscriptionVerified {
                try await verifySubscription(using: runner)
                subscriptionVerified = true
            }

            let authority = ClaudeSpawnAuthority(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                profileHomeURL: profileHomeURL)
            let spawnPlan = try authority.plan(ClaudeSpawnRequest(
                purpose: .chatTurn,
                canonicalModelSlug: modelID,
                effort: effort,
                toolPolicy: .none,
                networkPolicy: .allowed,
                workingDirectory: scratchDirectoryURL,
                additionalArguments: [
                    "-p",
                    "--safe-mode",
                    "--permission-mode", "dontAsk",
                    "--no-session-persistence",
                    "--output-format", "json",
                    "--json-schema", Self.responseSchema,
                ]))
            let result = try await runner.run(
                arguments: spawnPlan.arguments,
                standardInput: Data(
                    try Self.prompt(
                        request: request,
                        modelID: modelID,
                        workspaceRoot: workspaceRoot).utf8),
                environment: spawnPlan.environment,
                currentDirectoryURL: scratchDirectoryURL)
            guard result.exitCode == 0 else {
                throw Self.failure(for: result)
            }
            let turn = try Self.turn(
                from: result.stdout,
                modelID: modelID,
                vendorModelID: vendorModelID,
                effort: effort,
                allowedTools: Set(request.tools.map(\.name)))
            if case .assistantText = turn.response {
                let usage = Self.usage(from: result.stdout)
                usageRecorder(
                    "claude",
                    usage.inputTokens,
                    usage.outputTokens)
            }
            return turn
        }

        private func verifySubscription(
            using runner: any ChatNativeClaudeProcessRunning
        ) async throws {
            var authorityEnvironment = ClaudeSpawnAuthority.scrubbedEnvironment(
                ProcessInfo.processInfo.environment)
            authorityEnvironment["HOME"] = profileHomeURL.path
            ClaudeSpawnAuthority.injectProfileToken(
                into: &authorityEnvironment,
                profileHomeURL: profileHomeURL)
            let result = try await runner.run(
                arguments: ["auth", "status", "--json"],
                standardInput: nil,
                environment: authorityEnvironment,
                currentDirectoryURL: scratchDirectoryURL)
            // 2026-08-21：profile 走 setup-token 時 authMethod 不必然回
            // "claude.ai"；訂閱真實性仍由 loggedIn＋firstParty＋下游
            // vendor model fingerprint 把關。無 token 檔維持原嚴格檢查。
            let tokenBased =
                ChatNativeClaudeProfileToken.load(
                    profileHomeURL: profileHomeURL) != nil
            guard result.exitCode == 0,
                  let status = try JSONSerialization.jsonObject(
                    with: result.stdout) as? [String: Any],
                  status["loggedIn"] as? Bool == true,
                  tokenBased
                    || status["authMethod"] as? String == "claude.ai",
                  status["apiProvider"] as? String == "firstParty"
            else {
                throw ChatNativeClaudeSubscriptionRuntimeError
                    .subscriptionLoginRequired
            }
        }

        private static func supported(_ modelID: String) -> Bool {
            ChatNativeClaudeSubscriptionModelTransport.supportedModelIDs
                .contains(modelID)
        }

        private static func failure(
            for result: ChatNativeClaudeProcessResult
        ) -> ChatNativeClaudeSubscriptionRuntimeError {
            guard let envelope = try? JSONSerialization.jsonObject(
                with: result.stdout) as? [String: Any],
                  (envelope["api_error_status"] as? NSNumber)?.intValue
                    == 429,
                  let message = envelope["result"] as? String,
                  message.localizedCaseInsensitiveContains("session limit")
            else {
                return .processExited
            }
            return .subscriptionSessionLimit
        }

        private static let responseSchema = """
        {"type":"object","properties":{"kind":{"type":"string","enum":["assistant_text","tool_calls"]},"text":{"type":"string"},"toolCalls":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"arguments":{"type":"object"}},"required":["id","name","arguments"],"additionalProperties":false}}},"required":["kind"],"additionalProperties":false}
        """

        private static func prompt(
            request: TatwoNativeModelRequest,
            modelID: String,
            workspaceRoot: String
        ) throws -> String {
            let tools: [[String: Any]] = try request.tools.map {
                let schema = try JSONSerialization.jsonObject(
                    with: Data($0.inputSchemaJSON.utf8))
                return [
                    "name": $0.name,
                    "description": $0.description,
                    "inputSchema": schema,
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
            let payload: [String: Any] = [
                "workspaceRoot": workspaceRoot,
                "modelStep": request.modelStep,
                "tools": tools,
                "transcript": transcript,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys, .withoutEscapingSlashes])
            let modelName =
                modelID == "fable-5" ? "Claude Fable 5" : "Claude Opus 5"
            return """
            You are the exact \(modelName) execution engine inside TATWO OS.
            Do not use Claude built-in tools, shell, files, web, MCP, skills, \
            plugins, delegation, or external agents. TATWO Host Executor owns \
            every workspace action. If an action is required, return kind \
            tool_calls and only tools listed in the payload. If the task is \
            complete, return kind assistant_text. Never invent tool results.

            TATWO_NATIVE_REQUEST_JSON:
            \(String(decoding: data, as: UTF8.self))
            """
        }

        private static func turn(
            from data: Data,
            modelID: String,
            vendorModelID: String,
            effort: String,
            allowedTools: Set<String>
        ) throws -> TatwoNativeModelTurn {
            guard let envelope = try JSONSerialization.jsonObject(
                with: data) as? [String: Any],
                  envelope["is_error"] as? Bool == false,
                  envelope["subtype"] as? String == "success",
                  let modelUsage = envelope["modelUsage"]
                    as? [String: [String: Any]],
                  modelUsage.values.contains(where: {
                      $0["canonicalModel"] as? String
                        == vendorModelID
                        && $0["provider"] as? String == "firstParty"
                        && positiveOutputTokens(in: $0)
                  }),
                  !modelUsage.values.contains(where: {
                      guard let usedModel =
                        $0["canonicalModel"] as? String,
                            $0["provider"] as? String == "firstParty",
                            positiveOutputTokens(in: $0)
                      else { return true }
                      return usedModel != vendorModelID
                        && !usedModel.hasPrefix("claude-haiku-")
                  }),
                  let output = envelope["structured_output"]
                    as? [String: Any],
                  let kind = output["kind"] as? String
            else {
                throw ChatNativeClaudeSubscriptionRuntimeError
                    .modelAttestationMismatch
            }

            let response: TatwoNativeModelResponse
            switch kind {
            case "assistant_text":
                let canonicalText: String?
                if CanonicalVendorEventReadPath.usesCanonicalAdapter() {
                    guard case .assistantMessage(let text) =
                        try ClaudeRuntimeCanonicalAdapter.adapt(data)
                    else {
                        throw ChatNativeClaudeSubscriptionRuntimeError
                            .invalidProtocol
                    }
                    canonicalText = text
                } else {
                    // DEPRECATED: rollback-only legacy UI parser. Keep until
                    // the three-evidence deletion gate is independently met.
                    canonicalText = output["text"] as? String
                }
                guard let text = canonicalText,
                      !text.isEmpty
                else {
                    throw ChatNativeClaudeSubscriptionRuntimeError
                        .invalidProtocol
                }
                response = .assistantText(text)

            case "tool_calls":
                guard let values = output["toolCalls"]
                        as? [[String: Any]],
                      !values.isEmpty
                else {
                    throw ChatNativeClaudeSubscriptionRuntimeError
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
                        throw ChatNativeClaudeSubscriptionRuntimeError
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
                throw ChatNativeClaudeSubscriptionRuntimeError
                    .invalidProtocol
            }
            return TatwoNativeModelTurn(
                response: response,
                attestation: TatwoNativeModelAttestation(
                    modelID: modelID,
                    effort: effort,
                    fallbackCount: 0))
        }

        private static func positiveOutputTokens(
            in usage: [String: Any]
        ) -> Bool {
            (usage["outputTokens"] as? NSNumber)?.intValue ?? 0 > 0
        }

        private static func usage(
            from data: Data
        ) -> (inputTokens: Int?, outputTokens: Int?) {
            guard let envelope = try? JSONSerialization.jsonObject(
                with: data) as? [String: Any]
            else {
                return (nil, nil)
            }
            if let usage = envelope["usage"] as? [String: Any] {
                return (
                    (usage["input_tokens"] as? NSNumber)?.intValue
                        ?? (usage["inputTokens"] as? NSNumber)?.intValue,
                    (usage["output_tokens"] as? NSNumber)?.intValue
                        ?? (usage["outputTokens"] as? NSNumber)?.intValue)
            }
            guard let modelUsage = envelope["modelUsage"]
                as? [String: [String: Any]]
            else {
                return (nil, nil)
            }
            let values = modelUsage.values.filter {
                ($0["provider"] as? String) == "firstParty"
            }
            return (
                sum(values, key: "inputTokens"),
                sum(values, key: "outputTokens"))
        }

        private static func sum(
            _ values: [[String: Any]],
            key: String
        ) -> Int? {
            let tokens = values.compactMap {
                ($0[key] as? NSNumber)?.intValue
            }
            return tokens.isEmpty ? nil : tokens.reduce(0, +)
        }
    }
}
