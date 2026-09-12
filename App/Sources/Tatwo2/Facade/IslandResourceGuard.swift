import Foundation
import Darwin

@MainActor final class IslandResourceGuard {
    private var polling: Task<Void, Never>?
    private let sample: @Sendable () -> UInt64?
    private let interval: UInt64
    init(interval: TimeInterval = 10, sample: @escaping @Sendable () -> UInt64? = { IslandResourceGuard.residentBytes() }) {
        self.sample = sample; self.interval = UInt64(max(0.01, interval) * 1_000_000_000)
    }
    nonisolated static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
    func start(onReady: @escaping @MainActor () -> Void = {}, onLimit: @escaping @MainActor () -> Void) {
        guard polling == nil else { return }
        polling = Task { [sample, interval] in
            let baseline = await Task.detached(priority: .utility, operation: sample).value
            guard !Task.isCancelled else { return }
            onReady() // Baseline is captured before WKWebView is allocated.
            guard let baseline else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                let current = await Task.detached(priority: .utility, operation: sample).value
                guard !Task.isCancelled else { return }
                if let current, current > baseline, current - baseline > 300 * 1024 * 1024 { onLimit() }
            }
        }
    }
    func stop() { polling?.cancel(); polling = nil }
    deinit { polling?.cancel() }
}
