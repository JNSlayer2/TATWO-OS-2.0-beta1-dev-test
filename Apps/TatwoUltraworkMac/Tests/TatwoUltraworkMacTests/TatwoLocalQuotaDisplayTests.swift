import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class TatwoLocalQuotaDisplayTests: XCTestCase {
    func testGrokMapsLocalRequestsWithoutInventingTokens()
        async throws
    {
        let loaded = await TatwoLiveQuotaReader.loadGrok(
            provider: provider(
                id: "grok",
                displayName: "Grok"),
            snapshotReader: {
                TatwoLocalUsageSnapshot(
                    provider: "grok",
                    fiveHour: TatwoLocalUsageAggregate(
                        requestCount: 2,
                        inputTokens: nil,
                        outputTokens: nil),
                    sevenDay: TatwoLocalUsageAggregate(
                        requestCount: 5,
                        inputTokens: nil,
                        outputTokens: nil))
            })
        let row = try XCTUnwrap(loaded)

        XCTAssertEqual(row.sourceBadge, "本機計量")
        XCTAssertEqual(
            row.statusText,
            "5小時 2 次請求／7天 5 次請求")
        XCTAssertEqual(
            row.caption,
            "來源＝App 自身記錄；非 Grok 官方訂閱餘額。")
        XCTAssertEqual(
            compactWindowText(row),
            "5小時 2 次請求／7天 5 次請求")
        XCTAssertTrue(
            integrationGuideText("grok").contains(
                "App 自身的本機計量"))
        XCTAssertNil(row.remainingPercent)
    }

    func testMiniMaxMapsLocalRequestsAndRealTokenTotals()
        async throws
    {
        let loaded = await TatwoLiveQuotaReader.loadMiniMax(
            provider: provider(
                id: "minimax",
                displayName: "MiniMax"),
            snapshotReader: {
                TatwoLocalUsageSnapshot(
                    provider: "minimax",
                    fiveHour: TatwoLocalUsageAggregate(
                        requestCount: 3,
                        inputTokens: 120,
                        outputTokens: 30),
                    sevenDay: TatwoLocalUsageAggregate(
                        requestCount: 8,
                        inputTokens: 400,
                        outputTokens: 100))
            })
        let row = try XCTUnwrap(loaded)

        XCTAssertEqual(row.sourceBadge, "本機計量")
        XCTAssertEqual(
            row.statusText,
            "5小時 3 次請求（150 tokens）／7天 8 次請求（500 tokens）")
        XCTAssertTrue(
            row.caption.contains(
                "接 admin key 可顯示官方餘額"))
        XCTAssertEqual(compactWindowText(row), row.statusText)
        XCTAssertTrue(
            integrationGuideText("minimax").contains(
                "接 admin key 可顯示官方餘額"))
        XCTAssertNil(row.remainingPercent)
    }

    func testProvidersWithoutRecordsSayNoLocalUsage()
        async throws
    {
        let empty = TatwoLocalUsageSnapshot(
            provider: "empty",
            fiveHour: TatwoLocalUsageAggregate(
                requestCount: 0,
                inputTokens: nil,
                outputTokens: nil),
            sevenDay: TatwoLocalUsageAggregate(
                requestCount: 0,
                inputTokens: nil,
                outputTokens: nil))

        let loadedGrok = await TatwoLiveQuotaReader.loadGrok(
            provider: provider(
                id: "grok",
                displayName: "Grok"),
            snapshotReader: { empty })
        let loadedMiniMax = await TatwoLiveQuotaReader.loadMiniMax(
            provider: provider(
                id: "minimax",
                displayName: "MiniMax"),
            snapshotReader: { empty })
        let grok = try XCTUnwrap(loadedGrok)
        let miniMax = try XCTUnwrap(loadedMiniMax)

        for row in [grok, miniMax] {
            XCTAssertEqual(row.statusText, "尚無本機用量")
            XCTAssertEqual(row.sourceBadge, "本機計量")
            XCTAssertFalse(row.statusText.contains("0 次請求"))
            XCTAssertEqual(
                compactWindowText(row),
                "尚無本機用量")
        }
    }

    private func provider(
        id: String,
        displayName: String
    ) -> UsageProviderStatus {
        UsageProviderStatus(
            id: id,
            displayName: displayName,
            status: .unknown,
            cachePolicy: "test",
            liveRefreshPolicy: "test",
            quotaLabel: "test")
    }
}
