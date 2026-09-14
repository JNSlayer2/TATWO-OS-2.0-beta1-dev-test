import Foundation

struct BrowserDiagnosticsSettings: Equatable, Sendable {
    var memoryWarningMB: Double = 1200
}

struct BrowserMemoryWarningThrottle: Sendable {
    static let interval: TimeInterval = 30 * 60
    private(set) var lastWarningUptime: TimeInterval?

    /// Shared for the lifetime of the App, including sheet close/reopen.
    /// Sustained pressure can remind again only after thirty minutes.
    mutating func shouldWarn(helperMB: Double, thresholdMB: Double, uptime: TimeInterval) -> Bool {
        guard helperMB.isFinite, thresholdMB.isFinite, thresholdMB > 0,
              helperMB > thresholdMB, uptime.isFinite else { return false }
        if let lastWarningUptime, uptime - lastWarningUptime < Self.interval { return false }
        lastWarningUptime = uptime
        return true
    }
}
