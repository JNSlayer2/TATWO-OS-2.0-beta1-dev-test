// 來源：Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ClaudeOAuthUsageClient.swift；只讀 OAuth 用量與 localhost gateway，匯出環境固定使用 UsageFixture
import Foundation

enum UsageSource {
    static func load(providers: [UsageProviderStatus], environment: [String: String] = ProcessInfo.processInfo.environment) async -> LiveQuotaDeckSnapshot {
        guard !PluginsSource.isExport(environment) else { return fixture(providers: providers) }
        var rows: [String: LiveQuotaDisplay] = [:]
        for provider in providers {
            switch provider.id {
            case "claude": rows[provider.id] = await claudeDisplay(provider)
            case "codex-gpt": rows[provider.id] = await codexDisplay(provider)
            case "grok": rows[provider.id] = localDisplay(provider, label: "GROK", caption: "來源＝App 自身記錄；非 Grok 官方訂閱餘額。")
            default: rows[provider.id] = LiveQuotaDisplay.unverified(provider)
            }
        }
        return .init(loadedAt: Date(), rows: rows)
    }

    static func sourceTestLine() async -> String {
        let snapshot = await load(providers: UsageFixture.providers)
        let claude = snapshot.rows["claude"]
        return "SOURCETEST usage claude=\(claude?.statusText ?? "missing") source=\(claude?.sourceBadge ?? "missing") codex=\(snapshot.rows["codex-gpt"]?.statusText ?? "missing")"
    }

    private static func fixture(providers: [UsageProviderStatus]) -> LiveQuotaDeckSnapshot {
        .init(loadedAt: Date(), rows: Dictionary(uniqueKeysWithValues: providers.map { provider in
            let row: LiveQuotaDisplay
            switch provider.id {
            case "codex-gpt":
                row = LiveQuotaDisplay(id: provider.id, displayName: provider.displayName, planLabel: "CODEX", status: .unknown, statusText: "執行環境不可用", caption: "TATWO 內建 OpenAI 執行環境不可用", permissionLabel: provider.quotaLabel, sourceBadge: "無 live", remainingPercent: nil, primaryRemainingPercent: nil, secondaryRemainingPercent: nil, primaryResetAt: nil, secondaryResetAt: nil, resetCreditsAvailable: nil, resetCreditsExpiresAt: nil, resetCreditExpiryDates: [])
            case "claude":
                row = LiveQuotaDisplay(id: provider.id, displayName: provider.displayName, planLabel: "CLAUDE", status: .unknown, statusText: "執行環境不可用", caption: "TATWO 內建 Claude 執行環境不可用", permissionLabel: "未判定 · 不顯示用量", sourceBadge: "無 live", remainingPercent: nil, primaryRemainingPercent: nil, secondaryRemainingPercent: nil, primaryResetAt: nil, secondaryResetAt: nil, resetCreditsAvailable: nil, resetCreditsExpiresAt: nil, resetCreditExpiryDates: [])
            case "grok":
                row = localDisplay(provider, label: "GROK", caption: "來源＝App 自身記錄；非 Grok 官方訂閱餘額。")
            case "minimax":
                row = localDisplay(provider, label: "MINIMAX", caption: "來源＝App 自身記錄；接 admin key 可顯示官方餘額。")
            default: row = LiveQuotaDisplay.unverified(provider)
            }
            return (provider.id, row)
        }))
    }

    private static func claudeDisplay(_ provider: UsageProviderStatus) async -> LiveQuotaDisplay {
        do {
            let usage = try await ClaudeOAuthUsageClient().queryUsage()
            let fiveHour = remaining(usage.fiveHour.utilization)
            let sevenDay = remaining(usage.sevenDay.utilization)
            return LiveQuotaDisplay(id: provider.id, displayName: provider.displayName, planLabel: "CLAUDE", status: .installed, statusText: "live", caption: "5小時 / 7天 live 用量", permissionLabel: "Claude OAuth", sourceBadge: "Claude live", remainingPercent: fiveHour, primaryRemainingPercent: fiveHour, secondaryRemainingPercent: sevenDay, primaryResetAt: usage.fiveHour.resetsAt, secondaryResetAt: usage.sevenDay.resetsAt, resetCreditsAvailable: nil, resetCreditsExpiresAt: nil, resetCreditExpiryDates: [])
        } catch let error as ClaudeOAuthUsageError {
            return unavailable(provider, status: error == .unauthorized ? "需重新登入" : "執行環境不可用", caption: error.fallbackReason)
        } catch {
            return unavailable(provider, status: "執行環境不可用", caption: "尚無即時用量")
        }
    }

    private static func codexDisplay(_ provider: UsageProviderStatus) async -> LiveQuotaDisplay {
        guard let url = URL(string: "http://127.0.0.1:4177/v1/models") else { return unavailable(provider, status: "執行環境不可用", caption: "尚無即時用量") }
        var request = URLRequest(url: url); request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
                return LiveQuotaDisplay(id: provider.id, displayName: provider.displayName, planLabel: "CODEX", status: .installed, statusText: "可用", caption: "本機 gateway 可用；尚無官方 live 額度 API", permissionLabel: provider.quotaLabel, sourceBadge: "無 live", remainingPercent: nil, primaryRemainingPercent: nil, secondaryRemainingPercent: nil, primaryResetAt: nil, secondaryResetAt: nil, resetCreditsAvailable: nil, resetCreditsExpiresAt: nil, resetCreditExpiryDates: [])
            }
        } catch {}
        return unavailable(provider, status: "執行環境不可用", caption: "尚無即時用量")
    }

    private static func localDisplay(_ provider: UsageProviderStatus, label: String, caption: String) -> LiveQuotaDisplay {
        LiveQuotaDisplay(id: provider.id, displayName: provider.displayName, planLabel: label, status: .installed, statusText: "尚無本機用量", caption: caption, permissionLabel: "App 本機記錄", sourceBadge: "本機計量", remainingPercent: nil, primaryRemainingPercent: nil, secondaryRemainingPercent: nil, primaryResetAt: nil, secondaryResetAt: nil, resetCreditsAvailable: nil, resetCreditsExpiresAt: nil, resetCreditExpiryDates: [])
    }

    private static func unavailable(_ provider: UsageProviderStatus, status: String, caption: String) -> LiveQuotaDisplay {
        LiveQuotaDisplay(id: provider.id, displayName: provider.displayName, planLabel: provider.id == "claude" ? "CLAUDE" : "CODEX", status: .unknown, statusText: status, caption: caption, permissionLabel: provider.quotaLabel, sourceBadge: "無 live", remainingPercent: nil, primaryRemainingPercent: nil, secondaryRemainingPercent: nil, primaryResetAt: nil, secondaryResetAt: nil, resetCreditsAvailable: nil, resetCreditsExpiresAt: nil, resetCreditExpiryDates: [])
    }

    private static func remaining(_ utilization: Double) -> Int { Int(max(0, min(100, 100 - utilization)).rounded()) }
}

struct ClaudeOAuthUsage: Sendable, Equatable {
    struct Window: Sendable, Equatable { let utilization: Double; let resetsAt: Date? }
    let fiveHour: Window; let sevenDay: Window
}

enum ClaudeOAuthUsageError: Error, Sendable, Equatable {
    case keychainDenied, tokenMissing, unauthorized, network, invalidResponse, httpStatus(Int)
    var fallbackReason: String { switch self { case .keychainDenied: "Keychain 存取遭拒"; case .tokenMissing: "找不到 OAuth token"; case .unauthorized: "OAuth token 已過期（401）"; case .network: "網路不可用"; case .invalidResponse: "回應解析失敗"; case .httpStatus(let value): "服務回應 HTTP \(value)" } }
}

protocol ClaudeOAuthUsageQuerying: Sendable { func queryUsage() async throws -> ClaudeOAuthUsage }

final class ClaudeOAuthUsageClient: ClaudeOAuthUsageQuerying, @unchecked Sendable {
    func queryUsage() async throws -> ClaudeOAuthUsage {
        let token = try accessToken()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"; request.timeoutInterval = 6
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw ClaudeOAuthUsageError.network }
        guard let http = response as? HTTPURLResponse else { throw ClaudeOAuthUsageError.invalidResponse }
        if http.statusCode == 401 { throw ClaudeOAuthUsageError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ClaudeOAuthUsageError.httpStatus(http.statusCode) }
        struct Payload: Decodable { struct Window: Decodable { let utilization: Double; let resetsAt: String?; enum CodingKeys: String, CodingKey { case utilization; case resetsAt = "resets_at" } }; let fiveHour: Window; let sevenDay: Window; enum CodingKeys: String, CodingKey { case fiveHour = "five_hour"; case sevenDay = "seven_day" } }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { throw ClaudeOAuthUsageError.invalidResponse }
        return .init(fiveHour: .init(utilization: payload.fiveHour.utilization, resetsAt: date(payload.fiveHour.resetsAt)), sevenDay: .init(utilization: payload.sevenDay.utilization, resetsAt: date(payload.sevenDay.resetsAt)))
    }

    private func accessToken() throws -> String {
        let process = Process(); let output = Pipe(); let error = Pipe(); let done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-w", "-s", "Claude Code-credentials"]
        process.standardOutput = output; process.standardError = error; process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { throw ClaudeOAuthUsageError.keychainDenied }
        guard done.wait(timeout: .now() + 6) == .success else { process.terminate(); throw ClaudeOAuthUsageError.keychainDenied }
        guard process.terminationStatus == 0 else {
            let diagnostic = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.lowercased() ?? ""
            throw diagnostic.contains("item could not be found") ? ClaudeOAuthUsageError.tokenMissing : ClaudeOAuthUsageError.keychainDenied
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        struct Credentials: Decodable { struct OAuth: Decodable { let accessToken: String }; let claudeAiOauth: OAuth }
        guard let credential = try? JSONDecoder().decode(Credentials.self, from: data), !credential.claudeAiOauth.accessToken.isEmpty else { throw ClaudeOAuthUsageError.invalidResponse }
        return credential.claudeAiOauth.accessToken
    }

    private func date(_ raw: String?) -> Date? { guard let raw else { return nil }; return ISO8601DateFormatter().date(from: raw) }
}
