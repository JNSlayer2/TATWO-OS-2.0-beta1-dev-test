import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = path => readFileSync(join(root, path), 'utf8');
const app = 'App/Sources/Tatwo2/';
const design = read(app + 'Browser/BrowserWorkSpaceDesignView.swift');
const rows = read(app + 'Browser/BrowserBookmarkRows.swift');
const metrics = read(app + 'Visual/WorkspaceSidebarMetrics.swift');
const controls = read(app + 'Browser/BrowserSidebarControls.swift');
function section(source, start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, `${start} / ${end}`);
  return source.slice(a, b);
}

test('W66 bookmark rows project the bound tab and stay out of both ordinary tab lists', () => {
  assert.match(design, /var activeTabs: \[Tab\] \{ tabs.filter \{ !\$0.pinned && \$0.bookmarkID == nil \} \}/);
  assert.match(design, /var pinnedTabs: \[Tab\] \{ tabs.filter \{ \$0.pinned && \$0.bookmarkID == nil \} \}/);
  assert.match(rows, /store.tab\(forBookmark: bookmark.id\)/);
  for (const token of ['selected: selected', 'sleeping: tab?.sleeping', 'loading: tab?.loading']) assert.ok(rows.includes(token));
  assert.match(read(app + 'Browser/BrowserWorkSpaceCEFSurface.swift'), /registry.setLoading\(uuid, state.isLoading\)/);
  assert.match(read(app + 'Browser/BrowserTabRow.swift'), /if loading \{\s*ProgressView/);
});

test('W66 hover minus closes tabs only and remains keyboard/accessibility reachable', () => {
  for (const token of ['if tab != nil', 'store.folderHasOpenTabs(folder.id)', 'store.closeBookmark(bookmark.id)',
    'store.closeFolderTabs(folder.id)', 'Image(systemName: "minus")', 'in: Circle()', '.onHover',
    '.focused($focused)', '.accessibilityLabel(label).accessibilityIdentifier(identifier)',
    'browser.bookmark.close.', 'browser.folder.close.']) assert.ok(rows.includes(token), token);
  assert.doesNotMatch(rows, /deleteBookmark|removeBookmark|removeSpace/);
  assert.match(design, /contextMenu \{[\s\S]*Button\("刪除書籤"\) \{\s*store.deleteBookmark/);
});

test('W66 space capsule overlays the outer shell, not the padded mode section, with one height frame', () => {
  const sidebar = read(app + 'Chat/ChatPage+Sidebar.swift');
  const shell = section(sidebar, 'var browserSidebar:', 'var browserSpaceSwitcher:');
  const mode = section(shell, 'workspaceModeSection', 'BrowserWorkSpaceSidebarList');
  assert.doesNotMatch(mode, /overlay|browserSpaceSwitcher/);
  assert.match(shell, /frame\(maxHeight: \.infinity, alignment: \.topLeading\)\s*\}\s*\/\/[^\n]*\n\s*\/\/[^\n]*\n\s*\.overlay\(alignment: \.topLeading\)/);
  assert.match(shell, /padding\(\.leading, WindowChromeMetrics.appControlLeadingX\)/);
  assert.match(shell, /trafficLightTopInset\s*\+ WindowChromeMetrics.nativeTrafficLightDiameter \/ 2\s*- WorkspaceSidebarMetrics.spaceSwitcherHeight \/ 2/);
  // 原始 bug 是同一個 view 疊兩個打架的高度 frame。範圍收窄到膠囊本身，
  // 否則同列後來新增的獨立元件（側欄收合／固定鈕）會誤判。
  const menu = section(sidebar, 'private var browserSpaceMenu:', 'var chatSidebar:');
  assert.equal([...menu.matchAll(/\.frame\([^)]*(?:height|maxHeight|minHeight):/g)].length, 1);
  assert.doesNotMatch(menu, /maxHeight: \.infinity|padding\(\.top/);
  assert.match(menu, /Button\(space.name\) \{ browserWorkSpaceStore.selectSpace\(space.id\) \}/);
  assert.match(menu, /accessibilityIdentifier\("browser.spaceSwitcher"\)/);
  // Merely lifting the capsule is insufficient if the titlebar's AppKit drag NSView covers it.
  const rail = section(read(app + 'Shell/AppShell.swift'), 'struct TatwoWindowPageRail:', 'struct CompactPageTitle:');
  assert.match(rail, /frame\(width: showRightPanelToggle \? WindowChromeMetrics.trafficLightSafeWidth : WorkspaceSidebarMetrics.width\)\s*\.allowsHitTesting\(false\)/);
});

test('W66 live Bot and Browser share the approved dot-plus ratio and centered scroll group', () => {
  const browser = section(design, 'private var spaceControls:', 'private var downloadsPopover:');
  const bot = section(read(app + 'Bot/BotStudioPage.swift'), 'private var bottomBar:', '// MARK:');
  assert.match(read(app + 'Chat/ChatPage+Panels.swift'), /BotStudioRootView\(mode:/);
  for (const source of [browser, bot]) {
    for (const token of ['WorkspaceSpaceControls', 'WorkspaceSpaceControlMetrics.dotSize',
      'WorkspaceSpaceControlMetrics.cellWidth', 'WorkspaceSpaceControlMetrics.cellHeight',
      'WorkspaceSpaceControlMetrics.plusFontSize']) assert.ok(source.includes(token), token);
    assert.doesNotMatch(source, /Circle\(\)[\s\S]*?\.frame\(width: \d+, height: \d+\)/);
  }
  assert.match(metrics, /dotSize: CGFloat = 6/);
  assert.match(metrics, /visualGap: CGFloat = 8/);
  assert.match(metrics, /cellWidth: CGFloat = dotSize \+ visualGap/);
  assert.match(metrics, /plusFontSize: CGFloat = 9/);
  const shared = read(app + 'Shell/WorkspaceSpaceControls.swift');
  assert.match(shared, /HStack\(alignment: \.center, spacing: WorkspaceSpaceControlMetrics.itemSpacing\)/);
  assert.match(shared, /frame\(minWidth: geometry.size.width, alignment: \.center\)/);
  const session = section(browser, 'if space.isSessionSpace {', '} else {');
  assert.match(session, /strokeBorder/);
  assert.doesNotMatch(session, /Circle\(\).fill/);
});

test('W66 browser sidebar and canvas abut; work-space close and pin are labeled live actions', () => {
  const host = read(app + 'Chat/ChatPage.swift');
  assert.match(metrics, /browserContentGap: CGFloat = 0/);
  assert.match(host, /let sidebarContentGap = model.mode == .browser \? WorkspaceSidebarMetrics.browserContentGap : WorkspaceSidebarMetrics.contentGap/);
  assert.match(host, /sidebarWidth \+ sidebarContentGap/);
  assert.match(host, /HStack\(alignment: .top, spacing: showSidebar \? sidebarContentGap : 0\)/);
  assert.match(controls, /Button\(action: store.toggleSidebar\)/);
  assert.ok(controls.includes('.accessibilityIdentifier("browser.sidebarToggle")'));
  assert.equal([...controls.matchAll(/\.accessibilityLabel\(/g)].length, 1);
  assert.doesNotMatch(controls, /sidebarPin"|disabled|pin.fill/);
  assert.doesNotMatch(controls, /removeSpace|deleteBookmark|showDesignNotice|store.close|setPinned/);
  assert.doesNotMatch(design, /BrowserWorkspaceTabControls/);
});

test('W66 production registry/store: identity, close, folder scope, undo, reopen, persistence and pin', {
  skip: process.platform !== 'darwin', timeout: 150_000,
}, () => {
  const dir = testScratch('w66-sidebar-');
  const store = section(design, '@MainActor', '// MARK: - End local fixture model');
  const fixture = join(dir, 'Fixture.swift');
  writeFileSync(fixture, `import SwiftUI\nimport Combine\n${store}\n${read('tests/fixtures/browser-dia-sidebar-checks.swift')}`);
  const binary = join(dir, 'fixture');
  const compile = spawnSync('/bin/bash', ['-c', `
set -euo pipefail
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 60 --pid $$)
token=$(printf '%s\\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
swiftc -parse-as-library -swift-version 6 -num-threads 2 \\
  App/Sources/Tatwo2/Browser/TatwoBrowserLaneCore.swift \\
  App/Sources/Tatwo2/Browser/BrowserTabRegistry.swift \\
  App/Sources/Tatwo2/Browser/BrowserDailyNavigationPolicy.swift "$1" -o "$2"
`, 'w66-compile', fixture, binary], { cwd: root, encoding: 'utf8', timeout: 120_000 });
  assert.equal(compile.status, 0, compile.error?.message ?? compile.stderr);
  const run = spawnSync(binary, [dir], { cwd: root, encoding: 'utf8', timeout: 15_000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /W66 sidebar fixture PASS/);
});

// Latest user correction: combine pin and collapse into one Dia-style control.
test('one sidebar control lives before navigation; the space title has no second control', () => {
  const sidebar = read(app + 'Chat/ChatPage+Sidebar.swift');
  const row = section(sidebar, 'var browserSpaceSwitcher', 'private var browserSpaceMenu');
  assert.match(row, /browserSpaceMenu/);
  assert.doesNotMatch(row, /BrowserSidebarControls/);
  const toolbar = section(design, 'private var workspaceToolbar:', 'private var browserContent:');
  assert.ok(toolbar.indexOf('BrowserSidebarControls(store: store)') < toolbar.indexOf('EmbeddedBrowserToolbar('));
  assert.match(controls, /Button\(action: store.toggleSidebar\)/);
  assert.doesNotMatch(controls, /store\.close\(/);
});

test('explicit toggle unpins before collapsing; passive collapse still respects pinning', () => {
  assert.match(design, /let opening = focusMode\s*sidebarPinned = opening\s*focusMode = !opening/);
  assert.match(design, /sidebarPinned = false \{ didSet \{ if sidebarPinned \{ focusMode = false/);
  assert.match(design, /tabs\.isEmpty && !sidebarPinned \{ focusMode = false \}/);
});

test('single control shares navigation hit-size and icon tokens', () => {
  assert.match(controls, /BrowserOmniboxMetrics\.collapsedHeight/);
  assert.match(controls, /BrowserOmniboxMetrics\.iconSize/);
  assert.doesNotMatch(controls, /\.frame\(width: \d|size: \d/);
});

test('collapsed sidebar restore and menu use the same explicit toggle', () => {
  const toolbar = section(design, 'private var workspaceToolbar:', 'private var browserContent:');
  assert.match(toolbar, /BrowserSidebarControls\(store: store\)/);
  assert.match(toolbar, /Button\(store.focusMode \? "展開側欄" : "收合側欄", action: store.toggleSidebar\)/);
  assert.doesNotMatch(toolbar, /disabled\(store.sidebarPinned\)/);
});
