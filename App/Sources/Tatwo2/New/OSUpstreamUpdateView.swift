import SwiftUI

/// Only unresolved differences have a row. There is deliberately no "up to date" state.
struct OSUpstreamUpdateView: View {
    @ObservedObject var update: OSUpstreamUpdateModel
    @State private var reviewing: OSUpstreamRefresh.PendingUpdate?
    @State private var userEdited = false

    private func refreshEditedStatus() {
        guard OSUpstreamRefresh.generatedContent != nil else { return }
        Task {
            userEdited = await Task.detached { OSUpstreamRefresh.isUserEdited() }.value
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if OSUpstreamRefresh.generatedContent != nil, userEdited {
                Text("OS 執行期上游：已手改（保留自訂不代表已對齊）")
                    .font(.footnote).foregroundStyle(.orange)
                if update.pending == nil {
                    Button("重新檢視已保留差異") {
                        Task {
                            reviewing = await Task.detached { try? OSUpstreamRefresh.reviewDifference() }.value
                        }
                    }
                }
            }
            if let pending = update.pending {
                Button {
                    update.reload()
                    reviewing = update.pending
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.badge.arrow.up")
                        Text("OS 上游有更新，檢視差異")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("os-upstream-update-row")
                .id(pending.id)
            }
            if let error = update.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .sheet(item: $reviewing) { pending in
            OSUpstreamDiffSheet(pending: pending, error: update.error,
                apply: {
                    if update.applyBundled(pending) { reviewing = nil }
                    else { reviewing = update.pending }
                    refreshEditedStatus()
                },
                keep: {
                    if update.keepCustom(pending) { reviewing = nil }
                    else { reviewing = update.pending }
                    refreshEditedStatus()
                },
                close: { reviewing = nil })
        }
        .onAppear { update.reload(); refreshEditedStatus() }
        .onReceive(update.$pending) { _ in refreshEditedStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            update.reload(notify: true)
            refreshEditedStatus()
        }
    }
}

struct OSUpstreamDiffSheet: View {
    let pending: OSUpstreamRefresh.PendingUpdate
    let error: String?
    let apply: () -> Void
    let keep: () -> Void
    let close: () -> Void

    private var lines: [OSUpstreamLineDiff.Line] {
        OSUpstreamLineDiff.lines(runtime: pending.runtimeText, bundled: pending.bundledText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("OS 上游差異").font(.title3.bold())
                Spacer()
                Button("關閉", action: close).keyboardShortcut(.cancelAction)
            }
            Text("− 執行期（你的版本）　＋ OS 產生版本")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 10) {
                            Text(line.runtimeLine.map(String.init) ?? "")
                                .frame(width: 36, alignment: .trailing)
                            Text(line.bundledLine.map(String.init) ?? "")
                                .frame(width: 36, alignment: .trailing)
                            Text(line.kind.prefix).frame(width: 12)
                            Text(line.text.replacingOccurrences(of: "\r", with: "␍").isEmpty
                                 ? " " : line.text.replacingOccurrences(of: "\r", with: "␍"))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(line.kind == .removed ? Color.red : line.kind == .added ? Color.green : Color.primary)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.kind == .removed ? Color.red.opacity(0.08)
                                    : line.kind == .added ? Color.green.opacity(0.08) : Color.clear)
                    }
                }
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.topLeading)
            .border(Color.secondary.opacity(0.2))
            Text("套用前會備份你的版本；保留自訂後，同一組內容不再提示。")
                .font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            HStack {
                Button("保留我的自訂", action: keep)
                Spacer()
                if OSUpstreamRefresh.generatedContent != nil {
                    Button("套用 OS 產生版本", action: apply).buttonStyle(.borderedProminent)
                } else {
                    Button("套用 App 內建版本", action: apply).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
        .accessibilityIdentifier("os-upstream-diff")
    }
}
