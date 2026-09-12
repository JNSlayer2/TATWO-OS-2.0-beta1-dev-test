import Foundation

/// OS integration only: ownership, persistence, draft handoff and the existing five CLI tools.
/// Presentation actions are interpreted here; there are no tmux command strings in SwiftUI.
@MainActor
extension ChatPageModel {
    func initializeCLIWorkbench(environment: [String: String]) {
        guard cliRefreshTask == nil, isCLIRuntimeEnabled, let store = cliSessionStore else { return }
        let paths = EnginePaths(environment: environment)
        let bin = environment["TATWO2_RUNTIME_BIN"].map { URL(fileURLWithPath: $0) } ?? paths.runtimeBinDirectory
        let runtime = CLITmuxRuntime(root: store.root, executable: bin.appendingPathComponent("tmux").path)
        cliRuntime = runtime
        cliWorkbenchDocument = store.workbench
        for record in store.sessions {
            guard let owner = record.threadID else { continue }
            hydrateCLIWorkbenchRecord(record, owner: owner)
        }
        cliRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                if self == nil { return }
                await self?.refreshCLIWorkbenchSessions()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func hydrateCLIWorkbenchRecord(_ record: CLISessionStore.Record, owner: UUID) {
        guard let runtime = cliRuntime, let store = cliSessionStore else { return }
        if cliTabPTYByID[record.id] == nil {
            cliTabPTYByID[record.id] = makeCLIWorkbenchSession(id: record.id, runtime: runtime, store: store)
        }
        cliTabOwner[record.id] = owner
        if cliSessionsByThread[owner]?.contains(where: { $0.id == record.id }) != true {
            cliSessionsByThread[owner, default: []].append(.init(id: record.id,
                engine: .init(rawValue: record.engine) ?? .generic, title: record.title,
                workdir: record.cwd, createdAt: record.createdAt, updatedAt: record.lastActiveAt, isRunning: false))
        }
    }
    func makeCLIWorkbenchSession(id: UUID, runtime: CLITmuxRuntime, store: CLISessionStore) -> CLIWorkbenchTerminalSession {
        let session = CLIWorkbenchTerminalSession(id: id, runtime: runtime, store: store)
        session.editingOptions = cliWorkbenchDocument.editingOptions
        session.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.cliTabPIDByID[id] = session.pid
            self.cliTabStatuses[id] = session.error ?? session.status.rawValue
            if let owner = self.cliTabOwner[id],
               let i = self.cliSessionsByThread[owner]?.firstIndex(where: { $0.id == id }) {
                self.cliSessionsByThread[owner]?[i].isRunning = session.isRunning
            }
            self.applySpaceRuntimePreferences()
            self.objectWillChange.send()
        }
        session.onFocus = { [weak self] in self?.selectCLITab(id) }
        return session
    }
    func refreshCLIWorkbenchSessions() async {
        guard let runtime = cliRuntime, let store = cliSessionStore,
              store.sessions.contains(where: { $0.tmuxName != nil && $0.status != .exited }) else { return }
        do {
            let panes = try await runtime.list()
            for record in store.sessions where record.tmuxName == CLITmuxRuntime.name(record.id) {
                guard let session = cliTabPTYByID[record.id], !session.isStarting else { continue }
                session.reconcile(panes.first { $0.name == record.tmuxName })
            }
        } catch {
            // A transport error is not evidence of death, success, or a permission to replay.
            composerHint = "終端狀態暫時無法核實：\(error.localizedDescription)"
        }
    }
    var cliWorkbenchTabs: [CLIWorkbenchTab] {
        guard let owner = selectedThreadID else { return [] }
        if let workspace = cliWorkbenchDocument.threads[owner.uuidString] { return workspace.tabs }
        guard !isLive else { return [] }
        return cliTabs.map { .init(id: $0.id, title: $0.title, layout: .pane($0.id), focusedPaneID: $0.id) }
    }
    var cliSelectedWorkbenchID: UUID? {
        selectedThreadID.flatMap { cliWorkbenchDocument.threads[$0.uuidString]?.selectedTabID } ?? cliWorkbenchTabs.first?.id
    }
    var cliFocusedWorkbenchPaneID: UUID? {
        cliWorkbenchTabs.first { $0.id == cliSelectedWorkbenchID }?.focusedPaneID
    }
    var cliWorkbenchPanes: [CLIWorkbenchPane] {
        let visible = Set(cliWorkbenchTabs.flatMap { $0.layout?.paneIDs ?? [] })
        return cliUIRecords.filter { $0.threadID == selectedThreadID || (!isLive || $0.threadID == nil) }.map { record in
            let status = cliTabPTYByID[record.id]?.status ?? record.status
            let state: CLIWorkbenchProcessState
            switch status {
            case .running: state = .running
            case .waitingInput: state = .waiting
            case .exited: state = .exited
            case .unknown: state = .unknown
            }
            return .init(id: record.id, title: record.title, engine: record.engine,
                project: URL(fileURLWithPath: record.cwd).lastPathComponent,
                state: state, isBackground: !visible.contains(record.id), exitCode: record.exitCode.map(Int.init))
        }
    }
    func saveCLIWorkbench() { cliSessionStore?.saveWorkbench(cliWorkbenchDocument) }
    func registerCLIWorkbenchPane(_ pane: TatwoNativeCLISessionBook.Session, owner: UUID) {
        var workspace = cliWorkbenchDocument.threads[owner.uuidString] ?? .init()
        if let existing = workspace.tabs.first(where: { $0.layout?.paneIDs.contains(pane.id) == true }) {
            workspace.selectedTabID = existing.id
        } else {
            let tab = CLIWorkbenchTab(id: UUID(), title: pane.title, layout: .pane(pane.id), focusedPaneID: pane.id)
            workspace.tabs.append(tab)
            workspace.selectedTabID = tab.id
        }
        cliWorkbenchDocument.threads[owner.uuidString] = workspace
        saveCLIWorkbench()
    }
    func focusCLIWorkbenchPane(_ id: UUID, owner: UUID) {
        guard var workspace = cliWorkbenchDocument.threads[owner.uuidString],
              let index = workspace.tabs.firstIndex(where: { $0.layout?.paneIDs.contains(id) == true }) else { return }
        workspace.selectedTabID = workspace.tabs[index].id
        workspace.tabs[index].focusedPaneID = id
        if workspace.tabs[index].maximizedPaneID != nil { workspace.tabs[index].maximizedPaneID = id }
        cliWorkbenchDocument.threads[owner.uuidString] = workspace
        saveCLIWorkbench()
    }
    func removeCLIWorkbenchPane(_ id: UUID) {
        for key in Array(cliWorkbenchDocument.threads.keys) {
            guard var workspace = cliWorkbenchDocument.threads[key] else { continue }
            for i in workspace.tabs.indices {
                workspace.tabs[i].layout = workspace.tabs[i].layout?.removing(id)
                if workspace.tabs[i].focusedPaneID == id { workspace.tabs[i].focusedPaneID = workspace.tabs[i].layout?.paneIDs.first }
                if workspace.tabs[i].maximizedPaneID == id { workspace.tabs[i].maximizedPaneID = nil }
            }
            workspace.tabs.removeAll { $0.layout == nil }
            if !workspace.tabs.contains(where: { $0.id == workspace.selectedTabID }) { workspace.selectedTabID = workspace.tabs.first?.id }
            cliWorkbenchDocument.threads[key] = workspace
        }
        cliSessionStore?.update(id) { $0.background = true }
        cliTabPTYByID[id]?.detach()
        saveCLIWorkbench()
        objectWillChange.send()
    }
    func terminateCLIWorkbenchPane(_ id: UUID) async throws {
        guard let record = cliSessionStore?.sessions.first(where: { $0.id == id }) else {
            throw NSError(domain: "CLI", code: 11, userInfo: [NSLocalizedDescriptionKey: "找不到終端紀錄"])
        }
        // Pre-tmux history has no process to terminate. Never invent or replay one.
        if record.tmuxName == nil && record.status == .exited {
            removeCLIWorkbenchPane(id)
            return
        }
        guard let session = cliTabPTYByID[id], let runtime = cliRuntime else {
            throw NSError(domain: "CLI", code: 12, userInfo: [NSLocalizedDescriptionKey: "終端執行層尚未就緒，無法確認已關閉"])
        }
        await session.waitUntilReady()
        if try await runtime.list().contains(where: { $0.name == CLITmuxRuntime.name(id) }) {
            try await session.terminateAwaited()
        } else { session.reconcile(nil) }
        removeCLIWorkbenchPane(id)
    }
    func cliWorkbenchTail(_ id: UUID) async -> String {
        if let session = cliTabPTYByID[id] {
            await session.waitUntilReady()
            if let text = try? await session.capture() { return text }
        }
        return await cliSessionStore?.loadScrollback(id) ?? ""
    }

    func sendCLIWorkbench(_ action: CLIWorkbenchAction) {
        guard selectedRemote == nil, let owner = selectedThreadID else { return }
        var workspace = cliWorkbenchDocument.threads[owner.uuidString] ?? .init()
        let current = workspace.tabs.firstIndex { $0.id == workspace.selectedTabID }
        switch action {
        case .createTab(let engine):
            _ = openCLITab(engine: .init(rawValue: engine) ?? .generic)
            return
        case .selectTab(let id):
            guard let tab = workspace.tabs.first(where: { $0.id == id }) else { return }
            workspace.selectedTabID = id
            activeCLITabByThread[owner] = tab.focusedPaneID
        case .selectPane(let id): selectCLITab(id); return
        case .split(let id, let axis):
            guard let i = workspace.tabs.firstIndex(where: { $0.layout?.paneIDs.contains(id) == true }),
                  let newID = openCLITab(engine: .generic, workdir: cliUIRecord(id)?.cwd) else { return }
            // openCLITab registers a standalone tab; replace only that presentation with the split.
            workspace.tabs[i].layout = workspace.tabs[i].layout?.splitting(id, newPane: newID, axis: axis)
            workspace.tabs[i].focusedPaneID = newID
            workspace.tabs[i].maximizedPaneID = nil
            workspace.selectedTabID = workspace.tabs[i].id
        case .setRatio(let id, let ratio):
            guard let i = current else { return }
            workspace.tabs[i].layout = workspace.tabs[i].layout?.settingRatio(splitID: id, ratio: ratio)
        case .focusNext(let backwards):
            guard let i = current, let ids = workspace.tabs[i].layout?.paneIDs, !ids.isEmpty else { return }
            let index = ids.firstIndex(of: workspace.tabs[i].focusedPaneID ?? ids[0]) ?? 0
            selectCLITab(ids[(index + (backwards ? ids.count - 1 : 1)) % ids.count])
            return
        case .toggleMaximize(let id):
            guard let i = current, workspace.tabs[i].layout?.paneIDs.contains(id) == true else { return }
            workspace.tabs[i].focusedPaneID = id
            workspace.tabs[i].maximizedPaneID = workspace.tabs[i].maximizedPaneID == id ? nil : id
        case .requestClosePane(let id):
            cliPendingCloseIDs = [id]; cliPendingCloseTitle = cliUIRecord(id)?.title ?? "終端"
            return
        case .requestCloseTab(let id):
            guard let tab = workspace.tabs.first(where: { $0.id == id }) else { return }
            cliPendingCloseIDs = tab.layout?.paneIDs ?? []
            cliPendingCloseTitle = "\(tab.title) · \(cliPendingCloseIDs.count) 個窗格"
            return
        case .resolveClose(let choice):
            let ids = cliPendingCloseIDs
            cliPendingCloseIDs = []; cliPendingCloseTitle = nil
            if choice == .background { ids.forEach(removeCLIWorkbenchPane) }
            if choice == .terminate {
                Task { [weak self] in
                    for id in ids {
                        do { try await self?.terminateCLIWorkbenchPane(id) }
                        catch { self?.composerHint = "結束程序失敗：\(error.localizedDescription)" }
                    }
                }
            }
            return
        case .reattach(let id):
            guard isCLIRuntimeEnabled else { return }
            Task { [weak self] in
                guard let self, self.isCLIRuntimeEnabled else { return }
                if let record = cliUIRecord(id), cliTabPTYByID[id] == nil {
                    hydrateCLIWorkbenchRecord(record, owner: record.threadID ?? owner)
                }
                _ = await restoreCLITab(id)
            }
            return
        case .sendSelectionToDraft(let id):
            guard let text = cliTabPTYByID[id]?.display?.selectedText, !text.isEmpty else {
                composerHint = "請先在終端選取要送回 Chat 的文字"; return
            }
            prompt += (prompt.isEmpty ? "" : "\n") + text
            mode = .chat // Draft only: no Chat/Bot execution entrypoint is called.
            return
        case .find(let id, let text, let backwards):
            if cliTabPTYByID[id]?.display?.find(text, backwards: backwards) != true { composerHint = "找不到「\(text)」" }
            return
        case .setEditingOptions(let options):
            cliWorkbenchDocument.editingOptions = options
            for session in cliTabPTYByID.values { session.editingOptions = options }
            saveCLIWorkbench()
            objectWillChange.send()
            return
        }
        cliWorkbenchDocument.threads[owner.uuidString] = workspace
        saveCLIWorkbench()
        objectWillChange.send()
    }
}
