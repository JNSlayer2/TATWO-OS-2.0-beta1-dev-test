import Foundation
import CoreFoundation

/// Shares settings.json by merge-writing only the edited key. Other editors
/// (including stale general-settings snapshots) retain these fields.
struct BrowserMemorySettings: Equatable, Sendable {
    // -1 = automatic; 0 = unlimited / never. Positive values are explicit.
    var liveTabLimit = -1
    var sleepMinutes = -1
    static let limitOptions = [-1, 2, 4, 6, 8, 0]
    static let sleepOptions = [-1, 1, 3, 5, 10, 20, 0]
    static let changed = Notification.Name("tatwo.browser.memorySettingsChanged")
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TATWO OS/Browser/settings.json")

    func limit(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int? {
        if liveTabLimit == 0 { return nil }
        return Self.limitOptions.contains(liveTabLimit) && liveTabLimit > 0
            ? liveTabLimit : BrowserMemoryPolicy.defaultLimit(physicalMemory: physicalMemory)
    }

    func idleInterval(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
        // Existing opt-in performance fixture override; never accepts NaN/Inf.
        if let value = environment["TATWO_BROWSER_SLEEP_SECONDS"],
           let seconds = Double(value), seconds.isFinite, seconds > 0 { return seconds }
        if sleepMinutes == 0 { return .infinity }
        if Self.sleepOptions.contains(sleepMinutes), sleepMinutes > 0 { return Double(sleepMinutes * 60) }
        return BrowserMemoryPolicy.defaultSleepSeconds(physicalMemory: physicalMemory)
    }

    static func load(from url: URL = fileURL) -> Self {
        guard let data = try? Data(contentsOf: url),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Self() }
        var result = Self()
        func integer(_ key: String) -> Int? {
            guard let number = fields[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = fields[key] as? Int else { return nil }
            return value
        }
        if let value = integer("liveTabLimit"), limitOptions.contains(value) { result.liveTabLimit = value }
        if let value = integer("sleepMinutes"), sleepOptions.contains(value) { result.sleepMinutes = value }
        return result
    }

    enum Field: String { case liveTabLimit, sleepMinutes }
    enum SettingsError: Error { case invalidOption }

    static func save(_ field: Field, value: Int, to url: URL = fileURL) throws {
        let options = field == .liveTabLimit ? limitOptions : sleepOptions
        guard options.contains(value) else { throw SettingsError.invalidOption }
        var fields: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            // Corruption is not an empty file; never destroy unrelated settings.
            guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            fields = existing
        }
        fields[field.rawValue] = value
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .prettyPrinted])
            .write(to: url, options: .atomic)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
