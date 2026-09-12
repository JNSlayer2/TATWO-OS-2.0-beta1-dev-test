import Foundation
import CryptoKit

/// Machine-local preference; no cross-device sync or credentials. Only owner/repo
/// characters are accepted because the same value also enters an enrollment command.
enum FeedbackSettings {
    static let repositoryKey = "tatwo2.feedback.repository"
    static let defaultRepository = "tatwo214/TATWO-OS-2.0-beta1-dev-test"

    static func repository(defaults: UserDefaults = .standard) -> String {
        let value = (defaults.string(forKey: repositoryKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidRepository(value) ? value : defaultRepository
    }

    static func isValidRepository(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$"#,
                    options: .regularExpression) != nil
            && ![".", ".."].contains(value.split(separator: "/").last.map(String.init) ?? "")
    }

    static var feedbackRepository: String {
        get { repository() }
        set { UserDefaults.standard.set(newValue, forKey: repositoryKey) }
    }
}

struct FeedbackEnvironment: Equatable {
    var appVersion: String
    var appBuild: String
    var macOS: String
    var engine: String

    static func current(engine: String = "none") -> Self {
        Self(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
             appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
             macOS: ProcessInfo.processInfo.operatingSystemVersionString, engine: engine)
    }

    func appending(to body: String) -> String {
        body + "\n\n---\nApp: \(appVersion) (\(appBuild))\nmacOS: \(macOS)\nEngine: \(engine.isEmpty ? "none" : engine)"
    }
}

enum FeedbackReviewPolicy {
    static func requiresManualConfirmation(hasLoggedInEngine: Bool, failureCode: String? = nil) -> Bool {
        !hasLoggedInEngine || failureCode == "tool_unavailable"
    }
}

/// Text-only feedback. Review receipts are in-memory and bound to exact bytes;
/// delivery intent is durable BEFORE POST so a crash cannot enable a blind retry.
struct FeedbackDraft: Codable, Equatable {
    var title = ""
    var body = ""
    var account = ""
    var deliveryPending = false
    var deliveryStartedAt: Date?
    var issueNumber: Int?
    var deliveryRepository: String?
    var deliveryBody: String?
}

struct FeedbackIdentity {
    let username: String
    let token: String
}

enum FeedbackFailure: Error, LocalizedError, Equatable {
    case login, empty, tooLarge, credential, reviewUnavailable, reviewRejected(String)
    case changed, persistence, permission, requestRejected, uncertain, toolUnavailable
    var errorDescription: String? {
        switch self {
        case .toolUnavailable: return "tool_unavailable"
        case .login: return "請先登入github才能提交issue"
        case .empty: return "請填寫標題與內容"
        case .tooLarge: return "標題或內容太長，請縮短後重試"
        case .credential: return "內容疑似含有真實密鑰，請移除後重審"
        case .reviewUnavailable: return "原生模型審查不可用或回覆無效，未提交；請稍後重審"
        case .reviewRejected(let reason): return reason
        case .changed: return "內容或帳號已變更，請重新檢查並確認"
        case .persistence: return "草稿無法安全儲存，未送出"
        case .permission: return "目前 GitHub 帳號無法在 \(FeedbackSettings.feedbackRepository) 建立 Issue；請確認倉庫權限"
        case .requestRejected: return "GitHub 拒絕本次提交；請檢查登入、內容及倉庫權限"
        case .uncertain: return "提交結果尚未確認；請先到 GitHub 檢查，不會自動重送"
        }
    }
}

@MainActor
final class FeedbackService {
    static var repository: String { FeedbackSettings.feedbackRepository }
    // Historical routing fact, never a default for new feedback. Pre-W4 delivery
    // records have no destination field and must not follow a changed preference.
    private static let legacyDeliveryRepository = "tatwo214/tatwo2"
    typealias Reviewer = (String) async throws -> String
    typealias HTTP = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private struct Receipt {
        let fingerprint: String
        let date: Date
        var requiresManualConfirmation = false
    }
    private let draftURL: URL
    private let reviewer: Reviewer
    private let http: HTTP
    private let repositoryProvider: () -> String
    var targetRepository: String { repositoryProvider() }
    private var receipt: Receipt?
    private(set) var preparedBody: String?
    private var reviewing = false
    private var submitting = false
    private(set) var draft: FeedbackDraft

    init(draftURL: URL, reviewer: @escaping Reviewer, http: @escaping HTTP,
         repository: @escaping () -> String = { FeedbackSettings.feedbackRepository }) throws {
        self.repositoryProvider = repository
        self.draftURL = draftURL; self.reviewer = reviewer; self.http = http
        if FileManager.default.fileExists(atPath: draftURL.path) {
            do {
                draft = try JSONDecoder().decode(FeedbackDraft.self, from: Data(contentsOf: draftURL))
                if draft.deliveryRepository == nil, draft.deliveryPending || draft.issueNumber != nil {
                    draft.deliveryRepository = Self.legacyDeliveryRepository
                    draft.deliveryBody = draft.body
                    try persist()
                }
            }
            catch { throw FeedbackFailure.persistence }
        } else { draft = FeedbackDraft() }
    }

    func update(title: String, body: String, account: String) throws {
        guard !submitting, !draft.deliveryPending, draft.issueNumber == nil else { throw FeedbackFailure.uncertain }
        if draft.title != title || draft.body != body || draft.account != account { receipt = nil; preparedBody = nil }
        draft.title = title; draft.body = body; draft.account = account
        try persist()
    }

    private func persist() throws {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(draft).write(to: draftURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draftURL.path)
        } catch { throw FeedbackFailure.persistence }
    }

    static func localCheck(title: String, body: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FeedbackFailure.empty }
        guard title.count <= 256, body.utf8.count <= 60_000 else { throw FeedbackFailure.tooLarge }
        try Self.scanSecrets(title + "\n" + body)
    }

    nonisolated static func scanSecrets(_ text: String) throws {
        // Intentionally narrow: do not block criticism, code, email addresses,
        // file paths, exploit explanations, or generic words such as "password".
        let patterns = [
            #"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"#,
            #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#,
            #"\bgithub_pat_[A-Za-z0-9_]{60,}\b"#,
            #"\bAKIA[A-Z0-9]{16}\b"#,
            #"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}\b"#,
            #"\bxox[baprs]-[A-Za-z0-9-]{24,}\b"#
        ]
        if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
            throw FeedbackFailure.credential
        }
    }

    private func fingerprint(_ identity: FeedbackIdentity) -> String {
        // Length-delimited JSON avoids concatenation collisions; token never persists.
        let parts = [draft.title, draft.body, preparedBody ?? draft.body, identity.username, identity.token, targetRepository]
        return SHA256.hash(data: try! JSONEncoder().encode(parts)).map { String(format: "%02x", $0) }.joined()
    }

    private func validate(_ identity: FeedbackIdentity) throws {
        guard !identity.username.isEmpty, !identity.token.isEmpty else { throw FeedbackFailure.login }
        guard draft.account == identity.username else { throw FeedbackFailure.changed }
        guard !draft.deliveryPending, draft.issueNumber == nil else { throw FeedbackFailure.uncertain }
        try Self.localCheck(title: draft.title, body: draft.body)
    }

    @discardableResult
    func review(identity: FeedbackIdentity, hasLoggedInEngine: Bool = true,
                environment: FeedbackEnvironment = .current()) async throws -> Bool {
        guard !reviewing, !submitting else { throw FeedbackFailure.changed }
        receipt = nil
        try validate(identity) // Must precede ANY model call, including credentials.
        preparedBody = environment.appending(to: draft.body)
        // Scan both the raw draft and the exact augmented payload before review.
        try Self.localCheck(title: draft.title, body: preparedBody!)
        reviewing = true; defer { reviewing = false }
        let bound = fingerprint(identity)
        if FeedbackReviewPolicy.requiresManualConfirmation(hasLoggedInEngine: hasLoggedInEngine) {
            receipt = Receipt(fingerprint: bound, date: Date(), requiresManualConfirmation: true)
            return true
        }
        let payload = try JSONSerialization.data(withJSONObject: ["title": draft.title, "body": preparedBody!], options: [.sortedKeys])
        let output: String
        do { output = try await reviewer(String(decoding: payload, as: UTF8.self)) }
        catch {
            guard bound == fingerprint(identity) else { throw FeedbackFailure.changed }
            if FeedbackReviewPolicy.requiresManualConfirmation(hasLoggedInEngine: hasLoggedInEngine,
                                                               failureCode: error.localizedDescription) {
                receipt = Receipt(fingerprint: bound, date: Date(), requiresManualConfirmation: true)
                return true
            }
            throw FeedbackFailure.reviewUnavailable
        }
        guard bound == fingerprint(identity), !submitting else { throw FeedbackFailure.changed }
        guard output.utf8.count <= 4096,
              let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(object.keys) == Set(["decision", "reason"]) else { throw FeedbackFailure.reviewUnavailable }
        switch (object["decision"], object["reason"]) {
        case ("allow", "none"):
            receipt = Receipt(fingerprint: bound, date: Date())
        case ("block", "credential"):
            throw FeedbackFailure.reviewRejected("含有疑似真實憑證，請移除後重審")
        case ("block", "privacy"):
            throw FeedbackFailure.reviewRejected("含有明確私人敏感資訊，請移除後重審")
        case ("block", "malicious"):
            throw FeedbackFailure.reviewRejected("含有明確惡意可執行內容，請移除後重審")
        default: throw FeedbackFailure.reviewUnavailable
        }
        return false
    }

    func submit(identity: FeedbackIdentity, manualConfirmation: Bool = false) async throws -> Int {
        guard !submitting, !reviewing else { throw FeedbackFailure.changed }
        try validate(identity)
        guard let approved = receipt, approved.fingerprint == fingerprint(identity),
              Date().timeIntervalSince(approved.date) < 600,
              !approved.requiresManualConfirmation || manualConfirmation else { throw FeedbackFailure.changed }
        submitting = true; defer { submitting = false }
        // Verify token identity instead of trusting a local account label. Never
        // use repo-owner, gh CLI, environment or alternate-account credentials.
        var userRequest = request(path: "/user", identity: identity)
        userRequest.httpMethod = "GET"
        let userData: Data; let userResponse: HTTPURLResponse
        do { (userData, userResponse) = try await http(userRequest) }
        catch { throw FeedbackFailure.requestRejected }
        guard userResponse.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: userData) as? [String: Any],
              let login = object["login"] as? String,
              login.caseInsensitiveCompare(identity.username) == .orderedSame else { throw FeedbackFailure.login }
        guard approved.fingerprint == fingerprint(identity) else { throw FeedbackFailure.changed }
        // Persist pending first. Reloading the app preserves uncertainty, never a receipt.
        draft.deliveryRepository = targetRepository
        draft.deliveryBody = preparedBody
        draft.deliveryPending = true
        draft.deliveryStartedAt = Date()
        do { try persist() } catch { draft.deliveryPending = false; throw error }
        receipt = nil
        var post = request(path: "/repos/\(draft.deliveryRepository!)/issues", identity: identity)
        post.httpMethod = "POST"
        post.httpBody = try JSONSerialization.data(withJSONObject: ["title": draft.title, "body": draft.deliveryBody ?? draft.body])
        let data: Data; let response: HTTPURLResponse
        do { (data, response) = try await http(post) }
        catch { throw FeedbackFailure.uncertain }
        if response.statusCode == 201,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let number = object["number"] as? Int, number > 0 {
            draft.issueNumber = number; draft.deliveryPending = false
            // If saving fails, on-disk pending still blocks retries after restart.
            try? persist()
            return number
        }
        if [400, 401, 403, 404, 410, 422, 429].contains(response.statusCode) {
            draft.deliveryPending = false
            do { try persist() } catch { draft.deliveryPending = true; throw FeedbackFailure.uncertain }
            throw [403, 404].contains(response.statusCode) ? FeedbackFailure.permission : FeedbackFailure.requestRejected
        }
        throw FeedbackFailure.uncertain
    }

    func beginNewDraft() throws {
        guard !submitting, !reviewing, !draft.deliveryPending, let number = draft.issueNumber else { throw FeedbackFailure.uncertain }
        let archive = draftURL.deletingLastPathComponent().appendingPathComponent("submitted-\(number)-\(UUID().uuidString).json")
        do { try JSONEncoder().encode(draft).write(to: archive, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        } catch { throw FeedbackFailure.persistence }
        draft = FeedbackDraft(); receipt = nil; preparedBody = nil; try persist()
    }

    func reconcile(identity: FeedbackIdentity) async throws -> Int? {
        guard draft.deliveryPending, !submitting, draft.account == identity.username,
              !identity.token.isEmpty, let started = draft.deliveryStartedAt else { throw FeedbackFailure.uncertain }
        let name = identity.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let repository = draft.deliveryRepository ?? targetRepository
        var get = request(path: "/repos/\(repository)/issues?state=all&sort=created&direction=desc&per_page=100&creator=\(name)", identity: identity)
        get.httpMethod = "GET"
        let (data, response) = try await http(get)
        guard response.statusCode == 200,
              let issues = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw FeedbackFailure.uncertain }
        let formatter = ISO8601DateFormatter()
        let matches = issues.filter { row in
            guard row["pull_request"] == nil,
                  row["title"] as? String == draft.title, row["body"] as? String == (draft.deliveryBody ?? draft.body),
                  let user = row["user"] as? [String: Any],
                  (user["login"] as? String)?.caseInsensitiveCompare(identity.username) == .orderedSame,
                  let created = row["created_at"] as? String, let date = formatter.date(from: created)
            else { return false }
            return date >= started.addingTimeInterval(-5)
        }
        guard matches.count == 1, let number = matches[0]["number"] as? Int, number > 0 else { return nil }
        draft.issueNumber = number; draft.deliveryPending = false; try persist()
        return number
    }

    private func request(path: String, identity: FeedbackIdentity) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.timeoutInterval = 30
        request.setValue("Bearer " + identity.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }
}
