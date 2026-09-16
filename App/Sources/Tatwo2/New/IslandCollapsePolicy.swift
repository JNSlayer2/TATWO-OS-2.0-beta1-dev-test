import Foundation

/// Island 收合決策；時間由呼叫端注入，不讀時鐘、不啟動計時器。
struct IslandCollapsePolicy {
    static let delay: TimeInterval = 0

    enum Event {
        case hoverEntered
        case hoverExited(at: TimeInterval)
        case itemTapped
        case outsideTapped
        case escape
        case tick(now: TimeInterval)
    }

    private var exitedAt: TimeInterval?

    func remainingDelay(at now: TimeInterval) -> TimeInterval? {
        exitedAt.map { max(0, Self.delay - (now - $0)) }
    }

    @discardableResult
    mutating func handle(_ event: Event) -> Bool {
        switch event {
        case .hoverEntered:
            exitedAt = nil
        case .hoverExited(let time):
            if exitedAt == nil { exitedAt = time }
        case .itemTapped:
            break // Only consent/notice holdOpen may keep the Island open.
        case .outsideTapped, .escape:
            self = Self()
            return true
        case .tick(let now):
            guard let exitedAt, now - exitedAt >= Self.delay else { return false }
            self = Self()
            return true
        }
        return false
    }
}
