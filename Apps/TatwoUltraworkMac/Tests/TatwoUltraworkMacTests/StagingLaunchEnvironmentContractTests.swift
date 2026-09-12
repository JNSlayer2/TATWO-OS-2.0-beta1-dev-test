import Foundation
import XCTest
import TatwoUltraworkCore

@testable import TatwoUltraworkMac

/// 2026-08-29 fixed-slot staging contract：
/// Finder/LaunchServices 只讀 Info.plist 的 `LSEnvironment`，不會走
/// `build_staging_app.sh --open` 的 `env -i`。兩條啟動路徑因此都必須把 App
/// HOME 固定在同一個 staging runtime root，讓 WebKit cookie／登入／快取
/// 留在該 session；建置工具所需的真實家目錄只能走 `BUILD_SHELL_HOME`。
final class StagingLaunchEnvironmentContractTests: XCTestCase {
    private var repoRoot: URL {
        ChatPageSourceScanner.repoRoot()
    }

    private func stagingBuildScript() throws -> String {
        try ChatPageSourceScanner.readRelative(
            "script/build_staging_app.sh", repoRoot: repoRoot)
    }

    // MARK: - Info.plist / LSEnvironment bootstrap contract

    func testInfoPlistLSEnvironmentUsesRuntimeHomeAndExplicitScratchHome() throws {
        let script = try stagingBuildScript()

        XCTAssertTrue(
            script.contains("STAGING_HOME=\"$STAGING_RUNTIME_ROOT/home\""),
            "staging builder must derive one session-scoped HOME from the pinned runtime root")
        XCTAssertTrue(
            script.contains("<key>HOME</key>\n    <string>$STAGING_HOME</string>"),
            "LSEnvironment HOME must preserve the staging session's cookie/login/cache root")
        XCTAssertTrue(
            script.contains(
                "<key>TATWO_STAGING_SCRATCH_HOME</key>\n    <string>$STAGING_HOME</string>"),
            "LSEnvironment must carry the isolated scratch home explicitly")
        XCTAssertFalse(
            script.contains("<key>HOME</key>\n    <string>$BUILD_SHELL_HOME</string>"),
            "LaunchServices must not inherit the build shell's real account HOME")
    }

    func testInfoPlistLSEnvironmentStillPinsIsolatedStagingRuntimeRoots() throws {
        let script = try stagingBuildScript()

        for isolatedKey in [
            "<key>CFFIXED_USER_HOME</key>\n    <string>$STAGING_HOME</string>",
            "<key>XDG_CACHE_HOME</key>\n    <string>$STAGING_XDG_CACHE</string>",
            "<key>TATWO_STAGING_CACHE_HOME</key>\n    <string>$STAGING_CACHE</string>",
            "<key>TATWO_ULTRAWORK_APP_SUPPORT</key>\n    <string>$APP_SUPPORT</string>",
            "<key>TATWO_ULTRAWORK_STATE_DIR</key>\n    <string>$APP_STATE</string>",
            "<key>CODEX_HOME</key>\n    <string>$CODEX_HOME_VALUE</string>",
        ] {
            XCTAssertTrue(
                script.contains(isolatedKey),
                "LSEnvironment must keep staging mutable state isolated: \(isolatedKey)")
        }
    }

    func testStagingBuilderRejectsUnusableBuildShellHome() throws {
        let script = try stagingBuildScript()

        XCTAssertTrue(
            script.contains("BUILD_SHELL_HOME=\"${TATWO_STAGING_BUILD_HOME:-$HOME}\""),
            "staging builder must resolve build-only HOME separately from App runtime HOME")
        XCTAssertTrue(
            script.contains("error: staging build-shell HOME is unusable"),
            "staging builder must fail closed when its build-only HOME is unavailable")
        XCTAssertTrue(
            script.contains(
                "/usr/bin/env HOME=\"$BUILD_SHELL_HOME\" TMPDIR=\"$BUILD_TMP\""),
            "only Swift build subprocesses should consume the build-shell HOME")
    }

    func testDirectOpenPathKeepsTheSameHomeContractAsLSEnvironment() throws {
        let script = try stagingBuildScript()

        XCTAssertTrue(script.contains("\"HOME=$STAGING_HOME\""))
        XCTAssertTrue(script.contains("\"CFFIXED_USER_HOME=$STAGING_HOME\""))
        XCTAssertTrue(script.contains("\"XDG_CACHE_HOME=$STAGING_XDG_CACHE\""))
        XCTAssertTrue(
            script.contains("\"TATWO_STAGING_CACHE_HOME=$STAGING_CACHE\""))
        XCTAssertTrue(script.contains("\"TATWO_STAGING_SCRATCH_HOME=$STAGING_HOME\""))
        XCTAssertFalse(script.contains("\"HOME=$BUILD_SHELL_HOME\""))
    }

    // MARK: - App-side consumption of the explicit staging paths

    func testLaunchGuardReadsExplicitStagingScratchHome() {
        XCTAssertEqual(
            TatwoLaunchEnvironmentGuard.stagingScratchHome(environment: [
                "TATWO_STAGING_SCRATCH_HOME": "/staging/runtime-58/home"
            ]),
            "/staging/runtime-58/home")
        XCTAssertNil(
            TatwoLaunchEnvironmentGuard.stagingScratchHome(environment: [:]))
        XCTAssertNil(
            TatwoLaunchEnvironmentGuard.stagingScratchHome(environment: [
                "TATWO_STAGING_SCRATCH_HOME": "  "
            ]))
    }

    /// staging 的 `/Volumes` 值是刻意的隔離根。若被改寫成真實家目錄，
    /// `CODEX_HOME` 會被導回正式 `~/.codex`，等於把 staging 寫入正式資料。
    func testStagingLaunchDoesNotRewriteIsolatedCodexHomeIntoRealHome() {
        let stagingEnvironment = [
            "TATWO_STAGING_SCRATCH_HOME": "/Volumes/ext/runtime-58/home",
            "CODEX_HOME": "/Volumes/ext/runtime-58/codex-home",
            "PWD": "/Volumes/ext/runtime-58/home",
            "OLDPWD": "/Volumes/ext/runtime-58/home",
        ]
        let previousCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", "/Volumes/ext/runtime-58/codex-home", 1)
        defer {
            if let previousCodexHome {
                setenv("CODEX_HOME", previousCodexHome, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }

        TatwoLaunchEnvironmentGuard.sanitizeInheritedExternalVolumeEnvironment(
            environment: stagingEnvironment)

        XCTAssertEqual(
            ProcessInfo.processInfo.environment["CODEX_HOME"],
            "/Volumes/ext/runtime-58/codex-home")
    }

    /// 非 staging（正式 App）行為不變：誤繼承的 `/Volumes` 值仍被改寫掉。
    func testFormalLaunchStillSanitizesInheritedExternalVolumeCodexHome() {
        let previousCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", "/Volumes/stray/.codex", 1)
        defer {
            if let previousCodexHome {
                setenv("CODEX_HOME", previousCodexHome, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }

        TatwoLaunchEnvironmentGuard.sanitizeInheritedExternalVolumeEnvironment(
            environment: ["CODEX_HOME": "/Volumes/stray/.codex"])

        XCTAssertEqual(
            ProcessInfo.processInfo.environment["CODEX_HOME"],
            "\(NSHomeDirectory())/.codex")
    }

    // MARK: - Launch must not block on staging runtime-root I/O

    func testLaunchTimeHostResourceReconcileIsBoundedAndOffTheFirstFramePath() throws {
        let source = try ChatPageSourceScanner.readRelative(
            "\(ChatPageSourceScanner.sourcesDirectory)/AppShell.swift",
            repoRoot: repoRoot)
        let mainBody = try XCTUnwrap(
            source.range(of: "static func main() {").map { range in
                String(source[range.upperBound...].prefix(1_200))
            })

        XCTAssertTrue(
            mainBody.contains("TatwoLaunchEnvironmentGuard.configureHostResourceGovernorAtLaunch()"),
            "launch must use the bounded reconcile entry point")
        let applicationIndex = try XCTUnwrap(
            mainBody.range(of: "let application: NSApplication = TatwoCEFApplication.shared")?.lowerBound)
        let reconcileIndex = try XCTUnwrap(
            mainBody.range(
                of: "TatwoLaunchEnvironmentGuard.configureHostResourceGovernorAtLaunch()"
            )?.lowerBound)
        XCTAssertLessThan(
            applicationIndex, reconcileIndex,
            "NSApplication must exist before any staging runtime-root disk I/O")
        XCTAssertFalse(
            mainBody.contains("TatwoPreferenceStore.defaultStore()"),
            "main() must not perform unbounded synchronous preference I/O at launch")
    }

    func testBoundedReconcileReturnsAndNeverTouchesRealPreferences() throws {
        // 測試只准寫進 temp；正式 ~/Library/Application Support 不得被動到。
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesURL = scratch.appendingPathComponent("preferences.json")
        let previous = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_PREFERENCES"]
        setenv("TATWO_ULTRAWORK_PREFERENCES", preferencesURL.path, 1)
        defer {
            if let previous {
                setenv("TATWO_ULTRAWORK_PREFERENCES", previous, 1)
            } else {
                unsetenv("TATWO_ULTRAWORK_PREFERENCES")
            }
            try? FileManager.default.removeItem(at: scratch)
        }

        let start = Date()
        TatwoLaunchEnvironmentGuard.configureHostResourceGovernorAtLaunch(
            timeout: .milliseconds(200))
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 5,
            "launch reconcile must be bounded, not open-ended")

        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: preferencesURL.path),
              Date() < deadline
        {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: preferencesURL.path),
            "reconcile must still land at the resolved store path")
    }
}

// MARK: - staging 59：第一幀不得被 state-root open() 擋住

/// 2026-08-27 staging 59 sample：main thread 停在
/// `applicationDidFinishLaunching` → `startAppPressureRuntime` →
/// `TatwoDeviceSnapshotProducer.loadOrCreateLocalDeviceID` → `Data.write` →
/// `open/__open`（state root 在 `/Volumes`）。`_handleAEOpenEvent` 因此永不返回，
/// LaunchServices AppleEvent 8 秒逾時、第一幀不出現。
///
/// 這組測試釘住修法：裝置身分解析改為背景執行、解析完成才安裝 pressure runtime，
/// 而且監控與裝置身分本身沒有被關掉，只是延後到儲存可用時。
final class StagingLaunchDeviceIdentityDeferralTests: XCTestCase {
    private var repoRoot: URL {
        ChatPageSourceScanner.repoRoot()
    }

    /// 模擬「外接卷 open() 永遠不回」：解析期間 main run loop 必須仍可推進。
    @MainActor
    func testDeviceIdentityResolutionKeepsMainRunLoopFreeWhileDiskOpenBlocks() async {
        let blockedOpen = DispatchSemaphore(value: 0)
        let probe = LaunchDeviceIdentityProbe()
        let unreachableStateRoot = URL(
            fileURLWithPath: "/Volumes/tatwo-staging-blocked-\(UUID().uuidString)",
            isDirectory: true)

        let resolution = Task {
            await TatwoLaunchDeviceIdentity.resolveOffMainThread(
                stateRootURL: unreachableStateRoot,
                loader: { _ in
                    probe.recordLoaderThread(isMain: Thread.isMainThread)
                    blockedOpen.wait()
                    return "device-from-disk"
                })
        }

        DispatchQueue.main.async { probe.markMainRunLoopDrained() }
        for _ in 0..<100 where !probe.mainRunLoopDrained {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            probe.mainRunLoopDrained,
            "main run loop 必須在裝置身分解析被磁碟卡住時仍能推進，否則 AppleEvent 會逾時")

        blockedOpen.signal()
        let resolved = await resolution.value
        XCTAssertEqual(resolved, "device-from-disk")
        XCTAssertEqual(
            probe.loaderRanOnMainThread, false,
            "state-root 的 read/write 不得在 main thread 上執行")
    }

    func testExplicitDeviceIDOverrideIsPureInMemoryAndNeverTouchesDisk() {
        XCTAssertEqual(
            TatwoLaunchDeviceIdentity.explicitDeviceID(from: [
                TatwoLaunchDeviceIdentity.environmentOverrideKey: "  mac-studio-01  "
            ]),
            "mac-studio-01")
        XCTAssertNil(TatwoLaunchDeviceIdentity.explicitDeviceID(from: [:]))
        XCTAssertNil(
            TatwoLaunchDeviceIdentity.explicitDeviceID(from: [
                TatwoLaunchDeviceIdentity.environmentOverrideKey: "   "
            ]))
    }

    /// 延後不等於停用：解析完成後身分仍要落在傳入的 state root（staging 隔離根），
    /// 而且跨次呼叫必須穩定，不能每次啟動換一個 device id。
    func testDeferredResolutionStillPersistsStableDeviceIDInsideTheGivenStateRoot() async throws {
        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateRoot) }

        let first = await TatwoLaunchDeviceIdentity.resolveOffMainThread(
            stateRootURL: stateRoot)
        XCTAssertFalse(first.isEmpty)

        let identityFile = stateRoot.appendingPathComponent(
            TatwoDeviceSnapshotProducer.localDeviceIDFileName, isDirectory: false)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: identityFile.path),
            "裝置身分必須寫在解析到的 state root 內，不得外洩到正式資料目錄")

        let second = await TatwoLaunchDeviceIdentity.resolveOffMainThread(
            stateRootURL: stateRoot)
        XCTAssertEqual(first, second, "device id 必須穩定，延後解析不得每次換身分")
    }

    /// 啟動順序契約：`applicationDidFinishLaunching` 仍然啟動 pressure runtime，
    /// 但第一幀路徑上不得再有任何 state-root 同步開檔；實際安裝搬到解析完成之後。
    func testPressureRuntimeStartupIsDeferredButPreserved() throws {
        let source = try ChatPageSourceScanner.readRelative(
            "\(ChatPageSourceScanner.sourcesDirectory)/AppShell.swift",
            repoRoot: repoRoot)

        let didFinishLaunching = try XCTUnwrap(
            source.range(of: "func applicationDidFinishLaunching(").map {
                String(source[$0.upperBound...].prefix(900))
            })
        XCTAssertTrue(
            didFinishLaunching.contains("startAppPressureRuntime()"),
            "runtime 啟動必須保留在 didFinishLaunching")

        let startStart = try XCTUnwrap(
            source.range(of: "private func startAppPressureRuntime() {")?.upperBound)
        let installStart = try XCTUnwrap(
            source.range(of: "private func installAppPressureRuntime(deviceID")?.lowerBound)
        let startBody = String(source[startStart..<installStart])

        XCTAssertFalse(
            startBody.contains("loadOrCreateLocalDeviceID"),
            "第一幀路徑不得同步呼叫 state-root 的 device-id read/write")
        XCTAssertTrue(
            startBody.contains("TatwoLaunchDeviceIdentity.resolveOffMainThread("),
            "device id 必須走背景解析 seam")
        XCTAssertTrue(
            startBody.contains("installAppPressureRuntime(deviceID:"),
            "解析完成後仍必須安裝 runtime")

        let installBody = String(source[installStart...].prefix(1_400))
        XCTAssertTrue(
            installBody.contains("TatwoAppPressureRuntimeRegistry.install(runtime)"),
            "runtime 仍必須註冊進 registry")
        XCTAssertTrue(
            installBody.contains("runtime.start(reason: .appLaunch"),
            "監控仍必須以 appLaunch 啟動，不得被停用")
    }
}

/// 跨 thread 觀測用的小 probe（測試專用）。
final class LaunchDeviceIdentityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var loaderThreadWasMain: Bool?
    private var mainDrained = false

    var loaderRanOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return loaderThreadWasMain
    }

    var mainRunLoopDrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mainDrained
    }

    func recordLoaderThread(isMain: Bool) {
        lock.lock()
        loaderThreadWasMain = isMain
        lock.unlock()
    }

    func markMainRunLoopDrained() {
        lock.lock()
        mainDrained = true
        lock.unlock()
    }
}

// MARK: - staging 65：SwiftUI render 不得再同步開 preferences

/// 2026-08-28 staging 65 sample（pid 21103）：三條 thread 同時停在 `__open`——
/// main thread 在 `TatwoPanelView.body` → `TatwoHydratedPanelView.init` →
/// `TatwoAppSnapshotFactory.makeCurrent` → `TatwoPreferenceStore.load`；
/// user-initiated queue 在 `configureHostResourceGovernorAtLaunch` →
/// `reconcileHostResourceProfileAtLaunch` → 同一支 `load()`；
/// utility queue 在 device-id 解析。啟動期 reconcile 已經有界，但 render 期又把
/// 同一個外接卷檔案的同步 `open()` 拉回 main thread，第一幀因此永遠不出現，
/// 而且 main thread 被佔住時外接卷的 TCC 同意流程也沒有 run loop 可以顯示。
///
/// 這組測試釘住修法：面板 hydration 一律在背景解析、render 期沒有同步 fallback。
final class StagingPanelSnapshotHydrationDeferralTests: XCTestCase {
    private var repoRoot: URL {
        ChatPageSourceScanner.repoRoot()
    }

    /// 模擬「外接卷 open() 永遠不回」：hydration 期間 main run loop 必須仍可推進。
    @MainActor
    func testPanelHydrationKeepsMainRunLoopFreeWhilePreferenceOpenBlocks() async {
        let blockedOpen = DispatchSemaphore(value: 0)
        let probe = LaunchDeviceIdentityProbe()

        let hydration = Task {
            await TatwoPanelLaunchHydration.resolveOffMainThread(
                snapshotLoader: {
                    probe.recordLoaderThread(isMain: Thread.isMainThread)
                    blockedOpen.wait()
                    return TatwoAppSnapshotFactory.make(
                        preferences: TatwoUserPreferences())
                },
                modesAuthorityLoader: {
                    TatwoModesIssuedAuthorityResolution(
                        contract: nil, integrityState: .noPointer)
                })
        }

        DispatchQueue.main.async { probe.markMainRunLoopDrained() }
        for _ in 0..<100 where !probe.mainRunLoopDrained {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            probe.mainRunLoopDrained,
            "面板快照解析被磁碟卡住時，main run loop 仍必須能推進，否則第一幀與 TCC 同意流程都出不來")

        blockedOpen.signal()
        _ = await hydration.value
        XCTAssertEqual(
            probe.loaderRanOnMainThread, false,
            "preferences / goal-run 的讀取不得在 main thread 上執行")
    }

    /// 併發啟動：launch reconcile 與面板 hydration 會同時 `load()` 同一個檔案。
    /// 兩邊都必須拿到有效偏好，而且 main thread 不得被任一邊擋住。
    @MainActor
    func testConcurrentLaunchReconcileAndPanelHydrationBothCompleteOffMainThread()
        async throws
    {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true)
        let preferencesURL = scratch.appendingPathComponent("preferences.json")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let store = TatwoPreferenceStore(fileURL: preferencesURL)
        try store.save(
            TatwoUserPreferences(selectedMode: .l, selectedScenario: .trading))

        let probe = LaunchDeviceIdentityProbe()
        let reconcileDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? store.reconcileHostResourceProfileAtLaunch(
                physicalMemoryBytes: 64 * 1024 * 1024 * 1024)
            reconcileDone.signal()
        }

        let hydrated = await TatwoPanelLaunchHydration.resolveOffMainThread(
            snapshotLoader: {
                probe.recordLoaderThread(isMain: Thread.isMainThread)
                let preferences = (try? store.load()) ?? TatwoUserPreferences()
                return TatwoAppSnapshotFactory.make(preferences: preferences)
            },
            modesAuthorityLoader: {
                TatwoModesIssuedAuthorityResolution(
                    contract: nil, integrityState: .noPointer)
            })

        XCTAssertEqual(
            probe.loaderRanOnMainThread, false,
            "併發啟動時，面板側的偏好讀取仍必須在背景 thread")
        XCTAssertEqual(
            hydrated.snapshot.selectedMode, .l,
            "併發 reconcile 不得讓面板讀到殘缺／預設偏好")
        XCTAssertEqual(hydrated.snapshot.selectedScenario, .trading)
        XCTAssertEqual(
            reconcileDone.wait(timeout: .now() + 5), .success,
            "launch reconcile 必須在有界時間內收尾")

        let afterBoth = try store.load()
        XCTAssertEqual(
            afterBoth.selectedMode, .l,
            "reconcile 只准更新 host-resource 欄位，不得覆蓋使用者偏好")
        XCTAssertEqual(afterBoth.selectedScenario, .trading)
        XCTAssertEqual(afterBoth.detectedPhysicalMemoryBytes, 64 * 1024 * 1024 * 1024)
    }

    /// 傳入的快照代表呼叫端已經解析過，hydration 不得再為它開一次檔。
    func testPreloadedSnapshotSkipsAnyFurtherSnapshotDiskWork() async {
        let preloaded = TatwoAppSnapshotFactory.make(
            preferences: TatwoUserPreferences(selectedMode: .xl))
        let snapshotLoaderRan = LaunchDeviceIdentityProbe()

        let hydrated = await TatwoPanelLaunchHydration.resolveOffMainThread(
            preloadedSnapshot: preloaded,
            snapshotLoader: {
                snapshotLoaderRan.markMainRunLoopDrained()
                return TatwoAppSnapshotFactory.make(
                    preferences: TatwoUserPreferences())
            },
            modesAuthorityLoader: {
                TatwoModesIssuedAuthorityResolution(
                    contract: nil, integrityState: .noPointer)
            })

        XCTAssertEqual(hydrated.snapshot.selectedMode, .xl)
        XCTAssertFalse(
            snapshotLoaderRan.mainRunLoopDrained,
            "已預先解析的快照不得再觸發一次磁碟解析")
    }

    /// 原始程式碼契約：render 期不得留下任何同步 fallback，否則 staging 65 會重演。
    func testPanelRenderPathHasNoSynchronousSnapshotFallback() throws {
        let source = try ChatPageSourceScanner.readRelative(
            "\(ChatPageSourceScanner.sourcesDirectory)/AppShell.swift",
            repoRoot: repoRoot)

        let initStart = try XCTUnwrap(
            source.range(of: "private struct TatwoHydratedPanelView: View {")?
                .upperBound)
        let initBody = String(source[initStart...].prefix(3_000))

        XCTAssertFalse(
            initBody.contains("initialSnapshot ?? TatwoAppSnapshotFactory.makeCurrent()"),
            "TatwoHydratedPanelView.init 不得再有同步快照 fallback")
        XCTAssertFalse(
            initBody.contains("TatwoPanelModesInitialAuthority.resolve()"),
            "TatwoHydratedPanelView.init 不得再同步解析 Modes 授權")
        XCTAssertTrue(
            initBody.contains("initialSnapshot: TatwoAppSnapshot,"),
            "快照必須是必填參數，讓 render 期同步 I/O 在編譯期就無法重現")
        XCTAssertTrue(
            initBody.contains(
                "initialModesAuthority: TatwoModesIssuedAuthorityResolution,"),
            "Modes 授權必須是必填參數")

        let panelStart = try XCTUnwrap(
            source.range(of: "struct TatwoPanelView: View {")?.upperBound)
        let panelBody = String(source[panelStart...].prefix(4_500))
        XCTAssertTrue(
            panelBody.contains("TatwoPanelLaunchHydration.resolveOffMainThread("),
            "面板必須走背景 hydration seam")
        // 2026-08-28（staging 66）：first-frame shell 只保留給 `resolving`；
        // 逾時必須改走可見的 storageUnavailable，不得停在空白。
        XCTAssertTrue(
            panelBody.contains("case .resolving:"),
            "hydration 未完成前必須留在 first-frame shell，不得同步等待磁碟")
        XCTAssertTrue(
            panelBody.contains("case let .storageUnavailable(report):"),
            "逾時必須有可見的失敗狀態，空白第一幀必須有界")
    }

    /// 偏好讀取本身：啟動期同一個檔案被併發開啟，`load()` 不得做兩次 `open()`。
    func testPreferenceLoadUsesASingleOpenAndStillDefaultsWhenAbsent() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let missing = TatwoPreferenceStore(
            fileURL: scratch.appendingPathComponent("preferences.json"))

        XCTAssertEqual(try missing.load().selectedMode, TatwoUserPreferences().selectedMode)

        let source = try ChatPageSourceScanner.readRelative(
            "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/Persistence.swift",
            repoRoot: repoRoot)
        let loadStart = try XCTUnwrap(
            source.range(of: "public func load() throws -> TatwoUserPreferences {")?
                .upperBound)
        let loadBody = String(source[loadStart...].prefix(600))
        XCTAssertFalse(
            loadBody.contains("FileManager.default.fileExists"),
            "load() 不得在 Data(contentsOf:) 之前再開一次檔")
    }
}
