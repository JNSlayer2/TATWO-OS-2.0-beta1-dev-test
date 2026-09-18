import SwiftUI

/// Uses the existing app-wide download store; never starts a second download.
struct ChatBrowserDownloadsView: View {
    @ObservedObject private var store = BrowserDownloadStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("下載項目").font(.headline)
            if store.downloads.isEmpty {
                Text("尚無下載項目").foregroundStyle(.secondary).padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(store.downloads) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.filename).font(.callout.weight(.medium)).lineLimit(2)
                                Text(item.time).font(.caption).foregroundStyle(.secondary)
                                if let failure = item.failure, item.state == .failed {
                                    Text(failure).font(.caption).foregroundStyle(.red)
                                }
                                HStack {
                                    if store.canPause(item) { Button("暫停") { store.pause(item) } }
                                    if store.canResume(item) { Button("繼續") { store.resume(item) } }
                                    if store.canCancel(item) { Button("取消") { store.cancel(item) } }
                                    if store.canRetry(item) { Button("重試") { store.retry(item) } }
                                    if item.done {
                                        Button("預覽") { store.preview(item) }
                                        Button("在 Finder 顯示") { store.reveal(item) }
                                    }
                                }.controlSize(.small)
                            }
                            Divider()
                        }
                    }
                }.frame(maxHeight: 360)
            }
        }.padding(16).frame(width: 330)
    }
}
