import Foundation

// MARK: - W57a
// Command-9 selects the last tab; out-of-range digits do not wrap.
enum BrowserDailyNavigation {
    static func tabIndex(number: Int, count: Int) -> Int? {
        guard (1...9).contains(number), count > 0 else { return nil }
        return number == 9 ? count - 1 : (number <= count ? number - 1 : nil)
    }
    static func zoom(_ level: Double, delta: Double) -> Double {
        guard level.isFinite, delta.isFinite else { return 0 }
        return min(5, max(-5, level + delta))
    }
}
