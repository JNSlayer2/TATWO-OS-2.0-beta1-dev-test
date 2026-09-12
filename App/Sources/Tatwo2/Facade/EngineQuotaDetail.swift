import Foundation
import CryptoKit

/// 模型登入頁每家一份的完整額度：訂閱等級、到期日、各個時窗（5 小時／週／Opus 週…）用量與重置時間、購買的點數。
/// 來源全部是各家官方（OpenAI 走 codex app-server 的 account/rateLimits/read；Anthropic 走 OAuth usage）；Grok 官方沒有接口。
struct EngineQuotaDetail: Equatable {
    struct Window: Equatable, Identifiable {
        let id: String
        let label: String          // 例：5 小時、週上限、Opus／Fable 週上限、GPT-5.3-Codex-Spark 5 小時
        let usedPercent: Double    // 0–100
        let resetsAt: Date?
    }
    var tierLabel: String?         // 例：Pro、Max ×5、Max ×20
    var accountLabel: String?      // 顯示用帳號（email）
    var expiresAt: Date?           // 訂閱到期／續期日
    var subscribedAt: Date?        // 訂閱開始
    var windows: [Window]
    var creditsBalance: String?    // OpenAI 購買點數餘額
    var note: String               // 一句話說明來源或為什麼沒有
    var fetchedAt: Date?

    static let empty = EngineQuotaDetail(tierLabel: nil, accountLabel: nil, expiresAt: nil, subscribedAt: nil, windows: [], creditsBalance: nil, note: "", fetchedAt: nil)
}

enum EngineQuotaFetcher {
    // MARK: OpenAI（codex app-server）

    static func openAI(paths: EnginePaths, environment: [String: String] = ProcessInfo.processInfo.environment) -> EngineQuotaDetail {
        var detail = EngineQuotaDetail.empty
        // 訂閱等級與到期：auth.json 裡 id_token 的 claims
        if let email = codexIDTokenTopClaims(authFile: paths.codexAuth)?["email"] as? String { detail.accountLabel = email }
        if let claims = codexIDTokenClaims(authFile: paths.codexAuth) {
            if let plan = claims["chatgpt_plan_type"] as? String { detail.tierLabel = plan.capitalized }
            if let until = claims["chatgpt_subscription_active_until"] as? String { detail.expiresAt = isoDate(until) }
            if let start = claims["chatgpt_subscription_active_start"] as? String { detail.subscribedAt = isoDate(start) }
        }
        guard let reply = appServerCall(paths: paths, environment: environment, method: "account/rateLimits/read") else {
            detail.note = "官方額度讀不到（app-server 沒回應）"
            return detail
        }
        let result = reply["result"] as? [String: Any] ?? [:]
        let byID = result["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        var windows: [EngineQuotaDetail.Window] = []
        func add(_ limitID: String, _ name: String, _ w: [String: Any]?, suffix: String) {
            guard let w, let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { return }
            let mins = (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0
            let reset = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let span = mins >= 10080 ? "週上限" : (mins >= 300 ? "5 小時" : "\(mins) 分鐘")
            windows.append(.init(id: limitID + suffix, label: name.isEmpty ? span : "\(name) \(span)", usedPercent: used, resetsAt: reset))
        }
        // 主額度先放，其他模型額度接在後面
        let ordered = byID.keys.sorted { ($0 == "codex" ? 0 : 1, $0) < ($1 == "codex" ? 0 : 1, $1) }
        for key in ordered {
            let entry = byID[key] ?? [:]
            let name = key == "codex" ? "" : (entry["limitName"] as? String ?? key)
            add(key, name, entry["primary"] as? [String: Any], suffix: ".primary")
            add(key, name, entry["secondary"] as? [String: Any], suffix: ".secondary")
            if key == "codex", let credits = entry["credits"] as? [String: Any], (credits["hasCredits"] as? Bool) == true {
                detail.creditsBalance = credits["balance"] as? String
            }
        }
        if let plan = (result["rateLimits"] as? [String: Any])?["planType"] as? String, detail.tierLabel == nil { detail.tierLabel = plan.capitalized }
        detail.windows = windows
        detail.note = "OpenAI 官方額度（codex app-server）。重置券 OpenAI 沒給查詢接口；OS 絕不會自動使用。"
        detail.fetchedAt = Date()
        return detail
    }

    /// 使用一張 OpenAI 的「重置額度券」。只在使用者按了二次確認才會被呼叫。
    static func consumeOpenAIResetCredit(paths: EnginePaths, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        guard let reply = appServerCall(paths: paths, environment: environment, method: "account/rateLimitResetCredit/consume", params: ["limitId": "codex"]) else {
            return "app-server 沒回應，沒有使用任何重置券"
        }
        if let error = reply["error"] as? [String: Any] { return "OpenAI 拒絕：\(error["message"] as? String ?? "未知原因")" }
        return "已送出使用重置券的請求，重新檢查額度看結果"
    }

    private static func codexIDTokenTopClaims(authFile: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: authFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let token = (json["tokens"] as? [String: Any])?["id_token"] as? String ?? json["id_token"] as? String
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let decoded = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
    }

    private static func codexIDTokenClaims(authFile: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: authFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let token = (json["tokens"] as? [String: Any])?["id_token"] as? String ?? json["id_token"] as? String
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let decoded = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else { return nil }
        return claims["https://api.openai.com/auth"] as? [String: Any]
    }

    /// 起一個短命的 codex app-server，做一次 JSON-RPC，拿到回應就關掉。不碰對話。
    private static func appServerCall(paths: EnginePaths, environment: [String: String], method: String, params: [String: Any] = [:]) -> [String: Any]? {
        guard FileManager.default.isExecutableFile(atPath: paths.codexExecutable.path) else { return nil }
        let process = Process()
        process.executableURL = paths.codexExecutable
        process.arguments = ["app-server"]
        var env = environment
        env["CODEX_HOME"] = paths.codexHome.path
        env["PATH"] = paths.runtimeBinDirectory.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        func send(_ obj: [String: Any]) {
            if let d = try? JSONSerialization.data(withJSONObject: obj) {
                stdin.fileHandleForWriting.write(d); stdin.fileHandleForWriting.write(Data("\n".utf8))
            }
        }
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "tatwo2-quota", "title": "Tatwo2 額度", "version": "0.1"]]])
        var buffer = Data(); var reply: [String: Any]? = nil
        let deadline = Date().addingTimeInterval(10)
        var sentMain = false
        while Date() < deadline, reply == nil {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05); continue }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl); buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if let id = obj["id"] as? Int {
                    if id == 1, !sentMain {
                        sentMain = true
                        send(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
                        send(["jsonrpc": "2.0", "id": 2, "method": method, "params": params])
                    } else if id == 2 { reply = obj }
                }
            }
        }
        process.terminate()
        return reply
    }

    // MARK: Anthropic（OAuth usage）

    static func anthropic(paths: EnginePaths) -> EngineQuotaDetail {
        var detail = EngineQuotaDetail.empty
        // 獨立資料夾的 Keychain 項目：服務名 = "Claude Code-credentials-" + sha256(設定夾路徑) 前 8 碼；沒有就退回主 CLI 的
        let suffix = String(SHA256.hash(data: Data(paths.claudeConfigDirectory.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
        let creds = keychainJSON(service: "Claude Code-credentials-\(suffix)") ?? keychainJSON(service: "Claude Code-credentials")
        let oauth = creds?["claudeAiOauth"] as? [String: Any]
        if let tier = oauth?["rateLimitTier"] as? String ?? accountField(paths, "organizationRateLimitTier") as? String {
            detail.tierLabel = tierLabel(tier, subscription: oauth?["subscriptionType"] as? String)
        } else if let sub = oauth?["subscriptionType"] as? String { detail.tierLabel = sub.capitalized }
        if let created = accountField(paths, "subscriptionCreatedAt") as? String { detail.subscribedAt = isoDate(created) }
        if let email = accountField(paths, "emailAddress") as? String { detail.accountLabel = email }
        guard let token = oauth?["accessToken"] as? String, !token.isEmpty else {
            detail.note = "Anthropic 額度要登入後才讀得到"
            return detail
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let sem = DispatchSemaphore(value: 0)
        var payload: [String: Any]? = nil; var status = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data { payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        guard status == 200, let payload else {
            detail.note = status == 401 ? "Anthropic 的登入過期了，重新登入一次" : "Anthropic 官方額度讀不到（HTTP \(status)）"
            return detail
        }
        let labels: [(String, String)] = [
            ("five_hour", "5 小時"), ("seven_day", "週上限"), ("seven_day_opus", "Opus／Fable 週上限"),
            ("seven_day_sonnet", "Sonnet 週上限"), ("seven_day_oauth_apps", "外部 App 週上限"),
        ]
        var windows: [EngineQuotaDetail.Window] = []
        for (key, label) in labels {
            guard let w = payload[key] as? [String: Any], let used = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows.append(.init(id: key, label: label, usedPercent: used, resetsAt: isoDate(w["resets_at"] as? String)))
        }
        // Fable 有自己的獨立週額度，Anthropic 的回傳用內部代號；已知的對映放這裡，其餘非空時窗照代號列出，不藏。
        let codenames: [String: String] = ["nimbus_quill": "Fable 週上限"]
        let known = Set(labels.map(\.0) + ["extra_usage"])
        for (key, value) in payload where !known.contains(key) {
            guard let w = value as? [String: Any], let used = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows.append(.init(id: key, label: codenames[key] ?? "其他額度（\(key)）", usedPercent: used, resetsAt: isoDate(w["resets_at"] as? String)))
        }
        detail.windows = windows
        if let extra = payload["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true,
           let used = extra["used_credits"], let limit = extra["monthly_limit"] { detail.creditsBalance = "額外用量 \(used)/\(limit)" }
        detail.note = "Anthropic 官方額度（OAuth usage）。到期日 Anthropic 不提供，只有訂閱開始日。"
        detail.fetchedAt = Date()
        return detail
    }

    private static func tierLabel(_ tier: String, subscription: String?) -> String {
        // default_claude_max_5x → Max ×5
        let base = (subscription ?? (tier.contains("max") ? "max" : tier.contains("pro") ? "pro" : "")).capitalized
        if let m = tier.range(of: #"(\d+)x"#, options: .regularExpression) {
            let n = tier[m].dropLast()
            return "\(base) ×\(n)"
        }
        return base.isEmpty ? tier : base
    }

    private static func accountField(_ paths: EnginePaths, _ key: String) -> Any? {
        for url in [paths.claudeAccountFile, paths.fallbackClaudeAccountFile] {
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let account = json["oauthAccount"] as? [String: Any], let value = account[key] { return value }
        }
        return nil
    }

    private static func keychainJSON(service: String) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Grok

    static func grok() -> EngineQuotaDetail {
        var detail = EngineQuotaDetail.empty
        detail.note = "xAI 沒有提供 SuperGrok 額度的查詢接口，這裡只能顯示 App 自己的本機計數。"
        return detail
    }

    private static func isoDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }
}
