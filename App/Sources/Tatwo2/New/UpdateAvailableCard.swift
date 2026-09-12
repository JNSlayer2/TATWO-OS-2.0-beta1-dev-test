import SwiftUI
import AppKit

/// W2: mount at the top of the GitHub settings page when integration authorizes its call site.
struct UpdateAvailableCard: View {
    @ObservedObject var model: ChatPageModel
    let onOpenCLI: () -> Void
    @ObservedObject private var checker = GitHubReleaseUpdateChecker.shared
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
            if let release = checker.availableRelease, !checker.dismissed {
                Text("有新版 · \(release.tag_name)").font(.headline)
                if let title = release.name, !title.isEmpty { Text(title) }
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
                    Spacer()
                    Button("稍後") { checker.dismissForLaunch() }
                }
            } else if !checker.status.isEmpty && !checker.dismissed {
                Text(checker.status).font(.footnote).foregroundStyle(.secondary)
            }
            if let executionError { Text(executionError).font(.footnote).foregroundStyle(.red) }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
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
