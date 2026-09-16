@main struct W66SidebarChecks {
    @MainActor static func main() throws {
        let storage = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("registry.json")
        do {
            let blankRegistry = BrowserTabRegistry(storageURL: storage.appendingPathExtension("startpage"))
            let blankStore = BrowserWorkSpaceStore(registry: blankRegistry)
            precondition(blankStore.showsStartPage, "empty space has centered search")
            blankStore.addTab()
            let id = blankStore.selectedRegistryID
            precondition(id != nil && blankStore.showsStartPage, "new nil-URL tab has centered search")
            let url = URL(string: "https://example.com/search")!
            blankStore.navigateFromStartPage(to: url)
            precondition(blankStore.selectedRegistryID == id && blankRegistry.tabs.count == 1,
                         "start page navigates the existing tab, not a duplicate")
            precondition(!blankStore.showsStartPage && blankStore.selectedTab.url == url.absoluteString)
            blankStore.addTab(url: URL(string: "about:blank"))
            precondition(blankStore.showsStartPage, "restored about:blank also shows centered search")
            blankStore.selectSpace(blankStore.spaces.first { $0.isSessionSpace }!.id)
            precondition(!blankStore.showsStartPage, "session space never becomes a new-tab page")
        }
        let registry = BrowserTabRegistry(storageURL: storage)
        let store = BrowserWorkSpaceStore(registry: registry)
        let otherWindow = BrowserWorkSpaceStore(registry: registry)
        store.focusMode = true
        precondition(store.focusMode)
        store.sidebarPinned = true
        precondition(!store.focusMode, "pinning expands the sidebar")
        store.focusMode = true
        precondition(!store.focusMode, "all collapse entrypoints respect pinning")
        store.sidebarPinned = false
        store.focusMode = true
        precondition(store.focusMode, "unpinning restores collapse")
        store.focusMode = false
        for _ in 0..<3 {
            store.toggleSidebar()
            precondition(store.focusMode && !store.sidebarPinned, "explicit close fully collapses")
            store.toggleSidebar()
            precondition(!store.focusMode && store.sidebarPinned, "explicit open also pins")
        }
        let space = registry.spaces.first { !$0.isSessionSpace }!
        let owner = BrowserTabOwner.workSpace(spaceID: space.id)
        let folder = store.folders[0].id
        let secondFolder = store.addFolder()
        let url = URL(string: "https://example.com/original")!
        let bookmark = registry.addBookmark(folderID: folder, url: url, title: "Saved")!
        let sameURL = registry.addBookmark(folderID: folder, url: url, title: "Other identity")!
        let another = registry.addBookmark(folderID: secondFolder, url: url, title: "Other folder")!
        func projected(_ id: UUID) -> BrowserWorkSpaceStore.Bookmark {
            store.folders.flatMap(\.bookmarks).first { $0.id == id }!
        }
        let initialBookmarks = registry.spaces.flatMap(\.folders).flatMap(\.bookmarks)
        store.openBookmark(projected(bookmark.id), folderID: folder)
        let firstTab = store.selectedTab
        precondition(store.tabs.count == 1 && store.activeTabs.isEmpty && store.pinnedTabs.isEmpty)
        precondition(store.folders[0].expanded)
        precondition(otherWindow.tab(forBookmark: bookmark.id)?.registryID == firstTab.registryID)
        for _ in 0..<3 { store.openBookmark(projected(bookmark.id), folderID: folder) }
        precondition(store.tabs.count == 1 && store.selectedID == firstTab.id)
        registry.markSleeping(firstTab.registryID!, false)
        registry.setLoading(firstTab.registryID!, true)
        precondition(store.tab(forBookmark: bookmark.id)!.loading)
        precondition(!store.tab(forBookmark: bookmark.id)!.sleeping)
        registry.markSleeping(firstTab.registryID!, true)
        precondition(!store.tab(forBookmark: bookmark.id)!.loading && store.tab(forBookmark: bookmark.id)!.sleeping)
        registry.setPinned(firstTab.registryID!, true)
        precondition(store.selectedTab.pinned && store.pinnedTabs.isEmpty && store.activeTabs.isEmpty)
        precondition(registry.tabs.first { $0.id == firstTab.registryID }!.isPinned)
        registry.setPinned(firstTab.registryID!, false)
        precondition(!store.selectedTab.pinned)
        let navigated = URL(string: "https://example.com/navigated")!
        registry.update(firstTab.registryID!, url: navigated, title: "Navigation", favicon: nil)
        store.openBookmark(projected(bookmark.id), folderID: folder)
        precondition(store.selectedTab.url == navigated.absoluteString && store.tabs.count == 1)
        store.closeBookmark(bookmark.id)
        precondition(store.tab(forBookmark: bookmark.id) == nil && registry.tabs.isEmpty)
        precondition(registry.spaces.flatMap(\.folders).flatMap(\.bookmarks) == initialBookmarks)
        store.reopenClosedTab()
        precondition(store.selectedTab.url == navigated.absoluteString && store.selectedTab.bookmarkID == bookmark.id)
        precondition(store.selectedTab.title == "Navigation")
        precondition(store.activeTabs.isEmpty)
        // A closed-tab record must not overwrite a subsequently reopened, live page.
        store.closeBookmark(bookmark.id)
        store.openBookmark(projected(bookmark.id), folderID: folder)
        let liveID = store.selectedRegistryID!
        registry.update(liveID, url: url, title: "Live", favicon: nil)
        store.reopenClosedTab()
        precondition(store.tabs.count == 1 && store.selectedRegistryID == liveID && store.selectedTab.title == "Live")
        store.deleteBookmark(bookmark.id)
        precondition(store.activeTabs.count == 1 && store.tabs.count == 1)
        store.undoBookmarkDeletion()
        store.openBookmark(projected(bookmark.id), folderID: folder)
        precondition(store.tabs.count == 1 && store.activeTabs.isEmpty && store.selectedRegistryID == liveID)
        store.openBookmark(projected(sameURL.id), folderID: folder)
        precondition(store.tabs.count == 2 && store.selectedRegistryID != liveID)
        store.openBookmark(projected(another.id), folderID: secondFolder)
        let otherID = store.selectedRegistryID!
        // Popups within this folder close too; unrelated ordinary/other-owner tabs survive.
        let popup = registry.openTab(owner: owner, url: url, folderID: folder)
        let ordinary = registry.openTab(owner: owner, url: url)
        let chat = registry.openTab(owner: .chatSession(sessionID: "fixture-chat"), url: url, folderID: folder)
        precondition(store.folderHasOpenTabs(folder))
        store.closeFolderTabs(folder)
        precondition(!store.folderHasOpenTabs(folder))
        precondition(!registry.tabs.contains { $0.id == popup.id || $0.bookmarkID == bookmark.id || $0.bookmarkID == sameURL.id })
        precondition(registry.tabs.contains { $0.id == otherID })
        precondition(registry.tabs.contains { $0.id == ordinary.id })
        precondition(registry.tabs.contains { $0.id == chat.id })
        precondition(registry.spaces.flatMap(\.folders).flatMap(\.bookmarks) == initialBookmarks)
        try registry.flush()
        let restored = BrowserTabRegistry(storageURL: storage)
        let restoredStore = BrowserWorkSpaceStore(registry: restored)
        precondition(restoredStore.tab(forBookmark: another.id)?.registryID == otherID)
        precondition(!restoredStore.activeTabs.contains { $0.registryID == otherID })
        let newSpace = registry.addSpace(name: "Other space")
        let beforeMove = registry.tabs.count
        store.deleteBookmark(another.id)
        registry.move(otherID, to: .workSpace(spaceID: newSpace.id))
        store.undoBookmarkDeletion()
        precondition(registry.tabs.first { $0.id == otherID }?.bookmarkID == nil)
        precondition(registry.tabs.first { $0.id == otherID }?.folderID == nil)
        precondition(registry.tabs.count == beforeMove)
        precondition(registry.spaces.flatMap(\.folders).flatMap(\.bookmarks) == initialBookmarks)
        store.selectSpace(store.spaces.first { $0.name == "Other space" }!.id)
        precondition(store.activeTabs.count == 1 && store.activeTabs[0].registryID == otherID)
        let count = registry.tabs.count
        store.openBookmark(.init(id: another.id, title: "Wrong space", url: url.absoluteString), folderID: secondFolder)
        precondition(registry.tabs.count == count)
        store.selectSpace(store.spaces.first { $0.isSessionSpace }!.id)
        precondition(store.selectedRegistryID == nil, "session aggregate is not a workspace tab action target")
        precondition(!registry.tabs.first { $0.id == chat.id }!.isPinned)
        // Old tab documents without the optional binding remain readable.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registry.tabs[0])) as! [String: Any]
        old.removeValue(forKey: "bookmarkID")
        let decoded = try JSONDecoder().decode(BrowserTab.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(decoded.bookmarkID == nil)
        print("W66 sidebar fixture PASS")
    }
}
