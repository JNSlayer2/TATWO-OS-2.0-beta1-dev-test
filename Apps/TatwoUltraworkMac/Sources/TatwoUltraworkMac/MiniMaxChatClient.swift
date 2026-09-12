import Foundation
import TatwoUltraworkCore

enum MiniMaxChatFailure: String, Error, Sendable, Equatable,
    CustomStringConvertible
{
    case apiKeyMissing = "minimax_api_key_missing"
    case unauthorized = "minimax_unauthorized"
    case networkFailure = "minimax_network_failure"
    case httpFailure = "minimax_http_failure"
    case invalidResponse = "minimax_invalid_response"
    case incompleteStream = "minimax_incomplete_stream"

    var description: String { rawValue }
}

struct MiniMaxChatHTTPResponse: Sendable {
    let statusCode: Int
    let lines: AsyncThrowingStream<String, Error>
}

protocol MiniMaxChatHTTPTransport: Sendable {
    func stream(
        for request: URLRequest
    ) async throws -> MiniMaxChatHTTPResponse
}

final class MiniMaxURLSessionTransport:
    MiniMaxChatHTTPTransport,
    @unchecked Sendable
{
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 120
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func stream(
        for request: URLRequest
    ) async throws -> MiniMaxChatHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiniMaxChatFailure.invalidResponse
        }
        let lines = AsyncThrowingStream<String, Error> {
            continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(
                        throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return MiniMaxChatHTTPResponse(
            statusCode: http.statusCode,
            lines: lines)
    }
}

struct MiniMaxAPIKeyReader: Sendable {
    func read(
        environment: [String: String]
    ) -> String? {
        Self.read(
            environment: environment,
            readFile: { try String(contentsOfFile: $0, encoding: .utf8) })
    }

    static func read(
        environment: [String: String],
        readFile: (String) throws -> String
    ) -> String? {
        if let direct = nonEmpty(environment["MINIMAX_API_KEY"]) {
            return direct
        }
        guard let file = nonEmpty(
            environment["MINIMAX_API_KEY_FILE"]),
              let raw = try? readFile(file)
        else {
            return nil
        }
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#")
            else { continue }
            let assignment = trimmed.hasPrefix("export ")
                ? String(trimmed.dropFirst("export ".count))
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines)
                : trimmed
            let prefix = "MINIMAX_API_KEY="
            guard assignment.hasPrefix(prefix) else {
                continue
            }
            if let value = nonEmpty(
                stripShellQuotes(
                    String(assignment.dropFirst(prefix.count))))
            {
                return value
            }
        }
        let fallback = raw.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return fallback.hasPrefix("sk-") ? fallback : nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stripShellQuotes(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last,
              (first == "'" && last == "'")
                || (first == "\"" && last == "\"")
        else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }
}

final class MiniMaxChatClient: @unchecked Sendable {
    static let endpoint = URL(
        string: "https://api.minimax.io/v1/chat/completions")!
    static let backendModel = "MiniMax-M3"

    private let transport: any MiniMaxChatHTTPTransport
    private let environment: [String: String]
    private let keyReader: MiniMaxAPIKeyReader
    private let usageRecorder:
        @Sendable (String, Int?, Int?) -> Void

    init(
        transport:
            any MiniMaxChatHTTPTransport =
                MiniMaxURLSessionTransport(),
        environment: [String: String] =
            ProcessInfo.processInfo.environment,
        keyReader: MiniMaxAPIKeyReader =
            MiniMaxAPIKeyReader(),
        usageRecorder:
            @escaping @Sendable (String, Int?, Int?) -> Void = {
                provider, inputTokens, outputTokens in
                TatwoLocalUsageMeter.recordShared(
                    provider: provider,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens)
            }
    ) {
        self.transport = transport
        self.environment = environment
        self.keyReader = keyReader
        self.usageRecorder = usageRecorder
    }

    func makeRequest(prompt: String) throws -> URLRequest {
        guard let apiKey = keyReader.read(
            environment: environment)
        else {
            throw MiniMaxChatFailure.apiKeyMissing
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type")
        request.setValue(
            "text/event-stream",
            forHTTPHeaderField: "Accept")
        request.setValue(
            "Bearer \(apiKey)",
            forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": Self.backendModel,
                "messages": [
                    [
                        "role": "user",
                        "content": prompt,
                    ],
                ],
                "stream": true,
                "stream_options": [
                    "include_usage": true,
                ],
            ],
            options: [.sortedKeys])
        return request
    }

    func stream(
        prompt: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        let request = try makeRequest(prompt: prompt)
        let response: MiniMaxChatHTTPResponse
        do {
            response = try await transport.stream(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as MiniMaxChatFailure {
            throw failure
        } catch {
            // Never surface transport descriptions: they may echo request
            // headers, including the API key.
            throw MiniMaxChatFailure.networkFailure
        }
        if response.statusCode == 401 {
            throw MiniMaxChatFailure.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MiniMaxChatFailure.httpFailure
        }

        var sawTerminal = false
        var inputTokens: Int?
        var outputTokens: Int?
        do {
            for try await rawLine in response.lines {
                try Task.checkCancellation()
                let line = rawLine.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                guard line.hasPrefix("data:") else { continue }
                let dataText = String(
                    line.dropFirst(5))
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines)
                if dataText == "[DONE]" {
                    sawTerminal = true
                    break
                }
                guard let data = dataText.data(using: .utf8),
                      let event = try? JSONDecoder().decode(
                        MiniMaxChatCompletionEvent.self,
                        from: data)
                else {
                    throw MiniMaxChatFailure.invalidResponse
                }
                if let usage = event.usage {
                    inputTokens = usage.promptTokens
                    outputTokens = usage.completionTokens
                }
                for choice in event.choices {
                    if let content = choice.delta?.content,
                       !content.isEmpty
                    {
                        onDelta(content)
                    }
                    if choice.finishReason != nil {
                        sawTerminal = true
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as MiniMaxChatFailure {
            throw failure
        } catch {
            throw MiniMaxChatFailure.networkFailure
        }
        guard sawTerminal else {
            throw MiniMaxChatFailure.incompleteStream
        }
        usageRecorder(
            "minimax",
            inputTokens,
            outputTokens)
    }
}

private struct MiniMaxChatCompletionEvent: Decodable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let content: String?
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

protocol MiniMaxChatRunning: Sendable {
    func start(
        prompt: String,
        runID: String,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity?
    func terminate()
}

final class MiniMaxChatRunner:
    MiniMaxChatRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private let client: MiniMaxChatClient

    init(client: MiniMaxChatClient = MiniMaxChatClient()) {
        self.client = client
    }

    func start(
        prompt: String,
        runID: String,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity? {
        terminate()
        let identity = ChatRunnerAttemptIdentity(
            runID: runID,
            attempt: 1,
            instanceID: UUID(),
            revision: 1)
        let client = self.client
        let newTask = Task {
            do {
                try await client.stream(
                    prompt: prompt,
                    onDelta: { text in
                        onEvent(.output(text))
                    })
                onEvent(.exit(0))
            } catch is CancellationError {
                onEvent(.exit(130))
            } catch let failure as MiniMaxChatFailure {
                onEvent(.runtimeFailure(failure.rawValue))
            } catch {
                onEvent(.runtimeFailure(
                    MiniMaxChatFailure.networkFailure.rawValue))
            }
        }
        lock.withLock { task = newTask }
        return identity
    }

    func terminate() {
        let current = lock.withLock { () -> Task<Void, Never>? in
            defer { task = nil }
            return task
        }
        current?.cancel()
    }
}
