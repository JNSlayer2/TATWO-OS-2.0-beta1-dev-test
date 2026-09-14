import SwiftUI

struct BrowserWorkSpaceLifecycleModifier: ViewModifier {
    @ObservedObject var store: BrowserWorkSpaceStore
    let registry: BrowserTabRegistry
    let isWindow: Bool
    @State private var mounted = false
    @State private var error: String?

    private var lifecycle: BrowserWorkSpaceLifecycle {
        BrowserWorkSpaceLifecycle(store: store, registry: registry, queue: .shared)
    }

    func body(content: Content) -> some View {
        Group {
            // Resolve the persisted UUID before CEF can mount a default/first tab.
            if mounted || !isWindow { content }
            else { Color.clear }
        }
            .onAppear {
                guard isWindow else { return }
                perform { try lifecycle.enter() }
                mounted = true
            }
            .onDisappear {
                guard mounted else { return }
                mounted = false
                perform { try lifecycle.recordSelection() }
            }
            .onChange(of: store.selectedRegistryID) { _, _ in
                guard mounted else { return }
                perform { try lifecycle.recordSelection() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .tatwoBrowserOpenExternalURLs)) { _ in
                guard mounted else { return }
                perform { try lifecycle.consumePendingURLs() }
            }
            .overlay(alignment: .bottom) {
                if let error { Text(error).font(.caption).padding(8).background(.regularMaterial) }
            }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); error = nil }
        catch { self.error = "分頁還原設定未儲存：\(error.localizedDescription)" }
    }
}
