import SwiftUI

/// Catalogue wrapper only. Existing iPad USE remains the owner of its device operations.
struct PocketSettingsView: View {
    let threadID: UUID?
    @State private var selectedPlugin: PocketPlugin?
    @State private var showIPadUse = false
    @State private var selectedPage = "catalog"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("Pocket", systemImage: "puzzlepiece.extension")
                    .font(.title3.bold())
                Spacer()
                Text(PocketCatalogPresentation.publisher)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            Divider()
            if showIPadUse {
                Button("返回 Pocket", systemImage: "chevron.left") { showIPadUse = false }
                    .padding(.horizontal, 22).padding(.top, 12)
                IPadUseSettingsView(threadID: threadID)
            } else {
                catalogue
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("pocket-settings")
    }

    private var catalogue: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Pocket 頁面", selection: $selectedPage) {
                Text("插件目錄").tag("catalog")
                Text("環境").tag("environment")
                Text("已安裝").tag("installed")
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedPage) { _, _ in selectedPlugin = nil }
            if let plugin = selectedPlugin {
                Button("返回目錄", systemImage: "chevron.left") { selectedPlugin = nil }
                Form {
                    Section(plugin.title) {
                        Text(plugin.summary)
                        LabeledContent("需求", value: plugin.requirement)
                        LabeledContent("狀態", value: plugin.status)
                        LabeledContent("發佈", value: PocketCatalogPresentation.packageStatus)
                    }
                    if plugin == .iPadUse {
                        Button("開啟 iPad USE 設定") { showIPadUse = true }
                    }
                }
                .formStyle(.grouped)
            } else if selectedPage == "environment" {
                Form {
                    Section("環境") {
                        LabeledContent("裝置環境", value: PocketCatalogPresentation.environmentStatus)
                        Text(PocketCatalogPresentation.environmentExplanation)
                        Text("iPad USE 的連線與授權，請在其設定中確認。")
                    }
                }
                .formStyle(.grouped)
            } else if selectedPage == "installed" {
                ContentUnavailableView(PocketCatalogPresentation.installedStatus,
                                       systemImage: "tray",
                                       description: Text(PocketCatalogPresentation.installedExplanation))
            } else {
                List {
                    ForEach(PocketCategory.allCases) { category in
                        Section(category.title) {
                            ForEach(PocketCatalogPresentation.plugins(in: category)) { plugin in
                                Button { selectedPlugin = plugin } label: {
                                    HStack {
                                        Label(plugin.title, systemImage: plugin.symbol)
                                        Spacer()
                                        Text(plugin.status).foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("pocket-plugin-\(plugin.rawValue)")
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(22)
    }
}
