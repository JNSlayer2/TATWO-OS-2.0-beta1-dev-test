import SwiftUI

/// Settings hosts the existing Plugin page; it does not create a second registry.
struct PluginSettingsView: View {
    @ObservedObject var model: ChatPageModel
    @State private var entries = PluginSettingsView.annotated(TatwoPluginRegistryStore.loadDefaultEntries())

    var body: some View {
        PluginsPage(
            entries: entries,
            environment: [],
            skillsDirectoryCatalog: TatwoSkillsDirectoryCatalog(
                rootURL: TatwoSkillsDirectoryCatalog.defaultRoot()),
            skilletRepositoryStore: TatwoSkilletRepositoryStore(
                rootURL: DeviceSyncOutboxStore.defaultApplicationSupportRootPublic()
                    .appendingPathComponent("skillet", isDirectory: true)),
            onRegister: { kind, path, purpose, name in
                _ = try TatwoPluginRegistryStore.defaultStore().register(
                    kind: kind, path: path, plainPurpose: purpose, name: name)
                reload()
            },
            onRemove: { entry in
                _ = try TatwoPluginRegistryStore.defaultStore().remove(id: entry.id)
                reload()
            },
            onSyncClaude: {
                try await Task.detached(priority: .utility) {
                    try TatwoPluginRegistryStore.defaultStore().syncClaudeMCPConfig()
                }.value
            },
            pocketThreadID: model.selectedThreadID,
            scrollsContent: true
        )
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("plugin-settings")
    }

    private func reload() {
        entries = PluginSettingsView.annotated(TatwoPluginRegistryStore.loadDefaultEntries())
        model.reloadPluginRegistry()
    }

    /// W96：App 內建（受管）的技能那一列要說清楚來源，手改過就顯示「已保留」。
    /// 只改這一列的來源說明，其他技能與註冊流程一行不動。
    static func annotated(_ entries: [PluginRegistryEntry]) -> [PluginRegistryEntry] {
        entries.map { entry in
            guard entry.kind == .skill, let path = entry.path,
                  let label = ManagedSkills.sourceLabel(forSkillManifestPath: path) else { return entry }
            var annotated = PluginRegistryEntry(
                id: entry.id, name: entry.name, kind: entry.kind, purpose: entry.purpose,
                path: entry.path, trigger: entry.trigger, safetyLevel: entry.safetyLevel,
                installState: entry.installState, smokeCommand: entry.smokeCommand,
                publicInstallHint: "來源：" + label)
            annotated.liveness = entry.liveness
            annotated.toolCount = entry.toolCount
            annotated.lastCalledAt = entry.lastCalledAt
            annotated.availableTo = entry.availableTo
            return annotated
        }
    }
}
