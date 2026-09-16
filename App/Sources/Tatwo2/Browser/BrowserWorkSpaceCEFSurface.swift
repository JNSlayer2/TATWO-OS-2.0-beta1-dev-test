import SwiftUI
import Combine

/// One human profile across all work spaces: cookies and credentials belong to the person,
/// not the space. Native tabs survive SwiftUI removal; only close/sleep releases them.
@MainActor
final class BrowserWorkSpaceRuntime: ObservableObject {
    static let shared = BrowserWorkSpaceRuntime()
    static let profile = EmbeddedBrowserRuntimeProfile.persistent(
        UUID(uuidString: "00000000-0000-0000-0000-000000000047")!)
    private struct ChatRuntimeKey: Hashable {
        let registry: ObjectIdentifier
        let sessionID: String
    }
    private final class WeakRuntime {
        weak var value: BrowserWorkSpaceRuntime?
        init(_ value: BrowserWorkSpaceRuntime) { self.value = value }
    }
    private static var chatRuntimes: [ChatRuntimeKey: BrowserWorkSpaceRuntime] = [:]
    private static var retiredRuntimes: [ChatRuntimeKey: WeakRuntime] = [:]
    private static var memoryRuntimes: [WeakRuntime] = []
    private static var memorySource: DispatchSourceMemoryPressure?
    private static var settingsObservation: AnyCancellable?
    private static var memorySettings = BrowserMemorySettings.load()
    private(set) static var memoryPressure = BrowserMemoryPressure.normal
    static var memoryPressureText: String { memorySource == nil ? "尚未監看" : memoryPressure.title }
    private static var enforcingMemory = false
    private(set) static var protectedMemoryTabCount = 0
    private static var lastProtectionNotice = Date.distantPast

    private static func startMemoryMonitoring() {
        guard memorySource == nil else { return }
        // Diagnostics can construct the budget before any browser opens. A
        // settings edit in that interval has no runtime observer yet.
        memorySettings = BrowserMemorySettings.load()
        BrowserNativeMemoryBudget.shared.configure(limit: memorySettings.limit())
        // Swift's DISPATCH_SOURCE_TYPE_MEMORYPRESSURE wrapper; event-driven,
        // main-actor serialized and independent of the diagnostics sheet.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let flags = source.data
                handleMemoryPressure(flags.contains(.critical) ? .critical : flags.contains(.warning) ? .warning : .normal)
            }
        }
        memorySource = source
        source.resume()
        settingsObservation = NotificationCenter.default.publisher(for: BrowserMemorySettings.changed)
            .receive(on: DispatchQueue.main).sink { _ in
                applyMemorySettings(BrowserMemorySettings.load())
            }
    }

    private static func applyMemorySettings(_ settings: BrowserMemorySettings) {
        memorySettings = settings
        BrowserNativeMemoryBudget.shared.configure(limit: settings.limit())
        enforceMemoryPolicy()
        for runtime in memoryRuntimes.compactMap(\.value) { runtime.sleepIdleTabs(now: Date()) }
    }

    static func handleMemoryPressure(_ pressure: BrowserMemoryPressure) {
        memoryPressure = pressure
        let count = enforceMemoryPolicy()
        if pressure == .critical, protectedMemoryTabCount > 0,
           Date().timeIntervalSince(lastProtectionNotice) > 15 {
            lastProtectionNotice = Date()
            IslandNotice.shared.info(title: "記憶體吃緊，已保留進行中的分頁",
                detail: "有編輯、播放或下載中的內容；請先儲存，再手動關閉不需要的分頁。", duration: 10)
        } else if pressure == .critical, count > 0 {
            IslandNotice.shared.info(title: "記憶體吃緊，已釋放 \(count) 個分頁",
                                     detail: "點回分頁即可重新載入", duration: 6)
        }
    }

    @discardableResult
    private static func enforceMemoryPolicy() -> Int {
        guard !enforcingMemory else { return 0 }
        enforcingMemory = true
        defer { enforcingMemory = false }
        memoryRuntimes.removeAll { $0.value == nil }
        let runtimes = memoryRuntimes.compactMap(\.value)
        // One app-wide allowance across chat profiles and work spaces, not
        // four per session. Only mounted surfaces own protected selections.
        let selected = Set(runtimes.compactMap(\.selectedID))
        let protected = Set(runtimes.flatMap { runtime in
            (runtime.host?.protectedTabIDs ?? []).compactMap(UUID.init(uuidString:))
        })
        protectedMemoryTabCount = protected.count
        // Protecting all old tabs must not prevent admission of the new
        // selected tab. Closing native slots still remain counted until CEF
        // completes; only the floor for live protected selections is raised.
        BrowserNativeMemoryBudget.shared.configure(limit: memorySettings.limit(),
            protectedMinimum: selected.union(protected).count)
        var tabs: [UUID: BrowserTab] = [:]
        for runtime in runtimes {
            for tab in runtime.workTabs { tabs[tab.id] = tab }
        }
        let victims = BrowserMemoryPolicy.sleepCandidates(tabs: tabs.values.map {
            .init(id: $0.id, lastActiveAt: $0.lastActiveAt, isSleeping: $0.isSleeping)
        }, selected: selected, limit: memorySettings.limit(), protected: protected, pressure: memoryPressure)
        for id in victims {
            for runtime in runtimes where runtime.workTabs.contains(where: { $0.id == id }) {
                runtime.sleepTab(id)
            }
        }
        // Close victims before any host is allowed to create the next browser.
        for runtime in runtimes { runtime.updateHost(); runtime.retireIfUnused() }
        return victims.count
    }
    static func forChat(_ sessionID: String, registry: BrowserTabRegistry? = nil) -> BrowserWorkSpaceRuntime {
        let registry = registry ?? .shared
        let key = ChatRuntimeKey(registry: ObjectIdentifier(registry), sessionID: sessionID)
        if let runtime = chatRuntimes[key] { return runtime }
        retiredRuntimes = retiredRuntimes.filter { $0.value.value != nil }
        if let runtime = retiredRuntimes[key]?.value { return runtime }
        let profile = TatwoBrowserProfileIdentity(sessionID: sessionID)!.dataStoreIdentifier
        let runtime = BrowserWorkSpaceRuntime(owner: .chatSession(sessionID: sessionID), profile: .persistent(profile), registry: registry)
        retiredRuntimes[key] = WeakRuntime(runtime)
        return runtime
    }
    let owner: BrowserTabOwner?
    let runtimeProfile: EmbeddedBrowserRuntimeProfile
    @Published private(set) var shortcutSerial = 0
    private(set) var shortcutKind = ""
    @Published private(set) var findCount = 0
    @Published private(set) var findIndex = 0
    @Published private(set) var navigationTabID: UUID?
    @Published private(set) var navigationState = EmbeddedBrowserNavigationState.blank
    @Published private(set) var access : EmbeddedBrowserProfileAccessState
    @Published private(set) var error: String?
    private var host: TatwoCEFTabHostView?
    private var selectedID: UUID?
    @Published private(set) var surfaceID: UUID?
    private var command: EmbeddedBrowserCommand?
    private var geometryDragInProgress = false
    private var onPopup: ((UUID, URL) -> Void)?
    private var observations: Set<AnyCancellable> = []
    private let registry: BrowserTabRegistry

    private init(owner: BrowserTabOwner? = nil, profile: EmbeddedBrowserRuntimeProfile? = nil,
                 registry: BrowserTabRegistry? = nil) {
        self.registry = registry ?? .shared
        self.owner = owner
        runtimeProfile = profile ?? Self.profile
        access = .checking(profileKey: runtimeProfile.registryKey)
        Self.memoryRuntimes.append(WeakRuntime(self))
        Self.startMemoryMonitoring()
        self.registry.changes.receive(on: DispatchQueue.main).sink { [weak self] in self?.reconcile() }
            .store(in: &observations)
        Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] now in
            self?.sleepIdleTabs(now: now)
        }.store(in: &observations)
    }

    func authorize() async {
        guard !access.isReady(for: runtimeProfile.registryKey) else { return }
        let result = await EmbeddedBrowserProfileAccessCoordinator.live.recordAccessAndEnforce(
            profile: runtimeProfile, engine: .chromiumCEF)
        guard !Task.isCancelled else { return }
        switch result {
        case .success: access = .ready(profileKey: runtimeProfile.registryKey)
        case let .failure(failure): access = .blocked(profileKey: runtimeProfile.registryKey, failure: failure)
        }
    }

    func mount() -> TatwoCEFTabHostView {
        if let owner, case let .chatSession(sessionID) = owner {
            let key = ChatRuntimeKey(registry: ObjectIdentifier(registry), sessionID: sessionID)
            Self.chatRuntimes[key] = self
            Self.retiredRuntimes.removeValue(forKey: key)
        }
        if let host { return host }
        let host = TatwoCEFTabHostView(mountIdentity: EmbeddedChromiumBrowserMountIdentity(profile: runtimeProfile)) {
            [weak self] id, state in self?.receive(id, state: state)
        }
        host.onDailyShortcut = { [weak self] id, kind in
            guard let self, id == self.selectedID?.uuidString else { return }
            self.shortcutKind = kind
            self.shortcutSerial &+= 1
        }
        host.onFindResult = { [weak self] id, count, index in
            guard let self, id == self.selectedID?.uuidString else { return }
            if count >= 0 { self.findCount = count }
            if count == 0 { self.findIndex = 0 }
            else if index >= 0 { self.findIndex = index }
        }
        host.onPageMetadataChange = { [weak self] id, url, title, favicon in
            guard let self, let uuid = UUID(uuidString: id), let tab = self.workTabs.first(where: { $0.id == uuid }),
                  !tab.isSleeping, tab.url?.absoluteString == url else { return }
            self.registry.update(uuid, url: tab.url, title: title ?? tab.title, favicon: favicon ?? tab.faviconPNG)
        }
        host.onTabPopupRequested = { [weak self] sourceID, url in
            guard let self, let id = UUID(uuidString: sourceID),
                  let source = self.workTabs.first(where: { $0.id == id }) else { return }
            if id == self.selectedID, case let .workSpace(spaceID) = source.owner, let onPopup = self.onPopup {
                onPopup(spaceID, url)
            } else {
                let selected = self.registry.selectedTab(ownedBy: source.owner)?.id
                _ = self.registry.openTab(owner: source.owner, url: url, folderID: source.folderID)
                if let selected { self.registry.select(selected) }
            }
        }
        host.onIdle = { [weak self] in self?.retireIfUnused() }
        self.host = host
        return host
    }

    @discardableResult
    func select(_ id: UUID, surfaceID: UUID, command: EmbeddedBrowserCommand?, isGeometryDragInProgress: Bool = false, onPopup: @escaping (UUID, URL) -> Void) -> Bool {
        // One NSView cannot belong to two windows. A second surface waits rather than
        // reparenting the active window's browser or dispatching its commands there.
        guard workTabs.contains(where: { $0.id == id }),
              self.surfaceID == nil || self.surfaceID == surfaceID else { return false }
        if self.surfaceID != surfaceID { self.surfaceID = surfaceID }
        _ = mount()
        if selectedID != id {
            if let selectedID { registry.touch(selectedID) } // idle starts on departure, not arrival
            findCount = 0; findIndex = 0
            selectedID = id
            navigationTabID = id
            navigationState = .blank
            error = nil
            registry.touch(id)
            if workTabs.first(where: { $0.id == id })?.isSleeping == true { registry.markSleeping(id, false) }
        }
        self.command = command
        geometryDragInProgress = isGeometryDragInProgress
        self.onPopup = onPopup
        reconcile()
        return true
    }

    func detach(surfaceID: UUID) {
        guard self.surfaceID == surfaceID else { return }
        if let selectedID { registry.touch(selectedID) }
        self.surfaceID = nil
        selectedID = nil
        command = nil
        onPopup = nil
        reconcile()
        retireIfUnused()
    }

    /// Retire only after native OnBeforeClose released the lease. Quick reopen can
    /// otherwise race a second context against an asynchronously closing profile.
    private func retireIfUnused() {
        guard let owner, case let .chatSession(sessionID) = owner, surfaceID == nil,
              workTabs.allSatisfy(\.isSleeping), host?.isIdle != false else { return }
        let key = ChatRuntimeKey(registry: ObjectIdentifier(registry), sessionID: sessionID)
        guard Self.chatRuntimes[key] === self else { return }
        Self.chatRuntimes.removeValue(forKey: key)
        // A still-mounted empty panel may open another tab without reconstruction.
        // Keep only a weak lookup so that panel reuses its controller, not a second profile.
        Self.retiredRuntimes[key] = WeakRuntime(self)
        host?.onIdle = nil
        host?.close()
        host = nil
    }

    private var workTabs: [BrowserTab] {
        if let owner { return registry.tabs(ownedBy: owner) }
        return registry.tabs.filter { if case .workSpace = $0.owner { return true }; return false }
    }

    private func reconcile() {
        Self.enforceMemoryPolicy()
        updateHost()
    }

    private func updateHost() {
        let tabs = workTabs
        let selected = tabs.first { $0.id == selectedID && !$0.isSleeping }
        if selected == nil { command = nil }
        host?.update(tabID: selected?.id.uuidString,
            initialURL: selected.map { $0.url ?? URL(string: "about:blank")! },
            isAgentTab: selected?.usesAgentContext == true,
            openTabIDs: Set(tabs.filter { !$0.isSleeping }.map { $0.id.uuidString }),
            command: command, isGeometryDragInProgress: geometryDragInProgress)
    }

    private func sleepIdleTabs(now: Date) {
        let interval = Self.memorySettings.idleInterval()
        for tab in workTabs where !tab.isSleeping && BrowserTabSleepPolicy.shouldSleep(
            lastActiveAt: tab.lastActiveAt, now: now, isSelected: tab.id == selectedID, interval: interval) {
            sleepTab(tab.id)
        }
        reconcile()
        retireIfUnused()
    }

    private func sleepTab(_ id: UUID) {
        guard id != selectedID, let tab = workTabs.first(where: { $0.id == id }), !tab.isSleeping,
              host?.preventsAutomaticSleep(tabID: id.uuidString) != true else { return }
        host?.flushTabState(tab.id.uuidString)
        registry.markSleeping(tab.id, true)
    }

    private func receive(_ id: String, state: EmbeddedBrowserNavigationState) {
        guard let uuid = UUID(uuidString: id), let tab = workTabs.first(where: { $0.id == uuid }), !tab.isSleeping else { return }
        registry.setLoading(uuid, state.isLoading)
        if uuid == selectedID {
            error = state.visibleError?.message
            navigationTabID = uuid
            navigationState = state
        }
        guard let url = EmbeddedBrowserView.committedURLForPersistence(state) else { return }
        registry.update(uuid, url: url, title: tab.title, favicon: tab.url == url ? tab.faviconPNG : nil)
    }
}

struct BrowserWorkSpaceCEFSurface: View {
    let tabID: UUID
    let spaceID: UUID
    let command: EmbeddedBrowserCommand?
    let onPopup: (UUID, URL) -> Void
    @State private var surfaceID = UUID()
    @ObservedObject var runtime: BrowserWorkSpaceRuntime = .shared
    var isGeometryDragInProgress = false

    init(tabID: UUID, spaceID: UUID, command: EmbeddedBrowserCommand?, onPopup: @escaping (UUID, URL) -> Void,
         runtime: BrowserWorkSpaceRuntime? = nil, isGeometryDragInProgress: Bool = false,
         surfaceID: UUID = UUID()) {
        self.tabID = tabID
        self.spaceID = spaceID
        self.command = command
        self.onPopup = onPopup
        self.isGeometryDragInProgress = isGeometryDragInProgress
        _runtime = ObservedObject(wrappedValue: runtime ?? .shared)
        _surfaceID = State(initialValue: surfaceID)
    }

    @State private var retryCommand: EmbeddedBrowserCommand?

    var body: some View {
        Group {
            if EmbeddedBrowserEnginePolicy.current != .chromiumCEF {
                BrowserEngineUnavailablePlaceholder()
            } else if EmbeddedBrowserRuntimeMountPolicy.allowsMount(state: runtime.access,
                profileKey: runtime.runtimeProfile.registryKey) {
                BrowserWorkSpaceNativeSurface(runtime: runtime, surfaceID: surfaceID, tabID: tabID, command: retryCommand ?? command, onPopup: onPopup, isGeometryDragInProgress: isGeometryDragInProgress)
                    .overlay(alignment: .bottom) {
                        if let owner = runtime.surfaceID, owner != surfaceID {
                            Text("瀏覽器正在另一個視窗使用").font(.callout).padding(BrowserSidebarMetrics.laneRowSpacing)
                        } else if runtime.navigationTabID == tabID {
                            BrowserSurfaceStateOverlay(navigationState: runtime.navigationState) {
                                retryCommand = EmbeddedBrowserCommand(action: .reload)
                            }
                        }
                    }
            } else {
                VStack {
                    if case let .blocked(_, failure) = runtime.access {
                        Text(failure.visibleMessage)
                        Button("重試") { Task { await runtime.authorize() } }
                    } else { ProgressView() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(TatwoActivePalette.current.canvasBase)
        .task { if EmbeddedBrowserEnginePolicy.current == .chromiumCEF { await runtime.authorize() } }
        .onChange(of: command?.id) { _, _ in retryCommand = nil }
        .onChange(of: tabID) { _, _ in retryCommand = nil }
    }
}

private struct BrowserWorkSpaceNativeSurface: NSViewRepresentable {
    let runtime: BrowserWorkSpaceRuntime
    let surfaceID: UUID
    let tabID: UUID
    let command: EmbeddedBrowserCommand?
    let onPopup: (UUID, URL) -> Void
    var isGeometryDragInProgress = false
    final class Coordinator {
        let id: UUID
        let runtime: BrowserWorkSpaceRuntime
        var revision = 0
        var active = true
        init(id: UUID, runtime: BrowserWorkSpaceRuntime) { self.id = id; self.runtime = runtime }
    }
    func makeCoordinator() -> Coordinator { Coordinator(id: surfaceID, runtime: runtime) }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.revision += 1
        let revision = coordinator.revision
        DispatchQueue.main.async {
            guard coordinator.active, coordinator.revision == revision else { return }
            guard runtime.select(tabID, surfaceID: coordinator.id, command: command, isGeometryDragInProgress: isGeometryDragInProgress, onPopup: onPopup) else { return }
            let host = runtime.mount()
            if host.superview !== container {
                host.removeFromSuperview()
                host.frame = container.bounds
                host.autoresizingMask = [.width, .height]
                container.addSubview(host)
            }
        }
    }
    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.active = false
        coordinator.runtime.detach(surfaceID: coordinator.id)
    }
}

// Shared text tokens for chat and work space state surfaces.
enum BrowserSurfaceText {
    static let unavailable = "此建置未包含 Chromium 引擎，瀏覽器無法使用"
    static let navigationFailure = "無法載入網頁"
    static let subprocessRestart = "瀏覽器子程序已停止"
    static let reload = "重新載入"
    static func diagnostic(_ message: String, code: Int) -> String { "\(message)（code \(code)）" }
}

struct BrowserEngineUnavailablePlaceholder: View {
    var body: some View {
        VStack(spacing: BrowserSidebarMetrics.rowHorizontalPadding) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: BrowserSidebarMetrics.stateIconSize, weight: .semibold)).foregroundStyle(.secondary)
            Text(BrowserSurfaceText.unavailable)
                .font(.system(size: BrowserSidebarMetrics.stateTitleFontSize, weight: .semibold)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }.padding(BrowserSidebarMetrics.laneCardPadding).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BrowserSurfaceStateOverlay: View {
    let navigationState: EmbeddedBrowserNavigationState
    let onRetry: () -> Void
    @ViewBuilder
    var body: some View {
        switch EmbeddedBrowserSurfacePresentation.condition(
            for: navigationState)
        {
        // W60: navigation is deliberately quiet; the toolbar owns progress.
        // HTTP errors belong to the document (including its own 404 page).
        case .none, .pageCreating, .loadedAwaitingPaint, .blankNoncommitted, .httpFailure:
            EmptyView()
        case let .blockedBySecurity(message):
            browserStateCard(
                title:
                    EmbeddedBrowserSecurityStatusPresentation
                        .title(for: message),
                detail: message,
                systemImage: "exclamationmark.shield.fill",
                color: .orange)
                .accessibilityIdentifier(
                    "embedded-browser-security-block")
        case let .navigationFailure(message, code):
            browserStateCard(
                title: BrowserSurfaceText.navigationFailure,
                detail: diagnosticDetail(message: message, code: code),
                systemImage: "wifi.exclamationmark",
                color: .red,
                retry: onRetry)
                .accessibilityIdentifier(
                    "embedded-browser-navigation-failure")
        case let .subprocessRestart(message, code):
            browserStateCard(
                title: BrowserSurfaceText.subprocessRestart,
                detail: diagnosticDetail(message: message, code: code),
                systemImage: "exclamationmark.triangle.fill",
                color: .red,
                retry: onRetry)
                .accessibilityIdentifier(
                    "embedded-browser-subprocess-restart")
        }
    }

    private func browserStateCard(
        title: String,
        detail: String,
        systemImage: String,
        color: Color,
        retry: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: BrowserSidebarMetrics.rowHorizontalPadding) {
            Image(systemName: systemImage)
                .font(.system(size: BrowserSidebarMetrics.stateIconSize, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: BrowserSidebarMetrics.stateTitleFontSize, weight: .semibold))
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: BrowserSidebarMetrics.stateDetailMaxWidth)
            }
            if let retry {
                Button(BrowserSurfaceText.reload, action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(BrowserSidebarMetrics.laneCardPadding)
        .background(.regularMaterial)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func diagnosticDetail(
        message: String,
        code: Int?
    ) -> String {
        guard let code else { return message }
        return BrowserSurfaceText.diagnostic(message, code: code)
    }

}
