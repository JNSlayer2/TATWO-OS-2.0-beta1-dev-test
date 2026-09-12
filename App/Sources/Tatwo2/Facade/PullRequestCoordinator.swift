import SwiftUI
import AppKit

@MainActor
final class PullRequestCoordinator: ObservableObject {
    static let shared = PullRequestCoordinator()
    @Published var title = ""
    @Published var content = ""
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var submitDisabled = false
    private var window: NSWindow?
    private var snapshot: PullRequestService.Snapshot?
    private var directory: URL?
    private var repository = ""
    private var account = ""
    private var report: ((String) -> Void)?
    private let service = PullRequestService()

    func identity() throws -> FeedbackIdentity {
        let store = GitHubAccountsStore()
        guard let active = try store.loadAccounts().first,
              let token = try store.mcpToken(username: active.username), !token.isEmpty else {
            throw PullRequestFailure(message: "請先登入 GitHub 帳號。")
        }
        return FeedbackIdentity(username: active.username, token: token)
    }

    func present(directory: URL, title: String, report: @escaping (String) -> Void) {
        guard !busy else { report("PR 作業處理中，請勿重複執行。"); return }
        if let window, window.isVisible { report("請先完成或關閉已開啟的 PR 面板。"); window.makeKeyAndOrderFront(nil); return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let root = try await PullRequestService.git(["rev-parse", "--show-toplevel"], at: directory)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let directory = URL(fileURLWithPath: root, isDirectory: true)
                let identity = try identity()
                let repository = PullRequestService.repository
                let snapshot = try await service.preflight(directory: directory, repository: repository, identity: identity)
                self.directory = directory; self.repository = repository; self.snapshot = snapshot
                self.account = identity.username; self.report = report
                self.title = title; content = ""; message = ""; submitDisabled = false
                // Do not send the user's diff through the feedback-only Codex
                // reviewer or execute a tool-enabled chat turn to make prose.
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 650),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "Pull Request"; window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: PullRequestSheet(coordinator: self,
                            preview: snapshot.preview, account: identity.username, repository: repository))
                self.window = window; window.center(); window.makeKeyAndOrderFront(nil)
            } catch { report(error.localizedDescription) }
        }
    }
    /// Shares the legacy panel's busy lock; only the canvas Submit button calls this.
    func submitPlan(directory: URL, repository: String, identity expected: FeedbackIdentity,
                    snapshot: PullRequestService.Snapshot, title: String, description: String) async throws -> URL {
        guard !busy, window?.isVisible != true else {
            throw PullRequestFailure(message: "PR 作業處理中，請先完成或關閉 PR 面板。")
        }
        busy = true
        defer { busy = false }
        let current = try identity()
        guard current.username == expected.username, PullRequestService.repository == repository else {
            throw PullRequestFailure(message: "帳號或倉庫設定已變更，未自動送出 PR。")
        }
        return try await service.submit(directory: directory, repository: repository, identity: current,
                                        snapshot: snapshot, title: title, description: description)
    }

    func close() { guard !busy else { return }; window?.close(); window = nil }
    func submit() {
        guard !busy, !submitDisabled, let directory, let snapshot else { return }
        do {
            let identity = try identity()
            guard identity.username == account, PullRequestService.repository == repository else {
                throw PullRequestFailure(message: "帳號或倉庫設定已變更，請重新執行 /pr。")
            }
            let title = self.title, description = content
            busy = true; submitDisabled = true
            Task {
                defer { busy = false }
                do {
                    let url = try await service.submit(directory: directory, repository: repository,
                                         identity: identity, snapshot: snapshot, title: title, description: description)
                    message = "已建立 PR：\(url.absoluteString)"; report?(message)
                    NSWorkspace.shared.open(url)
                } catch {
                    message = error.localizedDescription + "\n請先確認本機分支與 GitHub 結果；本面板不會自動重送。"
                    report?(message)
                }
            }
        } catch { message = error.localizedDescription }
    }
}
