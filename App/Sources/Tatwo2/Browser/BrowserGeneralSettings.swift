import Foundation

enum BrowserSearchEngine: String, Codable, CaseIterable, Sendable {
    case google, duckduckgo, bing

    var title: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        }
    }

    func queryURL(_ query: String) -> URL {
        let base: String
        switch self {
        case .google: base = "https://www.google.com/search"
        case .duckduckgo: base = "https://duckduckgo.com/"
        case .bing: base = "https://www.bing.com/search"
        }
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // Search providers decode queries as form data, where a literal + means space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

struct BrowserGeneralSettings: Codable, Equatable, Sendable {
    enum SessionRetention: String, Codable, CaseIterable, Sendable {
        case keep, closeWithChat
    }
    var shortcuts: BrowserShortcutMap = .defaults {
        didSet { shortcutsEdited = true }
    }
    private var shortcutsEdited = false
    var zoomByHost: [String: Double] = [:]
    var defaultSpaceID: UUID? = nil
    var lastSelectedTabID: UUID? = nil
    var searchEngine: BrowserSearchEngine = .google
    // Stored only; W53 applies this when a chat closes.
    var sessionRetention: SessionRetention = .keep
    var passwordAssist = true {
        didSet { passwordAssistEdited = true }
    }
    private var passwordAssistEdited = false
    var passwordFillRequiresAuth: Bool = true {
        didSet { passwordFillRequiresAuthEdited = true }
    }
    private var passwordFillRequiresAuthEdited = false
    static let passwordAssistChanged = Notification.Name("tatwo.browser.passwordAssistChanged")

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TATWO OS/Browser/settings.json")
    }
    private enum CodingKeys: String, CodingKey { case shortcuts, defaultSpaceID, lastSelectedTabID, searchEngine, sessionRetention, zoomByHost, passwordAssist, passwordFillRequiresAuth }
    init() {}
    init(defaultSpaceID: UUID? = nil, searchEngine: BrowserSearchEngine = .google, sessionRetention: SessionRetention = .keep,
         passwordAssist: Bool = true, lastSelectedTabID: UUID? = nil) {
        self.defaultSpaceID = defaultSpaceID
        self.lastSelectedTabID = lastSelectedTabID
        self.searchEngine = searchEngine
        self.sessionRetention = sessionRetention
        self.passwordAssist = passwordAssist
        passwordAssistEdited = !passwordAssist
    }
    /// Tolerant decode: settings.json is shared with W47's `BrowserSettings` (searchEngine only),
    /// so a missing key must not throw the whole file back to defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcuts = ((try? container.decodeIfPresent(BrowserShortcutMap.self, forKey: .shortcuts)) ?? .defaults).upgradedFromLegacy
        shortcutsEdited = false
        zoomByHost = try container.decodeIfPresent([String: Double].self, forKey: .zoomByHost) ?? [:]
        defaultSpaceID = try container.decodeIfPresent(UUID.self, forKey: .defaultSpaceID)
        lastSelectedTabID = try container.decodeIfPresent(UUID.self, forKey: .lastSelectedTabID)
        searchEngine = try container.decodeIfPresent(BrowserSearchEngine.self, forKey: .searchEngine) ?? .google
        sessionRetention = try container.decodeIfPresent(SessionRetention.self, forKey: .sessionRetention) ?? .keep
        passwordAssist = try container.decodeIfPresent(Bool.self, forKey: .passwordAssist) ?? true
        passwordAssistEdited = false
        passwordFillRequiresAuth = (try? container.decodeIfPresent(Bool.self, forKey: .passwordFillRequiresAuth)) ?? true
        passwordFillRequiresAuthEdited = false
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.defaultSpaceID == rhs.defaultSpaceID && lhs.lastSelectedTabID == rhs.lastSelectedTabID
            && lhs.searchEngine == rhs.searchEngine && lhs.sessionRetention == rhs.sessionRetention
            && lhs.shortcuts == rhs.shortcuts && lhs.zoomByHost == rhs.zoomByHost && lhs.passwordAssist == rhs.passwordAssist
            && lhs.passwordFillRequiresAuth == rhs.passwordFillRequiresAuth
    }
    static func load(from url: URL = fileURL) -> Self {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }
    /// Merge-save: only this struct's keys are rewritten; keys owned by other writers survive.
    func save(to url: URL = Self.fileURL) throws {
        var fields: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           !data.isEmpty, !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Empty files are treated as fresh; non-empty but malformed files are never overwritten.
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            fields = existing
        }
        if shortcutsEdited || fields["shortcuts"] == nil {
            fields["shortcuts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shortcuts))
        }
        fields["zoomByHost"] = zoomByHost.filter { $0.value.isFinite }.mapValues { min(5, max(-5, $0)) }
        fields["defaultSpaceID"] = defaultSpaceID?.uuidString ?? NSNull()
        fields["lastSelectedTabID"] = lastSelectedTabID?.uuidString ?? NSNull()
        fields["searchEngine"] = searchEngine.rawValue
        fields["sessionRetention"] = sessionRetention.rawValue
        // A stale general-settings editor must not re-enable password assistance.
        if passwordAssistEdited || fields["passwordAssist"] == nil { fields["passwordAssist"] = passwordAssist }
        if passwordFillRequiresAuthEdited || fields["passwordFillRequiresAuth"] == nil {
            fields["passwordFillRequiresAuth"] = passwordFillRequiresAuth
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        if shortcutsEdited { NotificationCenter.default.post(name: BrowserShortcutMap.changed, object: nil) }
        if passwordAssistEdited || passwordFillRequiresAuthEdited {
            NotificationCenter.default.post(name: Self.passwordAssistChanged, object: nil)
        }
    }

    static func saveShortcuts(_ map: BrowserShortcutMap, to url: URL = fileURL) throws {
        var fields: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.coderReadCorrupt)
                }
                fields = existing
            }
        }
        fields["shortcuts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(map))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
        NotificationCenter.default.post(name: BrowserShortcutMap.changed, object: nil)
    }

    /// This single-key writer preserves concurrent settings-page ownership.
    static func savePasswordAssist(_ enabled: Bool, to url: URL = fileURL) throws {
        try savePasswordFlag("passwordAssist", enabled: enabled, to: url)
    }

    static func savePasswordFillRequiresAuth(_ enabled: Bool, to url: URL = fileURL) throws {
        try savePasswordFlag("passwordFillRequiresAuth", enabled: enabled, to: url)
    }

    private static func savePasswordFlag(_ key: String, enabled: Bool, to url: URL) throws {
        var fields: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.coderReadCorrupt)
                }
                fields = existing
            }
        }
        fields[key] = enabled
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
        NotificationCenter.default.post(name: passwordAssistChanged, object: nil)
    }
}

/// Decode only explicit version metadata; runtime hashes are not version numbers.
struct BrowserRuntimeVersion: Decodable {
    var cefVersion: String
    var chromiumVersion: String

    // Bundle metadata cannot change during this process; avoid reads on each UI update.
    static let bundledDescription = load(from: [
        Bundle.main.url(forResource: "cef-runtime-arm64", withExtension: "json"),
        Bundle.main.url(forResource: "runtime-layer", withExtension: "json")
    ].compactMap { $0 })

    static func load(from urls: [URL]) -> String {
        for url in urls {
            if let data = try? Data(contentsOf: url),
               let version = try? JSONDecoder().decode(Self.self, from: data),
               !version.cefVersion.isEmpty, !version.chromiumVersion.isEmpty {
                let cef = version.cefVersion.split(separator: "+").first.map(String.init) ?? version.cefVersion
                return "CEF \(cef) / Chromium \(version.chromiumVersion)"
            }
        }
        return "未知"
    }
}
