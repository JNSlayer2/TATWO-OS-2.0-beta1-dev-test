import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class HeaderQuotaStripModelTests: XCTestCase {
    func testModelUsesLiveQuotaDisplayRowsAndFiltersDisabledProviders() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let providers = [
            provider(id: "codex-gpt", name: "Codex / GPT"),
            provider(id: "claude", name: "Claude"),
        ]
        let snapshot = LiveQuotaDeckSnapshot(
            loadedAt: now,
            rows: [
                "codex-gpt": row(id: "codex-gpt", name: "Codex / GPT", status: .installed, percent: 70),
                "claude": row(id: "claude", name: "Claude", status: .missing, percent: nil),
            ]
        )

        let model = HeaderQuotaStripModel(providers: providers, snapshot: snapshot, now: now)
        let segment = try XCTUnwrap(model.segments.first)

        XCTAssertEqual(model.segments.map(\.id), ["codex-gpt"])
        XCTAssertEqual(segment.remainingPercent.percent, 70)
        XCTAssertEqual(segment.fillFraction, 0.70, accuracy: 0.001)
        XCTAssertEqual(segment.state, .live)
    }

    func testUnknownProviderRemainsVisibleAsLowContrastSegment() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let providers = [provider(id: "grok", name: "Grok")]
        let snapshot = LiveQuotaDeckSnapshot(
            loadedAt: now,
            rows: ["grok": row(id: "grok", name: "Grok", status: .unknown, percent: nil)]
        )

        let model = HeaderQuotaStripModel(providers: providers, snapshot: snapshot, now: now)

        XCTAssertEqual(model.segments.count, 1)
        XCTAssertEqual(model.segments[0].state, .unknown)
        XCTAssertEqual(model.segments[0].fillFraction, 0)
        XCTAssertTrue(model.segments[0].tooltip.contains("Grok"))
        XCTAssertEqual(model.segments[0].detailText, "test")
        XCTAssertEqual(model.segments[0].valueText, "test")
        XCTAssertTrue(model.segments[0].tooltip.contains("test"))
    }

    func testCriticalLiveQuotaUsesNonFlashingAlertWhileStaleDataDoesNot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let providers = [provider(id: "codex-gpt", name: "Codex / GPT")]
        let criticalSnapshot = LiveQuotaDeckSnapshot(
            loadedAt: now,
            rows: ["codex-gpt": row(id: "codex-gpt", name: "Codex / GPT", status: .installed, percent: 8)]
        )
        let staleSnapshot = LiveQuotaDeckSnapshot(
            loadedAt: now.addingTimeInterval(-301),
            rows: ["codex-gpt": row(id: "codex-gpt", name: "Codex / GPT", status: .installed, percent: 8)]
        )

        let critical = HeaderQuotaStripModel(providers: providers, snapshot: criticalSnapshot, now: now)
        let stale = HeaderQuotaStripModel(providers: providers, snapshot: staleSnapshot, now: now)

        XCTAssertEqual(critical.segments[0].state, .critical)
        XCTAssertEqual(critical.alert, .amber)
        XCTAssertEqual(stale.segments[0].state, .stale)
        XCTAssertEqual(stale.alert, .none)
    }

    func testFivePercentExportFixtureUsesRedCriticalAlert() throws {
        let providers = [provider(id: "codex-gpt", name: "Codex / GPT")]
        let snapshot = try XCTUnwrap(
            HeaderQuotaSnapshotFixture.make(kind: "critical-red", providers: providers)
        )
        let model = HeaderQuotaStripModel(
            providers: providers,
            snapshot: snapshot,
            now: snapshot.loadedAt ?? Date()
        )

        XCTAssertEqual(model.segments.first?.remainingPercent.percent, 5)
        XCTAssertEqual(model.segments.first?.state, .critical)
        XCTAssertEqual(model.alert, .red)
    }

    func testExpiredCodexWindowDoesNotRenderOldPercentageAsLive() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let providers = [provider(id: "codex-gpt", name: "Codex / GPT")]
        let snapshot = LiveQuotaDeckSnapshot(
            loadedAt: now,
            rows: [
                "codex-gpt": row(
                    id: "codex-gpt",
                    name: "Codex / GPT",
                    status: .installed,
                    percent: 72,
                    resetAt: now.addingTimeInterval(-1)
                )
            ]
        )

        let model = HeaderQuotaStripModel(providers: providers, snapshot: snapshot, now: now)

        XCTAssertEqual(model.segments[0].remainingPercent.percent, nil)
        XCTAssertEqual(model.segments[0].fillFraction, 0)
        XCTAssertEqual(model.segments[0].state, .unknown)
        XCTAssertEqual(model.alert, .none)
    }

    func testStripMetricsStayVisibleAtMinimumWindowWidth() {
        XCTAssertEqual(HeaderQuotaStripMetrics.visualWidth, 60)
        XCTAssertEqual(HeaderQuotaStripMetrics.visualHeight, 4)
        XCTAssertGreaterThanOrEqual(HeaderQuotaStripMetrics.hitHeight, 22)
        XCTAssertEqual(HeaderQuotaStripMetrics.visualWidth(forWindowWidth: 480), 60)
    }

    func testAllQuotaSurfacesReceiveFailureReasonInsteadOfBareDash()
        throws
    {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let providers = [
            provider(id: "codex-gpt", name: "Codex / GPT"),
        ]
        let reason = "OpenAI 額度回應解析失敗"
        let snapshot = LiveQuotaDeckSnapshot(
            loadedAt: now,
            rows: [
                "codex-gpt": LiveQuotaDisplay(
                    id: "codex-gpt",
                    displayName: "Codex / GPT",
                    planLabel: "PRO",
                    status: .installed,
                    statusText: "已登入",
                    caption: reason,
                    permissionLabel: "ChatGPT Pro",
                    sourceBadge: "失敗",
                    remainingPercent: nil,
                    primaryRemainingPercent: nil,
                    secondaryRemainingPercent: nil,
                    primaryResetAt: nil,
                    secondaryResetAt: nil,
                    resetCreditsAvailable: nil,
                    resetCreditsExpiresAt: nil,
                    resetCreditExpiryDates: []),
            ])
        let model = HeaderQuotaStripModel(
            providers: providers,
            snapshot: snapshot,
            now: now)
        let segment = try XCTUnwrap(model.segments.first)

        XCTAssertEqual(segment.valueText, reason)
        XCTAssertEqual(segment.detailText, reason)
        XCTAssertTrue(segment.tooltip.contains(reason))
        XCTAssertFalse(segment.valueText.contains("—"))
    }

    func testHydratedShellRefreshesAndSharesLiveQuotaWithChatAndUsage()
        throws
    {
        let repoRoot = ChatPageSourceScanner.repoRoot()
        let source = try ChatPageSourceScanner.readRelative(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift",
            repoRoot: repoRoot)
        let start = try XCTUnwrap(
            source.range(of: "private struct TatwoHydratedPanelView"))
        let end = try XCTUnwrap(
            source.range(
                of: "private struct TatwoPanelChatLauncher",
                range: start.upperBound..<source.endIndex))
        let hydratedShell = String(
            source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(hydratedShell.contains(
            "@State private var liveQuotaSnapshot: LiveQuotaDeckSnapshot"))
        XCTAssertTrue(hydratedShell.contains(
            "await TatwoQuotaSnapshotCache.shared.load("))
        XCTAssertTrue(hydratedShell.contains(
            "initialLiveQuotaSnapshot: liveQuotaSnapshot"))
        XCTAssertTrue(hydratedShell.contains(
            "initialLiveSnapshot: liveQuotaSnapshot"))
    }

    func testExportFixturesProduceNormalAndCriticalQuotaStates() throws {
        let providers = [
            provider(id: "codex-gpt", name: "Codex / GPT"),
            provider(id: "claude", name: "Claude"),
            provider(id: "grok", name: "Grok"),
        ]
        let normalSnapshot = try XCTUnwrap(
            HeaderQuotaSnapshotFixture.make(kind: "normal", providers: providers)
        )
        let criticalSnapshot = try XCTUnwrap(
            HeaderQuotaSnapshotFixture.make(kind: "critical", providers: providers)
        )

        let normal = HeaderQuotaStripModel(
            providers: providers,
            snapshot: normalSnapshot,
            now: normalSnapshot.loadedAt ?? Date()
        )
        let critical = HeaderQuotaStripModel(
            providers: providers,
            snapshot: criticalSnapshot,
            now: criticalSnapshot.loadedAt ?? Date()
        )

        XCTAssertEqual(normal.alert, .none)
        XCTAssertEqual(critical.alert, .amber)
        XCTAssertTrue(critical.segments.contains { $0.state == .critical })
    }

    private func provider(id: String, name: String) -> UsageProviderStatus {
        UsageProviderStatus(
            id: id,
            displayName: name,
            status: .unknown,
            cachePolicy: "test",
            liveRefreshPolicy: "test",
            quotaLabel: "test"
        )
    }

    private func row(
        id: String,
        name: String,
        status: InstallState,
        percent: Int?,
        resetAt: Date? = Date(timeIntervalSince1970: 1_800_003_600)
    ) -> LiveQuotaDisplay {
        LiveQuotaDisplay(
            id: id,
            displayName: name,
            planLabel: name.uppercased(),
            status: status,
            statusText: percent == nil ? "未接入" : "live",
            caption: "test",
            permissionLabel: "test",
            sourceBadge: percent == nil ? "無 live" : "live",
            remainingPercent: percent,
            primaryRemainingPercent: percent,
            secondaryRemainingPercent: nil,
            primaryResetAt: resetAt,
            secondaryResetAt: nil,
            resetCreditsAvailable: nil,
            resetCreditsExpiresAt: nil,
            resetCreditExpiryDates: []
        )
    }
}
