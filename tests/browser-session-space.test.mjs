import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const design = readFileSync(join(root, 'App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift'), 'utf8');
function section(start, end) {
  const a = design.indexOf(start), b = design.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a);
  return design.slice(a, b);
}

test('W40 session surface has folders, read-only lanes, hollow page dot and no creation/drop entry', () => {
  const sidebar = section('// MARK: - Session space', 'private var spaceControls:');
  const content = section('private var sessionContent:', 'private func favicon(');
  for (const source of [sidebar, content]) {
    assert.doesNotMatch(source, /openNewTab|addTab|newTabButton|⌘T|keyboardShortcut|dropDestination|onDrop|onDrag|CEF/);
    assert.doesNotMatch(source, /Button\("全部關閉"/);
  }
  for (const text of ['sessionFolders', 'chevron(expanded: folder.expanded)', '全部關閉並移除',
    '移入 browser space', '成為分頁（到目前 space）', '存成書籤到', 'Button("關閉")',
    'Divider()', 'Bot 開啟的瀏覽器', 'store.botTabs.isEmpty', '尚未有 bot 瀏覽器']) assert.ok(sidebar.includes(text), text);
  assert.match(content, /ForEach\(store.sessionLanes\)/);
  assert.match(content, /lane.url\?\.absoluteString/);
  assert.match(content, /lane.lastActiveAt/);
  assert.match(content, /Text\(lane.title\)/);
  assert.match(content, /縮圖佔位/);
  assert.match(design, /if store.selectedSpace.isSessionSpace \{ sessionContent \}\s*else \{ browserContent \}/);
  assert.match(design, /if store.selectedSpace.isSessionSpace \{\s*sessionSidebar\s*\} else \{/);
  assert.match(design, /if space.isSessionSpace \{\s*Circle\(\).strokeBorder\(store.selectedSpaceID == space.id \? folderFill : palette.surfaceBorder, lineWidth: WorkspaceSpaceControlMetrics.ringStroke\)/);
  assert.doesNotMatch(design, /Circle\(\).fill\(store.selectedSpaceID == space.id \? folderFill : .clear\)/);
  const shell = readFileSync(join(root, 'App/Sources/Tatwo2/Chat/ChatPage.swift'), 'utf8');
  assert.match(shell, /onDrop\(of: model.mode == .browser && browserWorkSpaceStore.selectedSpace.isSessionSpace\s*\? \[\] :/);
  assert.match(shell, /guard model.mode != .browser \|\| !browserWorkSpaceStore.selectedSpace.isSessionSpace else \{ return false \}/);
  assert.match(shell, /if dropIsTargeted && !\(model.mode == .browser && browserWorkSpaceStore.selectedSpace.isSessionSpace\)/);
  assert.match(design, /spaces = spaces.filter\(\\.isSessionSpace\) \+ spaces.filter/);
});

test('W40 in-memory production registry/projection: grouping, close, move, bookmark and guards', {
  timeout: 120000, skip: process.platform !== 'darwin',
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w40-session-'));
  const source = join(dir, 'Fixture.swift'), binary = join(dir, 'fixture');
  writeFileSync(source, `import Foundation
import Combine
${section('@MainActor', '// MARK: - End local fixture model')}
@main struct Fixture {
    @MainActor static func main() {
        let registry = BrowserTabRegistry(storageURL: nil, titleProvider: { id in
            ("Thread " + id, id.hasPrefix("project") ? "網站改版" : id == "named-general" ? "一般" : "")
        })
        let store = BrowserWorkSpaceStore(registry: registry)
        let observer = BrowserWorkSpaceStore(registry: registry)
        let normal = registry.spaces.first { !$0.isSessionSpace }!
        let sessionSpace = store.spaces.first!
        precondition(sessionSpace.isSessionSpace && !store.selectedSpace.isSessionSpace)
        precondition(store.sessionFolders.count == 1 && store.sessionFolders[0].name == "一般")
        precondition(store.sessionFolders[0].tabs.isEmpty && store.botTabs.isEmpty)
        let url = URL(string: "https://example.org/page")!
        let general = registry.openTab(owner: .chatSession(sessionID: "general"), url: url, title: "General")
        let project = registry.openTab(owner: .chatSession(sessionID: "project-a"), url: url, title: "Project")
        let sibling = registry.openTab(owner: .chatSession(sessionID: "project-b"), url: url, title: "Sibling")
        let secondLane = registry.openTab(owner: project.owner, url: url, title: "Second lane")
        precondition(store.sessionFolders.map(\\.name) == ["一般", "網站改版"])
        precondition(store.sessionFolders[1].sessions.count == 2 && store.sessionFolders[1].tabs.count == 3)
        store.selectSpace(sessionSpace.id)
        precondition(!store.canAddTab)
        let count = registry.tabs.count
        store.addTab()
        registry.renameSpace(BrowserTabRegistry.sessionSpaceID, to: "Changed")
        registry.removeSpace(BrowserTabRegistry.sessionSpaceID, closingTabs: true)
        registry.openTab(owner: .workSpace(spaceID: BrowserTabRegistry.sessionSpaceID), url: url)
        registry.move(general.id, to: .workSpace(spaceID: BrowserTabRegistry.sessionSpaceID))
        precondition(registry.tabs.count == count && store.selectedSpace.name == "Session space")
        precondition(registry.addFolder(spaceID: BrowserTabRegistry.sessionSpaceID) == nil)
        precondition(!store.saveDraggedTabs(["tatwo-browser-tab:0"], into: normal.folders[0].id))
        store.toggleSessionFolder("網站改版")
        registry.touch(project.id)
        precondition(!store.sessionFolders[1].expanded)
        store.selectSessionTab(project.id)
        precondition(store.selectedSession?.sessionID == "project-a")
        precondition(Set(store.sessionLanes.map(\\.id)) == Set([project.id, secondLane.id]))
        store.closeSessionTab(project.id)
        precondition(store.selectedSessionTabID == secondLane.id && store.sessionLanes.count == 1)
        store.closeSessionFolder("網站改版")
        precondition(store.sessionFolders.map(\\.name) == ["一般"])
        precondition(observer.sessionFolders.count == 1 && store.selectedSession == nil && store.sessionLanes.isEmpty)
        precondition(!registry.tabs.contains { [project.id, sibling.id, secondLane.id].contains($0.id) })
        store.moveSessionTab(general.id)
        precondition(registry.tabs(ownedBy: .workSpace(spaceID: normal.id)).count == 1)
        precondition(registry.tabs(ownedBy: general.owner).isEmpty)
        precondition(store.sessionFolders.count == 1 && store.sessionFolders[0].tabs.isEmpty)
        store.addSpace()
        let destination = store.sessionDestination!
        let folder = registry.addFolder(spaceID: destination.id, name: "參考")!
        store.selectSpace(sessionSpace.id)
        let bookmarkTab = registry.openTab(owner: .chatSession(sessionID: "project-c"), url: url, title: "Bookmark")
        store.bookmarkSessionTab(bookmarkTab.id, into: UUID())
        precondition(registry.tabs.contains { $0.id == bookmarkTab.id })
        store.bookmarkSessionTab(bookmarkTab.id, into: folder.id)
        precondition(!registry.tabs.contains { $0.id == bookmarkTab.id })
        precondition(registry.spaces.first { $0.id == destination.id }!.folders[0].bookmarks.count == 1)
        let moveTab = registry.openTab(owner: .chatSession(sessionID: "general"), url: url)
        store.moveSessionTab(moveTab.id)
        precondition(registry.tabs(ownedBy: .workSpace(spaceID: destination.id)).count == 1)
        let unnamed = registry.openTab(owner: .chatSession(sessionID: "general"), url: url)
        let named = registry.openTab(owner: .chatSession(sessionID: "named-general"), url: url)
        precondition(store.sessionFolders.count == 2 && store.sessionFolders.allSatisfy { $0.name == "一般" })
        store.closeSessionFolder(nil)
        precondition(store.sessionFolders.count == 1 && store.sessionFolders[0].id == "一般")
        precondition(!registry.tabs.contains { $0.id == unnamed.id })
        store.closeSessionTab(named.id)
        precondition(store.sessionFolders.count == 1 && store.sessionFolders[0].id == nil)
        let bot = registry.openTab(owner: .bot(botID: "fixture"), url: url)
        precondition(store.botTabs.map(\\.id) == [bot.id])
        store.closeSessionTab(bot.id)
        precondition(store.botTabs.count == 1)
        registry.close(bot.id)
        precondition(store.botTabs.isEmpty)
        let blank = registry.openTab(owner: .chatSession(sessionID: "project-blank"))
        precondition(store.sessionFolders.count == 1 && store.sessionFolders[0].name == "網站改版")
        store.selectSessionTab(blank.id)
        precondition(store.sessionLanes.map(\\.id) == [blank.id])
        store.bookmarkSessionTab(blank.id, into: folder.id)
        precondition(registry.tabs.contains { $0.id == blank.id })
        store.closeSessionFolder("網站改版")
        precondition(registry.tabs(ownedBy: blank.owner).isEmpty)
        registry.removeSpace(destination.id, closingTabs: true)
        precondition(store.sessionDestination?.id == normal.id)
        registry.removeSpace(normal.id, closingTabs: true)
        precondition(store.sessionDestination == nil && store.sessionBookmarkFolders.isEmpty)
        let stranded = registry.openTab(owner: .chatSession(sessionID: "general"), url: url)
        store.moveSessionTab(stranded.id)
        precondition(registry.tabs(ownedBy: stranded.owner).count == 1)
        store.addSpace()
        precondition(!store.selectedSpace.isSessionSpace && store.sessionDestination != nil)
        print("W40 session space fixture passed")
    }
}
`);
  const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    'App/Sources/Tatwo2/Browser/TatwoBrowserLaneCore.swift',
    'App/Sources/Tatwo2/Browser/BrowserTabRegistry.swift', 'App/Sources/Tatwo2/Browser/BrowserDailyNavigationPolicy.swift', source, '-o', binary],
    { cwd: root, encoding: 'utf8', timeout: 90000 });
  assert.equal(compile.status, 0, compile.stderr);
  const run = spawnSync('/usr/bin/sandbox-exec', ['-p', '(version 1)(allow default)(deny network*)(deny file-write*)', binary],
    { encoding: 'utf8', timeout: 15000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /W40 session space fixture passed/);
});

test('W40-fix: session space rows, dots and lane card use BrowserSidebarMetrics tokens (no bare sizes)', () => {
  const view = readFileSync(new URL('../App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift', import.meta.url), 'utf8');
  const start = view.indexOf('// MARK: - Session space');
  const end = view.indexOf('private func sessionTabRow');
  const sessionSidebar = view.slice(start, end);
  assert.ok(sessionSidebar.length > 200);
  assert.doesNotMatch(sessionSidebar, /font\(\.system\(size: \d/);
  assert.doesNotMatch(sessionSidebar, /\.padding\(\d/);
  assert.match(sessionSidebar, /BrowserSidebarMetrics\.rowFontSize/);
  assert.match(view, /BrowserSidebarMetrics\.childLeadingInset/);
  assert.match(view, /BrowserSidebarMetrics\.laneCardWidth/);
  assert.match(view, /WorkspaceSpaceControlMetrics\.ringStroke/);
  const metrics = readFileSync(new URL('../App/Sources/Tatwo2/Visual/WorkspaceSidebarMetrics.swift', import.meta.url), 'utf8');
  assert.match(metrics, /laneCardWidth: CGFloat = 520/);
  assert.match(metrics, /childLeadingInset: CGFloat = 30/);
});
