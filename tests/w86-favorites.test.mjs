import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = p => readFileSync(join(root, p), 'utf8');
const browser = 'App/Sources/Tatwo2/Browser/';

test('W86 strip geometry, placement, ID-only drops and W66 identity are explicit', () => {
  const strip = read(browser + 'BrowserFavoritesStrip.swift');
  const workspace = read(browser + 'BrowserWorkSpaceDesignView.swift');
  assert.match(strip, /iconSize: CGFloat = 28/);
  assert.match(strip, /ScrollView\(\.horizontal, showsIndicators: false\)/);
  assert.match(strip, /HStack\(spacing: BrowserSidebarMetrics.rowSpacing\)/);
  assert.match(strip, /\.help\(favorite.title\)/);
  assert.match(strip, /拖分頁到這裡珍藏/);
  assert.match(workspace, /BrowserFavoritesStrip\(store: store\)\s+pinnedSection/);
  for (const kind of ['tab', 'bookmark', 'favorite', 'registry-tab']) {
    assert.ok(strip.includes(`tatwo-browser-${kind}`));
  }
  assert.match(workspace, /BrowserFavoriteMenu[\s\S]*addFavorite\(tabID:/);
  assert.match(workspace, /BrowserFavoriteMenu[\s\S]*addFavorite\(bookmarkID:/);
  assert.match(read(browser + 'BrowserBookmarkRows.swift'), /store.closeBookmark\(bookmark.id\)/);
  assert.doesNotMatch(strip, /setPinned|removeBookmark|registry\.close\(|sidebarPinned\s*=/);
  const html = read('docs/goal-ui-2.0/mocks/w86-favorites.html');
  assert.match(html, /overflow-x: auto/);
  assert.doesNotMatch(html, /<script|https?:\/\//);
});

test('W86 registry durability and native drop/menu/click/scroll/theme candidates', {
  timeout: 180_000, skip: process.platform !== 'darwin',
}, () => {
  // Isolation intent: scratch on the external staging volume, outside any checkout (any room/lead dir qualifies).
  assert.match(process.env.TMPDIR ?? '', /\/staging\/tmp\/[^/]+\/?$/);
  const dir = mkdtempSync(join(tmpdir(), 'w86-native-'));
  const storeSource = read(browser + 'BrowserWorkSpaceDesignView.swift')
    .split('// MARK: - End local fixture model')[0];
  writeFileSync(join(dir, 'Store.swift'), storeSource);
  const tokens = read('App/Sources/Tatwo2/Visual/LiquidGlassTokens.swift')
    .split('// W54_V10_TOKENS_BEGIN')[1].split('// W54_V10_TOKENS_END')[0];
  writeFileSync(join(dir, 'Tokens.swift'), `import SwiftUI\nenum LiquidGlassTokens {\nstatic let shapeStyle = RoundedCornerStyle.continuous\n${tokens}\n}\n`);
  const source = String.raw`
import SwiftUI
import AppKit
import Combine

struct W86Page: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    let palette: TatwoThemePalette
    let menuTab: BrowserTab
    let menuBookmark: BrowserWorkSpaceStore.Bookmark
    let folderID: UUID
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrowserFavoritesStrip(store: store)
            Text("📌　釘選分頁").bold().padding(.horizontal, 8).frame(height: 32)
            BrowserTabRow(variant: .workspace, title: menuTab.title, tabID: menuTab.id.uuidString,
                selected: false, onSelect: {})
                .frame(height: 34)
                .contextMenu {
                    BrowserFavoriteMenu(registry: store.registry, url: menuTab.url) {
                        store.registry.addFavorite(tabID: menuTab.id)
                    }
                }
                .onDrag { NSItemProvider(object: "tatwo-browser-registry-tab:\(menuTab.id)" as NSString) }
            BrowserBookmarkRow(store: store, bookmark: menuBookmark, folderID: folderID)
                .frame(height: 34)
                .contextMenu {
                    BrowserFavoriteMenu(registry: store.registry, url: URL(string: menuBookmark.url)) {
                        store.registry.addFavorite(bookmarkID: menuBookmark.id)
                    }
                }
            Text("合成原生元件 fixture").font(.caption).padding(8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.canvasBase)
    }
}
final class W86Window: NSWindow { override var canBecomeKey: Bool { true } }
// Synthetic drag session, real AppKit destination / SwiftUI String transfer decoding.
// The user's global pasteboard and pointer are never touched.
@MainActor final class W86Drag: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 86 }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(_ payload: String, at point: NSPoint, window: NSWindow) {
        draggingLocation = point
        draggingDestinationWindow = window
        super.init()
        draggingPasteboard.setString(payload, forType: .string)
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop: ObjCBool = false
        for (index, item) in (draggingPasteboard.pasteboardItems ?? []).enumerated() {
            block(NSDraggingItem(pasteboardWriter: item), index, &stop)
            if stop.boolValue { break }
        }
    }
}
@main struct W86Checks {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); checks += 1; print("PASS " + label); fflush(stdout)
        }
        func url(_ value: String) -> URL { URL(string: value)! }
        let index = root.appendingPathComponent("registry/tabs.json")
        let registry = BrowserTabRegistry(storageURL: index)
        let store = BrowserWorkSpaceStore(registry: registry)
        let space = registry.spaces.first { !$0.isSessionSpace }!
        let owner = BrowserTabOwner.workSpace(spaceID: space.id)
        let folder = space.folders[0]
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.systemOrange.setFill(); NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill(); return true
        }
        let png = NSBitmapImageRep(data: icon.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let tab = registry.openTab(owner: owner, url: url("https://example.com/docs/#part"), title: "文件 & <合成>")
        registry.update(tab.id, url: tab.url, title: tab.title, favicon: png)
        registry.setPinned(tab.id, true)
        let first = registry.addFavorite(tabID: tab.id)!
        let duplicate = registry.addFavorite(url: url("https://example.com/docs"), title: "duplicate")
        check(first.id == duplicate.id && registry.favorites.count == 1, "fragment/trailing slash dedup")
        let query = registry.addFavorite(url: url("https://example.com/docs?q=1"), title: "query")
        check(registry.favorites.count == 2, "query remains significant")
        check(registry.favorites[0].faviconPNG == png, "favicon is a snapshot")
        registry.update(tab.id, url: tab.url, title: "changed tab", favicon: nil)
        check(registry.favorites[0].faviconPNG == png && registry.favorites[0].title == first.title, "navigation does not mutate snapshot")
        store.openFavorite(first.id)
        check(store.selectedRegistryID == tab.id && registry.tabs.count == 1, "favorite selects existing normalized URL")
        check(registry.tabs[0].isPinned, "pin unchanged")
        registry.close(tab.id)
        check(registry.favorites.count == 2, "close does not delete favorite")
        store.openFavorite(first.id)
        check(registry.tabs.count == 1 && registry.tabs[0].faviconPNG == png, "favorite opens new tab with snapshot")
        var opened = registry.tabs[0]
        let secondSpace = registry.addSpace(name: "Other fixture")
        store.openExternal(spaceID: secondSpace.id, url: url("https://example.org/other"))
        store.openFavorite(first.id)
        check(store.currentSpaceUUID == space.id && store.selectedRegistryID == opened.id, "switches across work spaces")
        let bookmark = registry.addBookmark(folderID: folder.id, url: url("https://example.org/bookmark"), title: "合成書籤")!
        let bound = registry.openBookmark(bookmark.id, folderID: folder.id, owner: owner)!
        registry.update(bound.id, url: url("https://example.org/navigated"), title: "navigated", favicon: png)
        check(BrowserFavoriteDrop.accept(["tatwo-browser-bookmark:\(bookmark.id)"], before: nil, registry: registry, tabID: { _ in nil }), "bookmark ID drop callback")
        let saved = registry.favorite(for: bookmark.url)!
        check(saved.faviconPNG == png && saved.url == bookmark.url, "bookmark persistent identity, not navigated URL")
        let alias = store.tabs.first { $0.registryID == opened.id }!.id
        check(BrowserFavoriteDrop.accept(["tatwo-browser-tab:\(alias)"], before: nil, registry: registry,
             tabID: { id in store.tabs.first { $0.id == id }?.registryID }), "workspace alias drop callback")
        check(BrowserFavoriteDrop.accept(["tatwo-browser-registry-tab:\(bound.id)"], before: nil, registry: registry, tabID: { _ in nil }), "registry UUID drop callback")
        check(!BrowserFavoriteDrop.accept(["https://example.net", "tatwo-browser-tab:9999", "tatwo-browser-bookmark:\(UUID())"],
              before: nil, registry: registry, tabID: { _ in nil }), "external text and stale IDs rejected")
        check(BrowserFavoriteDrop.accept(["tatwo-browser-favorite:\(saved.id)"], before: first.id, registry: registry, tabID: { _ in nil }), "reorder drop callback")
        check(registry.favorites.first?.id == saved.id, "reorder before target")
        registry.moveFavorite(saved.id, before: nil)
        check(registry.favorites.last?.id == saved.id, "reorder to tail")
        check(!registry.moveFavorite(saved.id, before: saved.id), "self reorder no-op")
        check(!registry.moveFavorite(saved.id, before: UUID()), "stale reorder target rejected")
        let count = registry.tabs.count
        registry.removeFavorite(saved.id)
        check(registry.tabs.count == count && registry.spaces[0].folders[0].bookmarks.contains { $0.id == bookmark.id }, "remove favorite preserves tabs/bookmark")
        check(registry.favorites.map(\.order) == Array(0..<registry.favorites.count), "contiguous order")
        try registry.flush()
        let reloaded = BrowserTabRegistry(storageURL: index)
        check(reloaded.favorites == registry.favorites, "tabs.json and favicon round trip")
        check(FileManager.default.fileExists(atPath: index.deletingLastPathComponent().appendingPathComponent("favicons/favorite-\(first.id).png").path), "icon uses existing favicons directory")
        let html = BrowserBookmarkExport.html(registry: registry)
        check(html.contains("文件 &amp; &lt;合成&gt;") && html.contains("<H3>珍藏網頁</H3>"), "Netscape favorites escaped and visible")
        let imported = BrowserTabRegistry()
        let importCount = try BrowserBookmarkExport.importFavorites(html: html, registry: imported)
        check(importCount == registry.favorites.count && imported.favorites == registry.favorites, "HTML export/import IDs/order/snapshot")
        let repeated = try BrowserBookmarkExport.importFavorites(html: html, registry: imported)
        check(repeated == 0, "HTML import dedup")
        let emptyHTML = BrowserBookmarkExport.html(registry: BrowserTabRegistry())
        let emptyCount = try BrowserBookmarkExport.importFavorites(html: emptyHTML, registry: imported)
        check(emptyCount == 0 && imported.favorites == registry.favorites, "empty export imports without clearing favorites")
        let collision = BrowserFavorite(id: first.id, url: url("https://example.net/collision"),
            title: "合成 ID collision", faviconPNG: png, order: -1)
        check(imported.importFavorites([collision, collision]) == 1, "import deduplicates incoming normalized URLs")
        check(imported.favorites.last?.id != first.id && Set(imported.favorites.map(\.id)).count == imported.favorites.count,
              "import remaps conflicting persistent IDs")
        imported.removeFavorite(imported.favorites.last!.id)
        do {
            _ = try BrowserBookmarkExport.importFavorites(html: "<html>not an archive</html>", registry: imported)
            preconditionFailure("invalid import must throw")
        } catch { check(imported.favorites == registry.favorites, "invalid import does not mutate") }
        var old = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [String: Any]
        old.removeValue(forKey: "favorites")
        let oldURL = root.appendingPathComponent("old.json")
        try JSONSerialization.data(withJSONObject: old).write(to: oldURL)
        let legacy = BrowserTabRegistry(storageURL: oldURL)
        check(legacy.favorites.isEmpty && legacy.persistenceError == nil, "pre-W86 document remains readable")
        var duplicateDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [String: Any]
        let stored = duplicateDocument["favorites"] as! [[String: Any]]
        var rejected = stored[0], accepted = stored[0]
        var rejectedValue = rejected["favorite"] as! [String: Any]
        rejectedValue["url"] = "https://example.net/recovered"
        rejectedValue["order"] = 100
        rejected["favorite"] = rejectedValue
        rejectedValue["id"] = UUID().uuidString
        rejectedValue["order"] = 101
        accepted["favorite"] = rejectedValue
        duplicateDocument["favorites"] = stored + [rejected, accepted]
        let duplicateURL = root.appendingPathComponent("duplicates.json")
        try JSONSerialization.data(withJSONObject: duplicateDocument).write(to: duplicateURL)
        let recovered = BrowserTabRegistry(storageURL: duplicateURL)
        check(recovered.favorites.count == registry.favorites.count + 1 &&
              recovered.favorite(for: url("https://example.net/recovered")) != nil,
              "rejected duplicate ID does not reserve the next valid URL")
        check(recovered.favorites.map(\.order) == Array(0..<recovered.favorites.count), "load repairs sparse order")
        let broken = root.appendingPathComponent("broken.json")
        try Data("bad".utf8).write(to: broken)
        let corrupt = BrowserTabRegistry(storageURL: broken)
        _ = corrupt.addFavorite(url: url("https://example.net"), title: "safe")
        do { try corrupt.flush(); preconditionFailure("must reject corrupt index write") }
        catch { check(try! String(contentsOf: broken, encoding: .utf8) == "bad", "corrupt document preserved") }
        let session = registry.openTab(owner: .chatSession(sessionID: "synthetic-session"),
            url: url("https://example.net/session"), title: "session")
        let sessionFavorite = registry.addFavorite(tabID: session.id)!
        store.openFavorite(sessionFavorite.id)
        check(store.selectedSpace.isSessionSpace && store.selectedSessionTabID == session.id, "switches to open session tab")
        store.openFavorite(first.id)
        store.sidebarPinned = true
        store.focusMode = true
        check(!store.focusMode, "W66 pin keeps sidebar expanded")
        store.toggleSidebar()
        check(store.focusMode && !store.sidebarPinned, "W66 explicit collapse releases pin")
        for n in 0..<12 { registry.addFavorite(url: url("https://example.com/fixture/\(n)"), title: "合成站 \(n)") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func click(_ point: NSPoint, window: NSWindow) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                app.sendEvent(event)
            }
            settle()
        }
        func menu(_ point: NSPoint, host: NSView, window: NSWindow) -> NSMenu {
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
            var view = host.hitTest(host.convert(point, from: nil))
            while let current = view {
                if let menu = current.menu(for: event) {
                    menu.update()
                    return menu
                }
                view = current.superview
            }
            fatalError("No native context menu at \(point)")
        }
        func perform(_ title: String, in menu: NSMenu) {
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                fatalError("Native menu lacks \(title): \(menu.items.map(\.title))")
            }
            check(menu.items[index].isEnabled, "native menu enabled: \(title)")
            menu.performActionForItem(at: index)
            settle()
        }
        func drop(_ payload: String, at point: NSPoint, host: NSView, window: NSWindow) {
            let info = W86Drag(payload, at: point, window: window)
            defer { info.draggingPasteboard.releaseGlobally() }
            // SwiftUI installs transparent sibling destinations, not hit-test ancestors.
            let destinations = descendants(host).filter {
                !$0.registeredDraggedTypes.isEmpty && $0.bounds.contains($0.convert(point, from: nil))
            }.sorted { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
            for current in destinations {
                if !current.draggingEntered(info).isEmpty {
                    check(current.prepareForDragOperation(info), "native destination prepares String transfer")
                    check(current.performDragOperation(info), "native destination accepts String transfer")
                    current.concludeDragOperation(info)
                    current.draggingExited(info)
                    settle()
                    return
                }
            }
            fatalError("No native drop destination at \(point)")
        }
        let menuTab = registry.openTab(owner: owner, url: url("https://example.org/context-tab"), title: "合成分頁")
        let menuBookmark = BrowserWorkSpaceStore.Bookmark(id: bookmark.id, title: bookmark.title, url: bookmark.url.absoluteString)
        for theme in [TatwoTheme.fable5, TatwoTheme.aurora] {
            TatwoActivePalette.current = theme.palette
            let host = NSHostingView(rootView: W86Page(store: store, palette: theme.palette,
                menuTab: menuTab, menuBookmark: menuBookmark, folderID: folder.id).environment(\.colorScheme, .light))
            let window = W86Window(contentRect: NSRect(x: 100, y: 100, width: 240, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            settle(); host.layoutSubtreeIfNeeded()
            store.select(store.tabs.first { $0.registryID == menuTab.id }!.id)
            let beforeClick = registry.tabs.count
            click(NSPoint(x: 22, y: 278), window: window)
            check(store.selectedRegistryID == opened.id && registry.tabs.count == beforeClick, "\(theme.id.rawValue) native icon click reuses tab")
            registry.close(opened.id)
            settle()
            click(NSPoint(x: 22, y: 278), window: window)
            let reopened = registry.tabs.first { $0.id == store.selectedRegistryID }!
            check(reopened.id != opened.id && registry.tabs.count == beforeClick &&
                  reopened.url == first.url, "\(theme.id.rawValue) native icon click opens missing tab")
            opened = reopened
            for (point, sourceURL) in [(NSPoint(x: 65, y: 207), menuTab.url!), (NSPoint(x: 65, y: 173), bookmark.url)] {
                check(registry.favorite(for: sourceURL) == nil, "context fixture starts without favorite")
                perform("加入珍藏", in: menu(point, host: host, window: window))
                check(registry.favorite(for: sourceURL) != nil, "\(theme.id.rawValue) native row menu adds favorite")
                perform("移出珍藏", in: menu(point, host: host, window: window))
                check(registry.favorite(for: sourceURL) == nil && registry.tabs.count == beforeClick,
                      "\(theme.id.rawValue) native row menu removes only favorite")
            }
            for (payload, sourceURL) in [("tatwo-browser-registry-tab:\(menuTab.id)", menuTab.url!),
                                         ("tatwo-browser-bookmark:\(bookmark.id)", bookmark.url)] {
                drop(payload, at: NSPoint(x: 22, y: 278), host: host, window: window)
                check(registry.favorites.first?.url == sourceURL, "\(theme.id.rawValue) native drop inserts before icon")
                perform("移出珍藏", in: menu(NSPoint(x: 22, y: 278), host: host, window: window))
                check(registry.favorite(for: sourceURL) == nil && registry.tabs.count == beforeClick,
                      "\(theme.id.rawValue) native icon menu removes only favorite")
            }
            drop("tatwo-browser-favorite:\(query.id)", at: NSPoint(x: 22, y: 278), host: host, window: window)
            check(registry.favorites.first?.id == query.id, "\(theme.id.rawValue) native favorite drop reorders")
            perform("移到最後", in: menu(NSPoint(x: 22, y: 278), host: host, window: window))
            check(registry.favorites.last?.id == query.id, "\(theme.id.rawValue) native icon menu moves to tail")
            drop("tatwo-browser-favorite:\(query.id)", at: NSPoint(x: 59, y: 278), host: host, window: window)
            check(registry.favorites[1].id == query.id, "\(theme.id.rawValue) native drop restores second position")
            perform("移到最前", in: menu(NSPoint(x: 59, y: 278), host: host, window: window))
            check(registry.favorites.first?.id == query.id, "\(theme.id.rawValue) native icon menu moves to head")
            drop("tatwo-browser-favorite:\(first.id)", at: NSPoint(x: 22, y: 278), host: host, window: window)
            check(registry.favorites.first?.id == first.id, "\(theme.id.rawValue) native reorder restores head")
            check(registry.favorites.map(\.order) == Array(0..<registry.favorites.count), "native reorder keeps contiguous order")
            guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first else { fatalError("native scroll view missing") }
            check(!scroll.hasHorizontalScroller, "\(theme.id.rawValue) scrollbar hidden")
            check(scroll.documentView!.bounds.width > scroll.contentSize.width, "\(theme.id.rawValue) real horizontal overflow")
            check(scroll.frame.height <= 44.5, "\(theme.id.rawValue) fixed strip height")
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("\(theme.id.rawValue)-favorites.png"))
            let origin = scroll.contentView.bounds.origin.x
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -180, wheel3: 0)!
            scroll.scrollWheel(with: NSEvent(cgEvent: cg)!)
            settle()
            check(scroll.contentView.bounds.origin.x > origin, "\(theme.id.rawValue) native horizontal wheel scroll")
            window.close(); settle()
        }
        let emptyRegistry = BrowserTabRegistry()
        let emptyStore = BrowserWorkSpaceStore(registry: emptyRegistry)
        let emptySpace = emptyRegistry.spaces.first { !$0.isSessionSpace }!
        let emptyTab = emptyRegistry.openTab(owner: .workSpace(spaceID: emptySpace.id),
            url: url("https://example.org/empty-strip"), title: "空列拖入")
        let emptyHost = NSHostingView(rootView: BrowserFavoritesStrip(store: emptyStore))
        let emptyWindow = W86Window(contentRect: NSRect(x: 100, y: 100, width: 240, height: 44),
            styleMask: [.borderless], backing: .buffered, defer: false)
        emptyWindow.isReleasedWhenClosed = false
        emptyWindow.contentView = emptyHost
        emptyWindow.makeKeyAndOrderFront(nil); settle()
        drop("tatwo-browser-registry-tab:\(emptyTab.id)", at: NSPoint(x: 90, y: 22), host: emptyHost, window: emptyWindow)
        check(emptyRegistry.favorites.count == 1, "native empty strip accepts first favorite")
        perform("移出珍藏", in: menu(NSPoint(x: 22, y: 22), host: emptyHost, window: emptyWindow))
        check(emptyRegistry.favorites.isEmpty && emptyRegistry.tabs.count == 1, "native last removal returns to empty without closing tab")
        emptyWindow.close(); settle()
        print("W86 RESULT checks=\(checks) failures=0")
        print("W86 native pointer drag still requires interactive App acceptance")
    }
}
`;
  writeFileSync(join(dir, 'Checks.swift'), source);
  const sources = [
    browser + 'TatwoBrowserLaneCore.swift', browser + 'BrowserTabRegistry.swift',
    browser + 'BrowserDailyNavigationPolicy.swift', browser + 'BrowserBookmarkExport.swift',
    browser + 'BrowserFavoritesStrip.swift', 'App/Sources/Tatwo2/Visual/WorkspaceSidebarMetrics.swift',
    browser + 'BrowserTabRow.swift', browser + 'BrowserBookmarkRows.swift',
    'App/Sources/Tatwo2/Visual/TatwoTheme.swift',
  ];
  const bin = join(dir, 'checks');
  const build = spawnSync('xcrun', ['swiftc', '-swift-version', '6', '-parse-as-library', '-j', '2',
    ...sources, join(dir, 'Store.swift'), join(dir, 'Tokens.swift'), join(dir, 'Checks.swift'), '-o', bin],
  { cwd: root, encoding: 'utf8', timeout: 120_000 });
  writeFileSync(join(dir, 'compile.log'), build.stdout + build.stderr);
  assert.equal(build.status, 0, build.stdout + build.stderr);
  const run = spawnSync(bin, [dir], { cwd: root, encoding: 'utf8', timeout: 45_000,
    env: { ...process.env, TATWO2_LIVE_ROOT: join(dir, 'live') } });
  writeFileSync(join(dir, 'native.log'), run.stdout + run.stderr);
  console.log(`W86 evidence: ${dir}\n${run.stdout}`);
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /W86 RESULT checks=\d+ failures=0/);
  const sha = p => createHash('sha256').update(readFileSync(p)).digest('hex');
  writeFileSync(join(dir, 'receipt.json'), JSON.stringify({
    kind: 'native-component-candidates-not-full-App-approval',
    timestamp: new Date().toISOString(),
    commit: spawnSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).stdout.trim(),
    scope: 'Production registry, rows, menus and strip; synthetic AppKit drag session, native destinations and menu actions. Full App pointer gesture and golden promotion require lead acceptance.',
    sources: Object.fromEntries([...sources, browser + 'BrowserWorkSpaceDesignView.swift',
      'App/Sources/Tatwo2/Visual/LiquidGlassTokens.swift', 'docs/goal-ui-2.0/mocks/w86-favorites.html',
      'tests/w86-favorites.test.mjs'].map(p => [p, sha(join(root, p))])),
    generated: Object.fromEntries(['Store.swift', 'Tokens.swift', 'Checks.swift'].map(p => [p, sha(join(dir, p))])),
    screenshots: ['fable5', 'aurora'].map(t => ({ path: `${t}-favorites.png`, sha256: sha(join(dir, `${t}-favorites.png`)) })),
  }, null, 2));
});
