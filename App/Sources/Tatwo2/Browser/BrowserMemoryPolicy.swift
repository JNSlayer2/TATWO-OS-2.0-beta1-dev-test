import Foundation

enum BrowserMemoryPressure: String, Sendable {
    case normal, warning, critical

    var title: String {
        switch self {
        case .normal: "正常"
        case .warning: "警告"
        case .critical: "嚴重"
        }
    }
}

/// A browser budget, not a promise about Chromium's OS process count:
/// site isolation can require additional renderer processes for one tab.
enum BrowserMemoryPolicy {
    struct Tab: Sendable {
        let id: UUID
        let lastActiveAt: Date
        let isSleeping: Bool
    }

    static func defaultLimit(physicalMemory: UInt64) -> Int {
        let gib: UInt64 = 1 << 30
        if physicalMemory <= 8 * gib { return 4 }
        if physicalMemory <= 16 * gib { return 6 }
        return 8
    }

    static func defaultSleepSeconds(physicalMemory: UInt64) -> TimeInterval {
        physicalMemory <= 8 * (1 << 30) ? 180 : 300
    }

    /// Stable tie-breaks make simultaneous opens deterministic. Every mounted
    /// surface's selected tab is protected, not just the last focused window.
    static func sleepCandidates(tabs: [Tab], selected: Set<UUID>, limit: Int?,
                                protected: Set<UUID> = [],
                                pressure: BrowserMemoryPressure = .normal) -> [UUID] {
        let awake = tabs.filter { !$0.isSleeping }
        let candidates = awake.filter { !selected.contains($0.id) && !protected.contains($0.id) }.sorted {
            $0.lastActiveAt == $1.lastActiveAt
                ? $0.id.uuidString < $1.id.uuidString : $0.lastActiveAt < $1.lastActiveAt
        }
        if pressure != .normal { return candidates.map(\.id) }
        guard let limit else { return [] }
        return candidates.prefix(max(0, awake.count - max(1, limit))).map(\.id)
    }
}
