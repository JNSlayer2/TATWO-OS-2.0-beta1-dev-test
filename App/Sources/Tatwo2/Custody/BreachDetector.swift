import AppKit
import Combine
import Foundation
import Network

enum BreachRules {
    struct Account: Hashable, Sendable {
        enum Vault: String, Sendable { case human, ai }
        let vault: Vault
        let id: UUID
    }
    struct LocalResult: Equatable {
        var reused: Set<Account> = []
        var sharedAcrossVaults: Set<Account> = []
    }
    static func splitSHA1(_ sha1: String) throws -> (prefix: String, suffix: String) {
        let hex = sha1.uppercased()
        guard hex.count == 40, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else {
            throw Failure.invalidResponse
        }
        return (String(hex.prefix(5)), String(hex.dropFirst(5)))
    }
    enum Failure: Error { case invalidResponse, unavailable }
    static func match(range: String, sha1: String) throws -> Int {
        let suffix = try splitSHA1(sha1).suffix
        var valid = false, matches = 0
        for line in range.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 35,
                  parts[0].uppercased().utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
                  let count = Int(parts[1]), count >= 0 else { continue }
            valid = true
            // Add-Padding entries with zero frequency are decoys, not breaches.
            if count > 0, parts[0].uppercased() == suffix { matches = max(matches, count) }
        }
        guard valid else { throw Failure.invalidResponse }
        return matches
    }
    static func localRules(_ fingerprints: [Account: String]) -> LocalResult {
        var groups: [String: Set<Account>] = [:]
        for (id, hash) in fingerprints { groups[hash, default: []].insert(id) }
        var result = LocalResult()
        for accounts in groups.values where accounts.count > 1 {
            result.reused.formUnion(accounts)
            if Set(accounts.map(\.vault)).count > 1 { result.sharedAcrossVaults.formUnion(accounts) }
        }
        return result
    }
}

/// This transport accepts ONLY a five-character prefix, never a password, username, URL or full hash.
final class HIBPRangeClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func range(prefix: String) async throws -> String {
        guard prefix.count == 5, prefix.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else {
            throw BreachRules.Failure.invalidResponse
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.pwnedpasswords.com/range/\(prefix)")!)
        request.httpMethod = "GET"
        request.setValue("true", forHTTPHeaderField: "Add-Padding")
        request.setValue("TATWO-OS", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == request.url else { throw BreachRules.Failure.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 512_000 else { throw BreachRules.Failure.invalidResponse }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw BreachRules.Failure.invalidResponse }
        return text
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // No redirect can disclose even the hash prefix to another host.
    }
}

@MainActor
final class BreachDetector: ObservableObject {
    typealias Account = BreachRules.Account
    static let shared = BreachDetector(human: .shared, ai: .shared)
    @Published private(set) var isScanning = false
    @Published private(set) var summary: String?
    @Published private(set) var localWarnings = ""
    @Published var automaticallyAssistAI: Bool {
        didSet { defaults?.set(automaticallyAssistAI, forKey: "custody.autoAssistAI") }
    }
    @Published private(set) var affectedHumanAccounts: [BrowserCredential] = []
    var onAssistAI: ((UUID) -> Void)?
    private let human: BrowserPasswordVault
    private let ai: BrowserAIVault
    private let defaults: UserDefaults?
    private let lookup: (String) async throws -> String
    private let notice: (String) -> Void
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    private var monitor: NWPathMonitor?
    private var scanTask: Task<Void, Never>?
    private var pending: Set<Account> = []
    private var pendingFull = false
    private var retries: Set<Account> = []
    private var retryAfter: Date?
    private var retryFull = false
    private var started = false
    private var lastSuccessfulFullScan: Date?
    private var online = false
    private var attemptedAssistance: [UUID: String] = [:]
    var pendingRetryCount: Int { retries.count }

    init(human: BrowserPasswordVault, ai: BrowserAIVault, defaults: UserDefaults? = .standard,
         lookup: ((String) async throws -> String)? = nil, notice: ((String) -> Void)? = nil) {
        self.human = human; self.ai = ai; self.defaults = defaults
        self.lookup = lookup ?? { try await HIBPRangeClient().range(prefix: $0) }
        self.notice = notice ?? { IslandNotice.shared.info(title: $0, detail: "人用與 AI 帳號分開處理；密碼不離開本機。") }
        automaticallyAssistAI = defaults?.bool(forKey: "custody.autoAssistAI") ?? false
        lastSuccessfulFullScan = defaults?.object(forKey: "custody.lastBreachScan") as? Date
        affectedHumanAccounts = human.credentials.filter { $0.breachedAt != nil }
    }

    /// Called once by the live App, never by preview/fixture or a settings-view appearance.
    func start() {
        guard !started else { return }
        started = true
        pendingFull = true // Restart must not forget a changed credential whose prior scan never succeeded.
        human.passwordChanges.sink { [weak self] in self?.enqueue(Account(vault: .human, id: $0)) }.store(in: &subscriptions)
        ai.passwordChanges.sink { [weak self] in self?.enqueue(Account(vault: .ai, id: $0)) }.store(in: &subscriptions)
        human.$credentials.sink { [weak self] in
            self?.affectedHumanAccounts = $0.filter { $0.breachedAt != nil }
        }.store(in: &subscriptions)
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                self?.online = available
                if available { self?.retryIfDue(); self?.scanIfDue(); self?.drain() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "custody.network", qos: .utility))
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retryIfDue(); self?.scanIfDue(); self?.drain() }
        }
    }

    func scanIfDue(now: Date = Date()) {
        guard online, lastSuccessfulFullScan.map({ now.timeIntervalSince($0) < 7 * 24 * 3600 }) != true else { return }
        scanNow()
    }
    func scanNow() {
        pendingFull = true
        drain(manual: true)
    }
    func retryIfDue(now: Date = Date()) {
        guard online, let retryAfter, now >= retryAfter else { return }
        pending.formUnion(retries)
        pendingFull = pendingFull || retryFull
        retries = []; retryFull = false; self.retryAfter = nil
    }
    private func enqueue(_ account: Account) {
        pending.insert(account)
        drain()
    }
    private func drain(manual: Bool = false) {
        guard !isScanning, manual || online, pendingFull || !pending.isEmpty else { return }
        let full = pendingFull
        let requested = pending
        pendingFull = false; pending = []
        isScanning = true
        scanTask = Task { @MainActor in
            await scan(full: full, requested: requested)
            isScanning = false
            scanTask = nil
            // New/changed credentials queued while awaiting network are never lost.
            if pendingFull || !pending.isEmpty { drain() }
        }
    }

    func fingerprint(_ account: Account) throws -> String {
        switch account.vault {
        case .human: return try human.withPasswordForSecurityCheck(account.id, CustodySHA1.hex)
        case .ai: return try ai.withPasswordForSecurityCheck(account.id, CustodySHA1.hex)
        }
    }

    /// Testable without live network or starting the background service.
    func scan(full: Bool, requested: Set<Account> = []) async {
        let accounts = human.credentials.map { Account(vault: .human, id: $0.id) } +
            ai.credentials.map { Account(vault: .ai, id: $0.id) }
        var fingerprints: [Account: String] = [:]
        var failed = human.storageError != nil || ai.storageError != nil
        for account in accounts {
            do { fingerprints[account] = try fingerprint(account) }
            catch { failed = true; retries.insert(account) }
        }
        let local = BreachRules.localRules(fingerprints)
        localWarnings = local.reused.isEmpty ? "" :
            "\(local.reused.count) 個帳號重複使用密碼；其中 \(local.sharedAcrossVaults.count) 個跨人用／AI 保險庫共用，請分別修改。"
        var ranges: [String: String] = [:] // Scan-lifetime only; never persisted.
        var newAIHits: [UUID] = []
        for account in accounts where full || requested.contains(account) {
            do {
                try Task.checkCancellation()
                guard let hash = fingerprints[account] else { continue }
                let prefix = try BreachRules.splitSHA1(hash).prefix
                let range: String
                if let cached = ranges[prefix] { range = cached }
                else { range = try await lookup(prefix); ranges[prefix] = range }
                let breached = try BreachRules.match(range: range, sha1: hash) > 0
                // Await is an authority boundary: never apply an old result to a new password.
                guard try fingerprint(account) == hash else { pending.insert(account); continue }
                switch account.vault {
                case .human: try human.setBreached(account.id, breached: breached)
                case .ai:
                    try ai.setBreached(account.id, breached: breached)
                    if breached && attemptedAssistance[account.id] != hash { newAIHits.append(account.id) }
                }
                retries.remove(account)
            } catch {
                failed = true
                // Deleted credentials are not queued forever.
                let exists = account.vault == .human ? human.credentials.contains { $0.id == account.id } :
                    ai.credentials.contains { $0.id == account.id }
                if exists { retries.insert(account) }
            }
        }
        affectedHumanAccounts = human.credentials.filter { $0.breachedAt != nil }
        let count = affectedHumanAccounts.count + ai.credentials.filter { $0.breachedAt != nil }.count
        summary = failed ? "掃描未全部完成，保留先前警示；網路或鑰匙圈恢復後再試。" :
            "掃描完成：\(count) 組密碼曾外洩（未命中不代表絕對安全）。"
        if full && !failed {
            lastSuccessfulFullScan = Date()
            defaults?.set(lastSuccessfulFullScan, forKey: "custody.lastBreachScan")
        }
        if failed {
            retryFull = retryFull || full
            retryAfter = Date().addingTimeInterval(5 * 60) // Timer/path retry, never immediate recursive network calls.
        }
        if count > 0 { notice("\(count) 組密碼曾外洩，到設定處理") }
        if automaticallyAssistAI {
            for id in newAIHits where ai.credentials.first(where: { $0.id == id })?.disabledAt == nil {
                guard let onAssistAI else { continue }
                attemptedAssistance[id] = fingerprints[Account(vault: .ai, id: id)]
                onAssistAI(id)
            }
        }
    }

    func assistHuman(_ id: UUID) {
        guard let account = human.credentials.first(where: { $0.id == id }),
              let url = AIPasswordChange.destination(origin: account.origin) else { return }
        Task { @MainActor in
            guard await IslandNotice.shared.ask(title: "要在 \(url.host ?? "") 換密碼嗎",
                detail: "在你的預設瀏覽器開啟改密碼頁；由你操作，人用密碼不交給 AI。完成後請回密碼設定更新。",
                allowLabel: "開啟", timeout: 30) == .allow else { return }
            NSWorkspace.shared.open(url)
        }
    }
    func reportStorageFailure() { summary = "無法更新保險庫，請檢查鑰匙圈及儲存位置。" }
}
