import Foundation
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class ClaudeOAuthUsageClientTests: XCTestCase {
    func testCredentialReaderUsesClaudeCodeKeychainIdentity()
        throws
    {
        let commandRunner = FakeClaudeKeychainCommandRunner(
            result: .success(
                Data(
                    #"{"claudeAiOauth":{"accessToken":"oauth-test-token"}}"#
                        .utf8)))
        let reader = ClaudeKeychainOAuthCredentialReader(
            environment: ["USER": "example"],
            commandRunner: commandRunner)

        let token = try reader.readAccessToken()

        XCTAssertEqual(token, "oauth-test-token")
        XCTAssertEqual(commandRunner.service, "Claude Code-credentials")
        XCTAssertEqual(commandRunner.account, "example")
    }

    func testClientParsesOfficialUsageFixtureAndBuildsOAuthRequest()
        async throws
    {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "claude-usage-probe",
                withExtension: "json"))
        let fixture = try Data(contentsOf: fixtureURL)
        let transport = FakeClaudeOAuthUsageHTTPTransport(
            data: fixture,
            statusCode: 200)
        let client = ClaudeOAuthUsageClient(
            credentialReader:
                FakeClaudeOAuthCredentialReader(
                    result: .success("oauth-test-token")),
            transport: transport)

        let usage = try await client.queryUsage()

        XCTAssertEqual(usage.fiveHour.utilization, 37)
        XCTAssertEqual(usage.sevenDay.utilization, 51)
        XCTAssertEqual(
            usage.fiveHour.resetsAt,
            parseTestDate(
                "2026-08-19T18:29:59.708396+00:00"))
        XCTAssertEqual(
            usage.sevenDay.resetsAt,
            parseTestDate(
                "2026-08-21T03:59:59.708418+00:00"))

        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer oauth-test-token")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "anthropic-beta"),
            "oauth-2025-04-20")
        XCTAssertEqual(request.timeoutInterval, 6)
    }

    func testClientFailsClosedWhenKeychainAccessIsDenied()
        async
    {
        let transport = FakeClaudeOAuthUsageHTTPTransport(
            data: Data(),
            statusCode: 200)
        let client = ClaudeOAuthUsageClient(
            credentialReader:
                FakeClaudeOAuthCredentialReader(
                    result: .failure(.keychainDenied)),
            transport: transport)

        do {
            _ = try await client.queryUsage()
            XCTFail("Keychain denial must fail closed")
        } catch let error as ClaudeOAuthUsageError {
            XCTAssertEqual(error, .keychainDenied)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(transport.request)
    }

    func testLoadClaudeMapsFiveHourAndSevenDayLiveUsage()
        async throws
    {
        let provider = claudeProvider()
        let fiveHourReset = Date(
            timeIntervalSince1970: 1_800_000_000)
        let sevenDayReset = Date(
            timeIntervalSince1970: 1_800_500_000)
        let loadedRow = await TatwoLiveQuotaReader.loadClaude(
            provider: provider,
            accountStatusReader: {
                Self.signedInStatus
            },
            usageClient: FakeClaudeOAuthUsageClient(
                result: .success(
                    ClaudeOAuthUsage(
                        fiveHour: .init(
                            utilization: 37,
                            resetsAt: fiveHourReset),
                        sevenDay: .init(
                            utilization: 51,
                            resetsAt: sevenDayReset)))))
        let row = try XCTUnwrap(loadedRow)

        XCTAssertEqual(row.status, .installed)
        XCTAssertEqual(row.statusText, "live")
        XCTAssertEqual(row.sourceBadge, "Claude live")
        XCTAssertEqual(row.remainingPercent, 63)
        XCTAssertEqual(row.primaryRemainingPercent, 63)
        XCTAssertEqual(row.secondaryRemainingPercent, 49)
        XCTAssertEqual(row.primaryResetAt, fiveHourReset)
        XCTAssertEqual(row.secondaryResetAt, sevenDayReset)
        XCTAssertTrue(row.caption.contains("5小時"))
        XCTAssertTrue(row.caption.contains("7天"))
    }

    func testLoadClaudeFailureCaptionsNameFailureClass()
        async throws
    {
        for failure in [
            ClaudeOAuthUsageError.keychainDenied,
            ClaudeOAuthUsageError.unauthorized,
            ClaudeOAuthUsageError.network,
            ClaudeOAuthUsageError.invalidResponse,
        ] {
            let loadedRow = await TatwoLiveQuotaReader.loadClaude(
                provider: claudeProvider(),
                accountStatusReader: {
                    Self.signedInStatus
                },
                usageClient: FakeClaudeOAuthUsageClient(
                    result: .failure(failure)))
            let row = try XCTUnwrap(loadedRow)

            if failure == .unauthorized {
                XCTAssertEqual(row.status, .missing)
                XCTAssertEqual(row.statusText, "需重新登入")
            } else {
                XCTAssertEqual(row.status, .installed)
                XCTAssertEqual(row.statusText, "授權OK")
            }
            XCTAssertEqual(row.sourceBadge, "無 live")
            XCTAssertNil(row.remainingPercent)
            XCTAssertNil(row.primaryRemainingPercent)
            XCTAssertNil(row.secondaryRemainingPercent)
            XCTAssertNil(row.primaryResetAt)
            XCTAssertNil(row.secondaryResetAt)
            XCTAssertTrue(
                row.caption.contains(failure.fallbackReason))
        }
    }

    func testClientDoesNotRefreshOnUnauthorizedResponse() async {
        let transport = FakeClaudeOAuthUsageHTTPTransport(
            data: Data(),
            statusCode: 401)
        let credentialReader = FakeClaudeOAuthCredentialReader(
            result: .success("expired-token"))
        let client = ClaudeOAuthUsageClient(
            credentialReader: credentialReader,
            transport: transport)

        do {
            _ = try await client.queryUsage()
            XCTFail("401 must fall back without refresh")
        } catch let error as ClaudeOAuthUsageError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(credentialReader.readCount, 1)
    }

    func testLoadClaudeReportsReauthenticationWhenUsageTokenExpired()
        async throws
    {
        let loadedRow = await TatwoLiveQuotaReader.loadClaude(
            provider: claudeProvider(),
            accountStatusReader: {
                Self.signedInStatus
            },
            usageClient: FakeClaudeOAuthUsageClient(
                result: .failure(.unauthorized)))
        let row = try XCTUnwrap(loadedRow)

        XCTAssertEqual(row.status, .missing)
        XCTAssertEqual(row.statusText, "需重新登入")
        XCTAssertEqual(row.sourceBadge, "無 live")
        XCTAssertNil(row.remainingPercent)
        XCTAssertTrue(row.caption.contains("已過期"))
    }

    private static let signedInStatus:
        ChatNativeClaudeSubscriptionAccountStatus =
            .signedIn(subscriptionType: "max")

    private func claudeProvider() -> UsageProviderStatus {
        UsageProviderStatus(
            id: "claude",
            displayName: "Claude",
            status: .installed,
            cachePolicy: "test",
            liveRefreshPolicy: "test",
            quotaLabel: "test")
    }

    private func parseTestDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.date(from: value)
    }
}

private final class FakeClaudeKeychainCommandRunner:
    ClaudeKeychainCommandRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let result: Result<Data, ClaudeOAuthUsageError>
    private var storedService: String?
    private var storedAccount: String?

    init(result: Result<Data, ClaudeOAuthUsageError>) {
        self.result = result
    }

    var service: String? {
        lock.withLock { storedService }
    }

    var account: String? {
        lock.withLock { storedAccount }
    }

    func readCredential(
        service: String,
        account: String
    ) throws -> Data {
        lock.withLock {
            storedService = service
            storedAccount = account
        }
        return try result.get()
    }
}

private final class FakeClaudeOAuthCredentialReader:
    ClaudeOAuthCredentialReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let result: Result<String, ClaudeOAuthUsageError>
    private var storedReadCount = 0

    init(result: Result<String, ClaudeOAuthUsageError>) {
        self.result = result
    }

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    func readAccessToken() throws -> String {
        lock.withLock { storedReadCount += 1 }
        return try result.get()
    }
}

private final class FakeClaudeOAuthUsageHTTPTransport:
    ClaudeOAuthUsageHTTPTransport,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let data: Data
    private let statusCode: Int
    private var storedRequest: URLRequest?

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    var request: URLRequest? {
        lock.withLock { storedRequest }
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        lock.withLock { storedRequest = request }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
        return (data, response)
    }
}

private struct FakeClaudeOAuthUsageClient:
    ClaudeOAuthUsageQuerying
{
    let result: Result<
        ClaudeOAuthUsage,
        ClaudeOAuthUsageError
    >

    func queryUsage() async throws -> ClaudeOAuthUsage {
        try result.get()
    }
}
