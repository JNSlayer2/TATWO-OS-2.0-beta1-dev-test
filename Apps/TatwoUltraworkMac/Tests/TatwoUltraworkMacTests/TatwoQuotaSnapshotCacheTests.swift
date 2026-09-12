import Foundation
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class TatwoQuotaSnapshotCacheTests: XCTestCase {
    func testSuccessfulSnapshotHitsTTLWithoutCallingUpstream()
        async
    {
        let clock = TestQuotaClock()
        let loader = FakeQuotaProviderLoader(
            results: [.success(row(percent: 72))])
        let cache = TatwoQuotaSnapshotCache(
            loader: loader,
            now: { clock.now() })

        _ = await cache.load(providers: [provider()])
        clock.advance(by: 239)
        let cached = await cache.load(providers: [provider()])

        let callCount = await loader.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(
            cached.rows["claude"]?.remainingPercent,
            72)
    }

    func testExpiredConcurrentRequestsUseOneUpstreamFlight()
        async
    {
        let clock = TestQuotaClock()
        let loader = FakeQuotaProviderLoader(
            results: [
                .success(row(percent: 68)),
                .success(row(percent: 64)),
            ],
            delayNanoseconds: 80_000_000)
        let cache = TatwoQuotaSnapshotCache(
            loader: loader,
            now: { clock.now() })
        let provider = provider()

        _ = await cache.load(providers: [provider])
        clock.advance(by: 241)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = await cache.load(
                        providers: [provider])
                }
            }
        }

        let callCount = await loader.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testRateLimitKeepsLastSuccessAddsCaptionAndBacksOff()
        async
    {
        let clock = TestQuotaClock()
        let loader = FakeQuotaProviderLoader(
            results: [
                .success(row(percent: 81)),
                .rateLimited(row(percent: nil)),
                .success(row(percent: 76)),
            ])
        let cache = TatwoQuotaSnapshotCache(
            loader: loader,
            now: { clock.now() })

        _ = await cache.load(providers: [provider()])
        clock.advance(by: 241)
        let limited = await cache.load(
            providers: [provider()])
        clock.advance(by: 120)
        let automaticDuringBackoff = await cache.load(
            providers: [provider()])
        let manualDuringBackoff = await cache.load(
            providers: [provider()],
            refreshKind: .manual,
            allowExternalAccess: true)

        let backedOffCallCount = await loader.callCount
        XCTAssertEqual(backedOffCallCount, 2)
        for snapshot in [
            limited,
            automaticDuringBackoff,
            manualDuringBackoff,
        ] {
            XCTAssertEqual(
                snapshot.rows["claude"]?.remainingPercent,
                81)
            XCTAssertTrue(
                snapshot.rows["claude"]?.caption.contains(
                    "稍後刷新（服務回應 HTTP 429）")
                    == true)
        }

        clock.advance(by: 481)
        let recovered = await cache.load(
            providers: [provider()])

        let recoveredCallCount = await loader.callCount
        XCTAssertEqual(recoveredCallCount, 3)
        XCTAssertEqual(
            recovered.rows["claude"]?.remainingPercent,
            76)
    }

    func testManualRefreshBypassesTTLButDeduplicatesForThirtySeconds()
        async
    {
        let clock = TestQuotaClock()
        let loader = FakeQuotaProviderLoader(
            results: [
                .success(row(percent: 90)),
                .success(row(percent: 80)),
                .success(row(percent: 70)),
            ])
        let cache = TatwoQuotaSnapshotCache(
            loader: loader,
            now: { clock.now() })

        _ = await cache.load(providers: [provider()])
        let manual = await cache.load(
            providers: [provider()],
            refreshKind: .manual,
            allowExternalAccess: true)
        clock.advance(by: 29)
        let deduplicated = await cache.load(
            providers: [provider()],
            refreshKind: .manual,
            allowExternalAccess: true)

        let deduplicatedCallCount = await loader.callCount
        XCTAssertEqual(deduplicatedCallCount, 2)
        XCTAssertEqual(
            manual.rows["claude"]?.remainingPercent,
            80)
        XCTAssertEqual(
            deduplicated.rows["claude"]?.remainingPercent,
            80)

        clock.advance(by: 2)
        let refreshed = await cache.load(
            providers: [provider()],
            refreshKind: .manual,
            allowExternalAccess: true)

        let refreshedCallCount = await loader.callCount
        XCTAssertEqual(refreshedCallCount, 3)
        XCTAssertEqual(
            refreshed.rows["claude"]?.remainingPercent,
            70)
    }

    func testLocalUsageProvidersUseSixtySecondTTL()
        async
    {
        let clock = TestQuotaClock()
        let loader = FakeQuotaProviderLoader(
            results: [
                .success(row(
                    providerID: "grok",
                    percent: nil)),
                .success(row(
                    providerID: "grok",
                    percent: nil)),
            ])
        let cache = TatwoQuotaSnapshotCache(
            loader: loader,
            now: { clock.now() })
        let grok = provider(id: "grok")

        _ = await cache.load(providers: [grok])
        clock.advance(by: 60)
        _ = await cache.load(providers: [grok])
        let cachedCallCount = await loader.callCount
        XCTAssertEqual(cachedCallCount, 1)

        clock.advance(by: 1)
        _ = await cache.load(providers: [grok])
        let refreshedCallCount = await loader.callCount
        XCTAssertEqual(refreshedCallCount, 2)
    }

    private func provider(
        id: String = "claude"
    ) -> UsageProviderStatus {
        UsageProviderStatus(
            id: id,
            displayName: id == "grok" ? "Grok" : "Claude",
            status: .installed,
            cachePolicy: "test",
            liveRefreshPolicy: "test",
            quotaLabel: "test")
    }

    private func row(
        providerID: String = "claude",
        percent: Int?
    ) -> LiveQuotaDisplay {
        LiveQuotaDisplay(
            id: providerID,
            displayName:
                providerID == "grok" ? "Grok" : "Claude",
            planLabel:
                providerID == "grok" ? "GROK" : "MAX",
            status: .installed,
            statusText: percent == nil ? "授權OK" : "live",
            caption: percent == nil
                ? "服務回應 HTTP 429"
                : "5小時 / 7天 live 用量",
            permissionLabel: "Claude · MAX",
            sourceBadge: percent == nil
                ? "無 live"
                : "Claude live",
            remainingPercent: percent,
            primaryRemainingPercent: percent,
            secondaryRemainingPercent: percent,
            primaryResetAt: nil,
            secondaryResetAt: nil,
            resetCreditsAvailable: nil,
            resetCreditsExpiresAt: nil,
            resetCreditExpiryDates: [])
    }
}

private actor FakeQuotaProviderLoader:
    TatwoQuotaProviderLoading
{
    private var results: [TatwoQuotaProviderLoadResult]
    private let delayNanoseconds: UInt64
    private(set) var callCount = 0

    init(
        results: [TatwoQuotaProviderLoadResult],
        delayNanoseconds: UInt64 = 0
    ) {
        self.results = results
        self.delayNanoseconds = delayNanoseconds
    }

    func load(
        provider _: UsageProviderStatus,
        allowExternalAccess _: Bool
    ) async -> TatwoQuotaProviderLoadResult {
        callCount += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(
                nanoseconds: delayNanoseconds)
        }
        if results.count > 1 {
            return results.removeFirst()
        }
        return results[0]
    }
}

private extension TatwoQuotaProviderLoadResult {
    static func success(
        _ row: LiveQuotaDisplay
    ) -> TatwoQuotaProviderLoadResult {
        TatwoQuotaProviderLoadResult(
            row: row,
            isSuccessful: true,
            isRateLimited: false)
    }

    static func rateLimited(
        _ row: LiveQuotaDisplay
    ) -> TatwoQuotaProviderLoadResult {
        TatwoQuotaProviderLoadResult(
            row: row,
            isSuccessful: false,
            isRateLimited: true)
    }
}

private final class TestQuotaClock:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var date = Date(
        timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(interval)
        lock.unlock()
    }
}
