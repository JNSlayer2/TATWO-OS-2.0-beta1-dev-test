import SwiftUI
import UniformTypeIdentifiers

// CLI UI presentation only. Metadata/scrollback access below uses the store's in-memory snapshots.
extension ChatPageModel {
    var cliUIRecords: [CLISessionStore.Record] {
        isLive ? (cliSessionStore?.sessions ?? []) : cliUIFixtureRecords
    }
    func cliUIRecord(_ id: UUID) -> CLISessionStore.Record? { cliUIRecords.first { $0.id == id } }
    var cliRailTabs: [TatwoNativeCLISessionBook.Session] {
        cliTabs.sorted {
            let a = cliUIRecord($0.id), b = cliUIRecord($1.id)
            if (a?.pinned ?? false) != (b?.pinned ?? false) { return a?.pinned == true }
            return (a?.order ?? Int.max) < (b?.order ?? Int.max)
        }
    }
    var cliRailHistory: [CLISessionStore.Record] {
        let open = Set(cliTabs.map(\.id))
        return restorableCLITabs.filter { !open.contains($0.id) && !cliRestoredHistoryIDs.contains($0.id) }
    }
    func beginCLIRename(_ id: UUID, title: String) {
        cliRenameID = id; cliRenameTitle = title; cliRenamePresented = true
    }
    func commitCLIRename() {
        guard let id = cliRenameID else { return }
        renameCLITab(id, title: cliRenameTitle)
        cliRenameID = nil
    }
    // Match the native NSString provider's exact advertised type; validate UUID/tab membership after loading.
    static let cliRailDragType = UTType.utf8PlainText
    func cliRailDragProvider(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider(object: id.uuidString as NSString)
        return provider
    }
    func handleCLIRailDrop(_ providers: [NSItemProvider], before destination: UUID) -> Bool {
        guard cliRailTabs.contains(where: { $0.id == destination }),
              let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(Self.cliRailDragType.identifier) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: Self.cliRailDragType.identifier) { [weak self] data, _ in
            guard let data, let raw = String(data: data, encoding: .utf8), let source = UUID(uuidString: raw) else { return }
            Task { @MainActor [weak self] in _ = self?.moveCLIRailTab(source, before: destination) }
        }
        return true
    }
    func moveCLIRailTab(_ source: UUID, before destination: UUID) -> Bool {
        var ids = cliRailTabs.map(\.id)
        guard source != destination, ids.contains(source), ids.contains(destination),
              (cliUIRecord(source)?.pinned ?? false) == (cliUIRecord(destination)?.pinned ?? false) else { return false }
        ids.removeAll { $0 == source }
        guard let index = ids.firstIndex(of: destination) else { return false }
        ids.insert(source, at: index)
        reorderCLITabs(ids)
        return true
    }
    func restoreCLIRailTab(_ id: UUID) async {
        guard !cliRestoringIDs.contains(id) else { return }
        cliRestoringIDs.insert(id)
        defer { cliRestoringIDs.remove(id) }
        if let restored = await restoreCLITab(id) {
            cliRestoredHistoryIDs.insert(id)
            selectCLITab(restored)
        } else {
            composerHint = "無法接回終端機，請先選擇本機討論串。"
        }
    }
    func cliRelativeLastActive(_ record: CLISessionStore.Record) -> String {
        let now = isLive ? Date() : CLISessionsFixture.now
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: record.lastActiveAt, relativeTo: now)
    }
    func cliUIStatusLabel(_ id: UUID) -> String {
        switch cliTabStatus(id) {
        case .running: return "● 執行中"
        case .waitingInput: return "● 等你輸入"
        case .exited:
            return "● 結束"
        case .unknown: return "○ 狀態未知"
        }
    }
    func cliUIStatusColor(_ id: UUID) -> Color {
        switch cliTabStatus(id) {
        case .running: return .green
        case .waitingInput: return .orange
        case .exited, .unknown: return .gray
        }
    }
}

// One process-wide weak reference, set by model initialization; termination never creates a model or reads disk.
@MainActor enum CLISessionsTermination {
    static weak var model: ChatPageModel?
    static func shouldTerminate() -> Bool {
        // Quit is detach, not cli_close. There is no destructive confirmation or command replay.
        model?.saveCLIWorkbench()
        for session in model?.cliTabPTYByID.values ?? Dictionary<UUID, CLIWorkbenchTerminalSession>().values {
            session.detach()
        }
        model?.cliSessionStore?.finishPendingWrites()
        return true
    }
}
