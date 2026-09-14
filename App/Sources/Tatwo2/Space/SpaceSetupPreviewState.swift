import Foundation
import SwiftUI
import Combine

/// UI-first review surface. Never reads a Bot store, starts an engine or persists data.
/// Remove this opt-in surface only after the human UI gate and production wiring.
@MainActor
final class SpaceSetupPreviewState: ObservableObject {
    static let isEnabled = ProcessInfo.processInfo.environment["TATWO_SPACE_SETUP_UI_PREVIEW"] == "1"
    static let shared = SpaceSetupPreviewState()

    enum Screen { case settings, builder, interface, conversation, tab(Tab) }
    /// Value identity for a top-level work space, including custom IDs.
    struct Tab: RawRepresentable, CaseIterable, Identifiable, Hashable {
        let rawValue: String
        init?(rawValue: String) {
            guard !rawValue.isEmpty else { return nil }
            self.rawValue = rawValue
        }
        static let chat = Self(rawValue: "Chat")!
        static let cli = Self(rawValue: "CLI")!
        static let bot = Self(rawValue: "Bot")!
        static let browser = Self(rawValue: "Browser")!
        static let allCases: [Self] = [.chat, .cli, .bot, .browser]
        var id: String { rawValue }
        var isCustom: Bool { !Self.allCases.contains(self) }
        var symbol: String {
            switch self {
            case .chat: "bubble.left"
            case .cli: "terminal"
            case .bot: "person.crop.square"
            case .browser: "globe"
            default: "square.dashed"
            }
        }
    }
    struct Bot: Identifiable, Equatable {
        let id: String
        let name: String
    }
    struct WorkInterface: Identifiable {
        let id: String
        let name: String
        let bot: Bot
        let specification: String
        // A shared conversation reference, not a copied transcript per entrypoint.
        let conversationID: String
    }
    @MainActor
    final class Domain: ObservableObject, Identifiable {
        let id: String
        let name: String
        @Published var screen: Screen = .builder
        @Published var tabs = Tab.allCases
        @Published var customTabs: [String: String] = [:]
        @Published var enabledTabs = Set(Tab.allCases)
        /// Fixture lifecycle only. No process or task is launched by these controls.
        @Published private(set) var runningTabs = Set<Tab>()
        @Published private(set) var pendingDisabledTabs = Set<Tab>()
        @Published var draft = "" { didSet { onPersist?() } }
        /// Empty means a new dedicated Bot; other values must resolve inside this domain.
        @Published var chosenBotID = "" { didSet { onPersist?() } }
        var isProduction = false
        var onPersist: (() -> Void)?
        var onSubmit: (() -> Void)?
        var beforeToggle: (() -> Void)?
        @Published var presentsInterface = false
        @Published var presentsBuilder = false
        var transcript: (() -> [ChatMessage])?
        @Published var isSubmitting = false
        @Published var bots: [Bot]
        @Published var interfaces: [WorkInterface] = []
        @Published var selectedInterfaceID: String?
        @Published var validationMessage: String?
        // UI-only composer choices. Never writes the live Chat/Bot configuration.
        @Published private(set) var composerRoute: ChatRouteChoice
        @Published var composerEffort: TatwoCodexReasoningEffort
        @Published var composerSpeed: TatwoModelSpeedTier?
        @Published var composerPermission: TatwoPermissionPreset = .askFirst
        @Published var composerCollaboration: ChatCollaborationLevel = .off

        init(id: String, name: String, bots: [Bot]) {
            self.id = id
            self.name = name
            self.bots = bots
            let route = ChatRouteChoice.all[0]
            composerRoute = route
            composerEffort = route.defaultEffort
            composerSpeed = route.defaultSpeedTier
        }
        func selectComposerRoute(_ id: String) {
            guard let route = ChatRouteChoice.all.first(where: { $0.id == id }) else { return }
            composerRoute = route
            if !route.allowedEfforts.contains(composerEffort) {
                composerEffort = route.defaultEffort
            }
            if composerSpeed.map({ !route.allowedSpeedTiers.contains($0) }) ?? true {
                composerSpeed = route.defaultSpeedTier
            }
        }
        var selectedInterface: WorkInterface? {
            interfaces.first { $0.id == selectedInterfaceID }
        }
        var visibleTabs: [Tab] {
            // Shipped bundles enable Browser via Info.plist; previews via the env flag (both in browserPreviewEnabled).
            tabs.filter { enabledTabs.contains($0) && ($0 != .browser || ChatRunMode.browserPreviewEnabled) }
        }
        var selectedTab: Tab? {
            switch screen {
            case .tab(let tab): tab
            case .conversation: .bot
            default: nil
            }
        }
        func showTab(_ tab: Tab) {
            guard enabledTabs.contains(tab) else { return }
            screen = tab == .bot ? .conversation : .tab(tab)
        }
        func isRequestedEnabled(_ tab: Tab) -> Bool {
            enabledTabs.contains(tab) && !pendingDisabledTabs.contains(tab)
        }
        var canPreview: Bool {
            !isSubmitting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (chosenBotID.isEmpty || bots.contains { $0.id == chosenBotID })
        }
        func name(for tab: Tab) -> String {
            guard let name = customTabs[tab.rawValue] else { return tab.rawValue }
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Work Space" : name
        }
        func addWorkSpace() {
            let tab = Tab(rawValue: UUID().uuidString)!
            customTabs[tab.rawValue] = "Work Space \(customTabs.count + 1)"
            tabs.append(tab)
            enabledTabs.insert(tab)
            onPersist?()
        }
        func renameWorkSpace(_ tab: Tab, to name: String) {
            let bounded = String(name.prefix(80))
            guard let current = customTabs[tab.rawValue], current != bounded else { return }
            customTabs[tab.rawValue] = bounded
            onPersist?()
        }
        func openBuilder() {
            validationMessage = nil
            screen = .builder
        }
        func cancelBuilder() {
            // Dismiss without creating anything; retain this domain's input for returning.
            validationMessage = nil
            presentsBuilder = false
            screen = selectedInterface == nil ? .settings : .interface
            if isProduction { presentsInterface = false }
        }
        func toggle(_ tab: Tab) {
            beforeToggle?()
            defer { onPersist?() }
            if pendingDisabledTabs.remove(tab) != nil {
                return // Cancel a queued disable; keep the running task untouched.
            }
            if enabledTabs.contains(tab) {
                if runningTabs.contains(tab) { pendingDisabledTabs.insert(tab) }
                else { finishDisabling(tab) }
            } else {
                enabledTabs.insert(tab)
            }
        }
        func setPreviewTaskRunning(_ running: Bool, for tab: Tab) {
            if running {
                guard enabledTabs.contains(tab), !pendingDisabledTabs.contains(tab) else { return }
                runningTabs.insert(tab)
            } else {
                runningTabs.remove(tab)
                if pendingDisabledTabs.remove(tab) != nil { finishDisabling(tab) }
            }
        }
        private func finishDisabling(_ tab: Tab) {
            enabledTabs.remove(tab)
            if selectedTab == tab { screen = .settings }
        }
        func moveTab(_ tab: Tab, before target: Tab) {
            guard tab != target,
                  let from = tabs.firstIndex(of: tab),
                  tabs.contains(target) else { return }
            tabs.remove(at: from)
            guard let to = tabs.firstIndex(of: target) else { return }
            tabs.insert(tab, at: to)
            onPersist?()
        }
        func moveTab(_ tab: Tab, offset: Int) {
            guard let from = tabs.firstIndex(of: tab),
                  tabs.indices.contains(from + offset) else { return }
            tabs.swapAt(from, from + offset)
            onPersist?()
        }
        func selectInterface(_ id: String, conversation: Bool = false) {
            guard interfaces.contains(where: { $0.id == id }) else { return }
            selectedInterfaceID = id
            screen = conversation ? .conversation : .interface
            onSelectInterface?(id)
        }
        var onSelectInterface: ((String) -> Void)?
        func previewResult() {
            if let onSubmit { onSubmit(); return }
            guard canPreview else {
                validationMessage = "請填寫搭建需求，並選擇此 work space 的 Bot。"
                return
            }
            let number = interfaces.count + 1
            let interfaceID = "\(id)-interface-\(number)"
            let bot: Bot
            if chosenBotID.isEmpty {
                bot = Bot(id: "\(interfaceID)-bot", name: "自訂 work space \(number) Bot")
                bots.append(bot)
            } else if let existing = bots.first(where: { $0.id == chosenBotID }) {
                bot = existing
            } else {
                return
            }
            interfaces.append(WorkInterface(
                id: interfaceID, name: "自訂 work space \(number)", bot: bot,
                specification: draft, conversationID: "\(interfaceID)-conversation"))
            selectedInterfaceID = interfaceID
            draft = ""
            chosenBotID = ""
            validationMessage = nil
            screen = .interface
        }
    }

    let domains: [Domain]
    @Published var selectedDomainID: String
    private var domainObservations: Set<AnyCancellable> = []

    init(domains providedDomains: [Domain]? = nil) {
        domains = providedDomains ?? [
            Domain(id: "preview-tattoo", name: "刺青", bots: [
                Bot(id: "preview-tattoo-assistant", name: "刺青助理")
            ]),
            Domain(id: "preview-admin", name: "行政", bots: [
                Bot(id: "preview-admin-assistant", name: "行政助理")
            ])
        ]
        selectedDomainID = domains[0].id
        // The existing Bot shell reads the selected domain's pills and sidebar.
        // Forward fixture changes without introducing another navigation store.
        for domain in domains {
            domain.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }.store(in: &domainObservations)
        }
    }
    var selectedDomain: Domain {
        domains.first { $0.id == selectedDomainID } ?? domains[0]
    }
    func selectDomain(_ id: String) {
        guard domains.contains(where: { $0.id == id }) else { return }
        selectedDomainID = id
    }

    static let specificationPrompt = """
    請協助我在目前 work space 搭建以下自訂 work space：

    【名稱】
    【使用者與工作領域】
    【希望解決的問題】
    【主要功能】
    【操作流程】
    【畫面區塊與呈現方式】
    【資料來源／檔案路徑】沒有可填「無」
    【需要連接的服務或工具】沒有可填「無」
    【Bot 要負責的工作】
    【需要先詢問我的操作】
    【不可變更或不可存取的範圍】
    【完成後如何驗收】

    請先整理需求，指出必要的待確認事項，
    提出介面與操作流程供我確認，再進行搭建。
    左列必須沿用 OS 共用側欄模板（WorkspaceSidebarShell／WorkspaceSidebarModePicker）：
    寬度、邊距、分頁列與底部對齊依 WorkspaceSidebarMetrics，不得各自另定比例。
    不得把此自訂 work space或對話帶到其他 work space。
    """
}
