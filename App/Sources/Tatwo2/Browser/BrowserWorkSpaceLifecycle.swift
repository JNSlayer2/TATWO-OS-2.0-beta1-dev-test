import Foundation

/// W57b integration adapter: the W57a view/store and CEF surface remain untouched.
@MainActor
final class BrowserWorkSpaceLifecycle {
    private let store: BrowserWorkSpaceStore
    private let registry: BrowserTabRegistry
    private let queue: BrowserExternalURLQueue
    private let settingsURL: URL

    init(store: BrowserWorkSpaceStore, registry: BrowserTabRegistry, queue: BrowserExternalURLQueue,
         settingsURL: URL = BrowserGeneralSettings.fileURL) {
        self.store = store
        self.registry = registry
        self.queue = queue
        self.settingsURL = settingsURL
    }

    func enter() throws {
        let settings = BrowserGeneralSettings.load(from: settingsURL)
        if let tab = registry.tabs.first(where: { $0.id == settings.lastSelectedTabID }),
           case let .workSpace(spaceID) = tab.owner, selectSpace(spaceID) {
            // The store exposes window-local Int aliases. Its public tab projection preserves
            // registry order; join those projections here rather than persist/reconstruct aliases.
            if let pair = zip(registry.tabs(ownedBy: tab.owner), store.tabs).first(where: { $0.0.id == tab.id }) {
                store.select(pair.1.id)
            }
        } else if let spaceID = settings.defaultSpaceID {
            _ = selectSpace(spaceID)
        }
        // W47's mounted CEF runtime wakes only this selected tab; all others stay sleeping.
        try consumePendingURLs()
    }

    private func selectSpace(_ id: UUID) -> Bool {
        let records = registry.spaces.filter { !$0.isSessionSpace }
        let projections = store.spaces.filter { !$0.isSessionSpace }
        guard let pair = zip(records, projections).first(where: { $0.0.id == id }) else { return false }
        store.selectSpace(pair.1.id)
        return store.currentSpaceUUID == id
    }

    func consumePendingURLs() throws {
        queue.consume(whenMounted: true) { urls in
            let settings = BrowserGeneralSettings.load(from: settingsURL)
            let target = registry.spaces.first { $0.id == store.currentSpaceUUID && !$0.isSessionSpace }
                ?? registry.spaces.first { $0.id == settings.defaultSpaceID && !$0.isSessionSpace }
                ?? registry.spaces.first { !$0.isSessionSpace }
                ?? registry.addSpace(name: "一般")
            for url in urls {
                // Existing UUID-aware entrypoint calls registry.openTab(owner: .workSpace, url:)
                // and selects the new tab; no Session-space or chat ownership can leak in.
                store.openExternal(spaceID: target.id, url: url)
                if let id = store.selectedRegistryID { registry.select(id) }
            }
        }
        try recordSelection()
    }

    func recordSelection() throws {
        // Visiting the read-only Session aggregate must not discard the last Browser selection.
        guard let spaceID = store.currentSpaceUUID else { return }
        var settings = BrowserGeneralSettings.load(from: settingsURL)
        let selected = store.selectedRegistryID.flatMap { id in
            registry.tabs.first { $0.id == id && $0.owner == .workSpace(spaceID: spaceID) }?.id
        }
        guard settings.lastSelectedTabID != selected else { return }
        settings.lastSelectedTabID = selected
        try settings.save(to: settingsURL)
    }
}
