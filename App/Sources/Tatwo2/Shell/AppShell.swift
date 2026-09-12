// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift；改動 13 行（原因：run A 照搬，僅移除舊水電 import／呼叫並接同名 Facade）
import SwiftUI
import AppKit
import Combine
import Darwin

enum TatwoAppSurfaceKind {
    case panel
    case window
}

enum TatwoLaunchSurfacePolicy {
    static func defaultSurface(from env: [String: String] = ProcessInfo.processInfo.environment) -> TatwoAppSurfaceKind {
        if env["TATWO_ULTRAWORK_AUTOSHOW_WINDOW"] == "1" { return .window }
        if env["TATWO_ULTRAWORK_AUTOSHOW_PANEL"] == "1" { return .panel }
        if env["TATWO_ULTRAWORK_DEFAULT_SURFACE"] == "panel" { return .panel }
        if env["TATWO_ULTRAWORK_DEFAULT_SURFACE"] == "window" { return .window }
        // Finder / Spotlight / `open app` should never look broken. The status
        // item remains the compact Codex Switch style entry; direct app launch
        // opens the full Work OS management window so the user can immediately
        // see, close, type into, and move it like a normal app.
        return .window
    }

    static func initialActivationPolicy(from env: [String: String] = ProcessInfo.processInfo.environment) -> NSApplication.ActivationPolicy {
        defaultSurface(from: env) == .panel ? .accessory : .regular
    }

    static func shouldReturnToAccessoryAfterWindowClose(from env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["TATWO_ULTRAWORK_KEEP_REGULAR_POLICY"] != "1" && defaultSurface(from: env) == .panel
    }
}

enum TatwoAppSurfaceMetrics {
    static let panelSize = NSSize(width: 520, height: 620)
    static let windowSize = NSSize(width: 1220, height: 980)
    static let compactWindowSize = NSSize(width: 520, height: 760)
    static let windowMinSize = NSSize(width: 480, height: 600)
    static let compactWindowMinSize = windowMinSize

    static func safeWindowSize(for screen: NSScreen? = NSScreen.main) -> NSSize {
        safeSize(windowSize, minimum: windowMinSize, screen: screen, horizontalInset: 160, verticalInset: 80)
    }

    static func safeCompactWindowSize(for screen: NSScreen? = NSScreen.main) -> NSSize {
        safeSize(compactWindowSize, minimum: compactWindowMinSize, screen: screen, horizontalInset: 96, verticalInset: 72)
    }

    static func windowSize(for page: TatwoPage, screen: NSScreen? = NSScreen.main) -> NSSize {
        page.prefersLargeWindow ? safeWindowSize(for: screen) : safeCompactWindowSize(for: screen)
    }

    static func exportWindowSize(for page: TatwoPage) -> NSSize {
        page.prefersLargeWindow ? windowSize : compactWindowSize
    }

    static func minimumWindowSize(for _: TatwoPage) -> NSSize {
        windowMinSize
    }

    private static func safeSize(
        _ preferred: NSSize,
        minimum: NSSize,
        screen: NSScreen?,
        horizontalInset: CGFloat,
        verticalInset: CGFloat
    ) -> NSSize {
        let visible = screen?.visibleFrame.size ?? windowSize
        return NSSize(
            width: min(preferred.width, max(minimum.width, visible.width - horizontalInset)),
            height: min(preferred.height, max(minimum.height, visible.height - verticalInset))
        )
    }
}

struct TatwoSurfaceKindEnvironmentKey: EnvironmentKey {
    static let defaultValue: TatwoAppSurfaceKind = .panel
}

extension EnvironmentValues {
    var tatwoSurfaceKind: TatwoAppSurfaceKind {
        get { self[TatwoSurfaceKindEnvironmentKey.self] }
        set { self[TatwoSurfaceKindEnvironmentKey.self] = newValue }
    }
}

extension Notification.Name {
    static let tatwoOpenWorkOSWindow = Notification.Name("tatwoOpenWorkOSWindow")
    static let tatwoCloseWorkOSWindow = Notification.Name("tatwoCloseWorkOSWindow")
    static let tatwoOpenStatusPanel = Notification.Name("tatwoOpenStatusPanel")
    /// 從 TATWO OS 選單「額度」叫出額度條的 Live quota popover（不開工具列面板）。
    static let tatwoShowLiveQuotaPopover = Notification.Name("tatwoShowLiveQuotaPopover")
    static let tatwoCloseStatusPanel = Notification.Name("tatwoCloseStatusPanel")
    static let tatwoStatusPanelSelectPage = Notification.Name("tatwoStatusPanelSelectPage")
    static let tatwoWorkOSPageDidChange = Notification.Name("tatwoWorkOSPageDidChange")
    static let tatwoWorkOSSelectPage = Notification.Name("tatwoWorkOSSelectPage")
    static let tatwoExternalReopenRequested = Notification.Name("com.tatwo.ultrawork.externalReopenRequested")
    static let tatwoChatSelectMode = Notification.Name("tatwoChatSelectMode")
    /// 工程 B 一鍵授權：object=String（mcp__ 工具名），寫入 per-thread allowlist 下一輪生效。
    static let tatwoChatAllowMCPTool = Notification.Name("tatwoChatAllowMCPTool")
    static let tatwoChatAnswerPlanQuestion = Notification.Name(
        "tatwoChatAnswerPlanQuestion")
}

enum TatwoNewChatShortcutCatalog {
    // Codex.app 26.814.41407 exposes both bindings for its `newTask`
    // command. Keep both so either muscle-memory path opens one Tatwo chat.
    static let primaryKeyEquivalent = "n"
    static let primaryModifierFlags: NSEvent.ModifierFlags = [.command]
    static let alternateKeyEquivalent = "o"
    static let alternateModifierFlags: NSEvent.ModifierFlags = [
        .command,
        .shift,
    ]

    static func matchesAlternate(_ event: NSEvent) -> Bool {
        matchesAlternate(
            keyEquivalent: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags)
    }

    static func matchesAlternate(
        keyEquivalent: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let shortcutModifiers = modifierFlags.intersection([
            .command,
            .shift,
            .option,
            .control,
        ])
        return keyEquivalent?.lowercased() == alternateKeyEquivalent
            && shortcutModifiers == alternateModifierFlags
    }
}

@MainActor
final class TatwoNewChatCommandCenter {
    static let shared = TatwoNewChatCommandCenter()

    private static var userOwnedRequestDepth = 0
    private var registration: (id: UUID, action: () -> Void)?
    private var pendingRequestCount = 0

    static var isDispatchingUserOwnedRequest: Bool {
        userOwnedRequestDepth > 0
    }

    func register(_ action: @escaping () -> Void) -> UUID {
        let id = UUID()
        registration = (id, action)
        let requestsToDrain = pendingRequestCount
        pendingRequestCount = 0
        for _ in 0..<requestsToDrain {
            Self.performUserOwnedRequest(action)
        }
        return id
    }

    func unregister(_ id: UUID) {
        guard registration?.id == id else { return }
        registration = nil
    }

    func request() {
        guard let action = registration?.action else {
            pendingRequestCount += 1
            return
        }
        Self.performUserOwnedRequest(action)
    }

    private static func performUserOwnedRequest(_ action: () -> Void) {
        userOwnedRequestDepth += 1
        defer { userOwnedRequestDepth -= 1 }
        action()
    }
}

enum TatwoUltraworkMacApp {
    @MainActor
    static func main() {
        ChatNativeSubscriptionEnvironment
            .scrubCurrentProcessCredentials()
        TatwoLaunchEnvironmentGuard.sanitizeInheritedExternalVolumeEnvironment()
        TatwoLaunchEnvironmentGuard.moveWorkingDirectoryOffExternalVolumes()
        // 2026-08-27：先讓程序成為可見的 GUI app，TCC 之類的同步同意流程才有
        // 機會顯示；啟動期磁碟 reconcile 移到 NSApplication 之後且有界。
        let application: NSApplication = TatwoCEFApplication.shared
        application.setActivationPolicy(TatwoLaunchSurfacePolicy.initialActivationPolicy())
        TatwoLaunchEnvironmentGuard.configureHostResourceGovernorAtLaunch()
        if TatwoPanelSnapshotExporter.exportIfRequested() { return }
        if TatwoSingleInstanceGuard.forwardToExistingInstanceAndExitIfNeeded() { return }
        let delegate = TatwoUltraworkAppDelegate()
        retainedTatwoAppDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}

enum TatwoSingleInstanceGuard {
    static func forwardToExistingInstanceAndExitIfNeeded() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let siblings = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
            .sorted { left, right in
                switch (left.launchDate, right.launchDate) {
                case let (leftDate?, rightDate?): return leftDate < rightDate
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return left.processIdentifier < right.processIdentifier
                }
            }

        guard let existing = siblings.first else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            .tatwoExternalReopenRequested,
            object: bundleID,
            userInfo: ["sourcePID": "\(currentPID)"],
            deliverImmediately: true)
        existing.activate(options: [])
        return true
    }

    static func registerExternalReopenObserver(_ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        let bundleID = Bundle.main.bundleIdentifier
        return DistributedNotificationCenter.default().addObserver(
            forName: .tatwoExternalReopenRequested,
            object: bundleID,
            queue: .main
        ) { _ in
            Task { @MainActor in
                handler()
            }
        }
    }
}

enum TatwoLaunchEnvironmentGuard {
    /// staging bundle 明示的隔離根。非 staging（正式 App）一律為 nil。
    static func stagingScratchHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let value = environment["TATWO_STAGING_SCRATCH_HOME"],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    static func sanitizeInheritedExternalVolumeEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        // 2026-08-27：staging 的 /Volumes 路徑是刻意的隔離根，不是誤繼承的
        // shell 環境。若改寫成真實家目錄，CODEX_HOME 會被導回正式 ~/.codex，
        // 破壞 staging 隔離，所以 staging 直接跳過改寫。
        guard stagingScratchHome(environment: environment) == nil else { return }
        let home = NSHomeDirectory()
        let replacements = [
            ("PWD", home),
            ("OLDPWD", home),
            ("CODEX_HOME", "\(home)/.codex")
        ]
        for (key, fallback) in replacements {
            guard let value = environment[key],
                  value.hasPrefix("/Volumes/")
            else { continue }
            setenv(key, fallback, 1)
        }
    }

    static func moveWorkingDirectoryOffExternalVolumes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let currentPath = FileManager.default.currentDirectoryPath
        guard currentPath.hasPrefix("/Volumes/") else { return }
        let destination = stagingScratchHome(environment: environment) ?? NSHomeDirectory()
        _ = FileManager.default.changeCurrentDirectoryPath(destination)
    }

    /// M3a 更新：App 可能被同步到不同 RAM 的 Mac，故每次啟動重新偵測，
    /// 寫回既有 Application Support preferences，並套用 storage override。
    ///
    /// 2026-08-27：LaunchServices 啟動的 staging bundle，其 state root 位於
    /// 外接卷，首次 open() 會被 TCC 同意流程同步擋住。這段原本跑在
    /// `NSApplication.shared` 之前的 main thread，因此程序永遠到不了第一幀，
    /// 連 AppleEvent 啟動都逾時。改成背景執行＋有界等待：磁碟正常時行為與
    /// 原本同步版本相同；逾時就先進入第一幀，讓 reconcile 在背景收尾。
    /// `TatwoRuntimeGovernor.shared` 本來就以偵測到的實體記憶體初始化，
    /// 所以逾時 fallback 不會讓 governor 停在錯誤等級，只是 override 晚一點套用。
    static func configureHostResourceGovernorAtLaunch(
        timeout: DispatchTimeInterval = .milliseconds(1_500)
    ) {
        let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            if let profile = try? TatwoPreferenceStore.defaultStore()
                .reconcileHostResourceProfileAtLaunch(
                    physicalMemoryBytes: physicalMemoryBytes)
            {
                TatwoRuntimeGovernor.shared.configure(tier: profile.effectiveTier)
            }
            completed.signal()
        }
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            fputs("tatwo_host_resource_reconcile=deferred reason=launch_io_timeout\n", stderr)
        }
    }
}

/// 啟動期的本機裝置身分解析（`<state root>/local-device-id`）。
///
/// 2026-08-27（staging 59 證據）：`applicationDidFinishLaunching` 原本同步呼叫
/// `TatwoDeviceSnapshotProducer.loadOrCreateLocalDeviceID`，那支會 read 並在缺檔時
/// `Data.write(..., .atomic)`。staging 的 state root 位於 `/Volumes`，第一次開檔會
/// 同步卡在 `open()`，於是 `applicationDidFinishLaunching` 不回、
/// `-[NSApplication _handleAEOpenEvent:]` 不回、LaunchServices AppleEvent 逾時、
/// 第一幀不出現（sample: main thread 停在 `__open`）。
///
/// 這個 seam 讓 main thread 只做記憶體內判斷：磁碟工作一律在背景 queue，解析完成
/// 才回到 main actor 安裝 pressure runtime。監控與裝置身分都沒有被停用，只是改成
/// 「儲存可用時才啟動」，並且仍寫在解析到的 state root（staging 維持隔離）。
enum TatwoLaunchDeviceIdentity {
    static let environmentOverrideKey = "TATWO_ULTRAWORK_DEVICE_ID"

    /// 環境變數指定的 device id。純記憶體判斷，永遠不碰磁碟。
    static func explicitDeviceID(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment[environmentOverrideKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return raw
    }

    /// 一律在 `queue` 上做磁碟解析；呼叫端 `await` 期間 main thread 可以繼續跑
    /// run loop，因此第一幀與 AppleEvent 不會被外接卷的 `open()` 擋住。
    static func resolveOffMainThread(
        stateRootURL: URL,
        queue: DispatchQueue = .global(qos: .utility),
        loader: @escaping @Sendable (URL) -> String = { url in
            TatwoDeviceSnapshotProducer
                .loadOrCreateLocalDeviceID(stateRootURL: url)
                .deviceID
        }
    ) async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: loader(stateRootURL))
            }
        }
    }
}

/// 啟動期的面板 hydration（App 快照＋Modes 已發布授權）。
///
/// 2026-08-28（staging 65 sample）：main thread 停在
/// `TatwoPanelView.body` → `TatwoHydratedPanelView.init` →
/// `TatwoAppSnapshotFactory.makeCurrent` → `TatwoPreferenceStore.load` →
/// `Data(contentsOf:)` → `__open`，同一時間
/// `TatwoLaunchEnvironmentGuard.configureHostResourceGovernorAtLaunch` 的背景
/// reconcile 也停在同一支 `__open`。啟動期 reconcile 已經改成有界等待，但
/// SwiftUI render 又在 main thread 上重新同步開了同一個外接卷檔案，於是第一幀
/// 再次卡死；main thread 被 `open()` 佔住時，外接卷的 TCC 同意流程也沒有 run
/// loop 可以顯示，形成永久等待。
///
/// 這個 seam 讓 SwiftUI 的 body/init 只做記憶體內組裝：快照與 Modes 授權一律在
/// 背景 queue 解析，解析完成才切換到 hydrated 面板。內容沒有被停用，也沒有改讀
/// 別的來源，只是延後到儲存可用時（staging 隔離根不變）。
/// 啟動期儲存無法取用時的可見報告。
///
/// 2026-08-28（staging 66 tccd 實證，msgID=436.41357）：staging 的 runtime root
/// 與 Chat workdir 位在 `<your-volume>`（APFS over USB），macOS 因此對它強制
/// `kTCCServiceSystemPolicyRemovableVolumes`。bundle 的 Info.plist 沒有
/// `NSRemovableVolumesUsageDescription`，tccd 記下
/// `No usage string found (key:NSRemovableVolumesUsageDescription)`、
/// `usage description: (null)` 後仍進入 `display_prompt`／`AUTHREQ_PROMPTING`，
/// 而同意面板沒有即時出現。sandboxd 的 `TCCAccessRequest` 是同步且沒有 timeout 的，
/// 它就是壓住 kernel `open()` 的那一層，於是三支啟動讀檔全部停在 `__open`
/// 172 秒（00:59:56.703 → 01:02:48.880 才 `AUTHREQ_RESULT authValue=2`）。
///
/// 這個型別只做純記憶體的路徑分類，不碰磁碟，讓「儲存被擋住」變成可測、可顯示的
/// 狀態，而不是無限空白。
struct TatwoLaunchStorageBlockReport: Sendable, Equatable {
    /// 依 App 實際讀取順序列出的執行階段根目錄。
    let blockedPaths: [String]
    /// 是否落在會觸發卸除式卷宗同意流程的 `/Volumes` 之下。
    let isRemovableVolumePath: Bool
    /// 已等待秒數（顯示用，非判斷依據）。
    let waitedSeconds: Double

    static let removableVolumePathPrefix = "/Volumes/"

    /// 純函式：只讀環境變數字串，不 stat、不 open，因此在測試中完全決定性。
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        waitedSeconds: Double
    ) -> TatwoLaunchStorageBlockReport {
        var paths: [String] = []
        for key in [
            "TATWO_ULTRAWORK_STATE_DIR",
            "TATWO_ULTRAWORK_APP_SUPPORT",
            "TATWO_ULTRAWORK_CHAT_WORKDIR",
        ] {
            guard let raw = environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty, !paths.contains(raw)
            else { continue }
            paths.append(raw)
        }
        return TatwoLaunchStorageBlockReport(
            blockedPaths: paths,
            isRemovableVolumePath: paths.contains {
                $0.hasPrefix(removableVolumePathPrefix)
            },
            waitedSeconds: waitedSeconds)
    }

    var title: String {
        isRemovableVolumePath
            ? "外接卷取用尚未授權"
            : "執行階段儲存尚未就緒"
    }

    /// 使用者可以照做的下一步。外接卷情境明確指向 TCC 同意，而不是「請稍候」。
    var guidance: String {
        if isRemovableVolumePath {
            return """
                執行階段資料在卸除式卷宗上，macOS 需要一次「檔案與檔案夾／卸除式卷宗」\
                授權。若系統詢問視窗出現，請按「允許」；若沒有出現，請到\
                系統設定 → 隱私權與安全性 → 檔案與檔案夾，允許本 App 存取卸除式卷宗。\
                授權完成後本頁會自動繼續，不需要重新啟動。
                """
        }
        return """
            無法讀取執行階段儲存位置。請確認磁碟已掛載且可讀，再按「重試」。\
            本 App 不會改用預設或空白狀態。
            """
    }
}

/// 第一幀 hydration 的三種可見狀態。`resolving` 必須是有界的：逾時後一定要走到
/// `storageUnavailable`，不得停在空白 shell。
enum TatwoPanelLaunchState: Sendable {
    case resolving
    case hydrated(TatwoPanelLaunchHydration)
    case storageUnavailable(TatwoLaunchStorageBlockReport)

    /// 契約：只有 `resolving` 允許渲染空白第一幀。
    var rendersBlankFirstFrame: Bool {
        if case .resolving = self { return true }
        return false
    }
}

/// 第一幀 hydration 的協調器：一次背景解析、有界等待、可自癒。
///
/// 關鍵約束：被 TCC 擋住的 `open()` **無法取消**。所以「重試」絕對不能再開一支
/// 新的解析（會累積永久阻塞的執行緒）。這裡只保留單一 in-flight 解析：逾時先把
/// UI 切到可見的失敗／重試狀態，背景那支解析仍在等；使用者同意後它自己回來，
/// 畫面就自動 hydrate，不需要再點一次。
@MainActor
final class TatwoPanelLaunchCoordinator: ObservableObject {
    @Published private(set) var state: TatwoPanelLaunchState = .resolving {
        didSet { onStateChange?(state) }
    }
    /// 測試用觀察點：讓狀態轉換可以被 `XCTestExpectation` 精準等待，
    /// 不必靠 sleep 猜排程時機。production 一律為 nil。
    var onStateChange: (@MainActor @Sendable (TatwoPanelLaunchState) -> Void)?
    /// 已啟動的背景解析次數。測試用來釘住「重試不得重複開檔」。
    private(set) var resolveAttemptCount = 0
    private(set) var retryCount = 0

    private let environment: [String: String]
    private let resolver: @Sendable () async -> TatwoPanelLaunchHydration
    private let deadlineTick: @Sendable () async -> Void
    private let deadlineSeconds: Double
    private var isResolveInFlight = false
    private var deadlineTask: Task<Void, Never>?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        deadlineSeconds: Double = 6,
        resolver: @escaping @Sendable () async -> TatwoPanelLaunchHydration,
        deadlineTick: (@Sendable () async -> Void)? = nil
    ) {
        self.environment = environment
        self.deadlineSeconds = deadlineSeconds
        self.resolver = resolver
        let seconds = deadlineSeconds
        self.deadlineTick = deadlineTick ?? {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    func start() {
        guard case .resolving = state else { return }
        armDeadline()
        guard !isResolveInFlight else { return }
        isResolveInFlight = true
        resolveAttemptCount += 1
        Task { [resolver] in
            let hydration = await resolver()
            self.finish(with: hydration)
        }
    }

    /// 重試只做兩件事：把畫面切回 resolving、重新開始倒數。永遠不新增解析。
    func retry() {
        retryCount += 1
        if case .hydrated = state { return }
        state = .resolving
        armDeadline()
        guard !isResolveInFlight else { return }
        isResolveInFlight = true
        resolveAttemptCount += 1
        Task { [resolver] in
            let hydration = await resolver()
            self.finish(with: hydration)
        }
    }

    private func armDeadline() {
        deadlineTask?.cancel()
        let waited = deadlineSeconds
        deadlineTask = Task { [deadlineTick] in
            await deadlineTick()
            guard !Task.isCancelled else { return }
            self.expireDeadline(waitedSeconds: waited)
        }
    }

    private func expireDeadline(waitedSeconds: Double) {
        guard case .resolving = state else { return }
        state = .storageUnavailable(
            TatwoLaunchStorageBlockReport.make(
                environment: environment, waitedSeconds: waitedSeconds))
        fputs(
            "tatwo_launch_storage=unavailable reason=launch_io_deadline "
                + "waited_seconds=\(waitedSeconds)\n",
            stderr)
    }

    private func finish(with hydration: TatwoPanelLaunchHydration) {
        isResolveInFlight = false
        deadlineTask?.cancel()
        deadlineTask = nil
        if case .hydrated = state { return }
        state = .hydrated(hydration)
    }
}

struct TatwoPanelLaunchHydration: Sendable {
    let snapshot: TatwoAppSnapshot
    let modesAuthority: TatwoModesIssuedAuthorityResolution

    /// 一律在 `queue` 上做磁碟解析；呼叫端 `await` 期間 main thread 可以繼續跑
    /// run loop，因此第一幀、AppleEvent 與 TCC 同意流程不會被外接卷的 `open()` 擋住。
    static func resolveOffMainThread(
        preloadedSnapshot: TatwoAppSnapshot? = nil,
        queue: DispatchQueue = .global(qos: .userInitiated),
        snapshotLoader: @escaping @Sendable () -> TatwoAppSnapshot = {
            TatwoAppSnapshotFactory.makeCurrent()
        },
        modesAuthorityLoader: @escaping @Sendable ()
            -> TatwoModesIssuedAuthorityResolution = {
            TatwoPanelModesInitialAuthority.resolve()
        }
    ) async -> TatwoPanelLaunchHydration {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: TatwoPanelLaunchHydration(
                        snapshot: preloadedSnapshot ?? snapshotLoader(),
                        modesAuthority: modesAuthorityLoader()))
            }
        }
    }
}

@MainActor
enum TatwoPanelSnapshotExporter {
    static func exportIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let graphPath = env["TATWO_ULTRAWORK_EXPORT_WORKFLOW_GRAPH"] {
            do {
                try exportWorkflowGraph(to: URL(fileURLWithPath: graphPath), env: env)
                fputs("tatwo_workflow_graph_snapshot=\(graphPath)\n", stderr)
            } catch {
                fputs("tatwo_workflow_graph_snapshot_failed=\(TatwoPrivacyRedactor.redacted(error.localizedDescription))\n", stderr)
            }
            return true
        }

        let panelPath = env["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"]
        let windowPath = env["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"]
        guard let path = windowPath ?? panelPath else {
            return false
        }
        let surface: TatwoAppSurfaceKind = (windowPath != nil || env["TATWO_ULTRAWORK_EXPORT_SURFACE"] == "window") ? .window : .panel
        do {
            try export(to: URL(fileURLWithPath: path), surface: surface)
            fputs("tatwo_\(surface == .window ? "window" : "panel")_snapshot=\(path)\n", stderr)
        } catch {
            fputs("tatwo_snapshot_failed=\(TatwoPrivacyRedactor.redacted(error.localizedDescription))\n", stderr)
        }
        return true
    }

    private static func export(to url: URL, surface: TatwoAppSurfaceKind) throws {
        let env = ProcessInfo.processInfo.environment
        let exportPage = TatwoPage.initialSelection
        let defaultSize = surface == .window
            ? TatwoAppSurfaceMetrics.exportWindowSize(for: exportPage)
            : TatwoAppSurfaceMetrics.panelSize
        let size = exportSizeOverride(env: env, fallback: defaultSize)
        let liveGatewayStatus = env["TATWO_ULTRAWORK_EXPORT_LIVE_GATEWAY"] == "1"
            ? TatwoGatewayLiveProbe.fetchSynchronously(environment: env)
            : nil
        let snapshot = TatwoAppSnapshotFactory.makeCurrent(
            environment: env,
            gatewayLiveStatus: liveGatewayStatus
        )
        let liveQuota = liveQuotaSnapshotIfRequested(env: env, appSnapshot: snapshot)
        let chatModel =
            TatwoChatProcessCompositionRegistry.chatPageModel(
                appMCPRuntimeProvider: {
                    TatwoAppMCPRuntimeRegistry.state
                })
        let view = NSHostingView(
            rootView: TatwoHydratedPanelView(
                chatModel: chatModel,
                surface: surface,
                initialSelection: exportPage,
                initialSnapshot: snapshot,
                // headless 匯出本來就是同步流程（沒有互動 run loop 要保護），
                // 這裡照舊在呼叫端一次解析完再交給 view。
                initialModesAuthority: TatwoPanelModesInitialAuthority.resolve(
                    environment: env),
                initialLiveQuotaSnapshot: liveQuota))
        if env["TATWO_ULTRAWORK_EXPORT_APPEARANCE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "dark"
        {
            view.appearance = NSAppearance(named: .darkAqua)
        }
        let settleMilliseconds = env["TATWO_ULTRAWORK_EXPORT_ASYNC_SETTLE_MS"].flatMap(Int.init) ?? 0
        let scale = exportScaleOverride(env: env)
        try exportHostingView(
            view,
            size: size,
            scale: scale,
            to: url,
            settleMilliseconds: settleMilliseconds)
    }

    private static func exportWorkflowGraph(to url: URL, env: [String: String]) throws {
        let snapshot = TatwoAppSnapshotFactory.makeCurrent(environment: env)
        let goalRunStore = TatwoGoalRunStore.default(environment: env)
        let contract = try resolveWorkflowGraphContract(
            snapshot: snapshot,
            goalRunStore: goalRunStore,
            sessionStore: TatwoSessionStore(directoryURL: goalRunStore.directoryURL),
            environment: env
        )
        let size = NSSize(width: WorkOSPlanLoopsGoalMetrics.width, height: WorkOSPlanLoopsGoalMetrics.height)
        let view = NSHostingView(rootView: WorkOSPlanLoopsGoalCycleMap(contract: contract))
        try exportHostingView(view, size: size, to: url)
    }

    /// Resolve the workflow graph from the same validated current-session projection used
    /// by the App snapshot. A missing pointer may use a pure preview; an existing invalid
    /// pointer throws so export cannot manufacture a clean-looking replacement graph.
    static func resolveWorkflowGraphContract(
        snapshot: TatwoAppSnapshot,
        goalRunStore: TatwoGoalRunStore,
        sessionStore: TatwoSessionStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        scenarioBook: TatwoScenarioConfigBookV1? = nil
    ) throws -> TatwoWorkOSContractV1 {
        let resolvedScenarioBook =
            scenarioBook
            ?? TatwoScenarioConfigStore.loadDefaultStaging(environment: environment)
        if let attachment = try sessionStore.inspectCurrent(
            scenarioBook: resolvedScenarioBook,
            goalStore: goalRunStore
        ) {
            return attachment.contract
        }
        return try WorkOSFactory.preview(
            mode: snapshot.selectedMode,
            scenarioProfileID: scenarioProfileID(for: snapshot.selectedScenario),
            objective: "Workflow graph snapshot",
            scenarioBook: resolvedScenarioBook
        )
    }

    private static func exportHostingView(
        _ view: NSHostingView<some View>,
        size: NSSize,
        scale: CGFloat = 1,
        to url: URL,
        settleMilliseconds: Int = 0
    ) throws {
        view.frame = NSRect(origin: .zero, size: size)
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        if settleMilliseconds > 0 {
            try primeAsyncContent(in: view)
            let boundedMilliseconds = boundedAsyncSettleMilliseconds(settleMilliseconds)
            let deadline = Date().addingTimeInterval(TimeInterval(boundedMilliseconds) / 1_000)
            while Date() < deadline {
                RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
                view.layoutSubtreeIfNeeded()
            }
        }

        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            throw NSError(domain: "TatwoPanelSnapshotExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "bitmap unavailable"])
        }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "TatwoPanelSnapshotExporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "png encoding unavailable"])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func primeAsyncContent(in view: NSView) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(
                domain: "TatwoPanelSnapshotExporter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "priming bitmap unavailable"]
            )
        }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
    }

    static func boundedAsyncSettleMilliseconds(_ requested: Int) -> Int {
        max(0, min(requested, 30_000))
    }

    nonisolated static func exportScaleOverride(env: [String: String]) -> CGFloat {
        guard let raw = env["TATWO_ULTRAWORK_EXPORT_SCALE"],
              let parsed = Double(raw),
              parsed.isFinite
        else { return 1 }
        return CGFloat(max(1, min(4, parsed)))
    }

    private static func scenarioProfileID(for scenario: ScenarioID) -> String {
        switch scenario {
        case .daily: "daily"
        case .design: "ui-ux"
        case .coding: "coding"
        case .trading: "trading-risk"
        case .modeling: "modeling"
        }
    }

    private static func exportSizeOverride(env: [String: String], fallback: NSSize) -> NSSize {
        let width = env["TATWO_ULTRAWORK_EXPORT_WIDTH"].flatMap(Double.init).map { CGFloat($0) } ?? fallback.width
        let height = env["TATWO_ULTRAWORK_EXPORT_HEIGHT"].flatMap(Double.init).map { CGFloat($0) } ?? fallback.height
        return NSSize(
            width: max(360, min(2600, width)),
            height: max(360, min(3600, height))
        )
    }

    private static func liveQuotaSnapshotIfRequested(
        env: [String: String],
        appSnapshot: TatwoAppSnapshot
    ) -> LiveQuotaDeckSnapshot? {
        if let fixture = HeaderQuotaSnapshotFixture.make(
            kind: env["TATWO_ULTRAWORK_EXPORT_QUOTA_FIXTURE"],
            providers: appSnapshot.catalog.usageProviders
        ) {
            return fixture
        }
        guard env["TATWO_ULTRAWORK_EXPORT_LIVE_USAGE"] == "1" else { return nil }
        let box = TatwoSnapshotLiveQuotaBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            let snapshot = await TatwoQuotaSnapshotCache.shared.load(
                providers: appSnapshot.catalog.usageProviders)
            box.set(snapshot)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 8.0)
        return box.get()
    }
}

final class TatwoSnapshotLiveQuotaBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: LiveQuotaDeckSnapshot?

    func set(_ snapshot: LiveQuotaDeckSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    func get() -> LiveQuotaDeckSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

@MainActor
var retainedTatwoAppDelegate: TatwoUltraworkAppDelegate?

/// Process-local authority for the App-owned MCP listener.
///
/// Chat consumes this state instead of inferring readiness from an environment
/// variable. A configured port is only intent; `.ready` is published after the
/// socket has actually bound and started listening.
@MainActor
enum TatwoAppMCPRuntimeRegistry {
    private(set) static var state: TatwoAppMCPRuntimeState = .notStarted

    static func markReady(_ endpoint: TatwoAppMCPEndpoint) {
        state = .ready(endpoint)
    }

    static func markFailed(_ reason: String) {
        state = .failed(reason)
    }
}

/// The App resolves its Chat authority and storage roots exactly once.
///
/// Every window, status-bar panel, export surface, and launch-time maintenance
/// action must use this same composition. Re-resolving individual stores at
/// call sites can make a Finder-launched staging bundle fall back to production
/// Application Support even though its remote dispatcher is isolated.
@MainActor
enum TatwoChatProcessCompositionRegistry {
    static let shared = TatwoChatProcessCompositionResolver.resolve()
    private static var sharedChatPageModel: ChatPageModel?

    static func chatPageModel(
        appMCPRuntimeProvider:
            @escaping @MainActor () -> TatwoAppMCPRuntimeState
    ) -> ChatPageModel {
        if let sharedChatPageModel {
            return sharedChatPageModel
        }
        let model = shared.makeChatPageModel(
            appMCPRuntimeProvider: appMCPRuntimeProvider)
        sharedChatPageModel = model
        return model
    }
}

enum TatwoChatLaunchSweepRootResolver {
    static func runtimeRoot(
        for composition: TatwoChatProcessComposition
    ) -> URL {
        composition.storage.chatRuntimeRootURL.standardizedFileURL
    }
}

@MainActor
enum TatwoChatPostFirstFrameLaunchSweep {
    private static var wasScheduled = false

    static func schedule(reason: String) {
        guard !wasScheduled else { return }
        guard ProcessInfo.processInfo.environment[
            "TATWO_ULTRAWORK_EXPORT_TAB"
        ] == nil else { return }
        wasScheduled = true
        Task { @MainActor in
            await Task.yield()
            start(reason: reason)
        }
    }

    private static func start(reason: String) {
        let root = TatwoChatLaunchSweepRootResolver.runtimeRoot(
            for: TatwoChatProcessCompositionRegistry.shared)
        let sweep = TatwoChatCommandPlanner.launchctlSubmitStaleJobSweepLaunch(
            rootPath: root.path,
            uid: "\(getuid())",
            currentAppPID: "\(getpid())")
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let nullInput = FileHandle(forReadingAtPath: "/dev/null")
            let nullOutput = FileHandle(forWritingAtPath: "/dev/null")
            process.executableURL = URL(fileURLWithPath: sweep.executable)
            process.arguments = sweep.arguments
            if let nullInput { process.standardInput = nullInput }
            if let nullOutput {
                process.standardOutput = nullOutput
                process.standardError = nullOutput
            }
            do {
                try process.run()
                fputs(
                    "tatwo_chat_launchctl_sweep=\(reason) pid=\(process.processIdentifier)\n",
                    stderr)
            } catch {
                let safe = TatwoPrivacyRedactor.redacted(
                    error.localizedDescription)
                fputs(
                    "tatwo_chat_launchctl_sweep=degraded \(reason) \(safe)\n",
                    stderr)
            }
        }
    }
}

@MainActor
final class TatwoUltraworkAppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: TatwoStatusBarController?
    private var islandShellController: TatwoIslandShellController?
    private let localMCPServer = TatwoLocalMCPHTTPServer(
        toolCaller: TatwoAppManagementMCP.call)
    private var sparkleUpdateCoordinator: TatwoSparkleUpdateCoordinator?
    private weak var signedUpdateMenuItem: NSMenuItem?
    private var externalReopenObserver: NSObjectProtocol?
    private var alternateNewChatShortcutMonitor: Any?
    private var pressureRuntime: TatwoAppPressureRuntimeV1?
    private var pressureRuntimeGeneration: UInt64?
    private var pressureSensorProvider: TatwoMacPressureSensorProviderV1?
    /// 裝置身分解析是延後的；若磁碟在 app 結束後才回應，不要再裝一個新的 runtime。
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        InAppUpdater.reconcileOnLaunch()
        let upstream = OSUpstreamRefresh.applyOnLaunch()
        fputs("tatwo_os_upstream=\(upstream.logMessage)\n", stderr)
        NSApp.setActivationPolicy(TatwoLaunchSurfacePolicy.initialActivationPolicy())
        installMainMenuWithEditCommands()
        installAlternateNewChatShortcutMonitor()
        startLocalMCPServer()
        startSignedUpdateCoordinator()
        startAppPressureRuntime()
        statusBarController = TatwoStatusBarController()
        islandShellController = TatwoIslandShellController()
        islandShellController?.show()
        externalReopenObserver = TatwoSingleInstanceGuard.registerExternalReopenObserver { [weak self] in
            self?.showDefaultSurfaceForUserOpen()
        }
    }

    /// 這個 app 沒有 SwiftUI App scene 的預設選單，故 Cmd+C/V/X/A/Z 全失效（使用者：聊天輸入無法複製貼上）。
    /// 裝一個含 Edit 群組的主選單，動作 target=nil 走 first responder → 所有 NSTextView/欄位都能複製貼上。
    private func installMainMenuWithEditCommands() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隱藏 Tatwo Ultrawork", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        let updateItem = appMenu.addItem(
            withTitle: "檢查更新…",
            action: #selector(checkForSignedUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.isEnabled = false
        signedUpdateMenuItem = updateItem
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "結束 Tatwo Ultrawork", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "檔案")
        let newChatItem = fileMenu.addItem(
            withTitle: "新聊天",
            action: #selector(requestNewChatFromShortcut(_:)),
            keyEquivalent: TatwoNewChatShortcutCatalog.primaryKeyEquivalent)
        newChatItem.target = self
        newChatItem.keyEquivalentModifierMask =
            TatwoNewChatShortcutCatalog.primaryModifierFlags
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "編輯")
        let undo = editMenu.addItem(withTitle: "復原", action: Selector(("undo:")), keyEquivalent: "z")
        undo.target = nil
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.target = nil
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全選", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let navigateItem = NSMenuItem()
        mainMenu.addItem(navigateItem)
        let navigateMenu = NSMenu(title: "前往")
        let chatItem = navigateMenu.addItem(
            withTitle: "對話",
            action: #selector(openWorkOSPageFromMenu(_:)),
            keyEquivalent: "1")
        chatItem.target = self
        chatItem.representedObject = TatwoPage.chat.rawValue
        let modesItem = navigateMenu.addItem(
            withTitle: "工作模式",
            action: #selector(openWorkOSPageFromMenu(_:)),
            keyEquivalent: "2")
        modesItem.target = self
        modesItem.representedObject = TatwoPage.modes.rawValue
        navigateItem.submenu = navigateMenu

        NSApp.mainMenu = mainMenu
    }

    private func installAlternateNewChatShortcutMonitor() {
        guard alternateNewChatShortcutMonitor == nil else { return }
        alternateNewChatShortcutMonitor =
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard TatwoNewChatShortcutCatalog.matchesAlternate(event)
                else { return event }
                self?.requestNewChatFromShortcut(nil)
                return nil
            }
    }

    @objc
    private func requestNewChatFromShortcut(_ sender: Any?) {
        NotificationCenter.default.post(
            name: .tatwoOpenWorkOSWindow,
            object: TatwoPage.chat.rawValue)
        TatwoNewChatCommandCenter.shared.request()
    }

    @objc
    private func openWorkOSPageFromMenu(_ sender: NSMenuItem) {
        guard let rawPage = sender.representedObject as? String,
              TatwoPage(rawValue: rawPage) != nil
        else { return }
        NotificationCenter.default.post(
            name: .tatwoOpenWorkOSWindow,
            object: rawPage)
    }

    @objc
    private func checkForSignedUpdates(_ sender: Any?) {
        sparkleUpdateCoordinator?.checkForUpdatesFromUser()
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        sparkleUpdateCoordinator?.stop()
        if let alternateNewChatShortcutMonitor {
            NSEvent.removeMonitor(alternateNewChatShortcutMonitor)
            self.alternateNewChatShortcutMonitor = nil
        }
        let runtime = pressureRuntime
        TatwoAppPressureRuntimeRegistry.clear(generation: pressureRuntimeGeneration)
        pressureRuntime = nil
        pressureRuntimeGeneration = nil
        pressureSensorProvider = nil
        Task {
            await runtime?.stop(reason: .appWillTerminate)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDefaultSurfaceForUserOpen()
        return true
    }

    /// Cmd+Q／選單「結束」的二次確認閘。loops 進行中直接關掉 app，派工會整批消失。
    ///
    /// 用 `.terminateLater` 而不是在這裡同步跑 modal：AppKit 正在收束終止流程時再開一個
    /// modal run loop 容易踩到重入，先讓 delegate 回覆「稍後再說」，下一輪 run loop 才問人。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // AppKit termination callback 絕對不能同步讀 registry。staging 的 registry
        // 位於外接卷時，macOS TCC 可以把 open() 無期限卡住，導致 Cmd+Q 連確認框
        // 都出不來。這裡只讀 monitor 已在背景發布的 process-local 快照；最多落後
        // 一個 5 秒 poll interval，寧可多顯示一次確認，也不能把主執行緒鎖死。
        let snapshot = TatwoLoopsActivityMonitor.terminationSnapshot()
        guard TatwoInterruptGate.decision(kind: .appTerminate, snapshot: snapshot)
            .requiresConfirmation
        else { return .terminateNow }

        DispatchQueue.main.async {
            let confirmed = TatwoInterruptConfirmationPresenter.confirm(
                kind: .appTerminate,
                snapshot: snapshot,
                window: NSApp.keyWindow)
            NSApp.reply(toApplicationShouldTerminate: confirmed)
        }
        return .terminateLater
    }

    private func showDefaultSurfaceForUserOpen() {
        NSApp.activate(ignoringOtherApps: true)
        statusBarController?.showDefaultSurfaceForUserOpen()
    }

    /// 只做路徑解析與排程，不在 main thread 上開任何 state-root 檔案。
    /// 裝置身分（`local-device-id`）是唯一需要磁碟的輸入，交給
    /// `TatwoLaunchDeviceIdentity.resolveOffMainThread`；解析完成才回到 main actor
    /// 安裝 runtime，因此 `applicationDidFinishLaunching` 可以立刻返回、第一幀先出來。
    private func startAppPressureRuntime() {
        let env = ProcessInfo.processInfo.environment
        let stateRootURL = TatwoGoalRunStore.default(environment: env).directoryURL
        if let explicitDeviceID = TatwoLaunchDeviceIdentity.explicitDeviceID(from: env) {
            installAppPressureRuntime(deviceID: explicitDeviceID)
            return
        }
        fputs("tatwo_pressure_monitor=deferred reason=device_identity_pending\n", stderr)
        Task { [weak self] in
            let deviceID = await TatwoLaunchDeviceIdentity.resolveOffMainThread(
                stateRootURL: stateRootURL)
            self?.installAppPressureRuntime(deviceID: deviceID)
        }
    }

    private func installAppPressureRuntime(deviceID resolvedDeviceID: String) {
        guard !isTerminating, pressureRuntime == nil else { return }
        let sensorProvider = TatwoMacPressureSensorProviderV1.appProcessOwned()
        let sampler = TatwoAppPressureSamplerV1(
            deviceID: resolvedDeviceID,
            provider: sensorProvider.provider()
        )
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: sampler,
            lifecycleReset: TatwoAppPressureRuntimeLifecycleResetV1 {
                await sensorProvider.resetSwapBaselineForLifecycle()
            }
        )
        pressureSensorProvider = sensorProvider
        pressureRuntime = runtime
        pressureRuntimeGeneration = TatwoAppPressureRuntimeRegistry.install(runtime)
        Task {
            await runtime.start(reason: .appLaunch, startTimers: true)
            let loggedDeviceID = await sampler.deviceID
            fputs("tatwo_pressure_monitor=started device=\(loggedDeviceID) lease_ttl=20s\n", stderr)
        }
    }

    private func startLocalMCPServer() {
        let rawPort = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_APP_MCP_PORT"] ?? "17377"
        guard let port = UInt16(rawPort), port != 0 else {
            TatwoAppMCPRuntimeRegistry.markFailed("invalid_configured_port")
            fputs("tatwo_app_mcp=failed reason=invalid_configured_port\n", stderr)
            return
        }
        do {
            let actualPort = try localMCPServer.start(port: port)
            guard actualPort == port,
                  let endpoint = TatwoAppMCPEndpoint.loopback(port: actualPort)
            else {
                TatwoAppMCPRuntimeRegistry.markFailed("listener_endpoint_mismatch")
                fputs("tatwo_app_mcp=failed reason=listener_endpoint_mismatch\n", stderr)
                return
            }
            TatwoAppMCPRuntimeRegistry.markReady(endpoint)
            fputs("tatwo_app_mcp=ready \(endpoint.url.absoluteString)\n", stderr)
        } catch {
            let safe = TatwoPrivacyRedactor.redacted(error.localizedDescription)
            TatwoAppMCPRuntimeRegistry.markFailed(safe)
            fputs("tatwo_app_mcp=failed reason=\(safe)\n", stderr)
        }
    }

    private func startSignedUpdateCoordinator() {
        let coordinator = TatwoSparkleUpdateCoordinator()
        coordinator.start()
        sparkleUpdateCoordinator = coordinator
        switch coordinator.runtimeStatus {
        case .notStarted:
            signedUpdateMenuItem?.isEnabled = false
            fputs("tatwo_signed_update=not_started\n", stderr)
        case .disabled(let reason):
            signedUpdateMenuItem?.isEnabled = false
            fputs("tatwo_signed_update=disabled reason=\(reason.rawValue)\n", stderr)
        case .active(let channel):
            signedUpdateMenuItem?.isEnabled = true
            fputs("tatwo_signed_update=active channel=\(channel.rawValue)\n", stderr)
        }
    }

}

@MainActor
final class TatwoStatusPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, viewController: NSViewController) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.transient, .moveToActiveSpace, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        contentViewController = viewController
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, let scrollView = targetScrollView(for: event) {
            scrollView.scrollWheel(with: event)
            return
        }
        super.sendEvent(event)
    }

    private func targetScrollView(for event: NSEvent) -> NSScrollView? {
        guard let contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard contentView.bounds.contains(point) else { return nil }

        return contentView.recursiveSubviews
            .compactMap { $0 as? NSScrollView }
            .max { lhs, rhs in
                (lhs.bounds.width * lhs.bounds.height) < (rhs.bounds.width * rhs.bounds.height)
            }
    }
}

extension NSView {
    var recursiveSubviews: [NSView] {
        subviews + subviews.flatMap(\.recursiveSubviews)
    }
}


@MainActor
final class TatwoWorkOSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Esc 關窗。注意 `close()` **不會**經過 `windowShouldClose(_:)`（那只有 `performClose:` 才走），
    /// 所以這條路徑必須自己過同一道閘，否則 Esc 就成了繞過確認的後門。
    override func cancelOperation(_ sender: Any?) {
        guard TatwoInterruptConfirmationPresenter.confirm(kind: .escapeClose, window: self) else {
            return
        }
        close()
    }
}

@MainActor
final class TatwoWorkOSWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var themeObservation: AnyCancellable?
    // 2026-08-20 極光 P0：視窗底色第二真相源（0.965/0.965/0.972 硬編碼）
    // 移除。視窗一律透明，底由 TatwoWindowGlassBase 依 active palette 繪製
    // （極光＝behind-window 玻璃、fable5＝canvasBase 牛皮紙實底）。

    func show(page: TatwoPage? = nil) {
        let target = currentOrExistingWindow() ?? makeWindow(initialPage: page)
        window = target
        closeDuplicateWorkOSWindows(keeping: target)
        if ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_PRESERVE_WINDOW_SIZE"] != "1" {
            let initialPage = page ?? TatwoPage.initialSelection
            target.minSize = TatwoAppSurfaceMetrics.minimumWindowSize(for: initialPage)
            target.setContentSize(TatwoAppSurfaceMetrics.windowSize(for: initialPage, screen: target.screen ?? NSScreen.main))
        }
        (target as? TatwoWorkOSWindow)?.layoutTatwoTrafficLights()
        placeNearTopIfNeeded(target)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        target.makeKeyAndOrderFront(nil)
        target.orderFrontRegardless()
        target.makeMain()
        target.makeKey()
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(workOSPageDidChange(_:)),
            name: .tatwoWorkOSPageDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func currentOrExistingWindow() -> NSWindow? {
        if let window, NSApp.windows.contains(where: { $0 === window }) {
            return window
        }
        return existingWorkOSWindows().sorted { lhs, rhs in
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.frame.area > rhs.frame.area
        }.first
    }

    private func existingWorkOSWindows() -> [TatwoWorkOSWindow] {
        NSApp.windows.compactMap { $0 as? TatwoWorkOSWindow }
    }

    /// 收掉重複視窗，只留一個。
    ///
    /// 刻意**不**過中斷確認閘：這裡收的是同一個 app 不該存在的第二個 Work OS 視窗，
    /// 使用者保留的那個視窗會續存，語意是「去重」而不是「結束工作」；
    /// 為了一個本來就不該在的視窗跳確認，只會讓使用者學會無腦按掉。
    /// `delegate = nil` 也是為此——避免它觸發 keptWindow 的 windowWillClose 收尾。
    private func closeDuplicateWorkOSWindows(keeping keptWindow: NSWindow) {
        for duplicate in existingWorkOSWindows() where duplicate !== keptWindow {
            duplicate.delegate = nil
            duplicate.close()
        }
        keptWindow.delegate = self
    }

    private func makeWindow(initialPage: TatwoPage? = nil) -> NSWindow {
        let hostingController = NSHostingController(rootView: TatwoPanelView(surface: .window, initialSelection: initialPage))
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        // 根治上下切割：不為 safe area(標題列)內縮 SwiftUI 內容，讓漸變/玻璃鋪到 y=0 標題列下，
        // 交通燈坐在同一片背景上，而非露出平底標題列與內容分兩塊（使用者反覆回饋 #37）。
        hostingController.safeAreaRegions = []
        let initialPage = initialPage ?? TatwoPage.initialSelection
        let initialSize = TatwoAppSurfaceMetrics.windowSize(for: initialPage)
        let window = TatwoWorkOSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Tatwo Ultrawork OS"
        window.configureTatwoChrome()
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.minSize = TatwoAppSurfaceMetrics.minimumWindowSize(for: initialPage)
        window.collectionBehavior = [.managed, .fullScreenNone]
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.contentViewController = hostingController
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.applyTatwoWindowSurface()
        themeObservation = TatwoThemeStore.shared.$activeThemeID
            .receive(on: DispatchQueue.main)
            .sink { [weak window] _ in window?.applyTatwoWindowSurface() }
        // 再套一次：分隔線樣式在 contentViewController 設定後才穩定生效，消頂部切割線（使用者 #29）。
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.layoutTatwoTrafficLights()
        window.delegate = self
        return window
    }

    func windowDidResize(_ notification: Notification) {
        (notification.object as? TatwoWorkOSWindow)?.layoutTatwoTrafficLights()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        (notification.object as? TatwoWorkOSWindow)?.layoutTatwoTrafficLights()
    }

    @objc private func workOSPageDidChange(_ notification: Notification) {
        guard let window,
              let raw = notification.object as? String,
              let page = TatwoPage(rawValue: raw)
        else { return }

        // Codex App keeps the outer window stable while switching left/top
        // surfaces. The previous animated resize on every toolbar click was a
        // major perceived-lag source and also made hit-testing feel offset while
        // the frame was moving. Keep one Codex-compatible minimum across pages,
        // and only resize the whole window behind an explicit diagnostics flag.
        window.minSize = TatwoAppSurfaceMetrics.minimumWindowSize(for: page)
        guard ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_RESIZE_ON_PAGE_CHANGE"] == "1",
              ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_PRESERVE_WINDOW_SIZE"] != "1"
        else { return }
        resize(window: window, for: page)
    }

    private func resize(window: NSWindow, for page: TatwoPage) {
        let targetContentSize = TatwoAppSurfaceMetrics.windowSize(for: page, screen: window.screen ?? NSScreen.main)
        window.minSize = TatwoAppSurfaceMetrics.minimumWindowSize(for: page)
        let currentTop = window.frame.maxY
        let currentMidX = window.frame.midX
        var targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize))
        targetFrame.origin.x = currentMidX - targetFrame.width / 2
        targetFrame.origin.y = currentTop - targetFrame.height
        targetFrame = clampedFrame(targetFrame, on: window.screen ?? NSScreen.main)

        window.setFrame(targetFrame, display: true)
    }

    private func placeNearTopIfNeeded(_ window: NSWindow) {
        guard ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_PRESERVE_WINDOW_SIZE"] != "1" else { return }
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        guard !screenFrame.isEmpty else {
            window.center()
            return
        }
        var frame = window.frame
        frame.origin.x = screenFrame.midX - frame.width / 2
        frame.origin.y = screenFrame.maxY - frame.height - 18
        window.setFrame(clampedFrame(frame, on: window.screen ?? NSScreen.main), display: false)
    }

    private func clampedFrame(_ frame: NSRect, on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        guard !visible.isEmpty else { return frame }
        var next = frame
        next.origin.x = min(max(next.origin.x, visible.minX + 8), visible.maxX - next.width - 8)
        next.origin.y = min(max(next.origin.y, visible.minY + 8), visible.maxY - next.height - 8)
        return next
    }

    /// 程式化關窗。
    ///
    /// 2026-07-27 查證：關窗**確實會中斷** in-flight loops，鏈路是
    /// `TatwoPanelView.onDisappear` → `TatwoRetainedChatLifecycle.closeContainer()`
    /// → `model.stop()` → `runner.terminate()`（連 launchctl submit 的子工作一起收）。
    /// app 進程本身不退出（repo 內無 `applicationShouldTerminateAfterLastWindowClosed`），
    /// 但這一輪的派工會沒。既然會中斷，就要和紅燈／Cmd+W／Esc 過同一道閘。
    ///
    /// `window?.close()` 不觸發 `windowShouldClose(_:)`（那只有 `performClose:` 才走），
    /// 所以這裡自己過閘。
    func close() {
        guard TatwoInterruptConfirmationPresenter.confirm(kind: .windowClose, window: window) else {
            return
        }
        window?.close()
    }

    /// 關窗（紅燈 / Cmd+W）的二次確認閘。Esc 走 `TatwoWorkOSWindow.cancelOperation`，
    /// 那條路徑 `close()` 不經過這裡，故兩處各自過閘、共用同一份判定。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        TatwoInterruptConfirmationPresenter.confirm(kind: .windowClose, window: sender)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        if TatwoLaunchSurfacePolicy.shouldReturnToAccessoryAfterWindowClose() {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private extension NSRect {
    var area: CGFloat { width * height }
}

@MainActor
final class TatwoStatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panelSize = TatwoAppSurfaceMetrics.panelSize
    private lazy var panel = makePanel()
    private let workOSWindowController = TatwoWorkOSWindowController()
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var panelOpenedAt: Date?

    override init() {
        super.init()
        setupStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openWorkOSWindowFromNotification(_:)),
            name: .tatwoOpenWorkOSWindow,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closeWorkOSWindowFromNotification(_:)),
            name: .tatwoCloseWorkOSWindow,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openStatusPanelFromNotification(_:)),
            name: .tatwoOpenStatusPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closeStatusPanelFromNotification(_:)),
            name: .tatwoCloseStatusPanel,
            object: nil
        )

        scheduleLaunchSurface()
    }

    func showDefaultSurfaceForUserOpen() {
        if defaultLaunchSurface() == .window {
            workOSWindowController.show()
        } else {
            showPanelFromStatusItem()
        }
    }

    private func scheduleLaunchSurface() {
        let env = ProcessInfo.processInfo.environment
        guard env["TATWO_ULTRAWORK_SUPPRESS_AUTOSHOW"] != "1" else { return }

        if defaultLaunchSurface() == .window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.workOSWindowController.show()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.showPanelAtScreenFallback()
        }
    }

    private func defaultLaunchSurface() -> TatwoAppSurfaceKind {
        TatwoLaunchSurfacePolicy.defaultSurface()
    }

    @objc private func openWorkOSWindowFromNotification(_ notification: Notification) {
        let requestedPage = (notification.object as? String).flatMap(TatwoPage.init(rawValue:))
        workOSWindowController.show(page: requestedPage)
        if let requestedPage {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .tatwoWorkOSSelectPage, object: requestedPage.rawValue)
            }
        }
    }

    /// 2026-07-27 查證：`.tatwoCloseWorkOSWindow` 目前**沒有任何 post 端**（全 repo 只有常數、
    /// 這個 observer 與 selector 三處引用；對比 `.tatwoOpenWorkOSWindow` 有 4 個真實 poster）。
    /// 即目前不可達。仍讓它走已過閘的 `close()`，這樣哪天有人補上 poster 也不會變成繞過確認的後門。
    @objc private func closeWorkOSWindowFromNotification(_ notification: Notification) {
        workOSWindowController.close()
    }

    @objc private func openStatusPanelFromNotification(_ notification: Notification) {
        let requestedPage = (notification.object as? String).flatMap(TatwoPage.init(rawValue:))
        guard requestedPage.map(TatwoPageNavigationPolicy.canOpenInStatusPanel) ?? true else { return }
        _ = panel
        showPanelFromStatusItem()
        guard let requestedPage else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .tatwoStatusPanelSelectPage,
                object: requestedPage.rawValue
            )
        }
    }

    @objc private func closeStatusPanelFromNotification(_ notification: Notification) {
        closePanel(nil)
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "Tatwo Ultrawork")
        button.image?.isTemplate = true
        button.title = " TATWO"
        button.toolTip = "Tatwo Ultrawork"
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func makePanel() -> TatwoStatusPanelWindow {
        let hostingController = NSHostingController(rootView: TatwoPanelView(surface: .panel))
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        return TatwoStatusPanelWindow(
            contentRect: NSRect(origin: .zero, size: panelSize),
            viewController: hostingController
        )
    }

    @objc private func togglePanel(_ sender: AnyObject?) {
        if panel.isVisible {
            closePanel(sender)
        } else {
            showPanelFromStatusItem()
        }
    }

    private func showPanelFromStatusItem(attempt: Int = 0) {
        guard let button = statusItem.button, button.window != nil else {
            guard attempt < 20 else {
                showPanelAtScreenFallback()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.showPanelFromStatusItem(attempt: attempt + 1)
            }
            return
        }
        panel.setFrameOrigin(panelOrigin(relativeTo: button))
        panel.orderFrontRegardless()
        panel.makeKey()
        panelOpenedAt = Date()
        startEventMonitoringUnlessAutomation()
    }

    private func showPanelAtScreenFallback() {
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: max(screenFrame.minX + 8, screenFrame.maxX - panelSize.width - 18),
            y: max(screenFrame.minY + 8, screenFrame.maxY - panelSize.height - 42)
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.makeKey()
        panelOpenedAt = Date()
        startEventMonitoringUnlessAutomation()
    }

    private func startEventMonitoringUnlessAutomation() {
        guard ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_DISABLE_AUTO_CLOSE"] != "1" else {
            stopEventMonitoring()
            return
        }
        startEventMonitoring()
    }

    private func closePanel(_ sender: Any?) {
        panel.orderOut(sender)
        stopEventMonitoring()
    }

    private func panelOrigin(relativeTo button: NSButton) -> NSPoint {
        guard let buttonWindow = button.window else { return .zero }
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        var origin = NSPoint(
            x: buttonFrameOnScreen.maxX - panelSize.width + 10,
            y: buttonFrameOnScreen.minY - panelSize.height - 10
        )
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - panelSize.width - 8)
        origin.y = max(origin.y, screenFrame.minY + 8)
        return origin
    }

    private func startEventMonitoring() {
        stopEventMonitoring()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.shouldCloseForCurrentMouseLocation() else { return }
                    self.closePanel(nil)
                }
            }

            self.localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown, event.keyCode == 53 {
                    self.closePanel(nil)
                    return nil
                }
                if (event.type == .leftMouseDown || event.type == .rightMouseDown) && self.shouldCloseForCurrentMouseLocation() {
                    self.closePanel(nil)
                }
                return event
            }
        }
    }

    private func stopEventMonitoring() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func shouldCloseForCurrentMouseLocation() -> Bool {
        if let panelOpenedAt, Date().timeIntervalSince(panelOpenedAt) < 0.3 {
            return false
        }
        let mouseLocation = NSEvent.mouseLocation
        if panel.frame.contains(mouseLocation) { return false }
        guard let buttonFrame = statusItemButtonFrameOnScreen() else { return true }
        return !buttonFrame.contains(mouseLocation)
    }

    private func statusItemButtonFrameOnScreen() -> NSRect? {
        guard let button = statusItem.button, let buttonWindow = button.window else { return nil }
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        return buttonWindow.convertToScreen(buttonFrameInWindow)
    }
}

enum TatwoPage: String, Identifiable, Hashable {
    case chat
    case usage
    case modes
    case scenarios
    case compatibility
    case plugins
    case devices
    case workflow

    var id: String { rawValue }
    // 2026-08-20 三分頁收斂：scenarios/compatibility 退出導覽（enum case
    // 保留供深連結與存檔相容，路由併入 .modes 的配置總覽）。
    static let allCases: [TatwoPage] = [.usage, .modes, .plugins, .devices, .workflow, .chat]

    static var initialSelection: TatwoPage {
        let env = ProcessInfo.processInfo.environment
        let raw = (env["TATWO_ULTRAWORK_EXPORT_TAB"] ?? env["TATWO_ULTRAWORK_INITIAL_PAGE"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return TatwoPage(rawValue: raw ?? "") ?? .chat
    }

    static var panelInitialSelection: TatwoPage {
        let env = ProcessInfo.processInfo.environment
        if let raw = (env["TATWO_ULTRAWORK_PANEL_INITIAL_PAGE"] ?? env["TATWO_ULTRAWORK_INITIAL_PAGE"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           let page = TatwoPage(rawValue: raw),
           page != .chat
        {
            return page
        }
        return .modes
    }

    var prefersLargeWindow: Bool {
        switch self {
        case .chat, .modes, .scenarios:
            true
        case .usage, .compatibility, .plugins, .devices, .workflow:
            false
        }
    }

    var title: String {
        switch self {
        case .chat: "對話"
        case .usage: "額度用量"
        case .modes: "配置"
        case .scenarios: "配置"
        case .compatibility: "配置"
        case .plugins: "外掛工具"
        case .devices: "設備"
        case .workflow: "OS"
        }
    }

    var subtitle: String {
        switch self {
        case .chat: "Codex / Claude 原生續聊"
        case .usage: "快取與即時額度分開看"
        case .modes: "模式 · 情境 · 特質一頁總覽"
        case .scenarios: "模式 · 情境 · 特質一頁總覽"
        case .compatibility: "模式 · 情境 · 特質一頁總覽"
        case .plugins: "技能與 MCP 工具登記"
        case .devices: "連線設備與主輔狀態"
        case .workflow: "架構總覽：上游、身份組、流程、記憶、設備、技能"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .usage: "gauge.with.dots.needle.67percent"
        case .modes: "square.stack.3d.up"
        case .scenarios: "slider.horizontal.3"
        case .compatibility: "point.3.connected.trianglepath.dotted"
        case .plugins: "puzzlepiece.extension"
        case .devices: "macbook.and.iphone"
        case .workflow: "point.3.connected.trianglepath.dotted"
        }
    }
}

enum TatwoPageNavigationPolicy {
    static let menuBarOSPages: [TatwoPage] = [
        .usage,
        .modes,
        .plugins,
        .devices,
        .workflow
    ]

    // Wave1: chatWindowPages dead constant removed (was always empty; chat has no page strip).

    static func canOpenInStatusPanel(_ page: TatwoPage) -> Bool {
        menuBarOSPages.contains(page)
    }
}

// 沿革：2026 夏使用者曾申訴「透底破色／頂部切割／刺眼」，此處一度被
// 判為不透明底。當年的病根是手工玻璃鏈參差；island 之後有了驗證過的
// 原生材質路線，2026-08-20 使用者裁決「最底版也要有液態效果」。
// 極光：底層玻璃由 TatwoWindowGlassBase 供材質，這裡只留閱讀舒適紗
// （白紗＋主題 tint），不再蓋不透明白平板。fable5 紀念主題維持原本
// 的不透明疊層，一個位元不動。
private struct ChatWindowCanvasBackdrop: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared

    var body: some View {
        if TatwoActivePalette.current.usesGlass {
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                Rectangle()
                    .fill(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity * 0.35))
            }
            .allowsHitTesting(false)
        } else {
            ZStack {
                LiquidGlassTokens.canvasBackground
                LinearGradient(
                    colors: [
                        Color(nsColor: .controlBackgroundColor).opacity(0.16),
                        Color(nsColor: .windowBackgroundColor).opacity(0.10),
                        Color(nsColor: .underPageBackgroundColor).opacity(0.14)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Rectangle()
                    .fill(Color.white.opacity(0.30))
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .allowsHitTesting(false)
            }
                .overlay {
                    Rectangle()
                        .fill(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity * 0.35))
                        .allowsHitTesting(false)
                }
        }
    }
}

struct TatwoModesIssuedAuthorityResolution: Equatable, Sendable {
    let contract: TatwoWorkOSContractV1?
    let integrityState: ModesIssuedIntegrityState
}

enum TatwoModesIssuedAuthorityResolver {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stateDirectoryURL: URL,
        scenarioBook: TatwoScenarioConfigBookV1? = nil
    ) -> TatwoModesIssuedAuthorityResolution {
        let goalStore = TatwoGoalRunStore(directoryURL: stateDirectoryURL)
        return resolve(
            environment: environment,
            goalStore: goalStore,
            sessionStore: TatwoSessionStore(directoryURL: goalStore.directoryURL),
            scenarioBook: scenarioBook)
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        goalStore: TatwoGoalRunStore? = nil,
        sessionStore: TatwoSessionStore? = nil,
        scenarioBook: TatwoScenarioConfigBookV1? = nil
    ) -> TatwoModesIssuedAuthorityResolution {
        let resolvedScenarioBook =
            scenarioBook
            ?? TatwoScenarioConfigStore.loadDefaultStaging(environment: environment)
        let resolvedGoalStore =
            goalStore ?? TatwoGoalRunStore.default(environment: environment)
        let resolvedSessionStore =
            sessionStore
            ?? TatwoSessionStore(directoryURL: resolvedGoalStore.directoryURL)
        do {
            guard let pointerSnapshot =
                try resolvedSessionStore.snapshotCurrent()
            else {
                return TatwoModesIssuedAuthorityResolution(
                    contract: nil,
                    integrityState: .noPointer
                )
            }
            let predecessor =
                try TatwoGoalRevisionPredecessorResolver.resolve(
                    pointer: pointerSnapshot.pointer,
                    scenarioBook: resolvedScenarioBook,
                    goalStore: resolvedGoalStore,
                    sessionStore: resolvedSessionStore)
            if let attachment = predecessor.attachment {
                return TatwoModesIssuedAuthorityResolution(
                    contract: attachment.contract,
                    integrityState:
                        predecessor.requiresBindingRevision
                        ? .revisionRequired(
                            "已簽發 Goal 的 identity bindings 與目前情境不同；"
                            + "請建立 Goal revision 後再執行。")
                        : .validated
                )
            }
            return TatwoModesIssuedAuthorityResolution(
                contract: nil,
                integrityState: .noPointer
            )
        } catch {
            return TatwoModesIssuedAuthorityResolution(
                contract: nil,
                integrityState: .blocked(
                    TatwoPrivacyRedactor.redacted(error.localizedDescription))
            )
        }
    }
}

enum TatwoPanelModesInitialAuthority {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        goalStore: TatwoGoalRunStore? = nil,
        sessionStore: TatwoSessionStore? = nil,
        scenarioBook: TatwoScenarioConfigBookV1? = nil
    ) -> TatwoModesIssuedAuthorityResolution {
        TatwoModesIssuedAuthorityResolver.resolve(
            environment: environment,
            goalStore: goalStore,
            sessionStore: sessionStore,
            scenarioBook: scenarioBook
        )
    }
}

actor TatwoModesIssuedAuthorityResolutionCoordinator {
    typealias ResolutionOperation =
        @Sendable () -> TatwoModesIssuedAuthorityResolution
    static let shared = TatwoModesIssuedAuthorityResolutionCoordinator()

    func resolve(
        using operation: ResolutionOperation
    ) -> TatwoModesIssuedAuthorityResolution? {
        guard !Task.isCancelled else { return nil }
        return operation()
    }

    nonisolated static func shouldApply(
        expectedRevision: UInt64,
        currentRevision: UInt64,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && expectedRevision == currentRevision
    }

    nonisolated static func shouldAssign(
        currentContract: TatwoWorkOSContractV1?,
        currentIntegrityState: ModesIssuedIntegrityState,
        resolved: TatwoModesIssuedAuthorityResolution
    ) -> Bool {
        currentContract != resolved.contract
            || currentIntegrityState != resolved.integrityState
    }
}

/// Watches the durable Work OS authority directories so Modes does not keep a
/// stale validated contract after another App surface, MCP call, or CLI process
/// atomically replaces current-session or mutates its canonical GoalRun.
///
/// Vnode observation is intentionally directory-scoped: current-session writes
/// use atomic replacement, and GoalRun receipts/status are persisted below the
/// sibling `goals` directory.
@MainActor
final class TatwoModesIssuedAuthorityMonitor: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    let resolutionCoordinator =
        TatwoModesIssuedAuthorityResolutionCoordinator.shared

    let stateDirectoryURL: URL
    private let debounceInterval: TimeInterval
    private var sourcesByPath: [String: DispatchSourceFileSystemObject] = [:]
    private var pendingMutation: DispatchWorkItem?

    convenience init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            stateDirectoryURL:
                TatwoGoalRunStore.default(environment: environment).directoryURL)
    }

    init(
        stateDirectoryURL: URL,
        debounceInterval: TimeInterval = 0.1
    ) {
        self.stateDirectoryURL = stateDirectoryURL.standardizedFileURL
        self.debounceInterval = debounceInterval
        refreshSources()
    }

    isolated deinit {
        pendingMutation?.cancel()
        for source in sourcesByPath.values {
            source.cancel()
        }
    }

    var watchedDirectoryPaths: Set<String> {
        Set(sourcesByPath.keys)
    }

    private var watchedDirectoryURLs: [URL] {
        let fileManager = FileManager.default
        var isStateDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: stateDirectoryURL.path,
            isDirectory: &isStateDirectory
        ), isStateDirectory.boolValue {
            let goalsDirectoryURL =
                stateDirectoryURL.appendingPathComponent("goals", isDirectory: true)
            var isGoalsDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: goalsDirectoryURL.path,
                isDirectory: &isGoalsDirectory
            ), isGoalsDirectory.boolValue {
                return [stateDirectoryURL, goalsDirectoryURL]
            }
            return [stateDirectoryURL]
        }
        guard let bootstrap = nearestExistingDirectoryAncestor(
            of: stateDirectoryURL,
            fileManager: fileManager)
        else { return [] }
        return [bootstrap]
    }

    private func refreshSources() {
        let desiredDirectoryURLs = watchedDirectoryURLs
        let desiredPaths = Set(
            desiredDirectoryURLs.map { $0.standardizedFileURL.path })
        for obsoletePath in Array(sourcesByPath.keys)
        where !desiredPaths.contains(obsoletePath) {
            removeSource(atPath: obsoletePath)
        }

        for directoryURL in desiredDirectoryURLs {
            let path = directoryURL.standardizedFileURL.path
            guard sourcesByPath[path] == nil else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue
            else { continue }

            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                queue: DispatchQueue.main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                guard let events = self.sourcesByPath[path]?.data else { return }
                if events.contains(.delete)
                    || events.contains(.rename)
                    || events.contains(.revoke)
                {
                    self.removeSource(atPath: path)
                }
                self.recordMutation()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            sourcesByPath[path] = source
            source.resume()
        }
    }

    private func nearestExistingDirectoryAncestor(
        of directoryURL: URL,
        fileManager: FileManager
    ) -> URL? {
        var candidate = directoryURL.deletingLastPathComponent()
        while true {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue {
                return candidate.standardizedFileURL
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    private func removeSource(atPath path: String) {
        guard let source = sourcesByPath.removeValue(forKey: path) else { return }
        source.cancel()
    }

    private func recordMutation() {
        pendingMutation?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingMutation = nil
            self.refreshSources()
            self.revision &+= 1
        }
        pendingMutation = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + debounceInterval,
            execute: workItem)
    }
}

struct TatwoPanelView: View {
    let surface: TatwoAppSurfaceKind
    let initialSelection: TatwoPage?
    let initialSnapshot: TatwoAppSnapshot?
    let initialLiveQuotaSnapshot: LiveQuotaDeckSnapshot?
    @State private var chatModel: ChatPageModel?
    // 啟動期磁碟解析狀態。resolving 走 first-frame shell，
    // main thread 不得為了它同步開檔（staging 65）；逾時必須走到
    // storageUnavailable，不得無限空白（staging 66）。
    @StateObject private var launch: TatwoPanelLaunchCoordinator

    init(
        surface: TatwoAppSurfaceKind = .panel,
        initialSelection: TatwoPage? = nil,
        initialSnapshot: TatwoAppSnapshot? = nil,
        initialLiveQuotaSnapshot: LiveQuotaDeckSnapshot? = nil
    ) {
        self.surface = surface
        self.initialSelection = initialSelection
        self.initialSnapshot = initialSnapshot
        self.initialLiveQuotaSnapshot = initialLiveQuotaSnapshot
        // 預先解析好的快照（headless 匯出路徑）仍要交給協調器，否則會多開一次檔。
        _launch = StateObject(
            wrappedValue: TatwoPanelLaunchCoordinator(
                resolver: {
                    await TatwoPanelLaunchHydration.resolveOffMainThread(
                        preloadedSnapshot: initialSnapshot)
                }))
    }

    var body: some View {
        Group {
            switch launch.state {
            case let .hydrated(hydration):
                if let chatModel {
                    TatwoHydratedPanelView(
                        chatModel: chatModel,
                        surface: surface,
                        initialSelection: initialSelection,
                        initialSnapshot: hydration.snapshot,
                        initialModesAuthority: hydration.modesAuthority,
                        initialLiveQuotaSnapshot: initialLiveQuotaSnapshot)
                } else {
                    TatwoChatFirstFrameShell(
                        surface: surface,
                        initialSelection: initialSelection)
                }
            case let .storageUnavailable(report):
                // 第一幀失敗必須看得見：明確原因＋路徑＋重試，不留空白。
                TatwoLaunchStorageUnavailableView(
                    surface: surface,
                    initialSelection: initialSelection,
                    report: report,
                    retry: { launch.retry() })
            case .resolving:
                TatwoChatFirstFrameShell(
                    surface: surface,
                    initialSelection: initialSelection)
            }
        }
        .task {
            guard chatModel == nil else { return }
            await Task.yield()
            guard !Task.isCancelled, chatModel == nil else { return }
            chatModel =
                TatwoChatProcessCompositionRegistry.chatPageModel(
                    appMCPRuntimeProvider: {
                        TatwoAppMCPRuntimeRegistry.state
                    })
        }
        .task {
            launch.start()
        }
        // 使用者在 TCC 面板或系統設定按下允許後會回到本 App；此時被擋住的
        // open() 通常已經放行，重新倒數即可自動 hydrate，不需要使用者再點。
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            if case .storageUnavailable = launch.state { launch.retry() }
        }
    }
}

/// 啟動期儲存被擋住時的可見狀態。這是 staging 66 的直接修補：舊版在
/// hydration 未完成時只渲染 `Color.clear`，於是 TCC 同意沒回來就永遠是白畫面。
private struct TatwoLaunchStorageUnavailableView: View {
    let surface: TatwoAppSurfaceKind
    let initialSelection: TatwoPage?
    let report: TatwoLaunchStorageBlockReport
    let retry: () -> Void

    private var size: NSSize {
        if surface == .window {
            return TatwoAppSurfaceMetrics.windowSize(
                for: initialSelection ?? TatwoPage.initialSelection)
        }
        return TatwoAppSurfaceMetrics.panelSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.title)
                .font(.headline)
            Text(report.guidance)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !report.blockedPaths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("等待中的執行階段路徑")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(report.blockedPaths, id: \.self) { path in
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            HStack(spacing: 10) {
                Button("重試", action: retry)
                    .keyboardShortcut(.defaultAction)
                Text("已等待 \(Int(report.waitedSeconds.rounded())) 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(
            minWidth: surface == .window
                ? TatwoAppSurfaceMetrics.windowMinSize.width
                : size.width,
            idealWidth: size.width,
            minHeight: surface == .window
                ? TatwoAppSurfaceMetrics.windowMinSize.height
                : size.height,
            idealHeight: size.height,
            alignment: .topLeading)
        .environment(\.tatwoSurfaceKind, surface)
    }
}

private struct TatwoChatFirstFrameShell: View {
    let surface: TatwoAppSurfaceKind
    let initialSelection: TatwoPage?

    private var size: NSSize {
        if surface == .window {
            return TatwoAppSurfaceMetrics.windowSize(
                for: initialSelection ?? TatwoPage.initialSelection)
        }
        return TatwoAppSurfaceMetrics.panelSize
    }

    var body: some View {
        Color.clear
            .frame(
                minWidth: surface == .window
                    ? TatwoAppSurfaceMetrics.windowMinSize.width
                    : size.width,
                idealWidth: size.width,
                minHeight: surface == .window
                    ? TatwoAppSurfaceMetrics.windowMinSize.height
                    : size.height,
                idealHeight: size.height)
            .environment(\.tatwoSurfaceKind, surface)
    }
}

private struct TatwoHydratedPanelView: View {
    @ObservedObject private var chatModel: ChatPageModel
    @ObservedObject private var authorityBootstrapModel:
        TatwoAppAuthorityBootstrapModel
    let surface: TatwoAppSurfaceKind
    @StateObject private var modesIssuedAuthorityMonitor:
        TatwoModesIssuedAuthorityMonitor
    @State private var selection: TatwoPage
    @State private var snapshot: TatwoAppSnapshot
    @State private var previewScenarioProfileID: String
    @State private var issuedModesContract: TatwoWorkOSContractV1?
    @State private var issuedModesIntegrityState: ModesIssuedIntegrityState
    @State private var pendingGoalRevision: TatwoGoalRevisionChallenge?
    @State private var goalRevisionErrorMessage: String?
    @State private var goalRevisionPreparationError: String?
    @State private var isConfirmingGoalRevision = false
    @State private var showsAuthorityBootstrapConfirmation = false
    @State private var retainedWindowPages: Set<TatwoPage>
    @State private var retainedChatLifecycle: TatwoRetainedChatLifecycle
    @State private var rightPanelPreference: Bool?
    @State private var liveGatewayStatus: TatwoGatewayLiveStatus?
    @State private var isRefreshingGateway = false
    @State private var liveQuotaSnapshot: LiveQuotaDeckSnapshot
    @State private var isRefreshingLiveQuota = false
    // 指定了右側面板內容（fixture/render）就預設開啟，便於 headless 驗證右列。
    @State private var isRightPanelOpen =
        ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_RIGHT_PANEL_CONTENT"] != nil
    // 主題切換時整棵樹重繪（LiquidGlassTokens 讀 active palette）；observe 讓 @Published 變更 invalidate 本 shell。
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    private var catalog: TatwoCatalog { snapshot.catalog }

    /// 2026-08-28（staging 65）：快照與 Modes 授權必須由呼叫端事先在背景解析後
    /// 傳進來。這裡刻意不再提供 `?? TatwoAppSnapshotFactory.makeCurrent()` 之類的
    /// 同步 fallback——那個 fallback 就是把外接卷 `open()` 拉回 SwiftUI render
    /// 的那一行；改成必填參數讓「render 期同步磁碟 I/O」在編譯期就無法重現。
    init(
        chatModel: ChatPageModel,
        surface: TatwoAppSurfaceKind = .panel,
        initialSelection: TatwoPage? = nil,
        initialSnapshot: TatwoAppSnapshot,
        initialModesAuthority: TatwoModesIssuedAuthorityResolution,
        initialLiveQuotaSnapshot: LiveQuotaDeckSnapshot? = nil
    ) {
        self.chatModel = chatModel
        _authorityBootstrapModel = ObservedObject(
            wrappedValue: chatModel.authorityBootstrapModel)
        self.surface = surface
        _modesIssuedAuthorityMonitor = StateObject(
            wrappedValue: TatwoModesIssuedAuthorityMonitor())
        let resolvedSelection =
            initialSelection ?? (surface == .panel ? TatwoPage.panelInitialSelection : TatwoPage.initialSelection)
        let resolvedSnapshot = initialSnapshot
        _selection = State(initialValue: resolvedSelection)
        _snapshot = State(initialValue: resolvedSnapshot)
        _previewScenarioProfileID = State(
            initialValue: Self.initialPreviewScenarioProfileID(snapshot: resolvedSnapshot))
        _issuedModesContract = State(initialValue: initialModesAuthority.contract)
        _issuedModesIntegrityState = State(
            initialValue: initialModesAuthority.integrityState)
        _pendingGoalRevision = State(initialValue: nil)
        _goalRevisionErrorMessage = State(initialValue: nil)
        _goalRevisionPreparationError = State(initialValue: nil)
        _isConfirmingGoalRevision = State(initialValue: false)
        _retainedWindowPages = State(initialValue: surface == .window && resolvedSelection == .chat ? [.chat] : [])
        _retainedChatLifecycle = State(initialValue: TatwoRetainedChatLifecycle(
            initiallySelectedChat: surface == .window && resolvedSelection == .chat))
        _rightPanelPreference = State(initialValue: Self.initialRightPanelPreference())
        _liveQuotaSnapshot = State(
            initialValue: initialLiveQuotaSnapshot ?? .loading)
    }

    private static func initialPreviewScenarioProfileID(
        snapshot: TatwoAppSnapshot,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let configured = environment["TATWO_ULTRAWORK_SELECTED_SCENARIO_CONFIG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty
        {
            return configured
        }
        switch snapshot.selectedScenario {
        case .daily: return "daily"
        case .design: return "ui-ux"
        case .coding: return "coding"
        case .trading: return "trading-risk"
        case .modeling: return "modeling"
        }
    }

    private static func initialRightPanelPreference(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool? {
        switch environment["TATWO_ULTRAWORK_CHAT_RIGHT_PANEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "1", "true", "open":
            true
        case "0", "false", "closed":
            false
        default:
            nil
        }
    }

    private var surfaceSize: NSSize {
        surface == .window ? TatwoAppSurfaceMetrics.windowSize(for: selection) : TatwoAppSurfaceMetrics.panelSize
    }

    private var surfaceMinSize: NSSize {
        surface == .window ? TatwoAppSurfaceMetrics.minimumWindowSize(for: selection) : TatwoAppSurfaceMetrics.panelSize
    }

    private var effectiveSurfaceMinSize: NSSize {
        guard surface == .window,
              isSnapshotExport,
              let exportSize
        else { return surfaceMinSize }
        return NSSize(
            width: min(surfaceMinSize.width, exportSize.width),
            height: min(surfaceMinSize.height, exportSize.height)
        )
    }

    private var isSnapshotExport: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
            || env["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"] != nil
    }

    private var exportSize: NSSize? {
        let env = ProcessInfo.processInfo.environment
        guard let rawWidth = env["TATWO_ULTRAWORK_EXPORT_WIDTH"],
              let width = Double(rawWidth)
        else { return nil }
        let height = env["TATWO_ULTRAWORK_EXPORT_HEIGHT"].flatMap(Double.init) ?? Double(surfaceMinSize.height)
        return NSSize(width: max(360, min(2600, CGFloat(width))), height: max(360, min(3600, CGFloat(height))))
    }

    private var safeHorizontalPadding: CGFloat {
        surface == .window ? 22 : 16
    }

    private var safeBottomPadding: CGFloat {
        surface == .window ? 24 : 18
    }

    private func makeSnapshot(mode: WorkModeID? = nil, scenario: ScenarioID? = nil) -> TatwoAppSnapshot {
        let preferences = TatwoUserPreferences(
            selectedMode: mode ?? snapshot.selectedMode,
            selectedScenario: scenario ?? snapshot.selectedScenario
        )
        let pluginEntries = TatwoPluginRegistryStore.loadDefaultEntries()
        let environment = ProcessInfo.processInfo.environment
        return TatwoAppSnapshotFactory.make(
            preferences: preferences,
            probe: .current(environment: environment).withGatewayLiveStatus(liveGatewayStatus),
            catalog: TatwoCatalog.defaults.replacingPlugins(pluginEntries)
        )
    }

    private func updateSnapshot(mode: WorkModeID? = nil, scenario: ScenarioID? = nil) {
        snapshot = makeSnapshot(mode: mode, scenario: scenario)
    }

    private func refreshModesIssuedAuthority(
        expectedRevision: UInt64
    ) async {
        let environment = ProcessInfo.processInfo.environment
        let stateDirectoryURL =
            modesIssuedAuthorityMonitor.stateDirectoryURL
        let resolved =
            await modesIssuedAuthorityMonitor.resolutionCoordinator.resolve(
                using: {
                TatwoModesIssuedAuthorityResolver.resolve(
                    environment: environment,
                    stateDirectoryURL: stateDirectoryURL)
                })
        guard let result = resolved
        else { return }
        guard TatwoModesIssuedAuthorityResolutionCoordinator.shouldApply(
            expectedRevision: expectedRevision,
            currentRevision: modesIssuedAuthorityMonitor.revision,
            isCancelled: Task.isCancelled)
        else { return }
        guard TatwoModesIssuedAuthorityResolutionCoordinator.shouldAssign(
            currentContract: issuedModesContract,
            currentIntegrityState: issuedModesIntegrityState,
            resolved: result)
        else { return }
        issuedModesContract = result.contract
        issuedModesIntegrityState = result.integrityState
    }

    private func requestGoalRevision(
        _ selection: TatwoGoalRevisionSelection
    ) {
        goalRevisionErrorMessage = nil
        goalRevisionPreparationError = nil
        let environment = ProcessInfo.processInfo.environment
        Task {
            let payload:
                (challenge: TatwoGoalRevisionChallenge?, error: String?) =
                await Task.detached(priority: .userInitiated) {
                do {
                    return (
                        challenge:
                            try TatwoGoalRevisionCoordinator.prepare(
                                selection: selection,
                                environment: environment),
                        error: Optional<String>.none
                    )
                } catch {
                    return (
                        challenge: Optional<TatwoGoalRevisionChallenge>.none,
                        error: TatwoPrivacyRedactor.redacted(
                            error.localizedDescription)
                    )
                }
            }.value
            guard !Task.isCancelled else { return }
            if let challenge = payload.challenge {
                pendingGoalRevision = challenge
            } else {
                goalRevisionPreparationError = payload.error
            }
        }
    }

    private func confirmGoalRevision(
        challenge: TatwoGoalRevisionChallenge,
        newObjective: String
    ) {
        guard !isConfirmingGoalRevision else { return }
        isConfirmingGoalRevision = true
        goalRevisionErrorMessage = nil
        let environment = ProcessInfo.processInfo.environment
        Task {
            let payload:
                (
                    confirmation: TatwoGoalRevisionConfirmationResult?,
                    error: String?
                ) = await Task.detached(priority: .userInitiated) {
                do {
                    return (
                        confirmation:
                            try TatwoGoalRevisionCoordinator.confirm(
                                challenge: challenge,
                                newObjective: newObjective,
                                environment: environment),
                        error: Optional<String>.none
                    )
                } catch {
                    return (
                        confirmation:
                            Optional<TatwoGoalRevisionConfirmationResult>.none,
                        error: TatwoPrivacyRedactor.redacted(
                            error.localizedDescription)
                    )
                }
            }.value
            guard !Task.isCancelled else { return }
            isConfirmingGoalRevision = false
            if let confirmation = payload.confirmation {
                let chatRefreshed =
                    chatModel.refreshAfterGoalRevisionPromotion()
                pendingGoalRevision = nil
                goalRevisionErrorMessage = nil
                issuedModesContract = confirmation.readback.contract
                issuedModesIntegrityState = .validated
                previewScenarioProfileID =
                    confirmation.pointerSnapshot.pointer.scenario
                snapshot = makeSnapshot(
                    mode: confirmation.pointerSnapshot.pointer.mode,
                    scenario: scenarioID(
                        for: confirmation.pointerSnapshot.pointer.scenario))
                if !chatRefreshed {
                    goalRevisionPreparationError =
                        "Goal revision 已 canonical promotion；"
                        + "selected thread 重新綁定未通過驗證，已隔離而未建立新 chat session。"
                }
            } else {
                goalRevisionErrorMessage = payload.error
            }
        }
    }

    private func scenarioID(for profileID: String) -> ScenarioID? {
        switch profileID {
        case "daily": return .daily
        case "ui-ux": return .design
        case "coding": return .coding
        case "trading-risk": return .trading
        case "modeling": return .modeling
        default: return nil
        }
    }

    private func refreshGatewayStatus() {
        guard !isRefreshingGateway else { return }
        let environment = ProcessInfo.processInfo.environment
        isRefreshingGateway = true
        Task {
            let status = await TatwoGatewayLiveProbe.fetch(environment: environment)
            await MainActor.run {
                liveGatewayStatus = status
                snapshot = makeSnapshot()
                isRefreshingGateway = false
            }
        }
    }

    @MainActor
    private func refreshLiveQuotaIfStale(
        maxAge: TimeInterval
    ) async {
        guard liveQuotaSnapshot.isStale(maxAge: maxAge) else { return }
        await refreshLiveQuota()
    }

    @MainActor
    private func refreshLiveQuota() async {
        guard !isRefreshingLiveQuota else { return }
        isRefreshingLiveQuota = true
        let providers = catalog.usageProviders
        let refreshed = await Task.detached(priority: .utility) {
            await TatwoQuotaSnapshotCache.shared.load(
                providers: providers,
                refreshKind: .automatic,
                allowExternalAccess: false)
        }.value
        liveQuotaSnapshot = refreshed
        isRefreshingLiveQuota = false
    }

    private func registerPlugin(kind: RegistryKind, path: String, purpose: String, name: String?) throws {
        _ = try TatwoPluginRegistryStore.defaultStore().register(
            kind: kind,
            path: path,
            plainPurpose: purpose,
            name: name
        )
        updateSnapshot()
    }

    private func removePlugin(_ entry: PluginRegistryEntry) throws {
        _ = try TatwoPluginRegistryStore.defaultStore().remove(id: entry.id)
        updateSnapshot()
    }

    private func syncPluginsToClaude() async throws -> TatwoClaudeMCPSyncReceiptV1 {
        try await Task.detached(priority: .utility) {
            try TatwoPluginRegistryStore.defaultStore().syncClaudeMCPConfig()
        }.value
    }

    // Engineering composition (not a Dashboard parameter): TatwoPanelBackdrop
    // always draws LiquidGlassTokens.radiusPrimary (34pt) rounded corners,
    // correct for the floating .panel surface whose NSWindow itself has
    // rounded corners, but on the square Chat window it leaves all four
    // corners transparent to the desktop behind -- read as "the outer/top
    // frame looks cut" and made the canvas feel too see-through. Scoped to
    // surface == .window && selection == .chat only; every other tab/surface
    // keeps TatwoPanelBackdrop unchanged.
    @ViewBuilder
    private var panelBackdrop: some View {
        if surface == .window && selection == .chat {
            ChatWindowCanvasBackdrop()
        } else {
            TatwoPanelBackdrop()
        }
    }

    var body: some View {
        ZStack {
            // 最底層：極光＝behind-window 真玻璃、fable5＝牛皮紙實底。
            // 只鋪主視窗；menu-bar panel 維持自己的圓角 backdrop 疊層。
            if surface == .window {
                TatwoWindowGlassBase()
                    .ignoresSafeArea()
            }
            panelBackdrop
                .ignoresSafeArea()
            // 預設主題：淡雅紫藍粉漸變（LiquidGlassTokens 單一真相源）疊在 backdrop 上、內容之下。
            // menu-bar 小視窗(panel)漸變強度砍半——同一漸變在小面積會過度集中變厚重(#23)。
            LiquidGlassTokens.canvasGradient(surface == .panel ? 0.45 : 1.0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            // fable5 牛皮紙噪點紙紋（底板）；極光 grain=0 不渲染。疊在漸變上、內容下。
            TatwoPaperGrainLayer()
                .ignoresSafeArea()
            VStack(spacing: 0) {
                if surface == .window {
                    // Chat 視窗：band 不佔垂直空間（改 overlay），讓左工作區玻璃延伸到頂、
                    // 消掉交通燈下方的空 band 斷層（使用者 2 天痛點 #27）。
                    // 其餘 OS 頁維持 band 在頂（內容較單純、不需貼頂）。
                    if selection != .chat {
                        TatwoWindowPageRail(
                            isRightPanelOpen: isRightPanelOpen,
                            toggleRightPanel: {
                                rightPanelPreference = !isRightPanelOpen
                            }
                        )
                    }
                } else {
                    TatwoPanelHeader(selection: $selection, snapshot: snapshot) {
                        updateSnapshot()
                        refreshGatewayStatus()
                    }
                        .padding(.horizontal, safeHorizontalPadding)
                        .padding(.top, surface == .window ? 42 : 14)
                        .padding(.bottom, 10)
                }

                if surface == .window {
                    if selection == .chat {
                        retainedWindowContent
                            .overlay(alignment: .top) {
                                // 只留拖曳區 + 交通燈透明 spacer；右面板開關交給頁內 icon-only strip（#50/#51 對齊 Codex，不再兩層）。
                                TatwoWindowPageRail(
                                    isRightPanelOpen: isRightPanelOpen,
                                    toggleRightPanel: {
                                        rightPanelPreference = !isRightPanelOpen
                                    },
                                    showRightPanelToggle: false
                                )
                            }
                    } else {
                        retainedWindowContent
                    }
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 14) {
                            if selection != .usage
                                && selection != .chat
                                && selection != .devices
                                && surface == .panel
                            {
                                CompactPageTitle(page: selection)
                            }
                            pageContent(for: selection)
                        }
                        .padding(.horizontal, safeHorizontalPadding)
                        // panel 頂部留白：頂部遮罩淡入區（見下方 .mask）會吃到卡片上緣，
                        // 下調卡片內容避開遮罩淡入區（所有 panel 分頁共用此容器）。
                        .padding(.top, surface == .window ? 2 : 10)
                        .padding(.bottom, safeBottomPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white, location: 0.018),
                                .init(color: .white, location: 0.985),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
            }
        }
        .onAppear {
            if surface == .window, !TatwoPage.allCases.contains(selection) {
                selection = .chat
            }
            refreshGatewayStatus()
            chatModel.scheduleColdStartHydrationAfterFirstFrame()
            TatwoChatPostFirstFrameLaunchSweep.schedule(
                reason: "first-frame-presented")
        }
        .task(id: modesIssuedAuthorityMonitor.revision) {
            await refreshModesIssuedAuthority(
                expectedRevision: modesIssuedAuthorityMonitor.revision)
        }
        .frame(
            minWidth: surface == .window ? effectiveSurfaceMinSize.width : surfaceSize.width,
            idealWidth: surfaceSize.width,
            maxWidth: surface == .window ? .infinity : surfaceSize.width,
            minHeight: surface == .window ? effectiveSurfaceMinSize.height : surfaceSize.height,
            idealHeight: surfaceSize.height,
            maxHeight: surface == .window ? .infinity : surfaceSize.height
        )
        .environment(\.tatwoSurfaceKind, surface)
        .overlay {
            if let failureMessage =
                chatModel.coldStartHydrationFailureMessage
            {
                ZStack {
                    Color.black.opacity(0.34)
                    VStack(spacing: 12) {
                        Text("Chat 尚未完成安全恢復")
                            .font(.headline)
                        Text(failureMessage)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("重試恢復") {
                            chatModel.retryColdStartHydration()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !chatModel.canRetryColdStartHydration)
                    }
                    .padding(20)
                    .frame(maxWidth: 420)
                    .tatwoAdaptiveMaterial(cornerRadius: 0, material: .regularMaterial)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 18,
                            style: .continuous))
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let proposal = authorityBootstrapModel.pendingProposal {
                VStack(alignment: .leading, spacing: 8) {
                    Text("需要你確認 Goal authority locks")
                        .font(.headline)
                    Text(proposal.objectivePreview)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Disposition · \(proposal.bootstrapDispositionPreview)")
                        Text("Contract · \(proposal.contractID)")
                        Text("Root · \(proposal.canonicalGoalStoreRootPath)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Subject · \(proposal.authoritySubjectDigest)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Preflight · \(proposal.preflightDigest)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    Text("不確認就不建立 Goal；partial/corrupt state 不會自動修復。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("取消") {
                            authorityBootstrapModel.dismissPending()
                        }
                        .disabled(authorityBootstrapModel.isConfirming)
                        Button("檢查並初始化") {
                            showsAuthorityBootstrapConfirmation = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(authorityBootstrapModel.isConfirming)
                    }
                }
                .padding(14)
                .frame(maxWidth: 360, alignment: .leading)
                .tatwoAdaptiveMaterial(cornerRadius: 0, material: .regularMaterial)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .padding(.top, surface == .window ? 48 : 12)
                .padding(.trailing, 14)
                .accessibilityIdentifier(
                    "tatwo.authority-lock-bootstrap.banner")
            }
        }
        .onChange(
            of: authorityBootstrapModel.pendingProposal?
                .authoritySubjectDigest,
            initial: true
        ) { _, authoritySubjectDigest in
            guard authoritySubjectDigest != nil,
                  !authorityBootstrapModel.isConfirming
            else { return }
            showsAuthorityBootstrapConfirmation = true
        }
        // DEPRECATED REFERENCE — 2026-08-20 Aurora reconnaissance:
        // S2 migration did not occur; this engine/tokens path has zero view consumers.
        // Retained only as a candidate foundation for a future semantic-token migration.
        // Revival or archival remains a user decision.
        // H7 S1: hang theme engine + semantic tokens. Views still read LiquidGlassTokens directly.
        .tatwoThemeEngineEnvironment(TatwoThemeEngine.shared)
        .clipShape(RoundedRectangle(cornerRadius: surface == .panel ? 30 : 0, style: .continuous))
        .task {
            repeat {
                await refreshLiveQuotaIfStale(maxAge: 10)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            } while !Task.isCancelled
        }
        .onChange(of: selection) { _, newPage in
            guard surface == .window else { return }
            let isChatSelected = newPage == TatwoPage.chat
            retainedChatLifecycle.pageSelectionChanged(isChatSelected: isChatSelected)
            if newPage == .chat {
                retainedWindowPages.insert(.chat)
            }
            NotificationCenter.default.post(name: .tatwoWorkOSPageDidChange, object: newPage.rawValue)
        }
        .onDisappear {
            guard surface == .window else { return }
            retainedChatLifecycle.closeContainer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tatwoWorkOSSelectPage)) { notification in
            guard surface == .window,
                  let raw = notification.object as? String,
                  let page = TatwoPage(rawValue: raw)
            else { return }
            selection = page
        }
        .onReceive(NotificationCenter.default.publisher(for: .tatwoStatusPanelSelectPage)) { notification in
            guard surface == .panel,
                  let raw = notification.object as? String,
                  let page = TatwoPage(rawValue: raw),
                  TatwoPageNavigationPolicy.canOpenInStatusPanel(page)
            else { return }
            selection = page
        }
        .sheet(item: $pendingGoalRevision) { challenge in
            GoalRevisionConfirmationSheet(
                challenge: challenge,
                isConfirming: isConfirmingGoalRevision,
                errorMessage: goalRevisionErrorMessage,
                onCancel: {
                    guard !isConfirmingGoalRevision else { return }
                    goalRevisionErrorMessage = nil
                    pendingGoalRevision = nil
                },
                onConfirm: { objective in
                    confirmGoalRevision(
                        challenge: challenge,
                        newObjective: objective)
                }
            )
        }
        .confirmationDialog(
            "確認初始化 Goal authority locks？",
            isPresented: $showsAuthorityBootstrapConfirmation,
            titleVisibility: .visible
        ) {
            Button("確認檢查並初始化") {
                Task {
                    await authorityBootstrapModel.confirmPending()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let proposal = authorityBootstrapModel.pendingProposal {
                Text("Disposition: \(proposal.bootstrapDispositionPreview)\nContract: \(proposal.contractID)\nRoot: \(proposal.canonicalGoalStoreRootPath)\n只允許全缺時 create-only，或完整既有時 readback 驗證；任何 partial、mixed、corrupt 狀態都會 fail closed。")
            } else {
                Text(
                    "只允許全缺時 create-only，或完整既有時 readback 驗證；任何 partial、mixed、corrupt 狀態都會 fail closed。")
            }
        }
        .alert(
            "Goal revision blocked",
            isPresented: Binding(
                get: { goalRevisionPreparationError != nil },
                set: { if !$0 { goalRevisionPreparationError = nil } }
            )
        ) {
            Button("好") { goalRevisionPreparationError = nil }
        } message: {
            Text(goalRevisionPreparationError ?? "")
        }
    }

    @ViewBuilder
    private var retainedWindowContent: some View {
        ZStack {
            retainedWindowPage(.chat)
            if selection != .chat {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        pageContent(for: selection)
                    }
                    .padding(.horizontal, safeHorizontalPadding)
                    .padding(.top, 2)
                    .padding(.bottom, safeBottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 0.018),
                            .init(color: .white, location: 0.985),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func retainedWindowPage(_ page: TatwoPage) -> some View {
        if retainedWindowPages.contains(page) || selection == page {
            pageContent(for: page)
                .padding(.horizontal, 0)
                .padding(.top, 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(selection == page ? 1 : 0)
                .allowsHitTesting(selection == page)
                .accessibilityHidden(selection != page)
                .zIndex(selection == page ? 2 : 0)
        }
    }

    @ViewBuilder
    private func pageContent(for page: TatwoPage) -> some View {
        switch page {
        case .chat:
            if surface == .panel {
                TatwoPanelChatLauncher()
            } else {
                ChatPage(
                    model: chatModel,
                    retainedLifecycle: retainedChatLifecycle,
                    quotaProviders: catalog.usageProviders,
                    initialLiveQuotaSnapshot: liveQuotaSnapshot,
                    gatewayLiveStatus: liveGatewayStatus,
                    rightPanelPreference: $rightPanelPreference,
                    isRightPanelOpen: $isRightPanelOpen
                )
            }
        case .usage:
            UsagePage(snapshot: snapshot, initialLiveSnapshot: liveQuotaSnapshot)
        // 2026-08-20 使用者裁決：模式／情境／特質三分頁雞肋，收成一頁
        // 總覽（不留深潛層）。三個 case 都導到同一頁，深連結不斷。
        // 舊 ModesPage/ScenariosPage/TraitsPage 保留原檔（刪除鐵律），
        // 僅退出路由。
        case .modes, .scenarios, .compatibility:
            TatwoConfigOverviewPage(
                modes: catalog.workModes,
                selectedMode: snapshot.selectedMode,
                profiles: TatwoIdentityCatalog.scenarioProfiles,
                previewScenarioProfileID: $previewScenarioProfileID,
                issuedContract: issuedModesContract,
                issuedIntegrityState: issuedModesIntegrityState,
                modelTraits: TeamRoutingCatalog.modelTraits
            ) { profile in
                previewScenarioProfileID = profile.id
                if let scenario = profile.baseScenario {
                    updateSnapshot(scenario: scenario)
                }
            }
        case .plugins:
            PluginsPage(
                entries: catalog.plugins,
                environment: snapshot.environment.components,
                skillsDirectoryCatalog: TatwoSkillsDirectoryCatalog(rootURL: TatwoSkillsDirectoryCatalog.defaultRoot()),
                skilletRepositoryStore: TatwoSkilletRepositoryStore(
                    rootURL: DeviceSyncOutboxStore.defaultApplicationSupportRootPublic()
                        .appendingPathComponent("skillet", isDirectory: true)
                ),
                onRegister: registerPlugin,
                onRemove: removePlugin,
                onSyncClaude: syncPluginsToClaude,
                pocketThreadID: chatModel.selectedThreadID
            )
        case .devices:
            DevicesPage(chatModel: chatModel)
        case .workflow:
            OSOverviewPage(model: chatModel)   // 2.0：Ultra 手冊頁換成 OS 架構總覽（New/OSOverviewPage.swift）
        }
    }
}

private struct TatwoPanelChatLauncher: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    var body: some View {
        GlassCard {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chat")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("在 OS 視窗開啟")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    NotificationCenter.default.post(
                        name: .tatwoOpenWorkOSWindow,
                        object: TatwoPage.chat.rawValue
                    )
                    NotificationCenter.default.post(name: .tatwoCloseStatusPanel, object: nil)
                } label: {
                    Text("打開")
                        .font(.caption.weight(.black))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                        .chatGlassChip(isSelected: true)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct TatwoPanelHeader: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @Binding var selection: TatwoPage
    let snapshot: TatwoAppSnapshot
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LiquidGlassTokens.ultraworkGradient)
                        .opacity(LiquidGlassTokens.tintOpacity)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    LiquidGlassTokens.tint.opacity(
                                        LiquidGlassTokens.strokeOpacity
                                    )
                                )
                        }
                    Image(systemName: "sparkles.rectangle.stack")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 16, weight: .bold))
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Tatwo Ultrawork")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Work OS 控制台")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 132, alignment: .leading)

                Spacer()

                Badge(snapshot.selectedMode.rawValue)
                Button {
                    NotificationCenter.default.post(name: .tatwoOpenWorkOSWindow, object: nil)
                } label: {
                    Label("OS 窗", systemImage: "macwindow")
                        .font(.caption.weight(.black))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .chatGlassChip()
                }
                .buttonStyle(.plain)
                .help("用正常 App 視窗打開大型 WorkOS 圖")
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 24)
                        .chatGlassChip()
                }
                .buttonStyle(.plain)
                .help("重新載入 App snapshot（只讀）")

                Button {
                    NotificationCenter.default.post(name: .tatwoCloseStatusPanel, object: nil)
                } label: {
                    Label("收起", systemImage: "xmark")
                        .font(.caption.weight(.black))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Color.red.opacity(0.10), in: Capsule())
                        .foregroundStyle(Color.red.opacity(0.92))
                }
                .buttonStyle(.plain)
                .help("收起工具列窗")
            }

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(TatwoPageNavigationPolicy.menuBarOSPages) { page in
                        Button {
                            selection = page
                        } label: {
                            TatwoPageNavButton(page: page, isSelected: selection == page)
                        }
                        .buttonStyle(.plain)
                        .help("\(page.stepNumber). \(page.title)：\(page.subtitle)")
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
        .padding(LiquidGlassTokens.radiusChip)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
    }
}

struct TatwoWindowPageRail: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let isRightPanelOpen: Bool
    let toggleRightPanel: () -> Void
    // Chat 模式的右面板開關已由頁內 icon-only rightPanelControlStrip（資訊卡/瀏覽器/檔案）
    // 承擔並對齊 Codex（#50/#51）；band 不再自帶重複的 sidebar.right toggle，避免兩層混一起。
    var showRightPanelToggle: Bool = true

    // 瀏覽器 overlay 齊頂後其工具列（分頁/＋/齒輪）畫進 band 區；拖曳
    // NSView 必須讓出 overlay 的水平範圍，否則 performDrag 吃掉點擊
    //（同 chatRightControlsReserve 先例，2026-07-12「按鈕沒反應」根因）。
    @AppStorage("tatwo.chat.browserOverlayOpen")
    private var browserOverlayOpen: Bool = false
    @AppStorage("tatwo.chat.browserPanelWidth")
    private var browserPanelWidth: Double = 480

    var body: some View {
        HStack(spacing: WindowChromeMetrics.controlSpacing) {
            Color.clear
                .frame(width: WindowChromeMetrics.trafficLightSafeWidth)
                .allowsHitTesting(false)

            TatwoWindowDragRegion()
                .frame(minWidth: 24, maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)

            if browserOverlayOpen {
                Color.clear
                    .frame(width: CGFloat(max(browserPanelWidth, 420)))
                    .allowsHitTesting(false)
            }

            if showRightPanelToggle {
                Button(action: toggleRightPanel) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 26)
                        .foregroundStyle(
                            isRightPanelOpen
                                ? LiquidGlassTokens.brandAccent
                                : Color.secondary
                        )
                        .chatGlassChip(isSelected: isRightPanelOpen)
                }
                .buttonStyle(.plain)
                .help(isRightPanelOpen ? "Hide side panel" : "Show side panel")
                .accessibilityLabel("Toggle side panel")
                .accessibilityValue(isRightPanelOpen ? "Open" : "Closed")
            } else {
                // Chat：頂右互動由頁內 icon strip 承載；拖曳區讓出這塊，否則 NSView 吃掉 strip 點擊（按鈕沒反應根因）。
                Color.clear
                    .frame(width: WindowChromeMetrics.chatRightControlsReserve)
                    .allowsHitTesting(false)
            }
        }
        .padding(.trailing, WindowChromeMetrics.headerHorizontalInset)
        .frame(height: WindowChromeMetrics.bandHeight)
    }
}

struct CompactPageTitle: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let page: TatwoPage

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(page.stepNumber)/\(TatwoPage.allCases.count)")
                        .font(.caption.weight(.black))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                        .chatGlassChip(isSelected: true)
                    Image(systemName: page.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 22)
                    Text(page.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Spacer()
                }
                Text(page.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("snapshot", systemImage: "camera.metering.center.weighted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
