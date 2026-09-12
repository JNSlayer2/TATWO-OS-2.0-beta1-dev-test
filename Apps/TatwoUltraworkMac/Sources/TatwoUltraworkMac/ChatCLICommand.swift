import Foundation
import Darwin
import CryptoKit
@_spi(TatwoHumanGateApp) import TatwoUltraworkCore

enum ChatCLIEvent: Sendable {
    case output(String)
    case raw(String)
    case diagnostic(String)
    case toolUse(ChatCLIActivity)
    case thinking(ChatCLIActivity)
    case reconnectProgress(TatwoNativeChatReconnectProgress)
    case activity(ChatActivityEventV1)
    case session(ChatEngine, String)
    case gatewayContinuation(TatwoGatewayContinuationReceiptV1)
    case nativeTerminalReceipt(receiptID: String, outputRef: String)
    case exit(Int32)
    case failure(String)
    case runtimeFailure(String)
}

struct ChatCLIActivity: Sendable {
    let text: String
    let rawType: String?
}

struct ChatCLICommand: Sendable {
    let engine: ChatEngine
    let executable: String
    let arguments: [String]
    let workingDirectory: URL
    let expectsJSON: Bool
    let capturesSessionID: Bool
    let logFileURL: URL?
    let standardInputFromDevNull: Bool
    let standardInputUTF8: String?
    let requiresForegroundScheduling: Bool
    let runtimeAdapter: TatwoChatRuntimeAdapter
    let nativeDevelopmentAccess: TatwoNativeDevelopmentAccess
    let runtimeFallbackReason: TatwoChatRuntimeFallbackReason?
    let environmentOverrides: [String: String]
    let commandMode: TatwoChatCommandMode
    let gatewayContinuationRequest: TatwoGatewayContinuationRequestV1?
    let automaticBridgeRetryPolicy:
        TatwoChatCommandPlanner.AutomaticBridgeRetryPolicy
    let isAlreadyBridged: Bool
    let ownedTemporaryFiles: [TatwoChatOwnedTemporaryFile]

    init(
        engine: ChatEngine,
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        expectsJSON: Bool,
        capturesSessionID: Bool,
        logFileURL: URL? = nil,
        standardInputFromDevNull: Bool = false,
        standardInputUTF8: String? = nil,
        requiresForegroundScheduling: Bool = false,
        runtimeAdapter: TatwoChatRuntimeAdapter,
        commandMode: TatwoChatCommandMode,
        nativeDevelopmentAccess: TatwoNativeDevelopmentAccess = .none,
        runtimeFallbackReason: TatwoChatRuntimeFallbackReason? = nil,
        environmentOverrides: [String: String] = [:],
        gatewayContinuationRequest: TatwoGatewayContinuationRequestV1? = nil,
        automaticBridgeRetryPolicy:
            TatwoChatCommandPlanner.AutomaticBridgeRetryPolicy = .disabled,
        isAlreadyBridged: Bool = false,
        ownedTemporaryFiles: [TatwoChatOwnedTemporaryFile] = []
    ) {
        self.engine = engine
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.expectsJSON = expectsJSON
        self.capturesSessionID = capturesSessionID
        self.logFileURL = logFileURL
        self.standardInputFromDevNull = standardInputFromDevNull
        self.standardInputUTF8 = standardInputUTF8
        self.requiresForegroundScheduling = requiresForegroundScheduling
        self.runtimeAdapter = runtimeAdapter
        self.nativeDevelopmentAccess = nativeDevelopmentAccess
        self.runtimeFallbackReason = runtimeFallbackReason
        self.environmentOverrides = environmentOverrides
        self.commandMode = commandMode
        self.gatewayContinuationRequest = gatewayContinuationRequest
        self.automaticBridgeRetryPolicy = automaticBridgeRetryPolicy
        self.isAlreadyBridged = isAlreadyBridged
        self.ownedTemporaryFiles = ownedTemporaryFiles
    }

    init(plan: TatwoChatCommandPlan, commandMode: TatwoChatCommandMode) {
        self.init(
            engine: plan.engine,
            executable: plan.executable,
            arguments: plan.arguments,
            workingDirectory: URL(fileURLWithPath: plan.workingDirectoryPath),
            expectsJSON: plan.expectsJSON,
            capturesSessionID: plan.capturesSessionID,
            logFileURL: plan.logFilePath.map { URL(fileURLWithPath: $0) },
            standardInputFromDevNull: plan.standardInputFromDevNull,
            standardInputUTF8: plan.standardInputUTF8,
            requiresForegroundScheduling: plan.requiresForegroundScheduling,
            runtimeAdapter: plan.runtimeAdapter,
            commandMode: commandMode,
            nativeDevelopmentAccess: plan.nativeDevelopmentAccess,
            runtimeFallbackReason: plan.runtimeFallbackReason,
            environmentOverrides: plan.environmentOverrides,
            gatewayContinuationRequest: plan.gatewayContinuationRequest,
            automaticBridgeRetryPolicy: .disabled,
            isAlreadyBridged: false,
            ownedTemporaryFiles: plan.ownedTemporaryFiles)
    }

    // Same turn, different launch path. Used only by the B7 zero-byte
    // bridge retry (see ChatCLIProcessRunner) to re-spawn through
    // `/bin/zsh -c 'exec "$@"' -- <exe> <args...>` without re-deriving the
    // rest of the plan.
    func bridged(executable: String, arguments: [String]) -> ChatCLICommand {
        ChatCLICommand(
            engine: engine,
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            expectsJSON: expectsJSON,
            capturesSessionID: capturesSessionID,
            logFileURL: logFileURL,
            standardInputFromDevNull: standardInputFromDevNull,
            standardInputUTF8: standardInputUTF8,
            requiresForegroundScheduling: requiresForegroundScheduling,
            runtimeAdapter: runtimeAdapter,
            commandMode: commandMode,
            nativeDevelopmentAccess: nativeDevelopmentAccess,
            runtimeFallbackReason: runtimeFallbackReason,
            environmentOverrides: environmentOverrides,
            gatewayContinuationRequest: gatewayContinuationRequest,
            automaticBridgeRetryPolicy: automaticBridgeRetryPolicy,
            isAlreadyBridged: true,
            ownedTemporaryFiles: ownedTemporaryFiles)
    }

    func withRuntimeFallbackReason(
        _ reason: TatwoChatRuntimeFallbackReason
    ) -> ChatCLICommand {
        ChatCLICommand(
            engine: engine,
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            expectsJSON: expectsJSON,
            capturesSessionID: capturesSessionID,
            logFileURL: logFileURL,
            standardInputFromDevNull: standardInputFromDevNull,
            standardInputUTF8: standardInputUTF8,
            requiresForegroundScheduling: requiresForegroundScheduling,
            runtimeAdapter: runtimeAdapter,
            commandMode: commandMode,
            nativeDevelopmentAccess: nativeDevelopmentAccess,
            runtimeFallbackReason: reason,
            environmentOverrides: environmentOverrides,
            gatewayContinuationRequest: gatewayContinuationRequest,
            automaticBridgeRetryPolicy: automaticBridgeRetryPolicy,
            isAlreadyBridged: isAlreadyBridged,
            ownedTemporaryFiles: ownedTemporaryFiles)
    }

    var display: String {
        Self.redacted(
            ([executable] + arguments).joined(separator: " ")
                + (standardInputFromDevNull
                    ? " < /dev/null"
                    : standardInputUTF8 == nil ? "" : " < <stdin-prompt>"))
    }

    private static func redacted(_ text: String) -> String {
        var value = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        value = value.replacingOccurrences(
            of: #"\[Hidden TATWO Ultrawork loopsConfig context[\s\S]*?\[/Hidden TATWO Ultrawork loopsConfig context\]\s*"#,
            with: "<hidden-loops-config> ",
            options: .regularExpression)
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            value = value.replacingOccurrences(of: home, with: "~")
        }
        value = value.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "~", options: .regularExpression)
        value = value.replacingOccurrences(of: #"/(?:private/)?var/folders/[^\s]+"#, with: "/var/folders/…", options: .regularExpression)
        value = value.replacingOccurrences(of: #"/Volumes/[^/\s]+(?:\s[^/\s]+)*/"#, with: "/Volumes/…/", options: .regularExpression)
        return value
    }

    func cleanupOwnedTemporaryFiles() {
        for file in ownedTemporaryFiles {
            ChatCLITemporaryFileOwner.cleanup(file)
        }
    }
}

final class ChatCLIStreamAdapter: @unchecked Sendable {
    private let lock = NSLock()
    private var rawBuffer = ""
    private let expectsJSON: Bool
    private let normalizer: TatwoNativeChatStreamNormalizer

    init(
        engine: ChatEngine,
        expectsJSON: Bool,
        capturesSessionID: Bool = true,
        runtimeAdapter: TatwoChatRuntimeAdapter = .unavailable,
        activityTurnID: String? = nil,
        activityAttempt: Int = 1
    ) {
        self.expectsJSON = expectsJSON
        self.normalizer = TatwoNativeChatStreamNormalizer(
            engine: engine,
            streamFormat: runtimeAdapter == .grokCLI
                ? .grokStreamingJSON
                : .genericJSONL,
            emitsSessionEvents: capturesSessionID,
            activityTurnID: activityTurnID,
            activityAttempt: activityAttempt,
            emitsActivityEvents: true)
    }

    func consume(_ chunk: String) -> [ChatCLIEvent] {
        guard expectsJSON else { return consumeRaw(chunk) }
        let events = normalizer.consume(chunk).map(Self.bridge(event:))
        let activityEvents = normalizer.drainActivityEvents().map(ChatCLIEvent.activity)
        return events + activityEvents
    }

    func flush() -> [ChatCLIEvent] {
        guard expectsJSON else { return consumeRaw("\n") }
        let events = normalizer.flush().map(Self.bridge(event:))
        let activityEvents = normalizer.drainActivityEvents().map(ChatCLIEvent.activity)
        return events + activityEvents
    }

    private func consumeRaw(_ chunk: String) -> [ChatCLIEvent] {
        lock.lock()
        defer { lock.unlock() }
        rawBuffer += chunk
        var events: [ChatCLIEvent] = []
        while let newline = rawBuffer.firstIndex(of: "\n") {
            let line = String(rawBuffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            rawBuffer.removeSubrange(...newline)
            if !line.isEmpty { events.append(.raw(line)) }
        }
        return events
    }

    private static func bridge(event: TatwoNativeChatEvent) -> ChatCLIEvent {
        if let reconnectProgress = event.reconnectProgress {
            return .reconnectProgress(reconnectProgress)
        }
        switch event.kind {
        case .session:
            return .session(event.engine, event.sessionID ?? event.text)
        case .continuation:
            guard let data = event.text.data(using: .utf8),
                  let receipt = try? JSONDecoder().decode(
                    TatwoGatewayContinuationReceiptV1.self,
                    from: data)
            else {
                return .failure("gateway_continuation_receipt_invalid")
            }
            return .gatewayContinuation(receipt)
        case .toolUse:
            return .toolUse(ChatCLIActivity(text: event.text, rawType: event.rawType))
        case .thinking:
            return .thinking(ChatCLIActivity(text: event.text, rawType: event.rawType))
        case .failure:
            return .failure(
                ChatRuntimeContinuationErrorMapping.dispatchFailureMessage(
                    event.text))
        case .raw:
            return .diagnostic(event.text)
        case .exit:
            return .diagnostic(event.text)
        case .message:
            return .output(event.text)
        }
    }
}

final class ChatCLIStreamEventGate: @unchecked Sendable {
    private let lock = NSLock()

    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

final class ChatCLIThinkingHeartbeat: @unchecked Sendable {
    static let sourceType = "tatwo.waiting.heartbeat"

    private let lock = NSLock()
    private let turnID: String
    private let attempt: Int
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let onEvent: @Sendable (ChatCLIEvent) -> Void
    private var timer: DispatchSourceTimer?
    private var observedProviderActivity = false
    private var sequence = 0

    init(
        turnID: String,
        attempt: Int,
        interval: TimeInterval = 2,
        queue: DispatchQueue = DispatchQueue(
            label: "com.tatwo.ultrawork.chat-thinking-heartbeat"),
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) {
        self.turnID = turnID
        self.attempt = max(1, attempt)
        self.interval = max(0.01, interval)
        self.queue = queue
        self.onEvent = onEvent
    }

    func start(
        installTimer: (DispatchSourceTimer) -> Bool
    ) {
        lock.lock()
        guard timer == nil, !observedProviderActivity else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.emitIfWaiting() }
        let installed = installTimer(timer)
        if !installed {
            self.timer = nil
        }
        lock.unlock()
    }

    func observe(_ event: ChatCLIEvent) {
        switch event {
        case .output, .thinking, .toolUse, .reconnectProgress, .activity,
             .session:
            stop()
        default:
            break
        }
    }

    func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        observedProviderActivity = true
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func emitIfWaiting() {
        lock.lock()
        guard !observedProviderActivity, timer != nil else {
            lock.unlock()
            return
        }
        sequence += 1
        let sequence = sequence
        lock.unlock()
        let now = Date()
        onEvent(.activity(ChatActivityEventV1(
            id: "waiting-heartbeat-\(attempt)-\(sequence)",
            kind: .thinking,
            label: "模型仍在思考",
            detail: "已送出，等待第一個回覆",
            startedAt: now,
            endedAt: now,
            status: .succeeded,
            turnID: turnID,
            attempt: attempt,
            sourceType: Self.sourceType)))
    }
}

final class ChatCLIFileTailState: @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutURL: URL
    private let stderrURL: URL
    private var stdoutOffset: UInt64 = 0
    private var stderrOffset: UInt64 = 0

    init(stdoutURL: URL, stderrURL: URL) {
        self.stdoutURL = stdoutURL
        self.stderrURL = stderrURL
    }

    func drain(_ consume: @Sendable (Data, String) -> Void) {
        let stdoutData = readNewData(from: stdoutURL, offset: &stdoutOffset)
        let stderrData = readNewData(from: stderrURL, offset: &stderrOffset)
        if !stdoutData.isEmpty { consume(stdoutData, "") }
        if !stderrData.isEmpty { consume(stderrData, "stderr: ") }
    }

    private func readNewData(from url: URL, offset: inout UInt64) -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        do {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if size < offset { offset = 0 }
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            return data
        } catch {
            return Data()
        }
    }
}

struct ChatCLIOutputPollPolicy: Sendable, Equatable {
    let initialDelay: TimeInterval
    let repeatInterval: TimeInterval

    static let production = ChatCLIOutputPollPolicy(
        initialDelay: 0.12,
        repeatInterval: 0.18)
}
