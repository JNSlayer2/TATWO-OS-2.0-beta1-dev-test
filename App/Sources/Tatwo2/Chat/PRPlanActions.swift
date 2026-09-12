import SwiftUI
import AppKit

struct PRPlanActions: View {
    let artifact: TatwoPlanArtifactV1
    let isDisabled: Bool
    let onConfirm: () -> Void
    let onSubmit: () -> Void
    @StateObject private var accounts = GitHubAccountsStore()
    @State private var loggedIn = false
    @State private var loggingIn = false
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let review = artifact.prReview {
                Text("\(review.account) → \(review.repository)").font(.caption).textSelection(.enabled)
                ForEach(PRPlanReview.files(review.snapshot.diff)) { file in
                    DisclosureGroup {
                        ScrollView(.horizontal) {
                            Text(file.preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    } label: {
                        Text("\(file.path)  +\(file.added) / -\(file.removed)")
                            .font(.caption).lineLimit(2).help(file.path)
                    }
                }
            }
            if let message = artifact.prMessage { Text(message).textSelection(.enabled) }
            if let loginError { Text(loginError).foregroundStyle(.red) }
            if !loggedIn {
                Button(loggingIn ? "登入中…" : "登入 GitHub") {
                    loggingIn = true; loginError = nil
                    Task {
                        defer { loggingIn = false }
                        do { _ = try await accounts.loginViaGH(); loggedIn = (try? PullRequestCoordinator.shared.identity()) != nil }
                        catch { loginError = error.localizedDescription }
                    }
                }.disabled(loggingIn)
                if let code = accounts.deviceCode {
                    Text(code).textSelection(.enabled)
                    Button("開啟 GitHub 驗證") {
                        accounts.submitLoginInput("")
                        if let url = accounts.verificationURL { NSWorkspace.shared.open(url) }
                    }
                }
            }
            if let url = artifact.prReview?.submittedURL {
                Link("已送 PR · \(url.absoluteString)", destination: url)
            } else if artifact.state == .ready {
                Button("送 PR", action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .disabled(isDisabled || !loggedIn || artifact.prReview?.attempted != false)
                    .accessibilityIdentifier("pr-plan-submit")
            } else {
                Button(artifact.state == .confirmed ? "計畫已確認" : "確認計畫", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(isDisabled || !loggedIn || artifact.state != .discussing || artifact.sections.isEmpty)
                    .accessibilityIdentifier("pr-plan-confirm")
            }
        }
        .onAppear { loggedIn = (try? PullRequestCoordinator.shared.identity()) != nil }
    }
}
