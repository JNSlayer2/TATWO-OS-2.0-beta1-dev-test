import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../App/Sources/Tatwo2/${path}`, import.meta.url), 'utf8');
const workspace = read('Browser/BrowserWorkSpaceDesignView.swift');
const host = read('Chat/ChatPage.swift');
const sidebar = read('Chat/ChatPage+Sidebar.swift');
const header = workspace.split('private var workspaceToolbar: some View {')[1].split('private var browserContent:')[0];

test('collapsed Browser unmounts the entire rail, not a narrow empty Browser column', () => {
  assert.match(host, /&& \(model.mode != \.browser \|\| !browserWorkSpaceStore.focusMode\)/);
  assert.doesNotMatch(host + sidebar, /browserFocusWidth/);
  assert.match(header, /BrowserSidebarControls\(store: store\)/);
  assert.match(header, /if store.focusMode \{\s*Color.clear.frame\(width: WindowChromeMetrics.trafficLightSafeWidth\)/);
  assert.match(header, /Menu\("工作區"\)/);
  assert.match(header, /name: \.tatwoChatSelectMode, object: mode.rawValue/);
});

test('toolbar consumes real layout height above native page, including empty/session spaces', () => {
  assert.match(workspace, /VStack\(spacing: BrowserOmniboxMetrics.zero\) \{\s*workspaceToolbar[\s\S]*?else if store.selectedSpace.isSessionSpace/);
  const content = workspace.split('private var browserContent: some View {')[1].split('private func performBrowserAction')[0];
  assert.doesNotMatch(content, /\.overlay\(alignment: \.top\)/);
  assert.match(header, /\.frame\(height: BrowserOmniboxMetrics.toolbarHeight\)/);
  assert.match(read('Chat/ChatPage+Panels.swift'), /BrowserWorkSpaceDesignView[\s\S]*?ignoresSafeArea\(\.container, edges: \.top\)/);
  assert.match(read('Shell/AppShell.swift'), /if chatModel.mode != \.browser \{\s*TatwoWindowPageRail/);
  assert.match(host, /if !isPanel && model.mode != \.browser/);
});

test('space title is text only, while native Menu remains accessible and functional', () => {
  const menu = sidebar.split('private var browserSpaceMenu: some View {')[1].split('var chatSidebar:')[0];
  assert.doesNotMatch(menu, /chevron|Capsule/);
  assert.match(menu, /\.menuIndicator\(\.hidden\)/);
  assert.match(menu, /Button\(space.name\)/);
  assert.match(menu, /accessibilityIdentifier\("browser.spaceSwitcher"\)/);
});

test('Dia address chrome is left aligned with separate navigation controls, not a centered pill', () => {
  const toolbar = read('Browser/EmbeddedBrowserToolbar.swift').split('struct EmbeddedBrowserToolbar: View')[1];
  const collapsed = toolbar.split('Button(action: expandEditor)')[1].split('.overlay(alignment: .top)')[0];
  assert.match(collapsed, /alignment: \.leading/);
  assert.doesNotMatch(collapsed, /BrowserOmniboxGlass|lock.fill|globe/);
  assert.match(toolbar, /control\("chevron.left"/);
  assert.match(toolbar, /control\("chevron.right"/);
});

test('fake installed-extension icons are absent; blocked execution is explicit', () => {
  assert.doesNotMatch(workspace, /ForEach\(\["文A", "S"\]|private var extensionStrip/);
  assert.match(read('Browser/BrowserExtensionsView.swift'), /尚不能安裝或執行/);
});

test('bottom space switcher cannot stretch vertically and float above the footer', () => {
  const controls = workspace.split('private var spaceControls: some View {')[1].split('private var downloadsPopover:')[0];
  assert.match(controls, /Color.clear.frame\(width: BrowserSidebarMetrics.footerControlSize, height: WorkspaceSpaceControlMetrics.cellHeight\)/);
  assert.match(controls, /\}\s*\.frame\(height: WorkspaceSpaceControlMetrics.cellHeight\)\s*\.buttonStyle/);
});

test('focus and find lifecycle cover the persistent toolbar, not only the detachable page', () => {
  const root = workspace.split('var body: some View {')[1].split('private var sessionContent:')[0];
  assert.match(root, /BrowserDailyFocusScope\(focused: \$browserFocused, acceptsWindowResponder: true\)/);
  assert.match(root, /onChange\(of: store.selectedSpaceID\)[\s\S]*?findPresented = false/);
  assert.match(root, /onChange\(of: store.selectedID\)[\s\S]*?findPresented = false/);
});

test('new and restored blank tabs retain the original centered search page', () => {
  assert.match(workspace, /var showsStartPage: Bool \{ canAddTab && \(selectedRegistryID == nil \|\| selectedTab.url == "about:blank" \|\| selectedTab.url.isEmpty\) \}/);
  const content = workspace.split('private var browserContent: some View {')[1].split('private func performBrowserAction')[0];
  assert.match(content, /if store.showsStartPage \{ page \}/);
  assert.match(workspace, /query = store.showsStartPage \? "" : store.selectedTab.url/);
  assert.match(workspace, /if store.showsStartPage \{ store.navigateFromStartPage\(to: url\) \}/);
  assert.match(workspace, /accessibilityIdentifier\("browser.startSearch"\)/);
});

test('centered search focus does not open the separate address popup', () => {
  assert.doesNotMatch(workspace, /onChange\(of: focusedField\)[^\n]*addressExpansionRequested/);
  assert.doesNotMatch(workspace, /onChange\(of: addressFocused\)[^\n]*focusedField/);
  assert.match(header, /enabled: store.canAddTab/);
});

test('start page submission also navigates a previously cached blank CEF tab', () => {
  const submit = workspace.split('private func submitSearch()')[1].split('// MARK: - Tab search')[0];
  assert.match(submit, /if store.showsStartPage \{ store.navigateFromStartPage\(to: url\) \}\s*send\(\.load\(url\)\)/);
});

test('start page has only the central search; submitted pages expose the address bar', () => {
  const toolbar = read('Browser/EmbeddedBrowserToolbar.swift');
  assert.match(header, /showsAddress: !store.showsStartPage/);
  assert.match(toolbar, /if showsAddress \{\s*Button\(action: expandEditor\)/);
  assert.match(toolbar, /if showsAddress && isExpanded/);
  assert.match(toolbar, /guard enabled && showsAddress else/);
  assert.match(toolbar, /private func dismissEditor[^{]+\{\s*guard isExpanded else \{ return \}/);
  assert.match(toolbar, /"重新載入", enabled && showsAddress/);
  assert.match(toolbar, /onChange\(of: showsAddress\)[\s\S]*?isExpanded = false/);
  assert.match(workspace, /case \.focusAddressBar: store.searchFocusRequest \+= 1/);
  assert.match(workspace, /task\(id: store.searchFocusRequest\)[\s\S]*?if store.showsStartPage \{ focusedField = \.search \}\s*else \{ addressExpansionRequested = true \}/);
});

test('persistent toolbar follows the workspace theme instead of the native white control fill', () => {
  assert.match(header, /\.background\(palette.canvasBase\)/);
  assert.doesNotMatch(header, /controlBackgroundColor/);
});
