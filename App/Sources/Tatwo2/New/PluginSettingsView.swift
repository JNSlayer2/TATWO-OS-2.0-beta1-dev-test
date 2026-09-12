import SwiftUI

/// Settings hosts the existing Plugin page; it does not create a second registry.
struct PluginSettingsView: View {
    @ObservedObject var model: ChatPageModel
    @State private var entries = TatwoPluginRegistryStore.loadDefaultEntries()

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
        entries = TatwoPluginRegistryStore.loadDefaultEntries()
        model.reloadPluginRegistry()
    }
}
