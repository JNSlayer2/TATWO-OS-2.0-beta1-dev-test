import XCTest
@testable import TatwoUltraworkMac

final class ChatNativeSubscriptionTokenPreflightTests: XCTestCase {
    func testRefreshesWhenAccessTokenHasLessThanFiveMinutesRemaining() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let data = authJSON(
            lastRefresh: now.addingTimeInterval(-1_000),
            expiry: now.addingTimeInterval(299))
        let recorder = RefreshRecorder(result: true)

        let outcome = await ChatNativeSubscriptionTokenPreflight.runIfNeeded(
            authData: data,
            now: now,
            refresh: recorder.refresh)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(recorder.count, 1)
    }

    func testDoesNotRefreshWhenTokenHasFiveMinutesOrMoreRemaining() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let data = authJSON(
            lastRefresh: now.addingTimeInterval(-60),
            expiry: now.addingTimeInterval(300))
        let recorder = RefreshRecorder(result: true)

        let outcome = await ChatNativeSubscriptionTokenPreflight.runIfNeeded(
            authData: data,
            now: now,
            refresh: recorder.refresh)

        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertEqual(recorder.count, 0)
    }

    func testRefreshFailureIsWarningOnlyAndDoesNotThrow() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let data = authJSON(
            lastRefresh: now.addingTimeInterval(-1_000),
            expiry: now.addingTimeInterval(-1))
        let recorder = RefreshRecorder(result: false)

        let outcome = await ChatNativeSubscriptionTokenPreflight.runIfNeeded(
            authData: data,
            now: now,
            refresh: recorder.refresh)

        XCTAssertEqual(outcome, .warning)
        XCTAssertEqual(recorder.count, 1)
    }

    func testLastRefreshFallbackEstimatesOneHourExpiry() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let data = try! JSONSerialization.data(withJSONObject: [
            "last_refresh": ISO8601DateFormatter().string(
                from: now.addingTimeInterval(-(60 * 60 - 299))),
            "tokens": [:],
        ])
        let recorder = RefreshRecorder(result: true)

        let outcome = await ChatNativeSubscriptionTokenPreflight.runIfNeeded(
            authData: data,
            now: now,
            refresh: recorder.refresh)

        XCTAssertEqual(outcome, .refreshed)
    }

    private func authJSON(
        lastRefresh: Date,
        expiry: Date
    ) -> Data {
        let header = Data(#"{"alg":"none"}"#.utf8)
            .base64EncodedString()
        let payload = try! JSONSerialization.data(withJSONObject: [
            "exp": Int(expiry.timeIntervalSince1970),
        ]).base64EncodedString()
        let token = [header, payload, ""]
            .map {
                $0.replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            .joined(separator: ".")
        return try! JSONSerialization.data(withJSONObject: [
            "last_refresh": ISO8601DateFormatter().string(from: lastRefresh),
            "tokens": ["access_token": token],
        ])
    }
}

private final class RefreshRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private let result: Bool

    init(result: Bool) {
        self.result = result
    }

    // 主導驗收機械修正：async context 禁止裸 lock/unlock（Swift 6），
    // 改 withLock 同步作用域（sol 的 swiftc -parse 驗不到 concurrency 檢查）。
    func refresh() async -> Bool {
        lock.withLock { count += 1 }
        return result
    }
}
