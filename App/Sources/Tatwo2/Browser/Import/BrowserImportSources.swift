import Foundation

enum ImportData: String, CaseIterable, Identifiable, Codable, Sendable {
    case bookmarks, passwords, history, extensions, pinned
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bookmarks: "書籤"
        case .passwords: "密碼"
        case .history: "瀏覽紀錄"
        case .extensions: "擴充功能"
        case .pinned: "釘選分頁"
        }
    }
    var symbol: String {
        switch self {
        case .bookmarks: "bookmark"
        case .passwords: "key"
        case .history: "clock"
        case .extensions: "puzzlepiece.extension"
        case .pinned: "pin"
        }
    }
}

enum BrowserImportSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case arc = "Arc", chrome = "Chrome", brave = "Brave", edge = "Edge"
    case opera = "Opera", vivaldi = "Vivaldi", safari = "Safari", firefox = "Firefox"
    var id: String { rawValue }
    var relativeDirectory: String {
        switch self {
        case .arc: "Library/Application Support/Arc/User Data"
        case .chrome: "Library/Application Support/Google/Chrome"
        case .brave: "Library/Application Support/BraveSoftware/Brave-Browser"
        case .edge: "Library/Application Support/Microsoft Edge"
        case .opera: "Library/Application Support/com.operasoftware.Opera"
        case .vivaldi: "Library/Application Support/Vivaldi"
        case .safari: "Library/Safari"
        case .firefox: "Library/Application Support/Firefox"
        }
    }
    var availableData: Set<ImportData> {
        switch self {
        case .arc: [.bookmarks, .passwords, .history]
        case .safari: [.bookmarks]
        case .firefox: []
        default: Set(ImportData.allCases)
        }
    }
    var symbol: String {
        switch self {
        case .arc: "a.circle"
        case .chrome: "circle.circle"
        case .brave: "shield"
        case .edge: "e.circle"
        case .opera: "o.circle"
        case .vivaldi: "v.circle"
        case .safari: "safari"
        case .firefox: "flame"
        }
    }
    var explanation: String {
        switch self {
        case .arc:
            "從 Arc 只能拿到書籤、密碼、瀏覽紀錄；Arc 的 Spaces、釘選分頁、Easels、Boosts 不會過來。"
        case .safari:
            "Safari 僅導入書籤。讀取需要「完整磁碟取用權」；允許 TATWO OS 後再試一次。"
        case .firefox: "Firefox 不支援。"
        default: "書籤保留資料夾路徑；瀏覽紀錄限最近 90 天、最多 5,000 筆。密碼經 macOS 授權直接導入，CSV 可作備援。"
        }
    }

    var safeStorageName: String? {
        switch self {
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .arc: "Arc"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .safari, .firefox: nil
        }
    }
}

struct BrowserImportProfile: Identifiable, Equatable, Sendable {
    let directory: URL
    let name: String
    // Bound by discovery, never inferred from a user-controlled folder name.
    var source: BrowserImportSource? = nil
    var id: String { directory.path }
}

struct BrowserImportSourceInfo: Identifiable, Sendable {
    let source: BrowserImportSource
    let isInstalled: Bool
    let profiles: [BrowserImportProfile]
    var id: BrowserImportSource { source }
    var availableData: Set<ImportData> { source.availableData }
    // TCC can hide even the Safari directory; keep its permission guidance reachable.
    var canSelect: Bool { source != .firefox && (source == .safari || (isInstalled && !profiles.isEmpty)) }
}

enum BrowserImportSources {
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Called off the UI actor. Does not inspect Keychain, Login Data or browser processes.
    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BrowserImportSourceInfo] {
        let fm = FileManager.default
        return BrowserImportSource.allCases.map { source in
            let root = home.appendingPathComponent(source.relativeDirectory, isDirectory: true)
            var isDirectory: ObjCBool = false
            let installed = fm.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
            if source == .safari {
                return BrowserImportSourceInfo(source: source, isInstalled: installed,
                    profiles: [BrowserImportProfile(directory: root, name: "Safari", source: source)])
            }
            guard installed, source != .firefox else {
                return BrowserImportSourceInfo(source: source, isInstalled: installed, profiles: [])
            }
            let localState = try? BrowserImportSnapshot.read(root.appendingPathComponent("Local State"))
            let state = localState.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let cache = (state?["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] ?? [:]
            let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            var profiles = children.filter { url in
                let name = url.lastPathComponent
                let profileName = name == "Default" || (name.hasPrefix("Profile ")
                    && !name.dropFirst("Profile ".count).isEmpty
                    && name.dropFirst("Profile ".count).allSatisfy(\.isNumber))
                return profileName && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && url.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath()
            }.sorted {
                if $0.lastPathComponent == "Default" { return true }
                if $1.lastPathComponent == "Default" { return false }
                return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }.map { url in
                BrowserImportProfile(directory: url, name: cache[url.lastPathComponent]?["name"] as? String ?? url.lastPathComponent,
                                     source: source)
            }
            // Opera commonly stores the profile directly at its application-support root.
            if source == .opera && ["Bookmarks", "Preferences", "History"].contains(where: {
                fm.fileExists(atPath: root.appendingPathComponent($0).path)
            }) {
                profiles.insert(BrowserImportProfile(directory: root, name: "Default", source: source), at: 0)
            }
            return BrowserImportSourceInfo(source: source, isInstalled: installed, profiles: profiles)
        }
    }
}
