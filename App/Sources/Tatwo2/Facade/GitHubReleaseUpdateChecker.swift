import Foundation
import Combine
import CryptoKit

/// Release-train precedence; accepts 2–4 numeric components, padding missing components with zero.
/// Invalid input fails closed. Numeric strings avoid integer overflow.
enum ReleaseVersionCompare {
    private struct Version {
        let core: [String]
        let prerelease: [String]

        init?(_ raw: String) {
            let text = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
            let build = text.split(separator: "+", omittingEmptySubsequences: false)
            guard build.count <= 2 else { return nil }
            func validIdentifier(_ value: Substring) -> Bool {
                !value.isEmpty && value.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0)
                        || (97...122).contains($0) || $0 == 45
                }
            }
            if build.count == 2 {
                guard build[1].split(separator: ".", omittingEmptySubsequences: false)
                    .allSatisfy(validIdentifier) else { return nil }
            }
            let parts = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard (2...4).contains(numbers.count),
                  numbers.enumerated().allSatisfy({ index, value in ReleaseVersionCompare.numeric(value) && (index == 3 || value == "0" || !value.hasPrefix("0")) })
            else { return nil }
            core = numbers.map { String($0.drop(while: { $0 == "0" })).isEmpty ? "0" : String($0.drop(while: { $0 == "0" })) } + Array(repeating: "0", count: 4 - numbers.count)
            if parts.count == 2 {
                let ids = parts[1].split(separator: ".", omittingEmptySubsequences: false)
                guard ids.allSatisfy(validIdentifier),
                      ids.allSatisfy({ !ReleaseVersionCompare.numeric(String($0)) || $0 == "0" || !$0.hasPrefix("0") })
                else { return nil }
                prerelease = ids.map(String.init)
            } else {
                prerelease = []
            }
        }
    }

    private static func numeric(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func numericLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }

    static func isValid(_ version: String) -> Bool { Version(version) != nil }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let lhs = Version(installed), let rhs = Version(candidate) else { return false }
        for (a, b) in zip(lhs.core, rhs.core) where a != b {
            return numericLess(a, b)
        }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if numeric(a) && numeric(b) { return numericLess(a, b) }
            if numeric(a) != numeric(b) { return numeric(a) }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// A credential stays in memory; marker alone never authorizes the private repository.
struct UpdateChannel {
    static let privateRepository = "tatwo214/TATWO-OS-2.0-private"
    let requestedPrivate: Bool
    let username: String?
    let token: String?
    var isPrivate: Bool { requestedPrivate && token?.isEmpty == false }
    static func current() -> Self {
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/tatwo2/os/update-channel")
        let requested = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "private"
        guard requested else { return Self(requestedPrivate: false, username: nil, token: nil) }
        let store = GitHubAccountsStore()
        let account = try? store.loadAccounts().first
        let token = account.flatMap { try? store.mcpToken(username: $0.username) }
        return Self(requestedPrivate: true, username: account?.username, token: token)
    }
    func authorize(_ request: inout URLRequest) {
        guard isPrivate, request.url?.scheme == "https", request.url?.host == "api.github.com",
              request.url?.path.hasPrefix("/repos/\(Self.privateRepository)/") == true else { return }
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
    }
}

// UPDATE-TRANSPORT-BEGIN
final class UpdateRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = UpdateRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if response.url?.host?.lowercased() != request.url?.host?.lowercased()
            || response.url?.scheme != request.url?.scheme || response.url?.port != request.url?.port {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }
}

enum UpdateReleaseRevalidation {
    struct Asset: Decodable { let id: Int64?; let name: String; let browser_download_url: String }
    private struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool; let assets: [Asset] }
    static func verify(session: URLSession, request: URLRequest, tag: String, cachedMarker: Data,
                       markerRequest: (Asset) throws -> URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request, delegate: UpdateRedirectDelegate.shared)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let markers = release.assets.filter { $0.name == "TATWO-OS.install-ready" }
        guard release.tag_name == tag, !release.draft, !release.prerelease, markers.count == 1 else {
            throw URLError(.resourceUnavailable)
        }
        let (marker, markerResponse) = try await session.data(for: markerRequest(markers[0]), delegate: UpdateRedirectDelegate.shared)
        guard (markerResponse as? HTTPURLResponse)?.statusCode == 200,
              SHA256.hash(data: marker) == SHA256.hash(data: cachedMarker) else { throw URLError(.resourceUnavailable) }
        return data
    }
}
// UPDATE-TRANSPORT-END

@MainActor
final class GitHubReleaseUpdateChecker: ObservableObject {
    struct Release: Decodable, Equatable {
        struct Asset: Decodable, Equatable { let name: String }
        var assets: [Asset]? = nil
        let tag_name: String
        let name: String?
        let draft: Bool
        let prerelease: Bool
    }

    static let shared = GitHubReleaseUpdateChecker()
    static let defaultRepository = "tatwo214/TATWO-OS-2.0-beta1-dev-test"
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/tatwo214/TATWO-OS-2.0-beta1-dev-test/main/install.sh | bash"
    var terminalInstallCommand: String {
        guard let tag = availableRelease?.tag_name,
              tag.range(of: #"^v?[0-9]+([.][0-9]+){1,3}$"#, options: .regularExpression) != nil else { return "" }
        return isPrivateChannel
            ? "gh api 'repos/\(UpdateChannel.privateRepository)/contents/scripts/install-private.sh?ref=\(tag)' -H 'Accept: application/vnd.github.raw+json' | TATWO_OS_VERSION='\(tag)' bash"
            : "curl -fsSL https://raw.githubusercontent.com/\(repository)/\(tag)/install.sh | TATWO_OS_VERSION='\(tag)' bash"
    }
    @Published private(set) var availableRelease: Release?
    @Published private(set) var isChecking = false
    @Published private(set) var status = ""
    @Published private(set) var isPrivateChannel = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var dismissed = false
    private var schedule: Task<Void, Never>?
    private let defaults: UserDefaults
    let session: URLSession
    var repository: String {
        if UpdateChannel.current().isPrivate { return UpdateChannel.privateRepository }
        return (defaults.string(forKey: "tatwo2.feedback.repository") ?? Self.defaultRepository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private let installedVersion: String

    init(defaults: UserDefaults = .standard, session: URLSession? = nil,
         installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
        self.defaults = defaults
        // Isolated public requests: no stored cookies, credentials, or Authorization.
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: UpdateRedirectDelegate.shared, delegateQueue: nil)
        self.installedVersion = installedVersion
    }

    func start() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                while !Task.isCancelled {
                    await self?.check()
                    try await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000)
                }
            } catch { /* cancellation on app termination */ }
        }
    }

    func stop() { schedule?.cancel(); schedule = nil }
    func dismissForLaunch() { dismissed = true }
    func checkForUpdatesFromUser() { Task { await check() } }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer {
            lastCheckedAt = Date(); isChecking = false
            if availableRelease?.assets?.contains(where: { $0.name == "TATWO-OS.install-ready" }) != true {
                InAppUpdater.shared.invalidateCandidate()
            }
        }
        let channel = UpdateChannel.current()
        if isPrivateChannel != channel.isPrivate { availableRelease = nil }
        isPrivateChannel = channel.isPrivate
        defer { if channel.requestedPrivate && !channel.isPrivate { status = "私人通道需要 GitHub 登入" } }
        let repository = self.repository
        guard repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
        else { availableRelease = nil; status = "更新倉庫設定無效"; return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TATWO-OS-UpdateChecker", forHTTPHeaderField: "User-Agent")
        channel.authorize(&request)
        do {
            let (data, response) = try await session.data(for: request, delegate: UpdateRedirectDelegate.shared)
            guard let response = response as? HTTPURLResponse else {
                status = "更新檢查失敗：無效回應"; return
            }
            guard response.statusCode != 404 else {
                availableRelease = nil; status = "尚無可用版本"; return
            }
            guard response.statusCode == 200 else {
                status = "更新檢查失敗（HTTP \(response.statusCode)），請稍後重試"; return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard ReleaseVersionCompare.isValid(installedVersion),
                  ReleaseVersionCompare.isValid(release.tag_name) else {
                availableRelease = nil
                status = "無法比較版本：App 版本或 Release tag 格式無效"; return
            }
            if !release.draft && !release.prerelease
                && ReleaseVersionCompare.isNewer(release.tag_name, than: installedVersion) {
                availableRelease = release
                status = "有新版"
                if release.assets?.contains(where: { $0.name == "TATWO-OS.install-ready" }) == true {
                    InAppUpdater.shared.prefetch(to: release.tag_name, repository: repository)
                }
            } else {
                availableRelease = nil
                status = "目前沒有較新的正式版本"
            }
        } catch {
            status = "更新檢查失敗，請確認網路後重試"
        }
    }
}
