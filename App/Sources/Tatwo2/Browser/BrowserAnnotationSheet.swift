import SwiftUI

/// A read/delete view of the existing profile-partitioned store. No second annotation ledger.
struct BrowserAnnotationSheet: View {
    let tab: BrowserTab
    @ObservedObject private var store = EmbeddedBrowserAnnotationStore.shared
    @Environment(\.dismiss) private var dismiss

    private var profileKey: UUID? {
        switch tab.owner {
        case let .chatSession(sessionID): TatwoBrowserProfileIdentity(sessionID: sessionID)?.dataStoreIdentifier
        case .workSpace: BrowserWorkSpaceRuntime.profile.registryKey
        case .bot: nil
        }
    }
    private var annotations: [EmbeddedBrowserAnnotation] {
        guard let profileKey, let url = tab.url?.absoluteString else { return [] }
        return store.annotations(forURL: url, profileKey: profileKey)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("註解").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(tab.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if annotations.isEmpty {
                Text("此頁尚無註解").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(annotations) { annotation in
                    HStack(alignment: .top, spacing: 8) {
                        Text(annotation.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button { store.remove(annotation) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).help("刪除此註解").accessibilityLabel("刪除此註解")
                    }.padding(.vertical, 6)
                }
            }
        }.padding(20).frame(minWidth: 360, idealWidth: 440, minHeight: 260, idealHeight: 360)
    }
}
