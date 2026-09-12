import SwiftUI

// Copied from FeedbackPanel; same field layout, PR-specific explicit submission.
struct PRPanel: View {
    @Binding var title: String
    @Binding var content: String
    let preview: String
    let account: String
    let destination: String
    let busy: Bool
    let message: String
    let submitDisabled: Bool
    let close: () -> Void
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("建立 Pull Request").font(.title3.bold())
                    Text("目標分支：main").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("關閉", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("關閉")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("標題").font(.callout.weight(.medium))
                        if !busy {
                            TextField("PR 標題", text: $title)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("PR 標題")
                        } else {
                            Text(title).frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("內容").font(.callout.weight(.medium))
                        if !busy {
                            TextField("描述改動與驗證結果",
                                      text: $content, axis: .vertical)
                                .lineLimit(8...12)
                                .textFieldStyle(.plain)
                                .accessibilityLabel("PR 說明")
                                .padding(10)
                                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(.quaternary, lineWidth: 1)
                                }
                        } else {
                            Text(content)
                                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    HStack(alignment: .top) {
                        Label(account, systemImage: "person.crop.circle")
                        Spacer(minLength: 8)
                        Text(destination)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text("Diff 摘要（前 200 行）").font(.callout.weight(.medium))
                    Text(preview).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("送出會建立分支、提交全部改動並推送至你的公開 fork。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(busy ? "處理中…" : "送出 PR", action: submit)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || submitDisabled || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 720, minHeight: 560)
        .onExitCommand(perform: close)
    }

}

struct PullRequestSheet: View {
    @ObservedObject var coordinator: PullRequestCoordinator
    let preview: String
    let account: String
    let repository: String
    var body: some View {
        PRPanel(title: $coordinator.title, content: $coordinator.content,
                preview: preview, account: account, destination: repository,
                busy: coordinator.busy, message: coordinator.message,
                submitDisabled: coordinator.submitDisabled,
                close: coordinator.close, submit: coordinator.submit)
    }
}
