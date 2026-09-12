import Foundation
import XCTest
@testable import TatwoUltraworkMac

final class MiniMaxChatClientTests: XCTestCase {
    func testRequestUsesOpenAICompatibleStreamingChatCompletions()
        throws
    {
        let client = MiniMaxChatClient(
            transport: FakeMiniMaxTransport(
                statusCode: 200,
                lines: ["data: [DONE]"]),
            environment: [
                "MINIMAX_API_KEY": "sk-test-secret",
            ])

        let request = try client.makeRequest(
            prompt: "hello minimax")

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.minimax.io/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 120)
        XCTAssertEqual(
            request.value(
                forHTTPHeaderField: "Authorization"),
            "Bearer sk-test-secret")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body)
                as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "MiniMax-M3")
        XCTAssertEqual(object["stream"] as? Bool, true)
        let messages = try XCTUnwrap(
            object["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [[
            "role": "user",
            "content": "hello minimax",
        ]])
    }

    func testSSEParserStreamsDeltasAndAcceptsDone()
        async throws
    {
        let transport = FakeMiniMaxTransport(
            statusCode: 200,
            lines: [
                ": heartbeat",
                #"data: {"choices":[{"delta":{"content":"Hello "},"finish_reason":null}]}"#,
                #"data: {"choices":[{"delta":{"content":"world"},"finish_reason":"stop"}]}"#,
                #"data: {"choices":[],"usage":{"prompt_tokens":21,"completion_tokens":8}}"#,
                "data: [DONE]",
            ])
        let usage = LockedUsageRecorder()
        let client = MiniMaxChatClient(
            transport: transport,
            environment: [
                "MINIMAX_API_KEY": "sk-test-secret",
            ],
            usageRecorder: usage.record)
        let recorder = LockedStringRecorder()

        try await client.stream(
            prompt: "hello",
            onDelta: recorder.append)

        XCTAssertEqual(recorder.value, "Hello world")
        XCTAssertNotNil(transport.request)
        XCTAssertEqual(
            usage.value,
            .init(
                provider: "minimax",
                inputTokens: 21,
                outputTokens: 8))
    }

    func testKeyReaderMatchesEnvironmentAndFileFormats()
        throws
    {
        XCTAssertEqual(
            MiniMaxAPIKeyReader.read(
                environment: [
                    "MINIMAX_API_KEY":
                        "  direct-secret  ",
                    "MINIMAX_API_KEY_FILE": "/ignored",
                ],
                readFile: { _ in
                    XCTFail("direct env key must win")
                    return ""
                }),
            "direct-secret")

        XCTAssertEqual(
            MiniMaxAPIKeyReader.read(
                environment: [
                    "MINIMAX_API_KEY_FILE": "/key.env",
                ],
                readFile: { path in
                    XCTAssertEqual(path, "/key.env")
                    return """
                    # comment
                    export MINIMAX_API_KEY='sk-file-secret'
                    """
                }),
            "sk-file-secret")

        XCTAssertEqual(
            MiniMaxAPIKeyReader.read(
                environment: [
                    "MINIMAX_API_KEY_FILE": "/raw.key",
                ],
                readFile: { _ in "sk-raw-secret\n" }),
            "sk-raw-secret")
    }

    func testMissingKeyUnauthorizedAndNetworkFailClosedWithoutSecretLeak()
        async
    {
        let secret = "sk-never-leak-this"

        await assertFailure(
            client: MiniMaxChatClient(
                transport: FakeMiniMaxTransport(
                    statusCode: 200,
                    lines: []),
                environment: [:]),
            expected: .apiKeyMissing,
            forbidden: secret)

        await assertFailure(
            client: MiniMaxChatClient(
                transport: FakeMiniMaxTransport(
                    statusCode: 401,
                    lines: [
                        "data: \(secret)",
                    ]),
                environment: [
                    "MINIMAX_API_KEY": secret,
                ]),
            expected: .unauthorized,
            forbidden: secret)

        await assertFailure(
            client: MiniMaxChatClient(
                transport: FakeMiniMaxTransport(
                    error: SecretBearingTransportError(
                        secret: secret)),
                environment: [
                    "MINIMAX_API_KEY": secret,
                ]),
            expected: .networkFailure,
            forbidden: secret)
    }

    func testDisconnectedStreamWithoutTerminalFailsClosed()
        async
    {
        await assertFailure(
            client: MiniMaxChatClient(
                transport: FakeMiniMaxTransport(
                    statusCode: 200,
                    lines: [
                        #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#,
                    ]),
                environment: [
                    "MINIMAX_API_KEY": "sk-test-secret",
                ]),
            expected: .incompleteStream,
            forbidden: "sk-test-secret")
    }

    private func assertFailure(
        client: MiniMaxChatClient,
        expected: MiniMaxChatFailure,
        forbidden: String
    ) async {
        do {
            try await client.stream(
                prompt: "test",
                onDelta: { _ in })
            XCTFail("expected \(expected.rawValue)")
        } catch let failure as MiniMaxChatFailure {
            XCTAssertEqual(failure, expected)
            XCTAssertFalse(
                String(describing: failure)
                    .contains(forbidden))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private final class FakeMiniMaxTransport:
    MiniMaxChatHTTPTransport,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let statusCode: Int
    private let lines: [String]
    private let error: Error?
    private var storedRequest: URLRequest?

    init(
        statusCode: Int,
        lines: [String]
    ) {
        self.statusCode = statusCode
        self.lines = lines
        self.error = nil
    }

    init(error: Error) {
        self.statusCode = 0
        self.lines = []
        self.error = error
    }

    var request: URLRequest? {
        lock.withLock { storedRequest }
    }

    func stream(
        for request: URLRequest
    ) async throws -> MiniMaxChatHTTPResponse {
        lock.withLock { storedRequest = request }
        if let error {
            throw error
        }
        let lines = self.lines
        return MiniMaxChatHTTPResponse(
            statusCode: statusCode,
            lines: AsyncThrowingStream {
                continuation in
                for line in lines {
                    continuation.yield(line)
                }
                continuation.finish()
            })
    }
}

private final class LockedStringRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedValue = ""

    var value: String {
        lock.withLock { storedValue }
    }

    func append(_ text: String) {
        lock.withLock { storedValue += text }
    }
}

private final class LockedUsageRecorder:
    @unchecked Sendable
{
    struct Value: Equatable {
        let provider: String
        let inputTokens: Int?
        let outputTokens: Int?
    }

    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.withLock { storedValue }
    }

    func record(
        provider: String,
        inputTokens: Int?,
        outputTokens: Int?
    ) {
        lock.withLock {
            storedValue = Value(
                provider: provider,
                inputTokens: inputTokens,
                outputTokens: outputTokens)
        }
    }
}

private struct SecretBearingTransportError:
    Error,
    CustomStringConvertible
{
    let secret: String
    var description: String {
        "request failed with Authorization: Bearer \(secret)"
    }
}
