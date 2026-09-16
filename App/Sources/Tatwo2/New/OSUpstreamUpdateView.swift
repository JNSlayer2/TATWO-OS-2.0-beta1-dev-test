import SwiftUI

/// Only unresolved differences have a row. There is deliberately no "up to date" state.
struct OSUpstreamUpdateView: View {
    @ObservedObject var update: OSUpstreamUpdateModel
    @State private var reviewing: OSUpstreamRefresh.PendingUpdate?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                },
                keep: {
                    if update.keepCustom(pending) { reviewing = nil }
                    else { reviewing = update.pending }
                },
                close: { reviewing = nil })
        }
        .onAppear { update.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            update.reload(notify: true)
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
            Text("− 執行期（你的版本）　＋ App 內建版本")
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
                Button("套用 App 內建版本", action: apply)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
        .accessibilityIdentifier("os-upstream-diff")
    }
}
