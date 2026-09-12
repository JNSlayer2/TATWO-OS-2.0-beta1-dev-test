import Foundation
import XCTest
import TatwoUltraworkCore

@testable import TatwoUltraworkMac

/// 2026-08-28 staging 66 residual：window 有回應但內容永遠空白。
///
/// tccd 實證（`log show --predicate 'subsystem == "com.apple.TCC"'`，
/// msgID=436.41357）：
///   `No usage string found (key:NSRemovableVolumesUsageDescription)`
///   `usage description: (null)` → `display_prompt` → `AUTHREQ_PROMPTING`
///   00:59:56.703 送出，01:02:48.880 才回 `AUTHREQ_RESULT authValue=2`（172 秒）。
/// sandboxd 的 `TCCAccessRequest` 同步且無 timeout，就是壓住 kernel `open()` 的那層，
/// 所以三支啟動讀檔全停在 `__open`。
///
/// 這組測試釘住兩個 seam：
///  1. 打包契約：外接卷 staging bundle 一定要帶得起同意面板的 usage string。
///  2. 執行期契約：hydration 逾時一定要走到可見的失敗／重試狀態，而且重試
///     不得再開一支無法取消的 `open()`。
final class StagingExternalVolumeLaunchAccessTests: XCTestCase {
    private func stagingBuildScript() throws -> String {
        try ChatPageSourceScanner.readRelative(
            "script/build_staging_app.sh",
            repoRoot: ChatPageSourceScanner.repoRoot())
    }

    private func sharedCEFBundleScript() throws -> String {
        try ChatPageSourceScanner.readRelative(
            "scripts/tatwo-cef-bundle.sh",
            repoRoot: ChatPageSourceScanner.repoRoot())
    }

    private func appShellSource() throws -> String {
        try ChatPageSourceScanner.readRelative(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift",
            repoRoot: ChatPageSourceScanner.repoRoot())
    }

    private func cefHelperInfoPlistTemplate(
        in script: String
    ) throws -> Substring {
        let marker =
            #"cat >"$helper_contents/Info.plist" <<PLIST"#
        let start = try XCTUnwrap(script.range(of: marker))
        let end = try XCTUnwrap(
            script.range(
                of: "\nPLIST",
                range: start.upperBound..<script.endIndex))
        return script[start.upperBound..<end.lowerBound]
    }

    // MARK: - Packaging contract: removable-volume consent must be presentable

    func testStagingInfoPlistDeclaresRemovableVolumeUsageDescription() throws {
        let script = try stagingBuildScript()

        XCTAssertTrue(
            script.contains("<key>NSRemovableVolumesUsageDescription</key>"),
            "staging Info.plist must declare NSRemovableVolumesUsageDescription; "
                + "without it tccd logs 'usage description: (null)' and the "
                + "removable-volume consent panel never resolves")
        XCTAssertTrue(
            script.contains(
                "<string>$REMOVABLE_VOLUME_USAGE_DESCRIPTION</string>"),
            "usage description must be a real non-empty string value")
        XCTAssertTrue(
            script.contains("REMOVABLE_VOLUME_USAGE_DESCRIPTION='"),
            "staging builder must define the removable-volume usage string")
        XCTAssertTrue(
            script.contains("<key>NSNetworkVolumesUsageDescription</key>"),
            "network-volume runtime roots need the same consent seam")
    }

    func testCEFHelperInfoPlistDeclaresExternalVolumeUsageDescriptions()
        throws
    {
        let script = try sharedCEFBundleScript()
        let helperTemplate = try cefHelperInfoPlistTemplate(in: script)

        XCTAssertTrue(
            helperTemplate.contains(
                "<key>NSRemovableVolumesUsageDescription</key>"))
        XCTAssertTrue(
            helperTemplate.contains(
                "<string>$removable_description</string>"))
        XCTAssertTrue(
            helperTemplate.contains(
                "<key>NSNetworkVolumesUsageDescription</key>"))
        XCTAssertTrue(
            helperTemplate.contains(
                "<string>$network_description</string>"))
    }

    func testStagingBuilderFailsWhenUsageDescriptionIsMissingFromBundle() throws {
        let script = try stagingBuildScript()

        XCTAssertTrue(
            script.contains(
                "PlistBuddy -c 'Print :NSRemovableVolumesUsageDescription'"),
            "builder must verify the produced bundle, not just the template")
        XCTAssertTrue(
            script.contains("REMOVABLE_USAGE_IN_BUNDLE"),
            "builder must capture the produced usage string for verification")
        XCTAssertTrue(
            script.contains(
                "removable-volume consent cannot be presented and launch reads "
                    + "will block in open()"),
            "the failure message must name the actual blocking mechanism")
        XCTAssertTrue(
            script.contains("removableVolumeUsageDescriptionPresent"),
            "staging receipt must record the consent-capability fact")
    }

    func testStagingBuilderVerifiesCEFHelperExternalVolumeUsageDescriptions()
        throws
    {
        let script = try sharedCEFBundleScript()
        let normalizedScript = script
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        XCTAssertTrue(
            normalizedScript.contains(
                #"assert_plist_value_equals \ "$helper_info" \ NSRemovableVolumesUsageDescription \ "$expected_removable_description""#))
        XCTAssertTrue(
            normalizedScript.contains(
                #"assert_plist_value_equals \ "$helper_info" \ NSNetworkVolumesUsageDescription \ "$expected_network_description""#))
    }

    // MARK: - Block report is a pure, deterministic classification

    func testBlockReportListsRuntimeRootsAndFlagsRemovableVolume() {
        let report = TatwoLaunchStorageBlockReport.make(
            environment: [
                "TATWO_ULTRAWORK_STATE_DIR":
                    "/Volumes/fixture-volume/runtime/sandbox/test/rt-63/state",
                "TATWO_ULTRAWORK_APP_SUPPORT":
                    "/Volumes/fixture-volume/runtime/sandbox/test/rt-63/app-support",
                "TATWO_ULTRAWORK_CHAT_WORKDIR":
                    "/Volumes/fixture-volume/runtime/sandbox/test",
            ],
            waitedSeconds: 6)

        XCTAssertEqual(
            report.blockedPaths,
            [
                "/Volumes/fixture-volume/runtime/sandbox/test/rt-63/state",
                "/Volumes/fixture-volume/runtime/sandbox/test/rt-63/app-support",
                "/Volumes/fixture-volume/runtime/sandbox/test",
            ],
            "the visible failure must name the exact runtime roots being waited on")
        XCTAssertTrue(report.isRemovableVolumePath)
        XCTAssertTrue(
            report.guidance.contains("卸除式卷宗"),
            "removable-volume guidance must point at the consent grant, not 'please wait'")
        XCTAssertTrue(
            report.guidance.contains("自動繼續"),
            "guidance must promise self-heal so the user does not click repeatedly")
    }

    func testBlockReportDoesNotClaimRemovableVolumeForLocalRoots() {
        let report = TatwoLaunchStorageBlockReport.make(
            environment: [
                "TATWO_ULTRAWORK_STATE_DIR": "/Users/example/Library/state",
                "TATWO_ULTRAWORK_APP_SUPPORT": "/Users/example/Library/support",
            ],
            waitedSeconds: 2)

        XCTAssertFalse(report.isRemovableVolumePath)
        XCTAssertFalse(report.guidance.contains("卸除式卷宗"))
        XCTAssertTrue(
            report.guidance.contains("不會改用預設或空白狀態"),
            "failure must not be confusable with a silent fallback to default state")
    }

    func testBlockReportDeduplicatesAndSkipsEmptyRoots() {
        let report = TatwoLaunchStorageBlockReport.make(
            environment: [
                "TATWO_ULTRAWORK_STATE_DIR": "/Volumes/X/state",
                "TATWO_ULTRAWORK_APP_SUPPORT": "   ",
                "TATWO_ULTRAWORK_CHAT_WORKDIR": "/Volumes/X/state",
            ],
            waitedSeconds: 1)

        XCTAssertEqual(report.blockedPaths, ["/Volumes/X/state"])
    }

    // MARK: - Only `resolving` may render a blank first frame

    func testOnlyResolvingStateRendersBlankFirstFrame() {
        let report = TatwoLaunchStorageBlockReport.make(
            environment: [:], waitedSeconds: 0)

        XCTAssertTrue(TatwoPanelLaunchState.resolving.rendersBlankFirstFrame)
        XCTAssertFalse(
            TatwoPanelLaunchState.storageUnavailable(report)
                .rendersBlankFirstFrame,
            "an unresolvable storage root must be visible, never blank")
    }

    func testPanelViewRoutesStorageUnavailableToAVisibleRetrySurface() throws {
        let source = try appShellSource()

        XCTAssertTrue(
            source.contains("case let .storageUnavailable(report):"),
            "TatwoPanelView must branch on the bounded failure state")
        XCTAssertTrue(
            source.contains("TatwoLaunchStorageUnavailableView("),
            "the failure branch must render a real surface, not Color.clear")
        XCTAssertTrue(
            source.contains("Button(\"重試\", action: retry)"),
            "the failure surface must offer an explicit retry")
        XCTAssertTrue(
            source.contains("NSApplication.didBecomeActiveNotification"),
            "returning from the consent panel must re-arm hydration automatically")
    }

    // MARK: - Bounded wait + single-flight self-heal

    /// 逾時後畫面必須切到可見失敗；被 TCC 擋住的解析回來後必須自動 hydrate。
    @MainActor
    func testDeadlineExpiryShowsFailureAndLateResolutionSelfHeals() async {
        let gate = LaunchProbeGate()
        let deadlineGate = LaunchProbeGate()
        let coordinator = TatwoPanelLaunchCoordinator(
            environment: ["TATWO_ULTRAWORK_STATE_DIR": "/Volumes/X/state"],
            deadlineSeconds: 6,
            resolver: {
                await gate.wait()
                return Self.stubHydration()
            },
            deadlineTick: { await deadlineGate.wait() })

        let blocked = expectation(description: "storage reported unavailable")
        let healed = expectation(description: "late resolution hydrated")
        coordinator.onStateChange = { state in
            switch state {
            case .storageUnavailable: blocked.fulfill()
            case .hydrated: healed.fulfill()
            case .resolving: break
            }
        }

        coordinator.start()
        XCTAssertTrue(coordinator.state.rendersBlankFirstFrame)

        deadlineGate.open()
        await fulfillment(of: [blocked], timeout: 5)
        guard case let .storageUnavailable(report) = coordinator.state else {
            return XCTFail("bounded deadline must surface a visible failure state")
        }
        XCTAssertEqual(report.blockedPaths, ["/Volumes/X/state"])
        XCTAssertEqual(report.waitedSeconds, 6)

        // 使用者按下允許 → 原本被壓住的 open() 回來 → 不需再互動就 hydrate。
        gate.open()
        await fulfillment(of: [healed], timeout: 5)
        guard case .hydrated = coordinator.state else {
            return XCTFail("late storage resolution must self-heal into hydration")
        }
        XCTAssertEqual(
            coordinator.resolveAttemptCount, 1,
            "self-heal must reuse the single in-flight probe")
    }

    /// 被 TCC 擋住的 `open()` 無法取消，所以重試絕不能再開一支。
    @MainActor
    func testRetryWhileBlockedNeverStartsASecondUncancellableProbe() async {
        let gate = LaunchProbeGate()
        let deadlineGate = LaunchProbeGate()
        let coordinator = TatwoPanelLaunchCoordinator(
            environment: ["TATWO_ULTRAWORK_STATE_DIR": "/Volumes/X/state"],
            deadlineSeconds: 1,
            resolver: {
                await gate.wait()
                return Self.stubHydration()
            },
            deadlineTick: { await deadlineGate.wait() })

        let blocked = expectation(description: "storage reported unavailable")
        // 重試後儲存仍被擋住時，回到 unavailable 是正確行為，不是過度 fulfill。
        blocked.assertForOverFulfill = false
        let healed = expectation(description: "hydrated after retry")
        coordinator.onStateChange = { state in
            switch state {
            case .storageUnavailable: blocked.fulfill()
            case .hydrated: healed.fulfill()
            case .resolving: break
            }
        }

        coordinator.start()
        deadlineGate.open()
        await fulfillment(of: [blocked], timeout: 5)

        coordinator.retry()
        coordinator.retry()
        coordinator.retry()

        XCTAssertEqual(coordinator.retryCount, 3)
        XCTAssertEqual(
            coordinator.resolveAttemptCount, 1,
            "retry must not accumulate blocked open() threads")
        // 這裡刻意不 await：`retry()` 是同步把畫面切回 resolving 的，
        // 之後倒數再次到期會（正確地）重新顯示失敗畫面。
        XCTAssertTrue(
            coordinator.state.rendersBlankFirstFrame,
            "retry returns to the resolving state while the probe is still pending")

        gate.open()
        await fulfillment(of: [healed], timeout: 5)
        guard case .hydrated = coordinator.state else {
            return XCTFail("probe completion must hydrate after retry")
        }
    }

    /// 儲存正常時行為不變：不得閃過失敗畫面。
    @MainActor
    func testHealthyStorageHydratesWithoutShowingFailureState() async {
        let deadlineGate = LaunchProbeGate()
        let coordinator = TatwoPanelLaunchCoordinator(
            environment: ["TATWO_ULTRAWORK_STATE_DIR": "/Volumes/X/state"],
            deadlineSeconds: 6,
            resolver: { Self.stubHydration() },
            deadlineTick: { await deadlineGate.wait() })

        let healed = expectation(description: "healthy storage hydrated")
        var sawUnavailable = false
        coordinator.onStateChange = { state in
            switch state {
            case .hydrated: healed.fulfill()
            case .storageUnavailable: sawUnavailable = true
            case .resolving: break
            }
        }

        coordinator.start()
        await fulfillment(of: [healed], timeout: 5)
        XCTAssertFalse(sawUnavailable, "healthy storage must never flash the failure surface")

        // 逾時計時器即使事後被觸發，也不得把已經 hydrate 的畫面打回失敗。
        deadlineGate.open()
        for _ in 0..<20 { await Task.yield() }
        guard case .hydrated = coordinator.state else {
            return XCTFail("a late deadline must not regress a hydrated panel")
        }
        XCTAssertFalse(sawUnavailable, "a late deadline must not regress a hydrated panel")
    }

    // MARK: - Helpers

    private static func stubHydration() -> TatwoPanelLaunchHydration {
        // 純記憶體 fixture：不讀磁碟，避免測試自己踩到本測試要修的那條 I/O 路徑。
        TatwoPanelLaunchHydration(
            snapshot: TatwoAppSnapshotFactory.make(
                preferences: TatwoUserPreferences()),
            modesAuthority: TatwoPanelModesInitialAuthority.resolve(
                environment: [:]))
    }

}

/// 決定性的閘門：測試明確決定 probe / deadline 什麼時候完成，不靠 sleep。
private final class LaunchProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
