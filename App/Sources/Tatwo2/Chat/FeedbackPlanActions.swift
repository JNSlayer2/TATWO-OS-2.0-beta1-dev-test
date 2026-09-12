import SwiftUI
import AppKit

/// Only this human-operated surface may move a feedback canvas into delivery.
struct FeedbackPlanActions: View {
    let artifact: TatwoPlanArtifactV1
    let isDisabled: Bool
    let onSubmitted: (UUID) -> Void
    @Binding var isLocked: Bool
    @StateObject private var coordinator: FeedbackCoordinator
    @StateObject private var accounts = GitHubAccountsStore()
    @State private var requestedText: String?
    @State private var loggingIn = false
    @State private var loginError: String?
    @AppStorage(FeedbackSettings.repositoryKey) private var repository = FeedbackSettings.defaultRepository

    init(artifact: TatwoPlanArtifactV1, isDisabled: Bool, isLocked: Binding<Bool>, onSubmitted: @escaping (UUID) -> Void) {
        self.artifact = artifact
        self.isDisabled = isDisabled
        self.onSubmitted = onSubmitted
        _isLocked = isLocked
        _coordinator = StateObject(wrappedValue: FeedbackCoordinator.forPlan(artifact.planID))
    }

    private var complete: Bool {
        let titles = ["標題", "環境", "重現步驟", "預期", "實際", "附註"]
        return titles.allSatisfy { title in
            let matches = artifact.sections.filter { $0.title == title }
            return matches.count == 1 && !matches[0].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedbackStatusMessage(account: coordinator.account, destination: coordinator.destination, phase: coordinator.phase)
            if let loginError { Text(loginError).foregroundStyle(.red) }
            if coordinator.account == nil {
                Button(loggingIn ? "登入中…" : "登入 GitHub") {
                    loggingIn = true; loginError = nil
                    Task {
                        defer { loggingIn = false }
                        do { _ = try await accounts.loginViaGH(); coordinator.refreshAccount() }
                        catch { loginError = error.localizedDescription }
                    }
                }
                .disabled(loggingIn)
                .accessibilityIdentifier("feedback-plan-login")
                if let code = accounts.deviceCode {
                    Text(code).textSelection(.enabled)
                    Button("開啟 GitHub 驗證") {
                        accounts.submitLoginInput("")
                        if let url = accounts.verificationURL { NSWorkspace.shared.open(url) }
                    }
                }
            }
            if let body = coordinator.reviewedBody {
                DisclosureGroup("提交全文") { Text(body).textSelection(.enabled) }
            }
            if coordinator.phase == .reviewed && coordinator.requiresManualConfirmation {
                Toggle("未經引擎審查，請自行確認內容不含私人資料", isOn: $coordinator.manualConfirmation)
                    .toggleStyle(.checkbox)
            }
            if case .submitted(let number) = coordinator.phase,
               let url = URL(string: "https://github.com/\(coordinator.destination)/issues/\(number)") {
                Link("已送出 #\(number) · \(url.absoluteString)", destination: url)
            } else if coordinator.phase == .unconfirmed {
                Button("確認提交狀態", action: coordinator.checkSubmission)
            } else {
                if coordinator.phase == .reviewed {
                    Button("返回修改") { requestedText = nil; coordinator.edit() }
                }
                Button(coordinator.phase == .checking ? "審查中…" : "提交 Issue", action: submitIssue)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .disabled(isDisabled || !complete || coordinator.account == nil || coordinator.phase.isBusy
                        || (coordinator.phase == .reviewed && coordinator.requiresManualConfirmation && !coordinator.manualConfirmation))
                    .accessibilityIdentifier("feedback-plan-submit")
            }
        }
        .onAppear {
            coordinator.refreshAccount(); isLocked = !coordinator.phase.allowsEditing
            if case .submitted = coordinator.phase { onSubmitted(artifact.planID) }
        }
        .onDisappear { requestedText = nil }
        .onChange(of: coordinator.phase) { _, phase in
            isLocked = !phase.allowsEditing
            if case .submitted = phase { onSubmitted(artifact.planID) }
            if phase == .reviewed, requestedText == artifact.editableText(), !isDisabled,
               !coordinator.requiresManualConfirmation { coordinator.submit() }
        }
        .onChange(of: repository) { _, _ in requestedText = nil; coordinator.repositoryChanged() }
    }

    private func submitIssue() {
        guard !isDisabled, complete else { return }
        if coordinator.phase == .reviewed, coordinator.title == issueTitle, coordinator.content == issueBody {
            coordinator.submit()
        } else {
            if coordinator.phase == .reviewed { coordinator.edit() }
            guard coordinator.phase.allowsEditing else { return }
            requestedText = artifact.editableText()
            coordinator.title = issueTitle
            coordinator.content = issueBody
            coordinator.review()
        }
    }

    private var issueTitle: String { artifact.sections.first { $0.title == "標題" }?.body ?? "" }
    private var issueBody: String {
        artifact.sections.filter { $0.title != "標題" }.map { "## \($0.title)\n\($0.body)" }.joined(separator: "\n\n")
    }
}
