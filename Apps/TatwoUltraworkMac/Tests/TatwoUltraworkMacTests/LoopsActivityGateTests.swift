import AppKit
import SwiftUI
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

/// Loops 進行中判定 + 中斷二次確認決策表。
/// 兩者都是純函式，不碰磁碟；registry I/O 由 `TatwoLoopsActivityMonitor` 負責，不在此測。
final class LoopsActivityGateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        id: String,
        binding: String,
        status: TatwoDispatchStatus,
        updatedAgo: TimeInterval = 60,
        startedAgo: TimeInterval = 300,
        identity: IdentityKind = .sub,
        modelID: String = "gpt-5.6-sol",
        subtask: String = "盤點 Core 型別"
    ) -> TatwoDispatchRecord {
        TatwoDispatchRecord(
            id: id,
            contractID: "contract-a",
            bindingID: binding,
            sourceSlotID: "slot-\(binding)",
            identity: identity,
            modelID: modelID,
            subtask: subtask,
            status: status,
            startedAt: now.addingTimeInterval(-startedAgo),
            updatedAt: now.addingTimeInterval(-updatedAgo))
    }

    private func run(
        contractID: String = "contract-a",
        records: [TatwoDispatchRecord],
        sealID: String? = nil
    ) -> TatwoStoredDispatchRun {
        TatwoStoredDispatchRun(
            contractID: contractID,
            records: records,
            updatedAt: now,
            sealID: sealID)
    }

    // MARK: - 判定：什麼算「進行中」

    func testQueuedAndRunningCountAsActiveCompletedAndFailedDoNot() {
        let snapshot = TatwoLoopsActivityPolicy.snapshot(
            from: [run(records: [
                record(id: "r1", binding: "b1", status: .running),
                record(id: "r2", binding: "b2", status: .queued),
                record(id: "r3", binding: "b3", status: .completed),
                record(id: "r4", binding: "b4", status: .failed)
            ])],
            now: now)

        XCTAssertTrue(snapshot.isActive)
        XCTAssertEqual(snapshot.activeCount, 2)
        XCTAssertEqual(snapshot.runningCount, 1)
        XCTAssertEqual(snapshot.queuedCount, 1)
        XCTAssertEqual(Set(snapshot.rows.map(\.id)), ["r1", "r2"])
    }

    func testEmptyRegistryIsNotActive() {
        let snapshot = TatwoLoopsActivityPolicy.snapshot(from: [], now: now)
        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot.activeCount, 0)
    }

    /// 同一個 binding 先 running 後 completed → 收斂到最新一筆，不算在動。
    func testLatestRecordPerBindingWinsSoSupersededRunningIsNotActive() {
        let snapshot = TatwoLoopsActivityPolicy.snapshot(
            from: [run(records: [
                record(id: "old", binding: "b1", status: .running, updatedAgo: 600),
                record(id: "new", binding: "b1", status: .completed, updatedAgo: 30)
            ])],
            now: now)

        XCTAssertFalse(snapshot.isActive)
    }

    /// 反向：最新一筆才是 running，也要正確判為在動。
    func testLatestRunningAfterEarlierCompletedIsActive() {
        let snapshot = TatwoLoopsActivityPolicy.snapshot(
            from: [run(records: [
                record(id: "old", binding: "b1", status: .completed, updatedAgo: 600),
                record(id: "new", binding: "b1", status: .running, updatedAgo: 30)
            ])],
            now: now)

        XCTAssertEqual(snapshot.rows.map(\.id), ["new"])
    }

    /// 孤兒保護：超過 staleCutoff 沒更新的 running 是殭屍，不應永遠攔住結束。
    func testStaleRunningRecordIsIgnored() {
        let stale = TatwoLoopsActivityPolicy.staleCutoff + 60
        let snapshot = TatwoLoopsActivityPolicy.snapshot(
            from: [run(records: [record(id: "z", binding: "b1", status: .running, updatedAgo: stale)])],
            now: now)

        XCTAssertFalse(snapshot.isActive)
    }

    func testRecordJustInsideStaleCutoffStillCounts() {
        let fresh = TatwoLoopsActivityPolicy.staleCutoff - 60
        let snapshot = TatwoLoopsActivityPolicy.snapshot(
            from: [run(records: [record(id: "z", binding: "b1", status: .running, updatedAgo: fresh)])],
            now: now)

        XCTAssertTrue(snapshot.isActive)
    }

    /// 已封存的 run 已結案，殘留 running 不再代表活動。
    func testSealedRunIsIgnored() {
        let snapshot = TatwoLoopsActivityPolicy.snapshot(
            from: [run(records: [record(id: "s", binding: "b1", status: .running)], sealID: "seal-1")],
            now: now)

        XCTAssertFalse(snapshot.isActive)
    }

    func testRunningRowsSortAheadOfQueuedRows() {
        let snapshot = TatwoLoopsActivityPolicy.snapshot(
            from: [run(records: [
                record(id: "q", binding: "b1", status: .queued, updatedAgo: 10),
                record(id: "r", binding: "b2", status: .running, updatedAgo: 500)
            ])],
            now: now)

        XCTAssertEqual(snapshot.rows.map(\.id), ["r", "q"])
    }

    func testRowsSpanMultipleContracts() {
        let snapshot = TatwoLoopsActivityPolicy.snapshot(
            from: [
                run(contractID: "a", records: [record(id: "r1", binding: "b1", status: .running)]),
                run(contractID: "b", records: [record(id: "r2", binding: "b1", status: .running)])
            ],
            now: now)

        XCTAssertEqual(snapshot.activeCount, 2)
    }

    @MainActor
    func testTerminationSnapshotUsesPublishedMemorySnapshot() {
        let published = activeSnapshot()
        let snapshot = TatwoLoopsActivityMonitor.terminationSnapshot(
            environment: [
                "TATWO_ULTRAWORK_STATE_DIR":
                    "/Volumes/permission-blocked-fixture/state"
            ],
            publishedSnapshot: published)

        XCTAssertEqual(snapshot, published)
    }

    @MainActor
    func testTerminationSnapshotKeepsFixturePrecedence() {
        let snapshot = TatwoLoopsActivityMonitor.terminationSnapshot(
            environment: ["TATWO_ULTRAWORK_EXPORT_LOOPS_FIXTURE": "1"],
            publishedSnapshot: .empty)

        XCTAssertEqual(snapshot.activeCount, 4)
        XCTAssertTrue(snapshot.rows.allSatisfy { $0.id.hasPrefix("fixture-") })
    }

    func testRowDisplayNameFallsBackToBindingWhenModelIDEmpty() {
        let snapshot = TatwoLoopsActivityPolicy.snapshot(
            from: [run(records: [record(id: "r1", binding: "binding-x", status: .running, modelID: "")])],
            now: now)

        XCTAssertEqual(snapshot.rows.first?.displayName, "binding-x")
    }

    // MARK: - 決策表：哪個入口要二次確認

    private func activeSnapshot() -> TatwoLoopsActivitySnapshot {
        TatwoLoopsActivityPolicy.snapshot(
            from: [run(records: [
                record(id: "r1", binding: "b1", status: .running),
                record(id: "r2", binding: "b2", status: .running),
                record(id: "r3", binding: "b3", status: .queued)
            ])],
            now: now)
    }

    func testCloseAndQuitGatesConfirmOnlyWhileLoopsAreRunning() {
        let active = activeSnapshot()
        for kind in [TatwoInterruptKind.appTerminate, .windowClose, .escapeClose] {
            XCTAssertTrue(
                TatwoInterruptGate.decision(kind: kind, snapshot: active).requiresConfirmation,
                "\(kind) 在 loops 進行中必須攔截")
            XCTAssertEqual(
                TatwoInterruptGate.decision(kind: kind, snapshot: .empty), .proceed,
                "\(kind) 在沒有 loops 時必須放行，否則確認會被訓練成反射動作")
        }
    }

    /// Esc 走的是和關窗同一道閘——不可因為入口不同就繞過。
    func testEscapeCloseSharesTheSameDecisionAsWindowClose() {
        let active = activeSnapshot()
        XCTAssertEqual(
            TatwoInterruptGate.decision(kind: .escapeClose, snapshot: active),
            TatwoInterruptGate.decision(kind: .windowClose, snapshot: active))
    }

    func testComposerStopAlwaysConfirms() {
        XCTAssertTrue(
            TatwoInterruptGate.decision(kind: .composerStop, snapshot: .empty).requiresConfirmation)
        XCTAssertTrue(
            TatwoInterruptGate.decision(kind: .composerStop, snapshot: activeSnapshot())
                .requiresConfirmation)
    }

    func testEveryInterruptKindConfirmsWhileLoopsAreRunning() {
        let active = activeSnapshot()
        for kind in TatwoInterruptKind.allCases {
            XCTAssertTrue(
                TatwoInterruptGate.decision(kind: kind, snapshot: active).requiresConfirmation,
                "\(kind) 在 loops 進行中必須二次確認")
        }
    }

    // MARK: - 文案

    func testTallyReportsRunningAndQueuedBreakdown() {
        let tally = TatwoInterruptGate.activityTally(activeSnapshot())
        XCTAssertTrue(tally.contains("3 個代理"), tally)
        XCTAssertTrue(tally.contains("2 執行中"), tally)
        XCTAssertTrue(tally.contains("1 排隊"), tally)
    }

    func testTallyIsEmptyWhenIdle() {
        XCTAssertEqual(TatwoInterruptGate.activityTally(.empty), "")
    }

    func testPromptsCarryDistinctConfirmButtonTitles() {
        let active = activeSnapshot()
        let quit = TatwoInterruptGate.prompt(kind: .appTerminate, snapshot: active)
        let close = TatwoInterruptGate.prompt(kind: .windowClose, snapshot: active)
        let stop = TatwoInterruptGate.prompt(kind: .composerStop, snapshot: active)

        XCTAssertEqual(quit.confirmTitle, "仍要結束")
        XCTAssertEqual(close.confirmTitle, "仍要關閉")
        XCTAssertEqual(stop.confirmTitle, "停止")
        for prompt in [quit, close, stop] {
            XCTAssertEqual(prompt.cancelTitle, "取消")
            XCTAssertFalse(prompt.title.isEmpty)
            XCTAssertFalse(prompt.message.isEmpty)
        }
    }

    func testStopPromptMentionsDispatchesOnlyWhenLoopsAreRunning() {
        XCTAssertTrue(
            TatwoInterruptGate.prompt(kind: .composerStop, snapshot: activeSnapshot())
                .message.contains("派工"))
        XCTAssertFalse(
            TatwoInterruptGate.prompt(kind: .composerStop, snapshot: .empty)
                .message.contains("派工"))
    }

    // MARK: - 光暈 token 來源錨定（os.md §3.6）

    /// 半徑仍是 Dashboard 真值直接映射（shadowBlur 14），不得被縮放。
    /// 來源：layer 玻璃 1 (glass-mqw4itdu-p5boy)。
    func testGlowRadiusStaysPinnedToDashboardTruth() {
        XCTAssertEqual(LiquidGlassTokens.loopsGlowRadius, 14)
    }

    /// 2026-07-27 設計裁決：呼吸上下限經**標註式工程放大**（os.md §3.6），
    /// 不再是 Dashboard 原值。鎖新值同時鎖來源字串，防止日後被誤當真值搬走。
    func testGlowOpacitiesAreEngineeringScaledWithDeclaredProvenance() {
        XCTAssertEqual(LiquidGlassTokens.loopsGlowPeakOpacity, 0.32, accuracy: 0.0001)
        XCTAssertEqual(LiquidGlassTokens.loopsGlowTroughOpacity, 0.07, accuracy: 0.0001)
        XCTAssertGreaterThan(
            LiquidGlassTokens.loopsGlowPeakOpacity,
            LiquidGlassTokens.loopsGlowTroughOpacity)

        // 換算式必須成立：Dashboard 原值 × 1.8 淺底對比補償。
        XCTAssertEqual(LiquidGlassTokens.loopsGlowContrastCompensation, 1.8, accuracy: 0.0001)
        XCTAssertEqual(
            LiquidGlassTokens.loopsGlowPeakOpacity,
            0.18 * LiquidGlassTokens.loopsGlowContrastCompensation,
            accuracy: 0.005,
            "峰值必須等於 Dashboard alpha 0.18 × 補償倍率")
        XCTAssertEqual(
            LiquidGlassTokens.loopsGlowTroughOpacity,
            0.04 * LiquidGlassTokens.loopsGlowContrastCompensation,
            accuracy: 0.005,
            "谷值必須與峰值等比，維持原本明暗比")

        // 來源聲明字串：必須講清楚是工程放大而非 Dashboard 真值。
        let provenance = LiquidGlassTokens.loopsGlowOpacityProvenance
        XCTAssertTrue(provenance.contains("0.18"), provenance)
        XCTAssertTrue(provenance.contains("1.8"), provenance)
        XCTAssertTrue(provenance.contains("工程放大"), provenance)
        XCTAssertTrue(provenance.contains("非 Dashboard 真值"), provenance)
    }

    /// 放大只准套在 alpha：半徑與週期不得跟著被乘。
    func testContrastCompensationDidNotLeakIntoRadiusOrPeriod() {
        XCTAssertEqual(LiquidGlassTokens.loopsGlowRadius, 14, "blur 仍須是 Dashboard shadowBlur")
        XCTAssertEqual(LiquidGlassTokens.loopsGlowBreathPeriod, 2.6, accuracy: 0.0001)
    }

    /// icon tint：同色相、比光暈實一階、又不等於 brandAccent 原色（那是按鈕/選取態語彙）。
    func testIconTintSitsBetweenGlowAndBrandAccent() throws {
        let accent = try XCTUnwrap(
            NSColor(LiquidGlassTokens.brandAccent).usingColorSpace(.deviceRGB))
        let glow = try XCTUnwrap(
            NSColor(LiquidGlassTokens.loopsGlowColor).usingColorSpace(.deviceRGB))
        let tint = try XCTUnwrap(
            NSColor(LiquidGlassTokens.loopsGlowIconTint).usingColorSpace(.deviceRGB))

        var accentHue: CGFloat = 0, accentSat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        accent.getHue(&accentHue, saturation: &accentSat, brightness: &bri, alpha: &alpha)
        var glowHue: CGFloat = 0, glowSat: CGFloat = 0
        glow.getHue(&glowHue, saturation: &glowSat, brightness: &bri, alpha: &alpha)
        var tintHue: CGFloat = 0, tintSat: CGFloat = 0
        tint.getHue(&tintHue, saturation: &tintSat, brightness: &bri, alpha: &alpha)

        XCTAssertEqual(tintHue, accentHue, accuracy: 0.01, "icon tint 必須同色相")
        XCTAssertGreaterThan(tintSat, glowSat, "icon 是小面積實心字形，比光暈實一階才看得出換色")
        XCTAssertLessThan(tintSat, accentSat, "不得等於 brandAccent 原色，避免讀成可點擊控制項")
    }

    /// 羽化距離必須落在設計指定的 12–16pt。
    func testGlowSpreadStaysWithinDesignedFeatherRange() {
        XCTAssertGreaterThanOrEqual(LiquidGlassTokens.loopsGlowSpread, 12)
        XCTAssertLessThanOrEqual(LiquidGlassTokens.loopsGlowSpread, 16)
    }

    /// 橫向拉伸要真的把正圓拉成橫躺橢圓。
    func testGlowIsStretchedIntoAHorizontalEllipse() {
        XCTAssertGreaterThan(
            LiquidGlassTokens.loopsGlowHorizontalStretch, 1.0,
            "沒有拉伸就會是正圓光點，不是橫躺燈暈")
    }

    /// 色彩：同色相、降飽和——像燈暈不像選取色塊。
    ///
    /// 亮度方向刻意**不是**提亮：app 底是牛皮紙淺色，提亮會讓光暈趨近底色，
    /// 在錨定 alpha 0.18 下實測不可見。淺底上要被看見必須比底稍深。
    func testGlowColourIsDesaturatedAndSlightlyDeeperThanBrandAccent() throws {
        let accent = try XCTUnwrap(
            NSColor(LiquidGlassTokens.brandAccent).usingColorSpace(.deviceRGB))
        let glow = try XCTUnwrap(
            NSColor(LiquidGlassTokens.loopsGlowColor).usingColorSpace(.deviceRGB))

        var accentHue: CGFloat = 0, accentSat: CGFloat = 0, accentBri: CGFloat = 0, alpha: CGFloat = 0
        accent.getHue(&accentHue, saturation: &accentSat, brightness: &accentBri, alpha: &alpha)
        var glowHue: CGFloat = 0, glowSat: CGFloat = 0, glowBri: CGFloat = 0
        glow.getHue(&glowHue, saturation: &glowSat, brightness: &glowBri, alpha: &alpha)

        XCTAssertEqual(glowHue, accentHue, accuracy: 0.01, "色相必須跟著 brandAccent")
        XCTAssertLessThan(glowSat, accentSat, "飽和度必須低於原色，否則讀成選取態色塊")
        XCTAssertLessThan(glowBri, accentBri, "淺底上光暈必須比原色稍深才看得見")
        XCTAssertLessThan(LiquidGlassTokens.loopsGlowSaturationScale, 1.0)
        XCTAssertLessThan(LiquidGlassTokens.loopsGlowBrightnessBoost, 1.0)

        // 只能「稍」深：過深就從燈暈變成陰影／色塊。
        XCTAssertGreaterThan(LiquidGlassTokens.loopsGlowBrightnessBoost, 0.7)
    }
}
