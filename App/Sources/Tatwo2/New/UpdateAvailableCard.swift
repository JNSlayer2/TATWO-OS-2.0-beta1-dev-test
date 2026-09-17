import SwiftUI
import AppKit

/// W2: mount at the top of the GitHub settings page when integration authorizes its call site.
struct UpdateAvailableCard: View {
    @ObservedObject private var checker = GitHubReleaseUpdateChecker.shared
    @ObservedObject private var updater = InAppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("App 更新").font(.headline)
                Spacer()
                Button(checker.isChecking ? "檢查中…" : "檢查更新") {
                    checker.checkForUpdatesFromUser()
                }
                .disabled(checker.isChecking)
            }
            Text("目前版本 v\(currentVersion)（build \(currentBuild)）")
                .font(.footnote).foregroundStyle(.secondary)
            if !updater.lastPhases.isEmpty {
                Text(updater.lastPhases).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let release = checker.availableRelease {
                Text("\(checker.isPrivateChannel ? "私人通道 · " : "")目前 v\(currentVersion) → 可更新到 \(release.tag_name.hasPrefix("v") ? release.tag_name : "v" + release.tag_name)")
                    .font(.headline)
            }
            if checker.status == "目前沒有較新的正式版本", let checkedAt = checker.lastCheckedAt {
                Text("目前 v\(currentVersion) · 已是最新（上次檢查 \(Self.checkTime.string(from: checkedAt))）")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if !checker.status.isEmpty && checker.status != "有新版" {
                Text(checker.status).font(.footnote).foregroundStyle(.secondary)
            }
            if let lastResult = updater.lastResult {
                Text(lastResult).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let release = checker.availableRelease, !checker.dismissed {
                if let title = release.name, !title.isEmpty { Text(title) }
                Text(updater.updateMarkTitle)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(updater.updateMarkTitle) {
                        Task {
                            await updater.activateUpdateMark(to: release.tag_name, repository: checker.repository)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.updateMarkDisabled)
                    .help(updater.updateMarkHelp)
                    Spacer()
                    Button("稍後") { checker.dismissForLaunch() }
                        .disabled(updater.phase == .handedOff)
                }
                if case .failed(let reason) = updater.phase {
                    Text(reason).font(.footnote).foregroundStyle(.red)
                }
                DisclosureGroup("進階：用終端機更新") {
                    Text("退出 TATWO OS 後在終端機貼上")
                    Text(checker.terminalInstallCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("複製指令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(checker.terminalInstallCommand, forType: .string)
                        }
                    }
                }
                .font(.footnote)
            }
        }
        .task(id: updater.lastResult) { await updater.refreshPhaseSummary() }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }

    private var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    }

    private static let checkTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

}

struct SidebarUpdateShortcut: View {
    @ObservedObject private var checker = GitHubReleaseUpdateChecker.shared
    @ObservedObject private var updater = InAppUpdater.shared
    let openUpdateSettings: () -> Void
    var body: some View {
        if let release = checker.availableRelease, !checker.dismissed {
            Button {
                Task {
                    await updater.activateUpdateMark(to: release.tag_name, repository: checker.repository)
                }
            } label: {
                Text((checker.isPrivateChannel ? "私人通道 · " : "") + updater.updateMarkTitle)
                    .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
                    .frame(minHeight: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(updater.updateMarkDisabled)
            .help(updater.updateMarkHelp)
            .accessibilityIdentifier("chat-sidebar-update")
        }
    }
}
