import SwiftUI
import TatwoUltraworkCore

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

/// TATWO OS 設定整頁：左列直行導覽，右側內容區。
struct TatwoSettingsPage: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @ObservedObject var model: ChatPageModel
    let onClose: () -> Void

    enum Section: String, CaseIterable, Identifiable {
        case issueList
        case browserManagement
        case modelAccess
        case tatwoIsland

        var id: String { rawValue }

        var title: String {
            switch self {
            case .issueList: "Issue List"
            case .browserManagement: "瀏覽器管理"
            case .modelAccess: "模型存取"
            case .tatwoIsland: "Tatwo Island"
            }
        }

        var icon: String {
            switch self {
            case .issueList: "tray.full"
            case .browserManagement: "globe.desk"
            case .modelAccess: "key"
            case .tatwoIsland: "capsule"
            }
        }
    }

    @State private var section: Section = .issueList
    @State private var issueTab: ChatPage.IssueSettingsTab = .all
    @State private var pendingRemove: TatwoIssueListEntryV1?

    var body: some View {
        HStack(spacing: 0) {
            leftNav
            Divider()
            rightContent
        }
        .frame(width: 780, height: 560)
        .onAppear { model.reloadIssueList() }
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

    @ViewBuilder
    private var rightContent: some View {
        switch section {
        case .issueList:
            issueListContent
        case .browserManagement:
            TatwoBrowserManagementView(
                model: model,
                provider: browserManagementProvider,
                onClose: onClose)
                .padding(22)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading)
        case .modelAccess:
            modelAccessContent
        case .tatwoIsland:
            tatwoIslandContent
        }
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
