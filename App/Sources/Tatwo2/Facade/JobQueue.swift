import Foundation

/// W95：主設備施工佇列。
///
/// 提交只走 W78 已經在用的簽章派發通道（`DeviceDispatch.signed` / `authenticate`）：
/// 這裡只是多一種 payload（`job_submit` / `job_status`），簽章、信任、指紋檢查一行都沒動。
/// 佇列與收據是主設備上的檔案，runner 是 GUI Terminal 前景腳本（`scripts/rooms/job-runner.sh`），
/// App 不跑常駐監工、不自動殺工作。
final class JobQueue: @unchecked Sendable {
    static let shared = JobQueue()

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
        /// 白名單／欄位驗證失敗一律以 invalidParams 回覆呼叫端。
        var invalidParams: Bool { reason.hasPrefix("invalid_params") }
    }

    /// kind 白名單；runner 的 kind→腳本對應表是同一組名字，不接受自由命令。
    static let kinds = ["build", "verify", "package", "thrice", "clean-gate", "install"]

    struct Job: Codable, Identifiable, Sendable {
        var id: String
        var device: String
        var branch: String
        var commit: String
        var kind: String
        var tests: [String]
        var status: String
        var reason: String?
        /// 時間一律 ISO8601 字串：另一個寫入者是 shell runner，字串是兩邊共同的格式。
        var submittedAt: String
        var updatedAt: String?
        var startedAt: String?
        var endedAt: String?
        var exit: Int?
    }

    struct Receipt: Codable, Sendable {
        var id: String
        var kind: String?
        var branch: String?
        var commit: String?
        var startedAt: String?
        var endedAt: String?
        var exit: Int?
        var logTail: [String]
        var artifacts: [String]
        var runner: String?
    }

    let entry: TatwoEntry
    let environment: [String: String]
    private let dispatch: DeviceDispatch
    private let lock = NSRecursiveLock()

    init(entry: TatwoEntry = TatwoEntry(),
         environment: [String: String] = ProcessInfo.processInfo.environment,
         dispatch: DeviceDispatch = .shared) {
        self.entry = entry
        self.environment = environment
        self.dispatch = dispatch
    }

    var staging: URL { DeviceStatusReader.stagingRoot(entry: entry, environment: environment) }
    var queueDir: URL { staging.appendingPathComponent("jobs/queue", isDirectory: true) }
    var receiptsDir: URL { staging.appendingPathComponent("jobs/receipts", isDirectory: true) }
    /// 副設備自己送出的工作留一份存根，設備頁才有東西可看；狀態以主設備回答為準。
    var submittedDir: URL { staging.appendingPathComponent("jobs/submitted", isDirectory: true) }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    // MARK: - 驗證（白名單；任何一項不過就是 invalidParams）

    static func validID(_ value: String) -> Bool { UUID(uuidString: value) != nil }

    static func validBranch(_ value: String) -> Bool {
        guard (1...120).contains(value.count), !value.contains(".."), !value.hasPrefix("-"),
              !value.hasPrefix("/"), !value.hasSuffix("/") else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._/-".contains($0)) }
    }

    /// commit 必須是 40 位小寫 hex（不收 64 位，也不收簡寫）。
    static func validCommit(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }

    /// tests 只准 `tests/<name>.test.mjs` 相對路徑：不准 `..`、不准子目錄、不准絕對路徑。
    static func validTest(_ value: String) -> Bool {
        guard value.hasPrefix("tests/"), value.hasSuffix(".test.mjs"), !value.contains(".."),
              value.count <= 120 else { return false }
        let name = String(value.dropFirst("tests/".count))
        guard !name.isEmpty, name != ".test.mjs" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// 形狀驗證（不含「commit 是否存在於主設備 repo」，那一項只有主設備答得出來）。
    func validatedShape(_ payload: [String: Any], device: String?) throws -> Job {
        guard let kind = payload["kind"] as? String, Self.kinds.contains(kind) else {
            throw Failure(reason: "invalid_params_kind")
        }
        guard let branch = payload["branch"] as? String, Self.validBranch(branch) else {
            throw Failure(reason: "invalid_params_branch")
        }
        guard let commit = payload["commit"] as? String, Self.validCommit(commit) else {
            throw Failure(reason: "invalid_params_commit")
        }
        let rawTests = payload["tests"] ?? [String]()
        guard let tests = rawTests as? [String], tests.count <= 20,
              tests.allSatisfy(Self.validTest) else { throw Failure(reason: "invalid_params_tests") }
        let claimed = (payload["device"] as? String) ?? device ?? ""
        guard Self.validID(claimed), device == nil || claimed.lowercased() == device?.lowercased() else {
            throw Failure(reason: "invalid_params_device")
        }
        guard Set(payload.keys).isSubset(of: ["device", "branch", "commit", "kind", "tests"]) else {
            throw Failure(reason: "invalid_params_unknown_field")
        }
        return Job(id: "", device: claimed, branch: branch, commit: commit, kind: kind, tests: tests,
                   status: "queued", reason: nil, submittedAt: Self.timestamp())
    }

    // MARK: - 主設備端

    private func write(_ job: Job) throws {
        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(job).write(to: queueDir.appendingPathComponent(job.id + ".json"), options: .atomic)
    }

    func job(id: String) throws -> Job? {
        guard Self.validID(id) else { throw Failure(reason: "invalid_params_id") }
        let url = queueDir.appendingPathComponent(id + ".json")
        guard let data = try? Data(contentsOf: url), data.count <= 262_144 else { return nil }
        return try JSONDecoder().decode(Job.self, from: data)
    }

    func receipt(id: String) throws -> Receipt? {
        guard Self.validID(id) else { throw Failure(reason: "invalid_params_id") }
        let url = receiptsDir.appendingPathComponent(id + ".json")
        guard let data = try? Data(contentsOf: url), data.count <= 4 * 1024 * 1024 else { return nil }
        var value = try JSONDecoder().decode(Receipt.self, from: data)
        if value.logTail.count > 200 { value.logTail = Array(value.logTail.suffix(200)) }
        return value
    }

    /// 經簽章通道抵達的提交。id 由主設備產生，回傳給副設備。
    func receive(_ payload: [String: Any], sender: String) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard try dispatch.identity().role == .primary else { throw Failure(reason: "not_primary") }
        var job = try validatedShape(payload, device: sender)
        guard DeviceStatusReader.git(entry.repoRoot, ["rev-parse", "--verify", job.commit + "^{commit}"]) == job.commit
        else { throw Failure(reason: "invalid_params_commit_not_in_primary_repository") }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: queueDir.path))?
            .filter { $0.hasSuffix(".json") }.count ?? 0
        guard existing < 512 else { throw Failure(reason: "job_queue_full") }
        job.id = UUID().uuidString.lowercased()
        job.submittedAt = Self.timestamp()
        try write(job)
        return ["id": job.id, "status": job.status]
    }

    /// 主設備端本機直接讀檔；副設備看收據走 `job_status` RPC。
    func statusResponse(_ payload: [String: Any]) throws -> [String: Any] {
        guard let id = payload["id"] as? String, Self.validID(id) else {
            throw Failure(reason: "invalid_params_id")
        }
        guard Set(payload.keys).isSubset(of: ["id"]) else { throw Failure(reason: "invalid_params_unknown_field") }
        guard let job = try job(id: id) else { throw Failure(reason: "job_not_found") }
        var response: [String: Any] = ["job": try DeviceDispatch.object(job)]
        if let receipt = try receipt(id: id) { response["receipt"] = try DeviceDispatch.object(receipt) }
        return response
    }

    // MARK: - 副設備端

    func submit(branch: String, commit: String, kind: String, tests: [String]) throws -> String {
        let local = try dispatch.identity()
        let payload: [String: Any] = ["device": local.deviceID, "branch": branch,
                                      "commit": commit, "kind": kind, "tests": tests]
        _ = try validatedShape(payload, device: local.deviceID)
        let response = try dispatch.callPrimary(method: "job_submit", payload: payload)
        guard let id = response["id"] as? String, Self.validID(id) else {
            throw Failure(reason: "invalid_job_submit_response")
        }
        var stub = try validatedShape(payload, device: local.deviceID)
        stub.id = id
        try? FileManager.default.createDirectory(at: submittedDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? JSONEncoder().encode(stub).write(to: submittedDir.appendingPathComponent(id + ".json"), options: .atomic)
        return id
    }

    func remoteStatus(id: String) throws -> [String: Any] {
        guard Self.validID(id) else { throw Failure(reason: "invalid_params_id") }
        let response = try dispatch.callPrimary(method: "job_status", payload: ["id": id])
        if let raw = response["job"] as? [String: Any], let job = try? DeviceDispatch.decode(Job.self, raw) {
            try? JSONEncoder().encode(job).write(to: submittedDir.appendingPathComponent(id + ".json"), options: .atomic)
        }
        return response
    }

    /// os.sock 本機呼叫（沒有簽章證明）：副設備轉發到主設備；主設備只准查詢，提交一律要走簽章通道。
    func localCall(method: String, params: [String: Any]) throws -> [String: Any] {
        let role = try dispatch.identity().role
        switch (method, role) {
        case ("job_submit", .secondary):
            guard let branch = params["branch"] as? String, let commit = params["commit"] as? String,
                  let kind = params["kind"] as? String else { throw Failure(reason: "invalid_params_missing_field") }
            let tests = params["tests"] as? [String] ?? []
            return ["id": try submit(branch: branch, commit: commit, kind: kind, tests: tests), "status": "queued"]
        case ("job_submit", _):
            throw Failure(reason: "invalid_params_job_submit_requires_signed_channel")
        case ("job_status", .secondary):
            guard let id = params["id"] as? String else { throw Failure(reason: "invalid_params_id") }
            return try remoteStatus(id: id)
        case ("job_status", _):
            return try statusResponse(params)
        default:
            throw Failure(reason: "invalid_params_method")
        }
    }

    // MARK: - 設備頁用的唯讀清單

    struct Row: Identifiable, Sendable {
        var id: String
        var kind: String
        var branch: String
        var status: String
        var startedAt: String?
        var endedAt: String?
        var exit: Int?
        var reason: String?
    }

    func rows(limit: Int = 50) -> [Row] {
        var byID: [String: Job] = [:]
        for directory in [submittedDir, queueDir] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted().prefix(512) where name.hasSuffix(".json") {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)), data.count <= 262_144,
                      let job = try? JSONDecoder().decode(Job.self, from: data) else { continue }
                byID[job.id] = job
            }
        }
        return byID.values.sorted { $0.submittedAt > $1.submittedAt }.prefix(limit).map { job in
            let paper: Receipt? = (try? receipt(id: job.id)) ?? nil
            return Row(id: job.id, kind: job.kind, branch: job.branch, status: job.status,
                       startedAt: job.startedAt ?? paper?.startedAt, endedAt: job.endedAt ?? paper?.endedAt,
                       exit: job.exit ?? paper?.exit, reason: job.reason)
        }
    }
}
