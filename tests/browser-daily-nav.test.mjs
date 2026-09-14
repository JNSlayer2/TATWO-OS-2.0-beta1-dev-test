import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync, readdirSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
const root = new URL('../', import.meta.url).pathname;
const b = 'App/Sources/Tatwo2/Browser/';
const read = p => readFileSync(join(root,p),'utf8');

test('W57a shortcuts are mounted in human Browser/chat-browser only and gated by local focus', () => {
  const controls = read(b+'BrowserDailyNavigationControls.swift');
  // W57e replaces W57a's built-in bindings with the user's map; only Cmd-T defaults.
  assert.match(controls, /map\.combos\(for: action\)/);
  assert.match(controls, /keyboardShortcut\(combo\.equivalent, modifiers: combo\.eventModifiers\)/);
  assert.match(controls, /\.disabled\(!focused\)/);
  assert.match(controls, /window\.isKeyWindow/);
  assert.match(controls, /bounds\.contains/);
  assert.doesNotMatch(controls, /addLocalMonitorForEvents|addGlobalMonitorForEvents/);
  const design = read(b+'BrowserWorkSpaceDesignView.swift');
  const body = design.slice(design.indexOf('private var browserContent:'),design.indexOf('private var extensionStrip:'));
  assert.match(body, /BrowserDailyNavigationControls\(focused: browserFocused/);
  assert.doesNotMatch(design.replace(body,''), /BrowserDailyNavigationControls\(/);
  const chat = read(b+'EmbeddedBrowserView.swift');
  assert.match(chat.slice(chat.indexOf('private struct ChatBrowserPanel:')), /BrowserDailyNavigationControls\(focused: browserFocused/);
  for (const folder of ['Chat','Shell']) {
    for (const path of readdirSync(join(root,'App/Sources/Tatwo2',folder),{recursive:true}).filter(p=>p.endsWith('.swift'))) {
      assert.doesNotMatch(read(`App/Sources/Tatwo2/${folder}/${path}`), /BrowserDailyNavigationControls\(/);
    }
  }
  assert.doesNotMatch(read(b+'BrowserTabRow.swift').split('struct BrowserBotTabRows')[1],/BrowserDailyNavigationControls|keyboardShortcut/);
});

test('W57a bridge: human-only menu/find/zoom, background popup and real callback dispatch', () => {
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const header = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoCEFBridge.h');
  for (const name of ['findText','setZoomLevel','OnBeforeContextMenu','OnContextMenuCommand','OnFindResult','OnPreKeyEvent','onDailyShortcut']) assert.ok(bridge.includes(name));
  assert.match(header,/onFindResult/); assert.match(header,/onContextMenuAction/);
  assert.match(bridge,/model->Clear\(\);\s*if \(!owner_ \|\| owner_\.browserActor == TatwoCEFBrowserActorAgent \|\| owner_\.agentControlled\) return;/);
  assert.match(bridge,/GetHost\(\)->Find\(ToCefString\(text\), forward, matchCase, next\)/);
  assert.match(bridge,/StopFinding\(true\)/);
  assert.match(bridge,/StartDownload\(ToCefString\(url\)\)/);
  const backend = read(b+'ChromiumCEFBackend.swift');
  assert.match(backend,/entry\.historyGeneration != generation/);
  assert.match(backend,/browser\.browserActor == \.human, !browser\.agentControlled/);
  assert.match(backend,/BrowserHistoryStore\.shared\.recordVisit/);
  assert.match(backend,/browser\.onFindResult/);
  const runtime = read(b+'BrowserWorkSpaceCEFSurface.swift');
  assert.match(runtime,/if let selected \{ self\.registry\.select\(selected\) \}/);
  const popup = read(b+'BrowserWorkSpaceDesignView.swift').split('func openPopup(')[1].split('func reopenClosedTab')[0];
  assert.doesNotMatch(popup,/selectedID =|selectSpace\(/);
});

test('W57a real Swift registry/history/zoom/policy fixtures', {skip:process.platform!=='darwin',timeout:120000}, () => {
  const dir = mkdtempSync(join(tmpdir(),'w57a-nav-'));
  const source = join(dir,'Checks.swift'), binary = join(dir,'checks');
  writeFileSync(source, String.raw`
import Foundation
// Only importer dependencies are doubled; history storage and registry are production code.
enum BrowserImportError: Error { case tooLarge, invalidData }
enum BrowserImportSnapshot { static let maximumJSONBytes = 16 * 1024 * 1024 }
enum ChromiumImporter {
    static func navigationURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme) else { return nil }
        return url
    }
}
@main struct Checks {
 @MainActor static func main() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let registry = BrowserTabRegistry(storageURL: nil)
    let space = registry.spaces.first { !$0.isSessionSpace }!
    let owner = BrowserTabOwner.workSpace(spaceID: space.id)
    let folder = space.folders[0].id
    let url = URL(string: "https://example.org/path")!
    let tab = registry.openTab(owner: owner, url: url, title: "Title", folderID: folder)
    registry.close(tab.id)
    precondition(registry.recentlyClosed.count == 1)
    let restored = registry.reopenClosedTab(owner: owner)!
    precondition(restored.id != tab.id && restored.url == url && restored.title == "Title")
    precondition(restored.owner == owner && restored.folderID == folder)
    precondition(registry.reopenClosedTab(owner: owner) == nil)
    for n in 0..<12 { registry.close(registry.openTab(owner: owner, title: String(n)).id) }
    precondition(registry.recentlyClosed.count == 10 && registry.recentlyClosed.first?.title == "2")
    let bot = registry.openTab(owner: .bot(botID: "fixture"), url: url)
    registry.close(bot.id)
    precondition(registry.recentlyClosed.count == 10)
    let chatOwner = BrowserTabOwner.chatSession(sessionID: "fixture")
    registry.close(registry.openTab(owner: chatOwner, url: url).id)
    precondition(registry.reopenClosedTab(owner: chatOwner)?.owner == chatOwner)
    for count in 0...12 {
        for number in 0...10 {
            let expected: Int? = count == 0 || !(1...9).contains(number) ? nil :
                (number == 9 ? count - 1 : (number <= count ? number - 1 : nil))
            precondition(BrowserDailyNavigation.tabIndex(number: number, count: count) == expected)
        }
    }
    let settingsURL = root.appendingPathComponent("settings.json")
    var settings = BrowserGeneralSettings()
    settings.zoomByHost["example.org"] = BrowserDailyNavigation.zoom(0, delta: 1)
    try settings.save(to: settingsURL)
    precondition(BrowserGeneralSettings.load(from: settingsURL).zoomByHost["example.org"] == 1)
    precondition(BrowserDailyNavigation.zoom(5, delta: 1) == 5)
    precondition(BrowserDailyNavigation.zoom(-5, delta: -1) == -5)
    precondition(BrowserDailyNavigation.zoom(.nan, delta: 1) == 0)
    precondition(BrowserGeneralSettings.load(from: root.appendingPathComponent("missing")).zoomByHost.isEmpty)
    let history = BrowserHistoryStore(storageURL: root.appendingPathComponent("history.json"))
    let now = Date()
    try await history.recordVisit(url: url, title: "First", at: now)
    try await history.recordVisit(url: url, title: "Second", at: now.addingTimeInterval(1))
    let entries = try await history.entries()
    precondition(entries.count == 1 && entries[0].visitCount == 2 && entries[0].title == "Second")
    _ = try await history.append(entries)
    let reimported = try await history.entries()
    precondition(reimported == entries)
    let many = (0..<10).map { n in BrowserHistoryEntry(url: URL(string:"https://example.org/\(n)")!,
        title:"Title \(n)", lastVisitTime: now.addingTimeInterval(Double(n)), visitCount:n) }
    let matches = BrowserHistoryStore.suggestions(many, matching:"example")
    precondition(matches.count == 6 && matches[0].visitCount == 9 && matches[5].visitCount == 4)
    precondition(BrowserHistoryStore.suggestions(many, matching:"Title 2").count == 1)
    precondition(BrowserHistoryStore.suggestions(many, matching:"").isEmpty)
    print("W57a fixture passed")
 }
}
`);
  const compile = spawnSync('swiftc',['-parse-as-library','-swift-version','6','-num-threads','2',
    b+'TatwoBrowserLaneCore.swift',b+'BrowserTabRegistry.swift',b+'BrowserGeneralSettings.swift',b+'BrowserShortcuts.swift',
    b+'BrowserDailyNavigationPolicy.swift',b+'Import/BrowserHistoryStore.swift',source,'-o',binary],
    {cwd:root,encoding:'utf8',timeout:90000});
  assert.equal(compile.status,0,compile.stderr);
  const run = spawnSync(binary,[dir],{encoding:'utf8',timeout:15000});
  assert.equal(run.status,0,run.stdout+run.stderr);
});

test('W57a-fix: native Esc defers to the host so an open find bar closes before stop-loading', () => {
  const bridge = readFileSync(new URL('../Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm', import.meta.url), 'utf8');
  assert.match(bridge, /if \(owner_\.onDailyShortcut\) \{ owner_\.onDailyShortcut\(@"escape"\); return true; \}/);
  const controls = readFileSync(new URL('../App/Sources/Tatwo2/Browser/BrowserDailyNavigationControls.swift', import.meta.url), 'utf8');
  assert.match(controls, /case "escape":\s*\n[^\n]*\n\s*if findPresented \{ onCommand\(\.stopFinding\); findPresented = false \} else \{ onCommand\(\.stopLoading\) \}/);
});
