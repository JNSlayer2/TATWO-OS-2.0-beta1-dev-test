import Foundation

struct BrowserHistoryEntry: Codable, Equatable, Sendable {
    let url: URL
    let title: String
    let lastVisitTime: Date
    let visitCount: Int
}

/// Shared with the future omnibox. Disk work is isolated from the UI actor.
/// Append/upsert only; repeated imports do not add visit counts a second time.
actor BrowserHistoryStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TATWO OS/Browser/history.json")
    static let shared = BrowserHistoryStore(storageURL: defaultURL)
    static let maximumEntries = 20_000
    let storageURL: URL
    private struct Document: Codable {
        var schemaVersion = 1
        var entries: [BrowserHistoryEntry]
    }
    struct AppendResult: Sendable {
        let added: Int
        let updated: Int
        let skipped: Int
        var stored: Int { added + updated }
    }

    init(storageURL: URL) { self.storageURL = storageURL }

    func entries() throws -> [BrowserHistoryEntry] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        let decoder = JSONDecoder()
        let data = try Data(contentsOf: storageURL)
        guard data.count <= BrowserImportSnapshot.maximumJSONBytes else { throw BrowserImportError.tooLarge }
        let document = try decoder.decode(Document.self, from: data)
        guard document.schemaVersion == 1 else { throw BrowserImportError.invalidData }
        return document.entries
    }

    /// Live visits increment once per committed navigation; imports retain their idempotent max-count merge.
    func recordVisit(url: URL, title: String, at date: Date = Date()) throws {
        let old = try entries().first { $0.url == url }
        _ = try append([BrowserHistoryEntry(url: url, title: title, lastVisitTime: date,
            visitCount: min(old?.visitCount ?? 0, Int.max - 1) + 1)])
    }

    static func suggestions(_ entries: [BrowserHistoryEntry], matching query: String) -> [BrowserHistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return Array(entries.filter {
            ($0.url.host ?? "").localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)
        }.sorted {
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            if $0.lastVisitTime != $1.lastVisitTime { return $0.lastVisitTime > $1.lastVisitTime }
            return $0.url.absoluteString < $1.url.absoluteString
        }.prefix(6))
    }

    func append(_ incoming: [BrowserHistoryEntry]) throws -> AppendResult {
        try Task.checkCancellation()
        // A corrupt/newer file is never replaced by an empty document.
        var byURL: [URL: BrowserHistoryEntry] = [:]
        for entry in try entries() {
            if let old = byURL[entry.url], old.lastVisitTime > entry.lastVisitTime { continue }
            byURL[entry.url] = entry
        }
        let originalURLs = Set(byURL.keys)
        var changed = Set<URL>()
        for entry in incoming {
            try Task.checkCancellation()
            guard ChromiumImporter.navigationURL(entry.url.absoluteString) != nil else { continue }
            if let old = byURL[entry.url] {
                guard entry.lastVisitTime > old.lastVisitTime || entry.visitCount > old.visitCount else { continue }
                byURL[entry.url] = BrowserHistoryEntry(url: entry.url,
                    title: entry.lastVisitTime >= old.lastVisitTime ? entry.title : old.title,
                    lastVisitTime: max(old.lastVisitTime, entry.lastVisitTime), visitCount: max(old.visitCount, entry.visitCount))
            } else { byURL[entry.url] = entry }
            changed.insert(entry.url)
        }
        let kept = Array(byURL.values.sorted {
            $0.lastVisitTime == $1.lastVisitTime ? $0.url.absoluteString < $1.url.absoluteString : $0.lastVisitTime > $1.lastVisitTime
        }.prefix(Self.maximumEntries))
        let retainedChanges = changed.intersection(Set(kept.map(\.url)))
        let added = retainedChanges.subtracting(originalURLs).count
        let updated = retainedChanges.intersection(originalURLs).count
        let encoder = JSONEncoder()
        // JSONEncoder's reference-date seconds round-trip subsecond visits. The
        // built-in ISO8601 strategy drops them, making identical reimports look newer.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(entries: kept))
        guard data.count <= BrowserImportSnapshot.maximumJSONBytes else { throw BrowserImportError.tooLarge }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        return AppendResult(added: added, updated: updated, skipped: incoming.count - added - updated)
    }
}
