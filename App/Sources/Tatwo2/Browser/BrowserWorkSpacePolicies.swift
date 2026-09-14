import Foundation

// `BrowserSearchEngine` lives in BrowserGeneralSettings.swift (W52). W47 callers use `searchURL`.
extension BrowserSearchEngine {
    func searchURL(_ query: String) -> URL { queryURL(query) }
}

struct BrowserSettings: Codable, Equatable {
    var searchEngine: BrowserSearchEngine = .google
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TATWO OS/Browser/settings.json")

    static func load(from url: URL = defaultURL) -> Self {
        (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url))) ?? Self()
    }

    func save(to url: URL = defaultURL) throws {
        // Preserve fields owned by later settings work; never overwrite malformed JSON.
        var fields: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            fields = existing
        }
        fields["searchEngine"] = searchEngine.rawValue
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

enum BrowserOmniboxResolver {
    static func resolve(_ input: String, engine: BrowserSearchEngine = .google) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains(where: \.isWhitespace) {
            let authority = String(text.split(separator: "/", maxSplits: 1).first ?? "")
            let host = String(authority.split(separator: ":", maxSplits: 1).first ?? "")
            if host == "localhost" || authority.hasPrefix("[::1]") {
                return URL(string: "http://" + text)
            }
            if let url = URL(string: text), let scheme = url.scheme {
                // host.tld:port is not a custom scheme.
                if !scheme.contains(".") { return url }
            }
            if host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") {
                return URL(string: "https://" + text)
            }
        }
        return engine.searchURL(text)
    }
}

enum BrowserTabSleepPolicy {
    static var idleInterval: TimeInterval { BrowserMemorySettings.load().idleInterval() }
    static func shouldSleep(lastActiveAt: Date, now: Date, isSelected: Bool,
                            interval: TimeInterval = idleInterval) -> Bool {
        !isSelected && interval.isFinite && now.timeIntervalSince(lastActiveAt) >= interval
    }
}
