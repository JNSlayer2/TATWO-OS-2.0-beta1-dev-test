import SwiftUI
import AppKit

// 2.0 入口：照 1.0 AppShell.swift:181 的 AppKit main 走同一條路（同一個 AppDelegate 建視窗、裝靈動島、隱藏標題列），
// 畫面才會跟 1.0 真機一致。差別只有：多了 SelfTest 鉤子，治理/水電守門走 Facade 假資料版。
@main
enum Tatwo2App {
    @MainActor
    static func main() {
        // Snapshot before launch environment sanitization; CEF snapshots in +load.
        _ = StagingBrowserLoopbackPolicy.runtimeEnvironment
        _ = StagingBrowserLoopbackPolicy.runtimeBundleIdentifier
        if let error = NativeStagingIsolation.validationError(ProcessInfo.processInfo.environment) {
            fputs("Tatwo2 staging blocked: \(error)\n", stderr)
            exit(78)
        }
        signal(SIGPIPE, SIG_IGN)   // 任何 socket／pipe 對端先關，都不准把 App 殺掉
        ExportPrefsShield.applyIfExporting()   // 匯出只看 env，不讀使用者／debug 偏好網域
        CallerBindingAcceptance.runIfRequested()
        JobsIndexAcceptance.runIfRequested()
        GlobalNoteStore.runTestIfRequested()
        if OSBindingAcceptance.runIfRequested() { dispatchMain() }
        SelfTest.runIfRequested()
        SidecarGroupedProcess.reapRecordedGroups()
        SidecarTerminationObserver.install()
        ChatNativeSubscriptionEnvironment.scrubCurrentProcessCredentials()
        TatwoLaunchEnvironmentGuard.sanitizeInheritedExternalVolumeEnvironment()
        TatwoLaunchEnvironmentGuard.moveWorkingDirectoryOffExternalVolumes()
        let application: NSApplication = TatwoCEFApplication.shared
        application.setActivationPolicy(TatwoLaunchSurfacePolicy.initialActivationPolicy())
        TatwoLaunchEnvironmentGuard.configureHostResourceGovernorAtLaunch()
        if TatwoPanelSnapshotExporter.exportIfRequested() { return }
        if TatwoSingleInstanceGuard.forwardToExistingInstanceAndExitIfNeeded() { return }
        BrowserTabRegistry.shared.prepareForLaunch()
        let delegate = TatwoUltraworkAppDelegate()
        retainedTatwoAppDelegate = delegate
        let cliDelegate = Tatwo2CLITerminationDelegate(wrapped: delegate)
        retainedCLITerminationDelegate = cliDelegate
        application.delegate = cliDelegate
        application.run()
    }
}


private final class SidecarTerminationObserver {
    private static var token: NSObjectProtocol?

    static func install() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            OSAgentBridge.shared.stopBackgroundJobs()   // 背景長工作跟 sidecar 一起收，不留孤兒
            SidecarGroupedProcess.terminateAll()
        }
    }
}

// CLI sessions remain attached while Quit is merely being confirmed.
@MainActor private var retainedCLITerminationDelegate: Tatwo2CLITerminationDelegate?

@MainActor private final class Tatwo2CLITerminationDelegate: NSObject, NSApplicationDelegate {
    let wrapped: TatwoUltraworkAppDelegate
    init(wrapped: TatwoUltraworkAppDelegate) { self.wrapped = wrapped; super.init() }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || wrapped.responds(to: selector)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        wrapped.responds(to: selector) ? wrapped : super.forwardingTarget(for: selector)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return wrapped.applicationShouldTerminate(sender)
    }
    func applicationWillTerminate(_ notification: Notification) {
        // This function always returns true after synchronously saving, detaching
        // and finishing pending writes. Run it only after AppKit accepted Quit.
        _ = CLISessionsTermination.shouldTerminate()
        wrapped.applicationWillTerminate(notification)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        wrapped.application(application, open: urls)
    }
}
