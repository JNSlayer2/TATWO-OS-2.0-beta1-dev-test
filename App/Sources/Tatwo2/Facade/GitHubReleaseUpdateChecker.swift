import Foundation
import Combine

/// SemVer precedence; accepts Apple's two-component bundle versions as x.y.0.
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
            guard (2...3).contains(numbers.count),
                  numbers.allSatisfy({ ReleaseVersionCompare.numeric($0) && ($0 == "0" || !$0.hasPrefix("0")) })
            else { return nil }
            core = numbers.count == 2 ? numbers + ["0"] : numbers
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

@MainActor
final class GitHubReleaseUpdateChecker: ObservableObject {
    struct Release: Decodable, Equatable {
        let tag_name: String
        let name: String?
        let draft: Bool
        let prerelease: Bool
    }

    static let shared = GitHubReleaseUpdateChecker()
    static let defaultRepository = "tatwo214/TATWO-OS-2.0-beta1-dev-test"
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/tatwo214/TATWO-OS-2.0-beta1-dev-test/main/install.sh | bash"
    @Published private(set) var availableRelease: Release?
    @Published private(set) var isChecking = false
    @Published private(set) var status = ""
    @Published private(set) var dismissed = false
    private var schedule: Task<Void, Never>?
    private let defaults: UserDefaults
    private let session: URLSession
    private let installedVersion: String

    init(defaults: UserDefaults = .standard, session: URLSession? = nil,
         installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
        self.defaults = defaults
        // Isolated public requests: no stored cookies, credentials, or Authorization.
        self.session = session ?? URLSession(configuration: .ephemeral)
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
        defer { isChecking = false }
        let repository = (defaults.string(forKey: "tatwo2.feedback.repository") ?? Self.defaultRepository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
        else { availableRelease = nil; status = "更新倉庫設定無效"; return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TATWO-OS-UpdateChecker", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
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
            } else {
                availableRelease = nil
                status = "目前沒有較新的正式版本"
            }
        } catch {
            status = "更新檢查失敗，請確認網路後重試"
        }
    }
}
