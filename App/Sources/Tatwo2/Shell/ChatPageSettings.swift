// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageSettings.swift；改動 2 行（原因：run A 照搬，僅移除舊水電 import／呼叫並接同名 Facade）
import SwiftUI
import UniformTypeIdentifiers

/// 設定 → Issue List 管理表：全部清單 / 封存的 issue；可還原、可三段移除。

/// TATWO OS 系統文字布標：TATWO 品牌漸層字 + OS 次級標；代表整個系統。
struct TatwoOSMark: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    /// 主字級（TATWO 字高）；OS 依比例縮放。
    var size: CGFloat = 13
    var body: some View {
        HStack(spacing: size * 0.24) {
            Text("TATWO")
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .kerning(size * 0.02)
                .foregroundStyle(LiquidGlassTokens.ultraworkGradient)
            Text("OS")
                .font(.system(size: size * 0.72, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityLabel("TATWO OS")
    }
}

/// The existing Settings navigation/frame, shared with native UI-only capture.
/// This chrome has no Chat model, issue reload, engine or persistence dependency.
struct TatwoSettingsShell<Content: View>: View {
    typealias Section = TatwoSettingsPage.Section
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @Binding var section: Section
    let content: Content

    init(section: Binding<Section>, @ViewBuilder content: () -> Content) {
        _section = section
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            leftNav
            Divider()
            content
        }
        .frame(width: 780, height: 560)
    }

    private var leftNav: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TatwoOSMark(size: 13)
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 10)
            Text("設定")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
            ForEach(Section.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(section == item ? LiquidGlassTokens.brandAccent : .secondary)
                            .frame(width: 18)
                        Text(item.title)
                            .font(.system(size: 12.5, weight: section == item ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        section == item
                            ? LiquidGlassTokens.brandAccent.opacity(0.12)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.secondary.opacity(0.05))
    }

}

/// TATWO OS 設定整頁：左列直行導覽，右側內容區。
struct TatwoSettingsPage: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @State private var browserDiagnosticsPresented = false
    @ObservedObject var model: ChatPageModel
    var initialSection: Section? = nil
    let onClose: () -> Void

    enum Section: String, CaseIterable, Identifiable {
        case space
        case issueList
        case browserManagement
        case modelAccess
        case tatwoIsland
        case computerUse
        case devices
        case plugin
        case github
        case documents
        case os

        var id: String { rawValue }

        var title: String {
            switch self {
            case .space: "Space"
            case .issueList: "Issue List"
            case .browserManagement: "瀏覽器"
            case .modelAccess: "模型登入"
            case .tatwoIsland: "Tatwo Island"
            case .computerUse: "Computer Use"
            case .devices: "設備"
            case .plugin: "Plugin"
            case .github: "GitHub"
            case .documents: "文件"
            case .os: "OS"
            }
        }

        var icon: String {
            switch self {
            case .space: "square.grid.2x2"
            case .issueList: "tray.full"
            case .browserManagement: "globe.desk"
            case .modelAccess: "key"
            case .tatwoIsland: "capsule"
            case .computerUse: "cursorarrow.rays"
            case .devices: "laptopcomputer.and.iphone"
            case .plugin: "puzzlepiece.extension"
            case .github: "chevron.left.forwardslash.chevron.right"
            case .documents: "doc.text"
            case .os: "point.3.connected.trianglepath.dotted"
            }
        }
    }

    @State private var section: Section = {
        let requested = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_SETTINGS_SECTION"] ?? ""
        return Section(rawValue: ["ipadUse", "pocket"].contains(requested) ? "plugin" : requested) ?? .issueList
    }()
    @State private var issueTab: ChatPage.IssueSettingsTab = .all
    @State private var pendingRemove: TatwoIssueListEntryV1?

    var body: some View {
        TatwoSettingsShell(section: $section) {
            rightContent
        }
        .onAppear {
            if let initialSection { section = initialSection }
            model.reloadIssueList()
        }
        .confirmationDialog(
            "移除這筆 issue？",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("確認移除", role: .destructive) {
                if let entry = pendingRemove { model.removeIssueListEntry(entry.id) }
                pendingRemove = nil
            }
            Button("取消", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("只移除佇列項；原本的 plan／chat 討論不會被刪除或改動。")
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        switch section {
        case .space:
            if SpaceSetupPreviewState.isEnabled {
            SpaceSetupPreviewView(opensSettings: true, onOpenBuilder: {
                SpaceSetupPreviewState.shared.selectedDomain.presentsBuilder = true
                onClose()
            })
            } else {
                SpaceLiveSetupView(opensSettings: true, onOpenBuilder: {
                    onClose()
                    SpaceWorkspaceController.shared.openBuilder()
                })
            }
        case .issueList:
            issueListContent
        case .browserManagement:
            browserSettingsContent
        case .modelAccess:
            EngineLoginCard(model: model)
        case .tatwoIsland:
            tatwoIslandContent
        case .computerUse:
            VStack(alignment: .leading, spacing: 8) {
                Text("授權層級跟隨對話的權限設定（要求核准／代我核准／完整存取權）")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22).padding(.top, 12)
                ComputerUseSettingsView(onClose: onClose)
            }
        case .devices:
            DevicesCard(model: model)
        case .plugin:
            PluginSettingsView(model: model)
        case .github:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    UpdateAvailableCard()
                        .padding(.horizontal, 22)
                        .padding(.top, 22)
                    GitHubAccountsCard(model: model)
                }
            }
        case .documents:
            OSDocumentsCard(model: model)
        case .os:
            OSBindingCard(model: model)
        }
    }

    @State private var browserGeneral = BrowserGeneralSettings.load()
    @State private var browserSecurity = BrowserSecuritySettings.load()
    @State private var browserSettingsError: String?

    private var browserSettingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrowserSettingsMetrics.sectionSpacing) {
                browserSettingsCard("Browser work space") { browserWorkSpaceSettings }
                browserSettingsCard("快捷鍵") { BrowserShortcutsSettingsView() }
                browserSettingsCard("Session 瀏覽器") { browserSessionSettings }
                // 密碼：直接使用 W50 的完整卡片。
                BrowserPasswordsSettingsView()
                browserSettingsCard("擴充功能") {
                    Text("2.0.7 尚未支援 Chrome 擴充功能。TATWO OS 的內建瀏覽器以嵌入模式執行，Chromium 的擴充功能框架只能在獨立視窗模式運作；我們正在評估替代方案。")
                    Text("導入時只會列出你原本的擴充功能，不會安裝")
                        .foregroundStyle(.secondary)
                }
                browserSettingsCard("引擎與安全") { browserSecuritySettings }
                browserSettingsCard("診斷") { browserDiagnosticsSettings }
                if let browserSettingsError {
                    Text(browserSettingsError).foregroundStyle(.red)
                }
            }
            .padding(BrowserSettingsMetrics.pagePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func browserSettingsCard<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: BrowserSettingsMetrics.rowSpacing) {
            Text(title).font(.headline)
            content().font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BrowserSettingsMetrics.cardPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BrowserSettingsMetrics.cardRadius))
    }

    private var browserWorkSpaceSettings: some View {
        VStack(alignment: .leading, spacing: BrowserSettingsMetrics.rowSpacing) {
            BrowserDefaultBrowserRow()
            Picker("預設 space", selection: generalBinding(\.defaultSpaceID)) {
                Text("自動").tag(nil as UUID?)
                ForEach(model.browserTabRegistry.spaces.filter { !$0.isSessionSpace }) { space in
                    Text(space.name).tag(Optional(space.id))
                }
                if let id = browserGeneral.defaultSpaceID,
                   !model.browserTabRegistry.spaces.contains(where: { $0.id == id && !$0.isSessionSpace }) {
                    Text("原 space 已移除，請重新選擇").tag(Optional(id))
                }
            }
            Picker("預設搜尋引擎", selection: generalBinding(\.searchEngine)) {
                ForEach(BrowserSearchEngine.allCases, id: \.self) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            HStack {
                Text("下載位置：~/Downloads")
                Spacer()
                Button("在 Finder 顯示") {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                }
            }
            Button("匯出書籤 HTML", action: exportBrowserBookmarks)
            Button("從其他瀏覽器導入…") {
                onClose()
                NotificationCenter.default.post(name: Notification.Name("tatwo.browser.openImport"), object: nil)
            }
        }
    }

    private var browserSessionSettings: some View {
        VStack(alignment: .leading, spacing: BrowserSettingsMetrics.rowSpacing) {
            Text("\(model.browserTabRegistry.openSessions.count) 條 session 開著瀏覽器")
            Button("去 Session space 管理") {
                onClose()
                // W47/AppShell integration owns navigation; Fable connects this event.
                NotificationCenter.default.post(name: Notification.Name("tatwo.browser.openSessionSpace"), object: nil)
            }
            Picker("關閉 chat 時", selection: generalBinding(\.sessionRetention)) {
                Text("保留分頁").tag(BrowserGeneralSettings.SessionRetention.keep)
                Text("自動關閉").tag(BrowserGeneralSettings.SessionRetention.closeWithChat)
            }
        }
    }

    private var browserSecuritySettings: some View {
        VStack(alignment: .leading, spacing: BrowserSettingsMetrics.sectionSpacing) {
            BrowserMemorySettingsView()
            HStack(alignment: .top, spacing: BrowserSettingsMetrics.sectionSpacing) {
                browserHumanSecurityColumn
                Divider()
                browserAISecurityColumn
            }
            Text("變更在下一個新分頁生效").font(.footnote).foregroundStyle(.secondary)
            TatwoBrowserManagementView(model: model, provider: browserManagementProvider, onClose: onClose)
                .frame(height: BrowserSettingsMetrics.managementHeight)
        }
    }

    private var browserHumanSecurityColumn: some View {
        VStack(alignment: .leading, spacing: BrowserSettingsMetrics.rowSpacing) {
            Text("人用分頁").font(.subheadline.bold())
            Toggle("擋第三方 cookie", isOn: securityBinding(\.blocksThirdPartyCookies))
            Toggle("擋廣告與追蹤", isOn: securityBinding(\.adBlock))
            Text("區網連線：每個網站問一次")
            Text("相機／麥克風／位置：詢問")
            Text("下載：允許，存到下載項目")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var browserAISecurityColumn: some View {
        VStack(alignment: .leading, spacing: BrowserSettingsMetrics.rowSpacing) {
            Text("AI 操作分頁").font(.subheadline.bold())
            Text("第三方 cookie：封鎖")
            Text("廣告與追蹤：唯讀（跟隨共用設定）")
            Text("區網連線：封鎖")
            Text("相機／麥克風／位置：封鎖")
            Text("下載：封鎖")
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var browserDiagnosticsSettings: some View {
        VStack(alignment: .leading, spacing: BrowserSettingsMetrics.rowSpacing) {
            Text("引擎版本：\(BrowserRuntimeVersion.bundledDescription)")
            Text("目前分頁數：\(model.browserTabRegistry.tabs.count)")
            HStack {
                Button("打開診斷頁") { browserDiagnosticsPresented = true }
            }
        }
        .sheet(isPresented: $browserDiagnosticsPresented) {
            BrowserDiagnosticsView(registry: model.browserTabRegistry)
        }
    }

    private func generalBinding<Value>(_ keyPath: WritableKeyPath<BrowserGeneralSettings, Value>) -> Binding<Value> {
        Binding(get: { browserGeneral[keyPath: keyPath] }, set: { value in
            var updated = BrowserGeneralSettings.load()
            updated[keyPath: keyPath] = value
            do {
                try updated.save()
                browserGeneral = updated
                browserSettingsError = nil
            } catch { browserSettingsError = "無法儲存瀏覽器設定，請確認儲存位置後再試。" }
        })
    }

    private func securityBinding(_ keyPath: WritableKeyPath<BrowserSecuritySettings, Bool>) -> Binding<Bool> {
        Binding(get: { browserSecurity[keyPath: keyPath] }, set: { value in
            var updated = BrowserSecuritySettings.load()
            updated[keyPath: keyPath] = value
            do {
                try updated.save()
                browserSecurity = updated
                browserSettingsError = nil
            } catch { browserSettingsError = "無法儲存安全設定，請確認儲存位置後再試。" }
        })
    }

    private func exportBrowserBookmarks() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "TATWO-bookmarks.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BrowserBookmarkExport.html(registry: model.browserTabRegistry).write(to: url, atomically: true, encoding: .utf8)
            browserSettingsError = nil
        } catch { browserSettingsError = "無法匯出書籤，請確認儲存位置後再試。" }
    }

    private var browserManagementProvider:
        any TatwoBrowserManagementProviding
    {
        TatwoBrowserManagementProviderFactory.make()
    }

    private var issueEntries: [TatwoIssueListEntryV1] {
        issueTab == .archived ? model.archivedIssueListEntries : model.allIssueListEntries
    }

    private var issueListContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Issue List")
                    .font(.title3.bold())
                Spacer()
                Button("完成") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .tint(LiquidGlassTokens.brandAccent)
                    .keyboardShortcut(.defaultAction)
            }
            Picker("", selection: $issueTab) {
                Text("全部清單（\(model.allIssueListEntries.count)）").tag(ChatPage.IssueSettingsTab.all)
                Text("封存的 issue（\(model.archivedIssueListEntries.count)）").tag(ChatPage.IssueSettingsTab.archived)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)

            if issueEntries.isEmpty {
                Text(issueTab == .archived ? "沒有封存的 issue" : "佇列是空的")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(issueEntries) { entry in
                            settingsRow(entry)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var tatwoIslandContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tatwo Island")
                        .font(.title3.bold())
                    Text("Island 設定開關預留區")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .tint(LiquidGlassTokens.brandAccent)
                    .keyboardShortcut(.defaultAction)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Image(systemName: "capsule")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                Text("目前沒有設定項目")
                    .font(.system(size: 13, weight: .semibold))
                Text("之後 Tatwo Island 的開關、尺寸、顯示規則與互動偏好會集中在這裡。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tatwo Island 設定空白分頁")

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var modelAccessContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("模型存取")
                        .font(.title3.bold())
                    Text("登入 TATWO 原生模型執行環境")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .tint(LiquidGlassTokens.brandAccent)
                    .keyboardShortcut(.defaultAction)
            }

            ChatNativeOpenAISubscriptionOnboardingView()
            ChatNativeClaudeSubscriptionOnboardingView()
            ChatNativeGrokSubscriptionOnboardingView()

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading)
    }

    private func settingsRow(_ entry: TatwoIssueListEntryV1) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor(entry.status))
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if !entry.body.isEmpty {
                    Text(entry.body)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("來源：\(entry.sourceType == .plan ? "Plan" : "Chat")・\(entry.sourceReference)・\(statusLabel(entry.status))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            if entry.status == .archived {
                Button {
                    model.restoreIssueFromArchive(entry.id)
                } label: {
                    Image(systemName: "arrow.uturn.up")
                }
                .buttonStyle(.borderless)
                .help("還原回等待中")
            }
            Button(role: .destructive) {
                pendingRemove = entry
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("移除（需確認）")
        }
        .padding(10)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func statusColor(_ status: TatwoIssueEntryStatusV1) -> Color {
        switch status {
        case .queued: return .secondary.opacity(0.6)
        case .activated: return .green
        case .archived: return .orange.opacity(0.7)
        }
    }

    private func statusLabel(_ status: TatwoIssueEntryStatusV1) -> String {
        switch status {
        case .queued: return "等待中"
        case .activated: return "已啟用"
        case .archived: return "已封存"
        }
    }
}
