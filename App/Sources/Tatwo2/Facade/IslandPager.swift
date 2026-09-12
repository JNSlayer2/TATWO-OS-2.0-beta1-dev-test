import Foundation
import Combine

@MainActor final class IslandPager: ObservableObject {
    @Published private(set) var spaces: [IslandSpaceRecord]
    @Published private(set) var currentIndex = 0
    @Published var isVisible = false { didSet { reconcile() } }
    private let providers: [UUID: any IslandSpaceProvider]
    private let unloadDelay: TimeInterval
    private var pendingUnload: Task<Void, Never>?
    init(spaces: [IslandSpaceRecord], providers: [UUID: any IslandSpaceProvider], unloadDelay: TimeInterval = 30) {
        self.spaces = spaces.filter(\.enabled).sorted { $0.order < $1.order }
        self.providers = providers; self.unloadDelay = unloadDelay
        reconcile()
    }
    deinit { pendingUnload?.cancel() }
    func next() { select(currentIndex + 1) }
    func prev() { select(currentIndex - 1) }
    func select(_ index: Int) { currentIndex = min(max(index, 0), max(0, spaces.count - 1)); reconcile() }
    private func reconcile() {
        pendingUnload?.cancel(); pendingUnload = nil
        let selected = isVisible && spaces.indices.contains(currentIndex) ? spaces[currentIndex].id : nil
        for (id, provider) in providers { if id != selected { provider.suspend() } }
        if let selected { providers[selected]?.activate() }
        if !isVisible {
            pendingUnload = Task { [weak self, unloadDelay] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0, unloadDelay) * 1_000_000_000)) } catch { return }
                guard let self, !self.isVisible else { return }
                self.providers.values.forEach { $0.unload() }
            }
        }
    }
}
