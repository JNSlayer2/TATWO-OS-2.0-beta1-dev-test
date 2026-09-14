import Foundation

/// Written only by backend lease/initialize outcomes, never by diagnostics polling.
@MainActor
final class BrowserEngineStartupTelemetry {
    enum State: String { case notStarted = "未啟動", starting = "啟動中", ready = "就緒", failed = "失敗" }
    static let shared = BrowserEngineStartupTelemetry()
    private(set) var state: State = .notStarted
    private(set) var firstLeaseUptime: TimeInterval?
    private(set) var firstReadyUptime: TimeInterval?
    var startupMilliseconds: Double? {
        guard let firstLeaseUptime, let firstReadyUptime else { return nil }
        return max(0, (firstReadyUptime - firstLeaseUptime) * 1000)
    }
    func leaseAcquired(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if firstLeaseUptime == nil { firstLeaseUptime = uptime }
        if state != .ready { state = .starting }
    }
    func initialized(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if firstReadyUptime == nil { firstReadyUptime = uptime }
        state = .ready
    }
    func failed() { if state != .ready { state = .failed } }
}
