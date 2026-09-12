import SwiftUI
import AppKit

/// W2: mount at the top of the GitHub settings page when integration authorizes its call site.
struct UpdateAvailableCard: View {
    @ObservedObject var model: ChatPageModel
    let onOpenCLI: () -> Void
    @ObservedObject private var checker = GitHubReleaseUpdateChecker.shared
    @ObservedObject private var updater = InAppUpdater.shared
    @State private var executionError: String?
    @State private var isExecuting = false

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
            if let release = checker.availableRelease {
                Text("目前 v\(currentVersion) → 可更新到 \(release.tag_name.hasPrefix("v") ? release.tag_name : "v" + release.tag_name)")
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
                // 2026-09-12 使用者：要像 Codex 一樣按一下就更新，不碰終端機。
                HStack {
                    Button(updateButtonTitle) { updater.update(to: release.tag_name) }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.phase == .starting || updater.phase == .handedOff)
                    Spacer()
                    if updater.phase == .starting {
                        Button("取消") { updater.cancelUpdate() }
                    } else {
                        Button("稍後") { checker.dismissForLaunch() }
                            .disabled(updater.phase == .handedOff)
                    }
                }
                if updater.phase == .starting {
                    ProgressView(value: updater.downloadProgress)
                    Text(updater.downloadSource)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(downloadStatus)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(updater.phase == .handedOff
                     ? "已下載，即將關閉 App 安裝…"
                     : "先在背景下載，下載完成後 App 才會關閉並安裝。裝好會自動重新開啟，舊版會保留備份。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let reason) = updater.phase {
                    Text(reason).font(.footnote).foregroundStyle(.red)
                }
                DisclosureGroup("進階：用終端機更新") {
                    Text(GitHubReleaseUpdateChecker.installCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("複製") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(GitHubReleaseUpdateChecker.installCommand, forType: .string)
                        }
                        Button("在 CLI 分頁執行") { executeInCLI() }
                            .disabled(isExecuting)
                    }
                }
                .font(.footnote)
            }
            if let executionError { Text(executionError).font(.footnote).foregroundStyle(.red) }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private var downloadStatus: String {
        let downloaded = String(format: "已下載 %.1f MB", Double(updater.downloadedBytes) / 1_000_000)
        guard updater.totalBytes > 0 else { return downloaded }
        return downloaded + String(format: " / %.1f MB（約 %.0f KB/s）",
                                   Double(updater.totalBytes) / 1_000_000, updater.downloadBytesPerSecond / 1_000)
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

    private var updateButtonTitle: String {
        switch updater.phase {
        case .idle, .failed:
            if let tag = checker.availableRelease?.tag_name, let bytes = updater.resumableBytes(for: tag) {
                return String(format: "繼續下載（已 %.1f MB）", Double(bytes) / 1_000_000)
            }
            return "下載並更新"
        case .starting: return "下載與校驗中…"
        case .handedOff: return "更新中，App 即將關閉"
        }
    }

    private func executeInCLI() {
        executionError = nil
        guard let id = model.openCLITab(engine: .generic, workdir: NSHomeDirectory()),
              let session = model.cliTabPTYSession(for: id) else {
            executionError = "請先選取本機對話並等待 CLI 就緒，再試一次。"
            return
        }
        model.renameCLITab(id, title: "TATWO OS 更新")
        model.selectCLITab(id)
        isExecuting = true
        Task {
            defer { isExecuting = false }
            do {
                try await session.sendLineAwaited(GitHubReleaseUpdateChecker.installCommand)
                model.mode = .cli
                onOpenCLI()
            }
            catch { executionError = "無法送出安裝指令；請複製到終端機執行。" }
        }
    }
}

struct SidebarUpdateShortcut: View {
    @ObservedObject private var checker = GitHubReleaseUpdateChecker.shared
    @ObservedObject private var updater = InAppUpdater.shared
    let openUpdateSettings: () -> Void
    var body: some View {
        if let release = checker.availableRelease, !checker.dismissed {
            Button(action: openUpdateSettings) {
                Text(updater.phase == .starting
                     ? updater.downloadProgress.map { "下載 \(Int($0 * 100))%" } ?? "準備下載…"
                     : "有新版 \(release.tag_name)")
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    .frame(minHeight: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("開啟設定的 App 更新卡")
            .accessibilityIdentifier("chat-sidebar-update")
        }
    }
}
