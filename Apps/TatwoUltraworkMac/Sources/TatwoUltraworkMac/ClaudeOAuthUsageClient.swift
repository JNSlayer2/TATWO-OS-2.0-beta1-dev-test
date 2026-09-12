import Foundation

struct ClaudeOAuthUsage: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        let utilization: Double
        let resetsAt: Date?
    }

    let fiveHour: Window
    let sevenDay: Window
}

enum ClaudeOAuthUsageError: Error, Sendable, Equatable {
    case keychainDenied
    case tokenMissing
    case unauthorized
    case network
    case invalidResponse
    case httpStatus(Int)

    var fallbackReason: String {
        switch self {
        case .keychainDenied:
            "Keychain 存取遭拒"
        case .tokenMissing:
            "找不到 OAuth token"
        case .unauthorized:
            "OAuth token 已過期（401）"
        case .network:
            "網路不可用"
        case .invalidResponse:
            "回應解析失敗"
        case .httpStatus(let status):
            "服務回應 HTTP \(status)"
        }
    }
}

protocol ClaudeOAuthUsageQuerying: Sendable {
    func queryUsage() async throws -> ClaudeOAuthUsage
}

protocol ClaudeOAuthCredentialReading: Sendable {
    func readAccessToken() throws -> String
}

protocol ClaudeKeychainCommandRunning: Sendable {
    func readCredential(
        service: String,
        account: String
    ) throws -> Data
}

protocol ClaudeOAuthUsageHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ClaudeOAuthUsageHTTPTransport {}

struct ClaudeSecurityKeychainCommandRunner:
    ClaudeKeychainCommandRunning
{
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    func readCredential(
        service: String,
        account: String
    ) throws -> Data {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/security",
            isDirectory: false)
        process.arguments = [
            "find-generic-password",
            "-a", account,
            "-w",
            "-s", service,
        ]
        process.standardOutput = output
        process.standardError = error
        process.terminationHandler = { _ in completed.signal() }

        do {
            try process.run()
        } catch {
            throw ClaudeOAuthUsageError.keychainDenied
        }
        guard completed.wait(timeout: .now() + timeout) == .success
        else {
            process.terminate()
            throw ClaudeOAuthUsageError.keychainDenied
        }
        let credential = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let diagnostic = String(
                data: error.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8)?.lowercased() ?? ""
            if diagnostic.contains("item could not be found")
                || diagnostic.contains("errsecitemnotfound")
            {
                throw ClaudeOAuthUsageError.tokenMissing
            }
            throw ClaudeOAuthUsageError.keychainDenied
        }
        return credential
    }
}

struct ClaudeKeychainOAuthCredentialReader:
    ClaudeOAuthCredentialReading
{
    private let service = "Claude Code-credentials"
    private let account: String
    private let commandRunner:
        any ClaudeKeychainCommandRunning

    init(
        environment: [String: String] =
            ProcessInfo.processInfo.environment,
        commandRunner:
            any ClaudeKeychainCommandRunning =
                ClaudeSecurityKeychainCommandRunner()
    ) {
        let candidate = environment["USER"]
            ?? environment["LOGNAME"]
            ?? NSUserName()
        if candidate.range(
            of: #"^[a-zA-Z0-9._-]+$"#,
            options: .regularExpression) != nil
        {
            account = candidate
        } else {
            account = "claude-code-user"
        }
        self.commandRunner = commandRunner
    }

    func readAccessToken() throws -> String {
        let data = try commandRunner.readCredential(
            service: service,
            account: account)
        do {
            let credentials = try JSONDecoder().decode(
                ClaudeStoredCredentials.self,
                from: data)
            let token = credentials.claudeAiOauth.accessToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw ClaudeOAuthUsageError.tokenMissing
            }
            return token
        } catch let error as ClaudeOAuthUsageError {
            throw error
        } catch {
            throw ClaudeOAuthUsageError.invalidResponse
        }
    }
}

final class ClaudeOAuthUsageClient:
    ClaudeOAuthUsageQuerying,
    @unchecked Sendable
{
    private let credentialReader:
        any ClaudeOAuthCredentialReading
    private let transport:
        any ClaudeOAuthUsageHTTPTransport

    init(
        credentialReader:
            any ClaudeOAuthCredentialReading =
                ClaudeKeychainOAuthCredentialReader(),
        transport:
            (any ClaudeOAuthUsageHTTPTransport)? = nil
    ) {
        self.credentialReader = credentialReader
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 6
            configuration.timeoutIntervalForResource = 6
            self.transport = URLSession(configuration: configuration)
        }
    }

    func queryUsage() async throws -> ClaudeOAuthUsage {
        let accessToken: String
        do {
            accessToken = try credentialReader.readAccessToken()
        } catch let error as ClaudeOAuthUsageError {
            throw error
        } catch {
            throw ClaudeOAuthUsageError.keychainDenied
        }

        var request = URLRequest(
            url: URL(
                string:
                    "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization")
        request.setValue(
            "oauth-2025-04-20",
            forHTTPHeaderField: "anthropic-beta")
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as ClaudeOAuthUsageError {
            throw error
        } catch {
            throw ClaudeOAuthUsageError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeOAuthUsageError.invalidResponse
        }
        if http.statusCode == 401 {
            throw ClaudeOAuthUsageError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeOAuthUsageError.httpStatus(http.statusCode)
        }
        do {
            let payload = try JSONDecoder().decode(
                ClaudeOAuthUsagePayload.self,
                from: data)
            return ClaudeOAuthUsage(
                fiveHour: ClaudeOAuthUsage.Window(
                    utilization: payload.fiveHour.utilization,
                    resetsAt: Self.parseDate(
                        payload.fiveHour.resetsAt)),
                sevenDay: ClaudeOAuthUsage.Window(
                    utilization: payload.sevenDay.utilization,
                    resetsAt: Self.parseDate(
                        payload.sevenDay.resetsAt)))
        } catch {
            throw ClaudeOAuthUsageError.invalidResponse
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractional.date(from: value) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }
}

private struct ClaudeStoredCredentials: Decodable {
    let claudeAiOauth: OAuth

    struct OAuth: Decodable {
        let accessToken: String
    }
}

private struct ClaudeOAuthUsagePayload: Decodable {
    let fiveHour: Window
    let sevenDay: Window

    struct Window: Decodable {
        let utilization: Double
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}
