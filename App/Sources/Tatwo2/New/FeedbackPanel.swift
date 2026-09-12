import SwiftUI

/// Shared Chat/note presentation. The caller owns the draft and every side effect.
/// Connected by FeedbackSheet; service receipts, not displayed phase, authorize POST.
/// A displayed phase is not security authorization: submission must revalidate
/// the caller's immutable reviewed payload. Closing does not cancel a submission.
struct FeedbackPanel: View {
    enum Phase: Equatable {
        case draft, checking, reviewed, submitting
        // `failed` means definitely not submitted; uncertain delivery is separate.
        case blocked(String), failed(String), unconfirmed, submitted(Int)

        var allowsEditing: Bool {
            switch self {
            case .draft, .blocked, .failed: return true
            default: return false
            }
        }

        var isBusy: Bool { self == .checking || self == .submitting }
    }

    @Binding var title: String
    @Binding var content: String
    let source: String
    let account: String?
    let destination: String?
    let phase: Phase
    let close: () -> Void
    let review: () -> Void
    let edit: () -> Void
    let submit: () -> Void
    let checkSubmission: () -> Void
    let openIssue: () -> Void
    var reviewedBody: String? = nil
    var requiresManualConfirmation = false
    @Binding var manualConfirmation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("回報問題").font(.title3.bold())
                    Text(source).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("關閉", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("關閉並保留草稿")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("標題").font(.callout.weight(.medium))
                        if phase.allowsEditing {
                            TextField("用一句話描述問題", text: $title)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("問題標題")
                        } else {
                            Text(title).frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("內容").font(.callout.weight(.medium))
                        if phase.allowsEditing {
                            TextField("發生了什麼？如何重現？你預期的結果是什麼？",
                                      text: $content, axis: .vertical)
                                .lineLimit(8...12)
                                .textFieldStyle(.plain)
                                .accessibilityLabel("問題內容")
                                .padding(10)
                                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(.quaternary, lineWidth: 1)
                                }
                        } else {
                            Text(reviewedBody ?? content)
                                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    HStack(alignment: .top) {
                        if let account { Label(account, systemImage: "person.crop.circle") }
                        Spacer(minLength: 8)
                        Text(destination ?? "回饋倉庫尚未設定")
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if phase == .reviewed && requiresManualConfirmation {
                        Toggle("未經引擎審查，請自行確認內容不含私人資料", isOn: $manualConfirmation)
                            .toggleStyle(.checkbox)
                    } else {
                        FeedbackStatusMessage(account: account, destination: destination, phase: phase)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("提交內容會附上 App 版本、macOS 版本與目前引擎；送出前可確認完整內容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    if phase == .reviewed {
                        Button("返回修改", action: edit)
                        Button("提交 Issue", action: submit)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canReview || (requiresManualConfirmation && !manualConfirmation))
                    } else if phase == .unconfirmed {
                        Button("確認提交狀態", action: checkSubmission)
                    } else if case .submitted = phase {
                        Button("查看 Issue", action: openIssue)
                    } else {
                        Button(phase.isBusy ? "處理中…" : "檢查內容", action: review)
                            .buttonStyle(.borderedProminent)
                            .disabled(!phase.allowsEditing || !canReview)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 560, maxWidth: 720)
        .onExitCommand(perform: close)
    }

    private var canReview: Bool {
        account?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && destination?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Can also occupy the existing composer status drawer; it does not add a drawer.
struct FeedbackStatusMessage: View {
    let account: String?
    let destination: String?
    let phase: FeedbackPanel.Phase

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if phase.isBusy {
                ProgressView().controlSize(.small)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(isError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    var message: String {
        // An account refresh must not hide a real pending or completed submission.
        if (phase == .draft || phase == .reviewed), let prerequisiteMessage {
            return prerequisiteMessage
        }
        switch phase {
        case .draft: return "送出前檢查敏感及危險資訊；檢查不會修改原文。"
        case .checking: return "正在檢查內容，尚未提交。"
        case .blocked(let reason):
            return ["未送出：\(reason)", prerequisiteMessage].compactMap { $0 }.joined(separator: "\n")
        case .reviewed: return "檢查通過。請確認上方完整內容與目的倉庫後提交。"
        case .submitting: return "正在提交，請勿重複送出。"
        case .submitted(let number): return "已建立 Issue #\(number)"
        case .failed(let reason):
            return ["未送出：\(reason)；草稿已保留。", prerequisiteMessage].compactMap { $0 }.joined(separator: "\n")
        case .unconfirmed: return "提交結果尚未確認，先確認狀態，不重複送出。"
        }
    }

    var isError: Bool {
        if (phase == .draft || phase == .reviewed)
            && account?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return true }
        switch phase {
        case .blocked, .failed, .unconfirmed: return true
        default: return false
        }
    }

    private var prerequisiteMessage: String? {
        if account?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return "請先登入github才能提交issue"
        }
        if destination?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return "回饋倉庫尚未開放，草稿不會送出。"
        }
        return nil
    }
}

/// One presentation reused by Chat and global notes; closing retains the draft.
struct FeedbackSheet: View {
    @ObservedObject var coordinator: FeedbackCoordinator
    @AppStorage(FeedbackSettings.repositoryKey) private var feedbackRepository = FeedbackSettings.defaultRepository
    var body: some View {
        VStack(spacing: 0) {
            FeedbackPanel(title: $coordinator.title, content: $coordinator.content,
                          source: coordinator.source, account: coordinator.account,
                          destination: coordinator.destination, phase: coordinator.phase,
                          close: coordinator.close, review: coordinator.review, edit: coordinator.edit,
                          submit: coordinator.submit, checkSubmission: coordinator.checkSubmission,
                          openIssue: coordinator.openIssue,
                          reviewedBody: coordinator.reviewedBody,
                          requiresManualConfirmation: coordinator.requiresManualConfirmation,
                          manualConfirmation: $coordinator.manualConfirmation)
            if case .submitted = coordinator.phase {
                Button("新增回報", action: coordinator.newDraft).padding(.bottom, 16)
            }
        }
        .onChange(of: feedbackRepository) { _, _ in coordinator.repositoryChanged() }
    }
}
