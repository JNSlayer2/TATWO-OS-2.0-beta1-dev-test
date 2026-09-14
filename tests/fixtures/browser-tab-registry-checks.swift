import Foundation
import Combine
import AppKit

// Real compatibility extension, only the app's unrelated engine/UI dependencies are doubled.
@MainActor final class ChatPageModel {
    let browserTabRegistry: BrowserTabRegistry
    init(_ registry: BrowserTabRegistry) { browserTabRegistry = registry }
}

@main struct RegistryChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = directory.appendingPathComponent("tabs.json")
        let registry = BrowserTabRegistry(storageURL: file, titleProvider: { ("Thread \($0)", "Project") })
        precondition(registry.tabs.isEmpty && registry.spaces.count == 2)
        let general = registry.spaces.first { !$0.isSessionSpace }!
        let session = BrowserTabOwner.chatSession(sessionID: "a")
        let other = BrowserTabOwner.chatSession(sessionID: "b")
        let a = registry.openTab(owner: session, url: URL(string: "https://example.com/a")!, title: "A")
        registry.openTab(owner: session, url: URL(string: "https://example.com/b")!, title: "B")
        registry.openTab(owner: other, url: URL(string: "https://example.org/a")!, title: "C")
        registry.openTab(owner: other, url: URL(string: "https://example.org/b")!, title: "D")
        precondition(registry.openSessions.count == 2)
        precondition(registry.openSessions.allSatisfy { $0.laneCount == 2 && $0.projectName == "Project" && $0.threadTitle.hasPrefix("Thread ") })
        let stale = registry.laneSnapshot(for: "a")!
        registry.move(a.id, to: .workSpace(spaceID: general.id))
        precondition(registry.tabs(ownedBy: session).count == 1)
        precondition(registry.tabs(ownedBy: .workSpace(spaceID: general.id)).count == 1)
        registry.storeLanes(stale, for: "a")
        precondition(registry.tabs(ownedBy: session).count == 1, "stale panel resurrected a moved tab")
        registry.closeAll(ownedBy: other)
        precondition(registry.openSessions.count == 1 && registry.tabs(ownedBy: other).isEmpty)
        precondition(registry.laneSnapshot(for: "b") == nil)
        registry.openTab(owner: .bot(botID: "bot"), url: URL(string: "https://example.net"), title: "Bot")
        let facade = ChatPageModel(registry)
        precondition(facade.browserLanes(for: nil) == nil)
        precondition(facade.openBrowserSessions.count == 1)
        facade.closeAllBrowserLanes()
        precondition(facade.openBrowserSessions.isEmpty)
        precondition(registry.tabs.count == 2, "chat close must preserve workspace and bot")
        let image = Data([137, 80, 78, 71, 13, 10, 26, 10])
        registry.update(a.id, url: a.url, title: "Updated", favicon: image)
        registry.setPinned(a.id, true)
        registry.markSleeping(a.id, true)
        registry.touch(a.id)
        registry.renameSpace(general.id, to: "Renamed")
        let folder = registry.addFolder(spaceID: general.id, name: "Folder")!
        registry.renameFolder(folder.id, to: "Renamed folder")
        let bookmark = registry.addBookmark(folderID: folder.id, url: a.url!, title: "Bookmark")!
        try registry.flush()
        let readback = BrowserTabRegistry(storageURL: file)
        precondition(readback.tabs == registry.tabs && readback.spaces == registry.spaces)
        let json = try String(contentsOf: file, encoding: .utf8)
        precondition(json.contains("schemaVersion") && json.contains("\(a.id.uuidString).png"))
        precondition(!json.contains(image.base64EncodedString()) && !json.contains("faviconPNG"))
        precondition((try? Data(contentsOf: directory.appendingPathComponent("favicons/\(a.id.uuidString).png"))) == image)
        registry.removeBookmark(bookmark.id)
        precondition(registry.moveTabToBookmark(tabID: a.id, folderID: folder.id))
        precondition(!registry.tabs.contains { $0.id == a.id })
        precondition(registry.spaces.first { $0.id == general.id }!.folders.last!.bookmarks.count == 1)
        let removeSpace = registry.addSpace(name: "Remove")
        registry.openTab(owner: .workSpace(spaceID: removeSpace.id))
        registry.removeSpace(removeSpace.id, closingTabs: false)
        precondition(registry.spaces.contains { $0.id == removeSpace.id })
        registry.removeSpace(removeSpace.id, closingTabs: true)
        precondition(!registry.spaces.contains { $0.id == removeSpace.id })
        registry.renameSpace(BrowserTabRegistry.sessionSpaceID, to: "Forbidden")
        registry.removeSpace(BrowserTabRegistry.sessionSpaceID, closingTabs: true)
        registry.openTab(owner: .workSpace(spaceID: BrowserTabRegistry.sessionSpaceID))
        precondition(registry.tabs(ownedBy: .workSpace(spaceID: BrowserTabRegistry.sessionSpaceID)).isEmpty)
        precondition(registry.spaces.contains { $0.isSessionSpace && $0.name == "Session space" })
        precondition(registry.addFolder(spaceID: BrowserTabRegistry.sessionSpaceID) == nil)

        // Exact legacy lane identities, bindings, selection, pinning, count limit and timestamps.
        let instant = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let lanes = [
            TatwoBrowserLane(id: .init(rawValue: "legacy-pinned"), binding: .goal(goalID: "g", contractID: "c"), title: "Pinned", isPinned: true, createdAt: instant, lastActiveAt: instant),
            TatwoBrowserLane(id: .init(rawValue: "legacy-selected"), binding: .unboundReadOnly, title: "Selected", createdAt: instant, lastActiveAt: instant)
        ]
        let state = TatwoBrowserLaneState(maximumLaneCount: 12, lanes: lanes, selectedLaneID: lanes[1].id)
        let snapshot = BrowserLaneSnapshot(laneState: state, laneURLs: [lanes[1].id.rawValue: URL(string: "https://example.com/legacy")!], updatedAt: instant)
        let legacyDir = directory.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacy = legacyDir.appendingPathComponent("browserLanesBySession.json")
        let legacyData = try JSONEncoder().encode(["browserLanesBySession": ["legacy": snapshot]])
        try legacyData.write(to: legacy)
        let migratedFile = legacyDir.appendingPathComponent("tabs.json")
        let migrated = BrowserTabRegistry(storageURL: migratedFile)
        precondition(migrated.persistenceError == nil)
        precondition(migrated.laneSnapshot(for: "legacy") == snapshot)
        precondition(migrated.tabs(ownedBy: .chatSession(sessionID: "legacy")).count == 2)
        precondition(!FileManager.default.fileExists(atPath: legacy.path))
        precondition((try? Data(contentsOf: legacy.appendingPathExtension("migrated"))) == legacyData)
        let migratedAgain = BrowserTabRegistry(storageURL: migratedFile)
        precondition(migratedAgain.tabs == migrated.tabs && migratedAgain.laneSnapshot(for: "legacy") == snapshot)
        let adapter = ChatPageModel(migratedAgain)
        precondition(adapter.browserLanesBySession["legacy"] == snapshot)
        adapter.storeBrowserLanes(state, laneURLs: [lanes[1].id: snapshot.openURLs[0]], for: "legacy")
        precondition(migratedAgain.tabs == migrated.tabs)
        adapter.closeBrowserLanes(for: "legacy")
        precondition(adapter.browserLanes(for: "legacy") == nil)

        // Identical legacy raw lane IDs in different sessions must not collide after a move.
        let collisions = BrowserTabRegistry(storageURL: directory.appendingPathComponent("collisions/tabs.json"))
        collisions.storeLanes(snapshot, for: "source")
        collisions.storeLanes(snapshot, for: "destination")
        let movedID = collisions.tabs(ownedBy: .chatSession(sessionID: "source"))[0].id
        collisions.move(movedID, to: .chatSession(sessionID: "destination"))
        let destinationSnapshot = collisions.laneSnapshot(for: "destination")!
        precondition(destinationSnapshot.laneState.lanes.count == 3)
        precondition(Set(destinationSnapshot.laneState.lanes.map(\.id)).count == 3)
        // W46-fix: a stale panel snapshot (taken before the move) must not delete the tab that was just moved in.
        let staleDestination = BrowserLaneSnapshot(laneState: snapshot.laneState, laneURLs: snapshot.laneURLs, updatedAt: Date())
        collisions.storeLanes(staleDestination, for: "destination")
        precondition(collisions.tabs.contains { $0.id == movedID && $0.owner == .chatSession(sessionID: "destination") },
                     "incoming tab must survive a stale snapshot store")
        precondition(collisions.tabs(ownedBy: .chatSession(sessionID: "destination")).count == 3)
        collisions.storeLanes(destinationSnapshot, for: "destination")
        precondition(collisions.tabs.contains { $0.id == movedID && $0.owner == .chatSession(sessionID: "destination") })
        // Once the panel has reported a tab, dropping it from the next snapshot closes it as before.
        let reportedOther = destinationSnapshot.laneState.lanes.first { $0.id.rawValue != movedID.uuidString }!
        let otherTabID = collisions.tabs(ownedBy: .chatSession(sessionID: "destination")).first {
            collisions.laneSnapshot(for: "destination")!.laneState.lanes.contains { lane in lane.id == reportedOther.id }
                && $0.title == reportedOther.title && $0.id != movedID
        }!.id
        let withoutOther = BrowserLaneSnapshot(laneState: TatwoBrowserLaneState(schemaVersion: destinationSnapshot.laneState.schemaVersion,
            maximumLaneCount: destinationSnapshot.laneState.maximumLaneCount,
            lanes: destinationSnapshot.laneState.lanes.filter { $0.id != reportedOther.id },
            selectedLaneID: nil), laneURLs: destinationSnapshot.laneURLs, updatedAt: Date())
        collisions.storeLanes(withoutOther, for: "destination")
        precondition(!collisions.tabs.contains { $0.id == otherTabID }, "a reported tab dropped from the snapshot closes")
        precondition(collisions.tabs.contains { $0.id == movedID && $0.owner == .chatSession(sessionID: "destination") })
        collisions.storeLanes(snapshot, for: "source")
        precondition(collisions.tabs(ownedBy: .chatSession(sessionID: "source")).count == 1)
        try collisions.flush()
        let persistedMove = BrowserTabRegistry(storageURL: directory.appendingPathComponent("collisions/tabs.json"))
        persistedMove.storeLanes(snapshot, for: "source")
        precondition(persistedMove.tabs(ownedBy: .chatSession(sessionID: "source")).count == 1)
        let lastSource = persistedMove.tabs(ownedBy: .chatSession(sessionID: "source"))[0]
        persistedMove.close(lastSource.id)
        precondition(persistedMove.laneSnapshot(for: "source") == nil)
        persistedMove.move(movedID, to: .chatSession(sessionID: "source"))
        persistedMove.storeLanes(persistedMove.laneSnapshot(for: "source")!, for: "source")
        precondition(persistedMove.tabs(ownedBy: .chatSession(sessionID: "source")).map(\.id) == [movedID])
        // A native UUID lane may return to its original owner; its old tombstone cannot drop it.
        let native = collisions.openTab(owner: .chatSession(sessionID: "native"), title: "Native")
        collisions.move(native.id, to: .workSpace(spaceID: collisions.spaces[0].id))
        collisions.move(native.id, to: .chatSession(sessionID: "native"))
        var nativeSnapshot = collisions.laneSnapshot(for: "native")!
        nativeSnapshot.laneURLs[native.id.uuidString] = URL(string: "https://example.com/returned")!
        collisions.storeLanes(nativeSnapshot, for: "native")
        precondition(collisions.tabs(ownedBy: .chatSession(sessionID: "native")).map(\.id) == [native.id])
        // Workspace -> chat must retain the registry UUID when the panel stores its projection.
        let workspaceTab = collisions.openTab(owner: .workSpace(spaceID: collisions.spaces[0].id), title: "From workspace")
        collisions.move(workspaceTab.id, to: .chatSession(sessionID: "new-chat"))
        var workspaceSnapshot = collisions.laneSnapshot(for: "new-chat")!
        workspaceSnapshot.laneURLs[workspaceSnapshot.laneState.lanes[0].id.rawValue] = URL(string: "https://example.com/new")!
        collisions.storeLanes(workspaceSnapshot, for: "new-chat")
        precondition(collisions.tabs(ownedBy: .chatSession(sessionID: "new-chat"))[0].id == workspaceTab.id)
        // An intentionally empty registry stays empty across launches, except the permanent Session space.
        let emptyFile = directory.appendingPathComponent("empty/tabs.json")
        let empty = BrowserTabRegistry(storageURL: emptyFile)
        empty.removeSpace(empty.spaces.first { !$0.isSessionSpace }!.id, closingTabs: true)
        try empty.flush()
        precondition(BrowserTabRegistry(storageURL: emptyFile).spaces.allSatisfy(\.isSessionSpace))

        // Bare dictionary export and failed migration retain the original bytes.
        let bare = directory.appendingPathComponent("bare.json")
        try JSONEncoder().encode(["bare": snapshot]).write(to: bare)
        let bareRegistry = BrowserTabRegistry(storageURL: directory.appendingPathComponent("bare-tabs.json"), legacyURL: bare)
        precondition(bareRegistry.laneSnapshot(for: "bare") == snapshot)
        let bad = directory.appendingPathComponent("bad.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: bad)
        let failed = BrowserTabRegistry(storageURL: directory.appendingPathComponent("failed-tabs.json"), legacyURL: bad)
        precondition(failed.persistenceError != nil)
        precondition((try? Data(contentsOf: bad)) == corrupt)
        precondition(!FileManager.default.fileExists(atPath: bad.appendingPathExtension("migrated").path))
        let badStore = BrowserTabRegistry(storageURL: bad)
        badStore.openTab(owner: .bot(botID: "no-overwrite"))
        do { try badStore.flush(); preconditionFailure("corrupt store overwritten") } catch {}
        precondition((try? Data(contentsOf: bad)) == corrupt)

        // Existing destination state and existing backup are both fail-closed migration gates.
        let conflictFile = directory.appendingPathComponent("conflict.json")
        try JSONEncoder().encode(["source": snapshot]).write(to: conflictFile)
        let conflictBytes = try Data(contentsOf: conflictFile)
        do { try persistedMove.migrateLegacy(at: conflictFile); preconditionFailure("migration conflict overwritten") } catch {}
        precondition((try? Data(contentsOf: conflictFile)) == conflictBytes)
        let blockedSource = directory.appendingPathComponent("blocked.json")
        try legacyData.write(to: blockedSource)
        try corrupt.write(to: blockedSource.appendingPathExtension("migrated"))
        do { try empty.migrateLegacy(at: blockedSource); preconditionFailure("backup overwritten") } catch {}
        precondition((try? Data(contentsOf: blockedSource)) == legacyData)
        precondition((try? Data(contentsOf: blockedSource.appendingPathExtension("migrated"))) == corrupt)

        let retiredFile = directory.appendingPathComponent("retired.json")
        try JSONEncoder().encode(["retired": snapshot]).write(to: retiredFile)
        let retired = BrowserTabRegistry(storageURL: directory.appendingPathComponent("retired-tabs.json"))
        retired.storeLanes(snapshot, for: "retired")
        retired.closeAll(ownedBy: .chatSession(sessionID: "retired"))
        do { try retired.migrateLegacy(at: retiredFile); preconditionFailure("unimported legacy archived") } catch {}
        precondition(FileManager.default.fileExists(atPath: retiredFile.path))
        precondition(!FileManager.default.fileExists(atPath: retiredFile.appendingPathExtension("migrated").path))

        // Debounce writes only the final state after 500ms; termination is a durability barrier.
        let debounceFile = directory.appendingPathComponent("debounce/tabs.json")
        let debounced = BrowserTabRegistry(storageURL: debounceFile)
        let pending = debounced.openTab(owner: .bot(botID: "pending"))
        try await Task.sleep(for: .milliseconds(200))
        precondition(!FileManager.default.fileExists(atPath: debounceFile.path))
        debounced.update(pending.id, url: nil, title: "final", favicon: nil)
        try await Task.sleep(for: .milliseconds(350))
        precondition(!FileManager.default.fileExists(atPath: debounceFile.path))
        try await Task.sleep(for: .milliseconds(350))
        precondition(BrowserTabRegistry(storageURL: debounceFile).tabs == debounced.tabs)
        debounced.update(pending.id, url: nil, title: "termination", favicon: nil)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        precondition(BrowserTabRegistry(storageURL: debounceFile).tabs == debounced.tabs)
        print("W46 registry fixture passed")
    }
}
