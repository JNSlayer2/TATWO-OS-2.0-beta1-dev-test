import Foundation
import Combine
import TatwoCEFBridge

@MainActor
final class BrowserDiagnostics: ObservableObject {
    @Published private(set) var report = BrowserDiagnosticsReport()
    @Published private(set) var isRefreshing = false
    private static var memoryWarning = BrowserMemoryWarningThrottle()
    private let registry: BrowserTabRegistry
    private let settings: BrowserDiagnosticsSettings

    init(registry: BrowserTabRegistry? = nil, settings: BrowserDiagnosticsSettings = .init()) {
        self.registry = registry ?? .shared
        self.settings = settings
    }

    /// Owned by the sheet's .task: cancellation stops polling on dismissal.
    /// No retained Timer, observer, or singleton poller survives the page.
    func observe() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
        }
    }

    private func refresh() async {
        let helperRoot = Bundle.main.privateFrameworksURL?.path
        let auditURL = TatwoWebMCPRuntime.auditURL
        let aiLoginURL = BrowserDiagnosticsAudit.aiLoginURL
        // libproc/sysctl and the bounded file tail do not block the UI actor.
        let worker = Task.detached(priority: .utility) {
            (BrowserProcessSampler.sample(helperRoot: helperRoot), BrowserDiagnosticsAudit.readTail(at: auditURL),
             BrowserDiagnosticsAudit.readTail(at: aiLoginURL))
        }
        let (processes, audit, aiLogins) = await worker.value
        guard !Task.isCancelled else { return }
        let telemetry = BrowserEngineStartupTelemetry.shared
        var snapshot = BrowserDiagnosticsReport()
        snapshot.version = BrowserRuntimeVersion.bundledDescription
        snapshot.engine = "\(telemetry.state.rawValue)（\(EmbeddedBrowserEnginePolicy.current.rawValue)）"
        snapshot.startupMilliseconds = telemetry.startupMilliseconds
        snapshot.sleepSeconds = BrowserTabSleepPolicy.idleInterval
        snapshot.liveTabLimit = BrowserMemorySettings.load().limit()
        snapshot.memoryPressure = BrowserWorkSpaceRuntime.memoryPressureText
        snapshot.nativeBrowserCount = BrowserNativeMemoryBudget.shared.count
        snapshot.memoryWarningMB = settings.memoryWarningMB
        snapshot.processes = processes
        snapshot.processHealth = BrowserProcessHealth(TatwoCEFRuntime.processDiagnostics())
        snapshot.processStatus = helperRoot == nil ? "非 App bundle；helper 無法列舉"
            : processes.contains(where: { $0.footprintBytes == nil }) ? "部分程序已結束或無權讀取，總和僅含已讀值" : "目前 App 與其 CEF helper"
        var owners: [BrowserTabOwner: String] = [:]
        snapshot.tabs = registry.tabs.map { tab in
            if owners[tab.owner] == nil {
                let kind: String
                switch tab.owner {
                case .workSpace: kind = "workSpace"
                case .chatSession: kind = "chatSession"
                case .bot: kind = "bot"
                }
                owners[tab.owner] = "\(kind) \(owners.count + 1)" // No private session/bot IDs.
            }
            let tools = registry.runtimeTabID(for: tab.id)
                .flatMap { TatwoWebMCPRuntime.shared.pageTools(tabID: $0) }?.tools ?? []
            return BrowserDiagnosticsTab(id: tab.id, owner: owners[tab.owner]!,
                title: BrowserDiagnosticsPrivacy.text(tab.title), host: BrowserDiagnosticsPrivacy.host(tab.url?.host),
                sleeping: tab.isSleeping, lastActive: tab.lastActiveAt,
                tools: tools.map { "\(BrowserDiagnosticsPrivacy.text($0.name)) | \(String(describing: $0.effect))" })
        }
        snapshot.audit = audit
        snapshot.aiLogins = aiLogins
        snapshot.policies = BrowserPolicyLog.shared.recent(50)
        report = snapshot
        if Self.memoryWarning.shouldWarn(helperMB: snapshot.helperMB, thresholdMB: settings.memoryWarningMB,
                                         uptime: ProcessInfo.processInfo.systemUptime) {
            IslandNotice.shared.info(title: "瀏覽器佔用較多記憶體",
                detail: "\(Int(snapshot.helperMB.rounded())) MB；睡眠分頁可釋放", duration: 6)
        }
    }
}
