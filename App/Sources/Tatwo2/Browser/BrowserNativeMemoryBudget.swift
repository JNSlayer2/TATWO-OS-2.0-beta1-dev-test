import Foundation

/// A root-tab slot stays occupied through CloseBrowser -> OnBeforeClose.
/// Never recycle a slot on a timeout or just because a registry row is asleep.
/// CEF-owned AI login popups and cross-site subframe processes are not root tabs.
@MainActor
final class BrowserNativeMemoryBudget {
    static let shared = BrowserNativeMemoryBudget()
    private(set) var limit: Int? = BrowserMemorySettings.load().limit()
    private var slots: Set<UUID> = []
    private var waiters: [ObjectIdentifier: () -> Void] = [:]
    private var wakeScheduled = false
    var count: Int { slots.count }

    func configure(limit: Int?) {
        self.limit = limit
        wakeWaiters()
    }

    func acquire(owner: AnyObject, retry: @escaping () -> Void) -> UUID? {
        let key = ObjectIdentifier(owner)
        guard limit.map({ slots.count < $0 }) ?? true else {
            waiters[key] = retry // Caller captures its host weakly.
            return nil
        }
        waiters.removeValue(forKey: key)
        let slot = UUID()
        slots.insert(slot)
        return slot
    }

    func cancelWait(owner: AnyObject) { waiters.removeValue(forKey: ObjectIdentifier(owner)) }

    func release(_ slot: UUID) {
        guard slots.remove(slot) != nil else { return }
        wakeWaiters()
    }

    private func wakeWaiters() {
        guard !wakeScheduled, !waiters.isEmpty else { return }
        wakeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.wakeScheduled = false
            let callbacks = Array(self.waiters.values)
            self.waiters.removeAll()
            for callback in callbacks { callback() }
        }
    }
}
