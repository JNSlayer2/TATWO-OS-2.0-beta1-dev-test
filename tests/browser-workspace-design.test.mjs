import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = file => readFileSync(join(root, file), 'utf8');
const design = read('App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift');
const registrySources = ['Browser/TatwoBrowserLaneCore.swift', 'Browser/BrowserTabRegistry.swift', 'Browser/BrowserDailyNavigationPolicy.swift'].map(p => join(root, 'App/Sources/Tatwo2', p));
const constants = read('App/Sources/Tatwo2/Chat/ChatPageConstants.swift');
const panels = read('App/Sources/Tatwo2/Chat/ChatPage+Panels.swift');
const controller = read('App/Sources/Tatwo2/Space/SpaceWorkspaceController.swift');
function section(source, start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `Missing fixture boundaries: ${start} / ${end}`);
  return source.slice(from, to);
}
const mode = section(constants, 'enum ChatRunMode:', 'enum ChatCollaborationLevel:');
const store = section(design, '@MainActor', '// MARK: - End local fixture model');

test('workspace design projects registry data; W47 transport is confined to its surface', () => {
  assert.doesNotMatch(store, /EmbeddedBrowser|CEF|URLSession|WKWebView/);
  assert.match(design, /BrowserWorkSpaceCEFSurface/);
  assert.deepEqual([...design.matchAll(/^import (.+)$/gm)].map(m => m[1]), ['SwiftUI', 'Combine']);
  assert.doesNotMatch(design, /FileManager|UserDefaults|AppStorage|SceneStorage|NSWorkspace|openURL|Process\(|Task\s*\{|Timer|Data\(contentsOf|write\s*\(/);
  assert.match(design, /TatwoActivePalette\.current/);
  assert.match(design, /LiquidGlassTokens\.radiusCard/);
  assert.doesNotMatch(design, /\.ultraThinMaterial/);
});

test('browser visibility is opt-in and the default controller fallback stays three modes', () => {
  assert.match(mode, /case chat, cli, bot, browser/);
  assert.match(mode, /case \.browser: "Browser"/);
  assert.match(mode, /case \.browser: "globe"/);
  assert.match(mode, /environment\["TATWO_BROWSER_WORKSPACE_PREVIEW"\] == "1"/);
  assert.match(mode, /modes\.filter \{ \$0 != \.browser \|\| enabled \}/);
  assert.match(mode, /previewFilteredModes\(\s*SpaceWorkspaceController\.shared\.visibleModes, enabled: browserPreviewEnabled\)/);
  // W33 replaced the literal fallback with allCases; browser must still be gated here.
  assert.match(controller, /\?\? ChatRunMode\.allCases/);
  assert.match(controller, /filter \{ \$0 != \.browser \|\| ProcessInfo[^}]*TATWO_BROWSER_WORKSPACE_PREVIEW[^}]*\}/);
});

test('mainPane gates design, fails closed on forced selection and excludes composer', () => {
  assert.match(panels, /else if model\.mode == \.browser \{\s*if ChatRunMode\.browserPreviewEnabled \{\s*BrowserWorkSpaceDesignView\(store: browserWorkSpaceStore\)\s*\.frame\(maxWidth: \.infinity, maxHeight: \.infinity\)/);
  assert.match(panels, /Color\.clear\s*\.onAppear \{ model\.mode = \.chat \}/);
  assert.match(panels, /if model\.mode != \.cli, model\.mode != \.bot, model\.mode != \.browser \{\s*composer/);
});

test('browser rejoins the shared chat sidebar shell and footer with no private shell', () => {
  const sidebar = read('App/Sources/Tatwo2/Chat/ChatPage+Sidebar.swift');
  const host = read('App/Sources/Tatwo2/Chat/ChatPage.swift');
  assert.match(sidebar, /case \.browser:\s*if ChatRunMode.browserPreviewEnabled \{ browserSidebar \}/);
  const browser = section(sidebar, 'var browserSidebar:', 'var chatSidebar:');
  for (const token of ['WorkspaceSidebarShell', 'workspaceModeSection', 'workspaceSidebarFooter', 'BrowserWorkSpaceSidebarList(store: browserWorkSpaceStore)']) assert.ok(browser.includes(token));
  assert.match(browser, /workspaceModeSection\s*\.padding\(\.top, WorkspaceSidebarMetrics.headerTopInset\)/);
  assert.match(browser, /overlay\(alignment: \.topLeading\)/);
  assert.match(browser, /frame\(height: WorkspaceSidebarMetrics.headerTopInset\)/);
  assert.match(browser, /frame\(maxHeight: \.infinity, alignment: \.topLeading\)/);
  assert.match(browser, /ForEach\(browserWorkSpaceStore.spaces\)/);
  assert.match(browser, /Button\("新增空間", action: browserWorkSpaceStore.addSpace\)/);
  assert.match(browser, /Button\("從其他瀏覽器導入…", action: browserWorkSpaceStore.requestImport\)/);
  assert.match(browser, /12\.5, weight: \.bold/);
  assert.doesNotMatch(design, /sidebarHeader|sidebarFooter|TatwoOSMark|WorkspaceSidebarShell|WorkspaceSidebarModePicker/);
  assert.match(host, /let workspaceOwnsSidebar = model\.mode == \.bot\n/);
  assert.match(host, /isChatProjectRailPinned \|\| model.mode == \.browser/);
  assert.match(host, /&& \(model.mode != \.browser \|\| ChatRunMode.browserPreviewEnabled\)/);
  assert.match(host, /@StateObject var browserWorkSpaceStore = BrowserWorkSpaceStore\(\)/);
  assert.match(browser, /contextMenu[\s\S]*?ForEach\(ChatRunMode.visibleChatTabs\)/);
  const controls = section(panels, "func rightPanelControlStrip", "if showsThreadControls");
  assert.match(controls, /if model.mode != \.browser \{\s*Button/);
  assert.match(host, /browserWorkSpaceStore.focusMode \? WorkspaceSidebarMetrics.browserFocusWidth/);
});

test('v6 sidebar has five ordered sections, white selection and no chat or search pane', () => {
  assert.doesNotMatch(design, /chatPane|messages|sendDraft|assistant|referenceActions/);
  const sidebar = section(design, 'struct BrowserWorkSpaceSidebarList:', 'private var spaceControls:');
  const tokens = ['pinnedSection', 'folderSection', 'Divider()', 'newTabButton', 'store.activeTabs'];
  for (let i = 1; i < tokens.length; i++) assert.ok(sidebar.indexOf(tokens[i - 1]) < sidebar.indexOf(tokens[i]));
  assert.doesNotMatch(sidebar, /TextField|tabSearch|searchBox/);
  assert.match(design, /Text\("📌"\)/);
  assert.match(design, /Text\("釘選分頁"\)\.fontWeight\(\.bold\)/);
  assert.match(design, /tabRow\(tab\)\.padding\(\.leading, 16\)/);
  assert.doesNotMatch(store, /folderNames|Dia 對照稿|Sign in successful|Device Activation|platform\.claude\.com/);
  assert.match(store, /registry\.spaces\.map/);
  assert.match(design, /Image\(systemName: "folder.fill"\)\.foregroundStyle\(folderFill\)/);
  assert.match(design, /Text\(folder.name\)\.fontWeight\(\.bold\)\s*chevron/);
  assert.match(design, /background\(selected \? fieldFill : \.clear, in: RoundedRectangle\(cornerRadius: 9\)\)/);
  assert.match(design, /shadowColor.opacity\(selected \? 0.14 : 0\)/);
  assert.match(design, /store\.select\(tab.id\)/);
  assert.match(design, /store\.close\(tab.id\)/);
  assert.match(design, /\.onHover/);
  assert.match(design, /ForEach\(store.spaces\)/);
  assert.match(design, /Button \{ store.selectSpace\(space.id\) \}/);
  assert.match(design, /Image\(systemName: "arrow.down.circle"\)/);
  assert.match(design, /sheet\(isPresented: \$downloadsPresented\) \{ downloadsSheet \}/);
  assert.match(design, /Button\("在 Finder 顯示"\) \{ downloadStore.reveal\(download\) \}/);
  assert.match(design, /Button\("清除紀錄", action: downloadStore.clearDownloads\)/);
  assert.doesNotMatch(design, /sidebar.left/);
});

test('W38 split downloads and traffic-light aligned space menu', () => {
  const downloads = section(design, 'private var downloadsSheet:', '// MARK: - Sidebar sections:');
  assert.match(downloads, /Button\("完成"\) \{ downloadsPresented = false \}\s*\.keyboardShortcut\(\.cancelAction\)/);
  assert.match(downloads, /onExitCommand \{ downloadsPresented = false \}/);
  assert.doesNotMatch(design, /popover\(isPresented: \$downloadsPresented/);
  for (const token of ['TextField("搜尋下載", text: $downloadQuery)', 'line.3.horizontal.decrease', '["今天", "昨天", "Earlier"]', 'downloadArtwork', 'downloadPreview', '選一個檔案預覽', 'width: 660, height: 520', 'LiquidGlassPanelCard']) assert.ok(downloads.includes(token));
  const menu = section(downloads, '.contextMenu {', 'private var downloadPreview:');
  assert.match(menu, /Button\("在 Finder 顯示"/);
  assert.match(menu, /Button\("快速預覽"/);
  assert.match(downloads, /disabled\(!download.done\)/);
  assert.match(downloads, /disabled\(!download.state.isTerminal\)/);
  for (const action of ['cancel', 'retry', 'pause', 'resume']) assert.ok(downloads.includes(`downloadStore.${action}(download)`));
  assert.match(downloads, /selected \|\| hoveredDownloadID == download.id/);
  assert.match(downloads, /RoundedRectangle\(cornerRadius: 5\).fill\(download.isImage \? folderFill : \.white\)/);
  assert.doesNotMatch(design, /尚無分頁/);
  assert.match(design, /store.toggleFolder\(folder.id\)/);
  const browser = section(read('App/Sources/Tatwo2/Chat/ChatPage+Sidebar.swift'), 'var browserSidebar:', 'var chatSidebar:');
  assert.match(browser, /overlay\(alignment: \.topLeading\)/);
  assert.match(browser, /padding\(\.leading, 70\)/);
  assert.ok(browser.indexOf('Text(browserWorkSpaceStore.selectedSpace.name)') < browser.indexOf('Image(systemName: "chevron.down")'));
});

test('Search stays centered and unfinished extension controls are honestly labeled', () => {
  const page = section(design, 'private var page:', 'private var extensionStrip:');
  assert.match(page, /ZStack/);
  assert.match(page, /RadialGradient\(colors: \[palette.brandAccent.opacity/);
  assert.match(page, /searchBox\s*\.frame\(maxWidth: 560\)/);
  assert.match(page, /\.frame\(maxWidth: \.infinity, maxHeight: \.infinity\)/);
  assert.match(page, /overlay\(alignment: \.topTrailing\).*extensionStrip/);
  assert.match(design, /Label\("擴充功能尚未支援", systemImage: "puzzlepiece.extension"\)/);
  assert.doesNotMatch(design, /ForEach\(\["文A", "S"\]/);
  assert.match(design, /puzzlepiece.extension/);
  assert.match(design, /TextField\("Search", text: \$query\).font\(.system\(size: 14.5\)\)/);
  assert.match(design, /magnifyingglass"\).font\(.system\(size: 16\)/);
  assert.match(design, /padding\(.top, 13\).padding\(.horizontal, 14\).padding\(.bottom, 11\)/);
  assert.match(design, /RoundedRectangle\(cornerRadius: 15\)/);
  assert.match(design, /frame\(width: 30, height: 30\)/);
  assert.match(design, /roundButton\("加入分頁", "plus"\)/);
  assert.match(design, /roundButton\("搜尋", "arrow.up"/);
  assert.doesNotMatch(section(design, 'private var searchBox:', 'private var suggestionList:'), /microphone|mic\.fill|"mic"|logo|標誌|標語|連接卡|arrow.left|arrow.right|arrow.clockwise|⌘K|keyboardShortcut\("k"/i);
  // W57e removes implicit focus/search hotkeys; existing controls remain.
  assert.doesNotMatch(design, /keyboardShortcut\("s"/);
  assert.doesNotMatch(design, /keyboardShortcut\("a"/);
  const search = section(design, 'private var tabSearchOverlay:', 'private func selectSearchResult');
  assert.match(search, /searchResults/);
  assert.doesNotMatch(search, /suggestions|addTab/);
});

test('v6 import is a seven-source, five-choice local sheet with profile and Arc restrictions', () => {
  assert.match(design, /\.sheet\(isPresented: \$store.importPresented\)/);
  assert.match(design, /count: 3\), spacing: 8/);
  for (const source of ['Arc', 'Chrome', 'Brave', 'Edge', 'Opera', 'Vivaldi', 'Safari']) assert.ok(store.includes(`"${source}"`));
  for (const label of ['書籤（含資料夾結構）', '密碼', '瀏覽紀錄（最近 90 天）', '擴充功能', '釘選分頁']) assert.ok(store.includes(`"${label}"`));
  assert.match(design, /Safari・即將支援/);
  assert.match(design, /disabled\(source == .safari\)/);
  assert.match(design, /Arc 不提供/);
  assert.match(design, /toggleStyle\(.checkbox\).disabled\(!store.supports\(data\)\)/);
  assert.match(design, /Firefox 不支援/);
  // The separate publisher mockup is not shipped in release source archives.
  assert.match(store, /static let importExplanation =/);
  assert.match(design, /count: 2\),\s*alignment: \.leading, spacing: 6/);
  assert.match(design, /padding\(22\).frame\(width: 520\)/);
  assert.match(design, /Picker\("設定檔", selection: \$store.profile\)/);
  assert.match(design, /Button\("取消", action: store.cancelImport\)/);
  assert.match(design, /Button\("導入", action: store.finishImport\)/);
  assert.match(design, /設計稿：未接線/);
});

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root, encoding: 'utf8', timeout: 120_000, maxBuffer: 4 * 1024 * 1024, ...options,
  });
  assert.equal(result.status, 0, `${command}: ${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}
const modeStubs = `
enum TatwoChatCommandMode { case chat, cli }
@MainActor final class SpaceWorkspaceController {
    static let shared = SpaceWorkspaceController()
    var visibleModes: [ChatRunMode] = [.chat, .cli, .bot, .browser]
    func displayName(for id: String) -> String { id }
}
${mode}
`;

test('swiftc fixture projects isolated registry tabs and import state with network and file writes denied', {
  skip: process.platform !== 'darwin' ? 'Requires macOS SwiftUI toolchain' : false,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w36-browser-fixture-'));
  const source = join(dir, 'Fixture.swift');
  const binary = join(dir, 'fixture');
  writeFileSync(source, `import SwiftUI
import Combine
import Foundation
${modeStubs}
${store}
@main struct Fixture {
    @MainActor static func main() {
        let enabled = ProcessInfo.processInfo.environment["TATWO_BROWSER_WORKSPACE_PREVIEW"] == "1"
        precondition(ChatRunMode.browserPreviewEnabled == enabled)
        precondition(ChatRunMode.visibleChatTabs.contains(.browser) == enabled)
        precondition(ChatRunMode.previewFilteredModes([.chat, .cli, .bot, .browser], enabled: false) == [.chat, .cli, .bot])
        var emptyFolder = BrowserWorkSpaceStore.Folder()
        emptyFolder.toggle()
        precondition(!emptyFolder.expanded && emptyFolder.chevronExpanded)
        emptyFolder.toggle()
        precondition(!emptyFolder.expanded && !emptyFolder.chevronExpanded)
        var populatedFolder = BrowserWorkSpaceStore.Folder(bookmarks: [.init(id: UUID(), title: "Fixture", url: "about:blank")])
        populatedFolder.toggle()
        precondition(populatedFolder.expanded)
        populatedFolder.toggle()
        precondition(!populatedFolder.expanded)
        let registry = BrowserTabRegistry()
        let store = BrowserWorkSpaceStore(registry: registry)
        let secondWindow = BrowserWorkSpaceStore(registry: registry)
        precondition(store.tabs.isEmpty && store.folders.count == 1)
        precondition(!store.canReopenClosedTab)
        precondition(store.spaces.count == 2 && store.selectedSpace.name == "一般")
        let space = registry.spaces.first { !$0.isSessionSpace }!
        let tab = registry.openTab(owner: .workSpace(spaceID: space.id), url: URL(string: "https://example.com")!, title: "Fixture page")
        precondition(store.tabs.count == 1 && secondWindow.tabs == store.tabs)
        let tabID = store.tabs[0].id
        let folderID = store.folders[0].id
        let originalTabs = store.tabs
        precondition(store.saveBookmark(tabID: tabID, into: folderID))
        precondition(store.folders[0].bookmarks.count == 1)
        precondition(store.folders[0].bookmarks.last?.url == store.selectedTab.url)
        precondition(store.tabs == originalTabs)
        precondition(!store.saveBookmark(tabID: -1, into: folderID))
        precondition(!store.saveBookmark(tabID: tabID, into: UUID()))
        precondition(!store.saveDraggedTabs(["garbage", "tatwo-browser-tab:-1"], into: folderID))
        precondition(store.saveDraggedTabs(["tatwo-browser-tab:\\(tabID)"], into: folderID))
        precondition(store.tabs == originalTabs && store.folders[0].bookmarks.count == 2)
        store.toggleFolder(folderID)
        precondition(store.folders[0].expanded && store.folders[0].chevronExpanded)
        let emptyID = store.addFolder()
        store.toggleFolder(emptyID)
        precondition(!store.folders[1].expanded && store.folders[1].chevronExpanded)
        precondition(store.saveBookmark(tabID: tabID, into: emptyID))
        store.toggleFolder(emptyID)
        precondition(store.folders[1].expanded && store.folders[1].chevronExpanded)
        let newFolderID = store.addFolder()
        store.renameFolder(newFolderID, to: "  同名也保留獨立識別  ")
        precondition(store.folders.last?.name == "同名也保留獨立識別")
        store.renameFolder(newFolderID, to: " ")
        precondition(store.folders.last?.name == "同名也保留獨立識別")
        store.bookmarkCurrentTab()
        precondition(store.folders[0].bookmarks.count == 2 && store.folders[1].bookmarks.count == 2) // current folder, not always first
        let firstSpace = store.selectedSpaceID
        store.addSpace()
        precondition(store.spacePageCount == 3 && store.tabs.isEmpty && store.folders.isEmpty)
        store.selectSpace(-1)
        precondition(store.selectedSpaceID != -1)
        store.selectSpace(firstSpace)
        precondition(store.tabs == originalTabs && store.folders.count == 3)
        precondition(!store.focusMode)
        store.focusMode.toggle()
        precondition(store.focusMode)
        precondition(store.downloads.count == 2)
        store.clearDownloads()
        precondition(store.downloads.isEmpty)
        registry.setPinned(tab.id, true)
        precondition(store.activeTabs.isEmpty && store.pinnedTabs.count == 1)
        precondition(secondWindow.pinnedTabs.count == 1)
        store.select(tabID)
        store.select(-1)
        precondition(store.selectedID == tabID)
        precondition(store.suggestions(for: " ").isEmpty)
        precondition(store.suggestions(for: "Fixture").map(\\.section) == ["已開分頁", "搜尋"])
        precondition(store.searchTabs("xyz-no-match").isEmpty)
        precondition(store.searchTabs("Fixture").first?.pinned == true)
        store.addTab()
        let added = store.selectedID
        precondition(store.selectedTab.title == "新分頁")
        precondition(!store.saveBookmark(tabID: added, into: folderID))
        store.close(added)
        precondition(store.selectedID != added)
        store.focusMode = true
        for id in store.tabs.map(\\.id) { store.close(id) }
        precondition(store.tabs.isEmpty && store.selectedTab.id == -1 && !store.focusMode)
        precondition(store.canReopenClosedTab)
        store.reopenClosedTab()
        precondition(store.tabs.count == 1 && store.selectedTab.title == "Fixture page")
        precondition(store.selectedTab.url == "https://example.com" && store.selectedRegistryID != nil)
        store.close(store.selectedID)
        precondition(store.tabs.isEmpty)
        store.close(-1)
        let chatTab = registry.openTab(owner: .chatSession(sessionID: "fixture-session"), url: URL(string: "https://example.org")!, title: "Chat page")
        store.selectSpace(store.spaces.first { $0.isSessionSpace }!.id)
        precondition(!store.canAddTab && store.tabs.count == 1)
        store.addTab()
        precondition(store.tabs.count == 1)
        registry.move(chatTab.id, to: .workSpace(spaceID: space.id))
        precondition(store.tabs.isEmpty && secondWindow.tabs.count == 1)
        precondition(BrowserWorkSpaceStore.ImportSource.allCases.count == 7)
        precondition(BrowserWorkSpaceStore.ImportData.allCases.count == 5)
        precondition(!store.importPresented && store.notice.isEmpty)
        store.openImport()
        precondition(store.importPresented)
        precondition(store.importSource == .arc)
        precondition(store.importData == [.bookmarks, .passwords, .history])
        precondition(!store.supports(.extensions) && !store.supports(.pinned))
        store.setImportData(.extensions, selected: true)
        precondition(!store.importData.contains(.extensions))
        for source in BrowserWorkSpaceStore.ImportSource.allCases where source != .arc && source != .safari {
            store.selectSource(source)
            precondition(BrowserWorkSpaceStore.ImportData.allCases.allSatisfy { store.supports($0) })
        }
        store.selectSource(.chrome)
        store.setImportData(.extensions, selected: true)
        store.setImportData(.pinned, selected: true)
        precondition(store.importData.count == 5)
        store.selectSource(.safari)
        precondition(store.importSource == .chrome)
        store.selectSource(.arc)
        precondition(store.importData.count == 3)
        store.setImportData(.passwords, selected: false)
        precondition(!store.importData.contains(.passwords))
        store.profile = "工作"
        store.cancelImport()
        precondition(!store.importPresented && store.notice.isEmpty)
        store.openImport()
        let tabs = store.tabs
        store.finishImport()
        precondition(!store.importPresented && store.notice == "設計稿：未接線")
        precondition(store.tabs == tabs)
        print("offline fixture passed; preview=\\(enabled)")
    }
}
`);
  run('swiftc', ['-parse-as-library', '-num-threads', '2', ...registrySources, source, '-o', binary]);
  const profile = '(version 1)(allow default)(deny network*)(deny file-write*)';
  for (const value of [undefined, '0', '1', 'true']) {
    const env = { ...process.env };
    if (value === undefined) delete env.TATWO_BROWSER_WORKSPACE_PREVIEW;
    else env.TATWO_BROWSER_WORKSPACE_PREVIEW = value;
    assert.match(run('/usr/bin/sandbox-exec', ['-p', profile, binary], { env }), /offline fixture passed/);
  }
});

test('swiftc typechecks complete design and real wrapping picker against isolated signatures', {
  skip: process.platform !== 'darwin' ? 'Requires macOS SwiftUI toolchain' : false,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w36-browser-view-'));
  // Signature doubles: not an app build, render, or visual approval.
  const sidebar = read('App/Sources/Tatwo2/Chat/ChatPage+Sidebar.swift');
  const browserSidebar = section(sidebar, '    var browserSidebar:', '    var chatSidebar:');
  const modeSection = section(sidebar, '    var workspaceModeSection:', '    var cliSidebar:');
  const stubs = join(dir, 'VisualSignatures.swift');
  writeFileSync(stubs, `import SwiftUI
@MainActor enum BrowserWebFeatures { static func focusOwner(for view: NSView) -> NSView { view } }
struct BrowserDiagnosticsView: View { var body: some View { EmptyView() } }
@MainActor enum BrowserHumanInteraction {
    static func title(_ value: String) -> String { value }
    static func oneLine(_ value: String) -> String { value }
}
@MainActor final class IslandNotice {
    static let shared = IslandNotice()
    func info(title: String, detail: String, duration: TimeInterval = 6) {}
}
struct EmbeddedBrowserCommand {
    enum Action { case load(URL), reload, goBack, goForward, stopLoading, printPage, printPDF, openPDF, resetDownloadPermission, find(String, forward: Bool, matchCase: Bool), stopFinding, zoom(Double) }
    let action: Action
}
struct EmbeddedBrowserNavigationState {
    static let blank = Self()
    var urlString: String? = nil
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var isPDF = false
    var navigationGeneration: UInt64 = 0
    var showsNavigationProgress: Bool { isLoading }
}
@MainActor final class BrowserWorkSpaceRuntime: ObservableObject {
    static let shared = BrowserWorkSpaceRuntime()
    var navigationTabID: UUID? = nil
    var navigationState = EmbeddedBrowserNavigationState.blank
    var shortcutSerial = 0
    var shortcutKind = ""
    var findCount = 0
    var findIndex = 0
}
struct NonWindowDraggingView: View { var body: some View { Color.clear } }
enum BrowserImportError: Error { case tooLarge, invalidData }
enum BrowserImportSnapshot { static let maximumJSONBytes = 16 * 1024 * 1024 }
enum ChromiumImporter { static func navigationURL(_ raw: String) -> URL? { URL(string: raw) } }
enum EmbeddedBrowserEngine { case chromiumCEF, webKitLegacy }
enum EmbeddedBrowserEnginePolicy { static let current = EmbeddedBrowserEngine.chromiumCEF }
struct BrowserEngineUnavailablePlaceholder: View { var body: some View { Color.clear } }
struct BrowserAnnotationSheet: View { let tab: BrowserTab; var body: some View { Color.clear } }
struct BrowserWorkSpaceCEFSurface: View {
    let tabID: UUID
    let spaceID: UUID
    let command: EmbeddedBrowserCommand?
    let onPopup: (UUID, URL) -> Void
    var body: some View { Color.clear }
}
${modeStubs}
@MainActor final class ChatPageModel: ObservableObject { @Published var mode: ChatRunMode = .browser }
struct LiquidGlassPanelCard<Content: View>: View {
    let content: Content
    init(cornerRadius: CGFloat, @ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content }
}
struct ChatPage: View {
    @StateObject var browserWorkSpaceStore = BrowserWorkSpaceStore()
    @StateObject var model = ChatPageModel()
    var workspaceSidebarFooter: some View { Text("Footer signature") }
    var body: some View { browserSidebar }
${browserSidebar}
${modeSection}
}
struct TatwoThemePalette {
    let brandAccent: Color = .primary
    let canvasBase: Color = .primary
    let surfaceFill: Color = .primary
    let surfaceBorder: Color = .primary
}
enum TatwoActivePalette { static var current: TatwoThemePalette { .init() } }
enum LiquidGlassTokens {
    static let radiusCard: CGFloat = 20
    static let radiusChip: CGFloat = 12
    static let shapeStyle = RoundedCornerStyle.continuous
}
enum ChatTypography {
    static func systemUI(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}
extension View {
    func chatGlassChip(isSelected: Bool = false) -> some View { self }
}
`);
  const toolbar = join(dir, 'Toolbar.swift');
  writeFileSync(toolbar, 'import SwiftUI\n' + read('App/Sources/Tatwo2/Browser/EmbeddedBrowserToolbar.swift').split('struct EmbeddedBrowserToolbar: View')[1].replace(/^/, 'struct EmbeddedBrowserToolbar: View'));
  run('swiftc', ['-typecheck', '-num-threads', '2', ...registrySources, stubs, toolbar,
    join(root, 'App/Sources/Tatwo2/Browser/BrowserNavigationProgress.swift'),
    join(root, 'App/Sources/Tatwo2/Browser/BrowserDailyNavigationControls.swift'),
    join(root, 'App/Sources/Tatwo2/Browser/Import/BrowserHistoryStore.swift'),
    join(root, 'App/Sources/Tatwo2/Visual/WorkspaceSidebarMetrics.swift'),
    join(root, 'App/Sources/Tatwo2/Shell/WorkspaceSidebarModePicker.swift'),
    join(root, 'App/Sources/Tatwo2/Shell/WorkspaceSidebarShell.swift'),
    join(root, 'App/Sources/Tatwo2/Browser/BrowserDownloadStore.swift'),
    join(root, 'App/Sources/Tatwo2/Browser/BrowserWorkSpacePolicies.swift'), join(root, 'App/Sources/Tatwo2/Browser/BrowserMemoryPolicy.swift'), join(root, 'App/Sources/Tatwo2/Browser/BrowserMemorySettings.swift'), join(root, 'App/Sources/Tatwo2/Browser/BrowserNativeMemoryBudget.swift'),
    join(root, 'App/Sources/Tatwo2/Browser/BrowserGeneralSettings.swift'),
    join(root, 'App/Sources/Tatwo2/Browser/BrowserShortcuts.swift'),
    join(root, 'App/Sources/Tatwo2/Browser/BrowserExternalLoginPolicy.swift'),
    join(root, 'App/Sources/Tatwo2/Browser/BrowserLoginHelpView.swift'),
    join(root, 'App/Sources/Tatwo2/Browser/BrowserTabRow.swift'),
    join(root, 'App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift')]);
});


test('W39 Browser-only shortcut, bookmark drops, blank-area menu and add-space control', () => {
  const page = section(design, 'private var page:', 'private var extensionStrip:');
  assert.match(design, /onAction: performBrowserAction/);
  assert.match(design, /case \.newTab: if store.canAddTab/);
  for (const name of ['ChatPage+Sidebar.swift', 'ChatPage.swift', 'ChatPage+Panels.swift', 'ChatPage+Composer.swift']) {
    assert.doesNotMatch(read(`App/Sources/Tatwo2/Chat/${name}`), /keyboardShortcut\(\s*"t"/);
  }
  const sidebar = section(design, 'struct BrowserWorkSpaceSidebarList:', 'private var spaceControls:');
  const menu = sidebar.slice(sidebar.indexOf('.contextMenu {'));
  for (const label of ['新增分頁', '新增書籤（目前分頁）', '新增 space', '新增資料夾']) assert.ok(menu.includes(`"${label}"`));
  assert.match(design, /onDrag \{ NSItemProvider\(object: "tatwo-browser-tab:/);
  assert.match(design, /dropDestination\(for: String.self\)/);
  assert.match(design, /store.saveDraggedTabs\(payloads, into: folder.id\)/);
  assert.match(design, /targetedFolderID == folder.id \? palette.surfaceBorder/);
  assert.match(design, /rotationEffect\(\.degrees\(expanded \? 90 : 0\)\)/);
  assert.match(design, /animation\(\.easeInOut/);
  assert.match(design, /ForEach\(folder.bookmarks\)/);
  assert.match(design, /TextField\("資料夾名稱"/);
  const controls = section(design, 'private var spaceControls:', 'private var downloadsSheet:');
  assert.match(controls, /Button\(action: store.addSpace\)/);
  assert.match(controls, /Image\(systemName: "plus"\).font\(\.system\(size: 12\)\).foregroundStyle\(\.secondary\)/);
  const browser = section(read('App/Sources/Tatwo2/Chat/ChatPage+Sidebar.swift'), 'var browserSidebar:', 'var chatSidebar:');
  assert.match(browser, /frame\(maxHeight: \.infinity, alignment: \.center\)/);
});

test('space name next to the traffic lights is 12.5pt bold, name before chevron', () => {
  const sidebar = readFileSync(new URL('../App/Sources/Tatwo2/Chat/ChatPage+Sidebar.swift', import.meta.url), 'utf8');
  const menu = sidebar.slice(sidebar.indexOf('browserWorkSpaceStore.selectedSpace.name'), sidebar.indexOf('browserWorkSpaceStore.selectedSpace.name') + 400);
  assert.match(menu, /\.font\(\.system\(size: 12\.5, weight: \.bold\)\)/, '空間名稱 12.5 粗體');
  assert.ok(menu.indexOf('selectedSpace.name') < menu.indexOf('chevron.down'), '名稱在 chevron 前');
});

test('W56-fix: space visibleTabs honours the shipped Info.plist browser flag, not only the env flag', () => {
  const state = readFileSync(join(root, 'App/Sources/Tatwo2/Space/SpaceSetupPreviewState.swift'), 'utf8');
  assert.match(state, /\$0 != \.browser \|\| ChatRunMode\.browserPreviewEnabled/);
  assert.doesNotMatch(state, /visibleTabs: \[Tab\] \{[^}]*TATWO_BROWSER_WORKSPACE_PREVIEW/);
});
