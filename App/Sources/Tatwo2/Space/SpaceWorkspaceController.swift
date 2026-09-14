import SwiftUI
import Combine

/// One projection of the existing library/runtime, shared by both entrypoints.
/// Initialization alone starts no service and writes no document.
@MainActor
final class SpaceWorkspaceController: ObservableObject {
    static let shared = SpaceWorkspaceController()
    @Published private(set) var state: SpaceSetupPreviewState?
    var presentsInterface: Bool {
        get { state?.selectedDomain.presentsInterface ?? false }
        set { state?.selectedDomain.presentsInterface = newValue }
    }
    @Published private(set) var error: String?
    private weak var model: ChatPageModel?
    private var library: BotLibrary?
    private var observation: AnyCancellable?
    private var writeTail: Task<Void, Never>?
    private var draftIDs: [String: UUID] = [:]
    private var hasInvalidWorkspace = false

    var selectedDomainID: String? { state?.selectedDomainID }
    var visibleModes: [ChatRunMode] {
        if hasInvalidWorkspace { return [] }
        let modes = activeSetupState?.selectedDomain.visibleTabs.compactMap { ChatRunMode(rawValue: $0.rawValue) }
            ?? ChatRunMode.allCases
        return modes.filter { $0 != .browser || ProcessInfo.processInfo.environment["TATWO_BROWSER_WORKSPACE_PREVIEW"] == "1"
            || ChatRunMode.browserPreviewEnabled }
    }
    private var activeSetupState: SpaceSetupPreviewState? {
        SpaceSetupPreviewState.isEnabled ? SpaceSetupPreviewState.shared : state
    }
    func displayName(for id: String) -> String {
        guard let domain = activeSetupState?.selectedDomain,
              let tab = SpaceSetupPreviewState.Tab(rawValue: id) else { return id }
        return domain.name(for: tab)
    }
    func allows(_ mode: ChatRunMode) -> Bool {
        if hasInvalidWorkspace { return false }
        if mode == .browser && !ChatRunMode.browserPreviewEnabled { return false }
        guard let state = activeSetupState,
              let tab = SpaceSetupPreviewState.Tab(rawValue: mode.rawValue) else { return true }
        return state.selectedDomain.isRequestedEnabled(tab)
    }

    func load(model: ChatPageModel) async {
        guard self.model !== model, let library = model.botLibraryForBridge else { return }
        self.model = model
        await load(library: library)
    }

    func load(library: BotLibrary) async {
        self.library = library
        state = nil
        error = nil
        observation = nil
        hasInvalidWorkspace = false
        await library.ready()
        if let failure = library.snapshot.spaceWorkspaceError {
            hasInvalidWorkspace = true
            error = failure
            return
        }
        let domains = library.snapshot.spaces.map { record in
            let bots = library.list().filter { $0.spaceIDs.contains(record.id) }
                .map { SpaceSetupPreviewState.Bot(id: $0.id, name: $0.name) }
            let domain = SpaceSetupPreviewState.Domain(id: record.id, name: record.name, bots: bots)
            domain.isProduction = true
            restore(domain)
            domain.onPersist = { [weak self, weak domain] in
                guard let self, let domain else { return }
                self.queueSave(domain)
            }
            domain.onSubmit = { [weak self, weak domain] in
                guard let self, let domain else { return }
                self.submit(domain)
            }
            domain.beforeToggle = { [weak self] in self?.synchronizeRuntimeState() }
            domain.onSelectInterface = { [weak self, weak domain] interfaceID in
                guard let self, let domain else { return }
                self.saveInterfaceSelection(spaceID: domain.id, interfaceID: interfaceID)
            }
            return domain
        }
        guard !domains.isEmpty else { error = "尚無領域 Space；請先建立領域。"; return }
        let projection = SpaceSetupPreviewState(domains: domains)
        if let id = library.snapshot.spaceWorkspace.selectedDomainID { projection.selectDomain(id) }
        state = projection
        observation = projection.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.model?.objectWillChange.send()
        }
    }

    private func restore(_ domain: SpaceSetupPreviewState.Domain) {
        guard let library else { return }
        let saved = library.snapshot.spaceWorkspace.domains[domain.id] ?? SpaceDomainRecord(id: domain.id)
        draftIDs[domain.id] = saved.draft.id
        domain.draft = saved.draft.text
        domain.chosenBotID = saved.draft.existingBotID ?? ""
        domain.tabs = saved.tabOrder.compactMap { SpaceSetupPreviewState.Tab(rawValue: $0.modeRawValue) }
        domain.customTabs = saved.customTabs ?? [:]
        domain.enabledTabs = Set(domain.tabs.filter {
            !saved.disabledTabs.contains(SpaceManagedTab(modeRawValue: $0.rawValue)!)
        })
        domain.bots = library.list().filter { $0.spaceIDs.contains(domain.id) }
            .map { .init(id: $0.id, name: $0.name) }
        domain.interfaces = saved.interfaces.filter { $0.submission == .accepted }.compactMap { item in
            guard let bot = domain.bots.first(where: { $0.id == item.botID }) else { return nil }
            return .init(id: item.id.uuidString, name: item.name, bot: bot,
                         specification: item.initialRequest, conversationID: item.conversationID.uuidString)
        }
        domain.selectedInterfaceID = saved.selectedInterfaceID?.uuidString
        if domain.selectedInterfaceID != nil { domain.screen = .conversation }
    }

    private func queueSave(_ domain: SpaceSetupPreviewState.Domain) {
        guard let library else { return }
        let id = domain.id
        let draft = SpaceBuilderDraft(id: draftIDs[id] ?? UUID(), text: domain.draft,
                                     existingBotID: domain.chosenBotID.isEmpty ? nil : domain.chosenBotID)
        draftIDs[id] = draft.id
        let order = domain.tabs.compactMap { SpaceManagedTab(modeRawValue: $0.rawValue) }
        let disabled = Set(domain.tabs.filter { !domain.isRequestedEnabled($0) }
            .compactMap { SpaceManagedTab(modeRawValue: $0.rawValue) })
        let customTabs = domain.customTabs
        let previous = writeTail
        writeTail = Task { [weak self] in
            await previous?.value
            do {
                _ = try await library.updateSpaceDomain(id: id) {
                    $0.draft = draft; $0.tabOrder = order; $0.disabledTabs = disabled
                    $0.customTabs = customTabs
                }
                self?.error = nil
                self?.model?.applySpaceRuntimePreferences()
            } catch { self?.error = "Space 儲存失敗：\(error)" }
        }
    }

    func selectDomain(_ id: String) {
        if id != selectedDomainID {
            ComputerUseController.shared.stop()
            BrowserAgentBridge.shared.revokeRequests()
        }
        guard let state, let library, state.domains.contains(where: { $0.id == id }) else { return }
        state.selectDomain(id)
        let previous = writeTail
        writeTail = Task { [weak self] in
            await previous?.value
            do { try await library.selectWorkspaceDomain(id) }
            catch { self?.error = "Space 切換儲存失敗：\(error)" }
            self?.model?.applySpaceRuntimePreferences()
        }
        model?.objectWillChange.send()
    }

    func openBuilder() {
        guard let domain = activeSetupState?.selectedDomain else { return }
        domain.openBuilder()
        domain.presentsBuilder = true
    }

    func openInterface(_ id: String) {
        guard let domain = state?.selectedDomain else { return }
        domain.selectInterface(id, conversation: true)
        presentsInterface = true
        model?.mode = .bot
    }

    private func saveInterfaceSelection(spaceID: String, interfaceID: String) {
        guard let library, let id = UUID(uuidString: interfaceID) else { return }
        let previous = writeTail
        writeTail = Task { [weak self] in
            await previous?.value
            do {
                _ = try await library.updateSpaceDomain(id: spaceID) {
                    guard $0.interfaces.contains(where: { $0.id == id && $0.spaceID == spaceID }) else {
                        throw BotLibraryError.invalid("space_interface_selection_invalid")
                    }
                    $0.selectedInterfaceID = id
                }
            } catch { self?.error = "工作介面選擇儲存失敗：\(error)" }
        }
    }

    func saveConversationDraft(spaceID: String, interfaceID: String, text: String) {
        guard let library else { return }
        let previous = writeTail
        writeTail = Task { [weak self] in
            await previous?.value
            do {
                _ = try await library.updateSpaceDomain(id: spaceID) {
                    var drafts = $0.conversationDrafts ?? [:]
                    drafts[interfaceID] = text
                    $0.conversationDrafts = drafts
                }
            } catch { self?.error = "草稿儲存失敗：\(error)" }
        }
    }

    func flushWrites() async { await writeTail?.value }

    func synchronizeRuntimeState() {
        guard let model, let state, let library else { return }
        let runningCLI = model.cliSessionsByThread.values.flatMap { $0 }.contains(where: \.isRunning)
        for domain in state.domains {
            let snapshot = library.snapshot
            let interfaceRunning = snapshot.spaceWorkspace.domains[domain.id]?.interfaces
                .contains { model.live?.isRunning($0.conversationID) == true } ?? false
            let botRunning = snapshot.bots.filter { $0.spaceIDs.contains(domain.id) }.contains { bot in
                snapshot.sessions[bot.id]?.contains {
                    model.live?.isRunning(UUID(uuidString: $0.threadID)) == true
                } ?? false
            }
            for (tab, running) in [(SpaceSetupPreviewState.Tab.bot, interfaceRunning || botRunning),
                                   (.cli, runningCLI),
                                   (.chat, model.isRunning)] {
                if domain.runningTabs.contains(tab) != running {
                    domain.setPreviewTaskRunning(running, for: tab)
                }
            }
        }
    }

    private func submit(_ domain: SpaceSetupPreviewState.Domain) {
        guard domain.canPreview, let model, let library else { return }
        domain.isSubmitting = true
        queueSave(domain)
        let pendingWrite = writeTail
        let originalText = domain.draft
        let draftID = draftIDs[domain.id]!
        let route = domain.composerRoute
        let permission = domain.composerPermission
        let name = SpaceBuilderDraft(text: originalText).interfaceName
        let owner = library.snapshot.spaces.first { $0.id == domain.id }?.ownerBotID
        let cwd = owner.flatMap { library.bot(id: $0)?.workdir } ?? model.selectedThreadProject?.workdir
        Task { [weak self, weak domain] in
            await pendingWrite?.value
            guard let self, let domain else { return }
            defer { domain.isSubmitting = false }
            do {
                guard self.error == nil, let cwd else { throw BotLibraryError.invalid(self.error ?? "請先選擇工作目錄") }
                let item = try await model.submitSpaceInterface(spaceID: domain.id, draftID: draftID,
                    name: String(name.prefix(80)), route: route, workdir: cwd, permission: permission)
                // Merge only submission-owned fields. A whole-domain restore here
                // would overwrite edits made while the send was awaiting IO.
                domain.bots = library.list().filter { $0.spaceIDs.contains(domain.id) }
                    .map { .init(id: $0.id, name: $0.name) }
                if !domain.interfaces.contains(where: { $0.id == item.id.uuidString }),
                   let bot = domain.bots.first(where: { $0.id == item.botID }) {
                    domain.interfaces.append(.init(id: item.id.uuidString, name: item.name,
                        bot: bot, specification: item.initialRequest,
                        conversationID: item.conversationID.uuidString))
                }
                self.draftIDs[domain.id] = UUID()
                if domain.draft == originalText { domain.draft = "" }
                domain.selectInterface(item.id.uuidString, conversation: true)
                domain.validationMessage = nil
                self.queueSave(domain)
                // Do not change global selection: completion stays with its owner.
                self.objectWillChange.send()
            } catch { domain.validationMessage = String(describing: error) }
        }
    }
}

@MainActor
extension ChatPageModel {
    func applySpaceRuntimePreferences() {
        let spaces = SpaceWorkspaceController.shared
        spaces.synchronizeRuntimeState()
        let runningCLI = cliSessionsByThread.values.flatMap { $0 }.contains(where: \.isRunning)
        if spaces.allows(.cli) {
            if cliRefreshTask == nil {
                initializeCLIWorkbench(environment: osBindingEnvironment)
            }
        } else if !runningCLI {
            cliRefreshTask?.cancel()
            cliRefreshTask = nil
        }
        if !spaces.visibleModes.contains(mode) {
            mode = spaces.visibleModes.first ?? .bot
        }
        objectWillChange.send()
    }
}
