import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const browser = 'App/Sources/Tatwo2/Browser/';
const read = p => readFileSync(join(root, p), 'utf8');
const run = (cmd, args, options = {}) => {
  const result = spawnSync(cmd, args, { cwd: root, encoding: 'utf8', timeout: 90000, ...options });
  assert.equal(result.status, 0, `${cmd}: ${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
};

test('actual build-app plist heredoc registers browser schemes and HTML/URL Viewer types', () => {
  const script = read('scripts/build-app.sh');
  const body = script.match(/cat > "\$APP\/Contents\/Info\.plist" <<PLIST\n([\s\S]*?)\nPLIST/);
  assert.ok(body, 'must inspect the production heredoc, not merely bash -n');
  // Evaluate only the plist producer: no build, bundle staging, signing or installation.
  const xml = run('bash', ['-c', `RELEASE_VERSION=1.2.3\ncat <<PLIST\n${body[1]}\nPLIST`]);
  const plist = JSON.parse(run('python3', ['-c',
    'import json,plistlib,sys; print(json.dumps(plistlib.loads(sys.stdin.buffer.read())))'], { input: xml }));
  const handler = plist.CFBundleURLTypes[0];
  assert.equal(handler.CFBundleURLName, plist.CFBundleIdentifier);
  assert.deepEqual(handler.CFBundleURLSchemes, ['http', 'https']);
  assert.equal(handler.CFBundleTypeRole, 'Viewer');
  assert.equal(handler.LSHandlerRank, 'Default');
  assert.equal(plist.CFBundleDocumentTypes, undefined, '2.0.7 does not register document types (no local files)');
  assert.equal(plist.TatwoBrowserWorkspaceEnabled, true);
  const packaging = read('scripts/package-release.sh');
  assert.match(packaging, /bash scripts\/build-app.sh/);
  assert.doesNotMatch(packaging, /cat\s*>[^\n]*Info\.plist|<<PLIST/);
});

test('delegate forwarding, cold-launch replay and mounted-only delivery use the real inbox', () => {
  const app = read('App/Sources/Tatwo2/Tatwo2App.swift');
  const shell = read('App/Sources/Tatwo2/Shell/AppShell.swift');
  const modifier = read(browser + 'BrowserWorkSpaceLifecycleModifier.swift');
  assert.match(app, /func application\(_ application: NSApplication, open urls: \[URL\]\)[\s\S]*?wrapped\.application\(application, open: urls\)/);
  assert.ok(app.indexOf('BrowserTabRegistry.shared.prepareForLaunch()') < app.indexOf('application.run()'));
  assert.match(shell, /func application\(_ application: NSApplication, open urls: \[URL\]\)[\s\S]*?BrowserExternalURLQueue\.shared\.enqueue\(urls\)/);
  assert.match(shell, /if BrowserExternalURLQueue\.shared\.hasPendingURLs \{ showExternalBrowserWindow\(\) \}/);
  assert.match(shell, /\.onAppear \{[\s\S]*?surface == \.window, BrowserExternalURLQueue\.shared\.hasPendingURLs[\s\S]*?selection = \.chat\s*chatModel.mode = \.browser/);
  assert.match(shell, /publisher\(for: \.tatwoBrowserOpenExternalURLs\)[\s\S]*?selection = \.chat\s*chatModel.mode = \.browser/);
  assert.match(modifier, /if mounted \|\| !isWindow \{ content \}/);
  assert.match(modifier, /\.onAppear[\s\S]*?lifecycle.enter\(\)[\s\S]*?mounted = true/);
  assert.match(modifier, /\.onDisappear[\s\S]*?mounted = false/);
  assert.match(modifier, /publisher\(for: \.tatwoBrowserOpenExternalURLs\)[\s\S]*?guard mounted else \{ return \}/);
  assert.match(modifier, /\.onAppear \{\s*guard isWindow else \{ return \}/);
  assert.match(read('App/Sources/Tatwo2/Chat/ChatPage+Panels.swift'), /BrowserWorkSpaceLifecycleModifier\(store: browserWorkSpaceStore, registry: model.browserTabRegistry, isWindow: surface == \.window\)/);
  assert.match(read('App/Sources/Tatwo2/Chat/ChatPageConstants.swift'), /Bundle.main.object\(forInfoDictionaryKey: "TatwoBrowserWorkspaceEnabled"\)/);
  assert.match(read('App/Sources/Tatwo2/Space/SpaceWorkspaceController.swift'), /if mode == \.browser && !ChatRunMode.browserPreviewEnabled/);
});

test('settings adds one row with consent API, live HTTPS query and visible failures', () => {
  assert.match(read('App/Sources/Tatwo2/Shell/ChatPageSettings.swift'), /BrowserDefaultBrowserRow\(\)/);
  const row = read(browser + 'BrowserDefaultBrowserRow.swift');
  assert.match(row, /Text\("預設瀏覽器：/);
  assert.match(row, /Button\("設為預設"/);
  assert.match(row, /urlForApplication\(toOpen: URL\(string: "https:\/\/example.com"\)!/);
  assert.match(row, /for scheme in \["http", "https"\]/);
  assert.match(row, /try await NSWorkspace.shared.setDefaultApplication\(\s*at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme\)/);
  assert.match(row, /defer \{ isSetting = false; refresh\(\) \}/);
  assert.match(row, /error.localizedDescription/);
  assert.match(row, /if let failure \{ Text\(failure\)/);
  assert.doesNotMatch(row, /LSSetDefault|UserDefaults|Process\(/);
  if (process.platform === 'darwin') {
    run('swiftc', ['-typecheck', '-num-threads', '2', browser + 'BrowserDefaultBrowserRow.swift']);
  }
});

test('W57e custom close action closes only a tab and the empty workspace remains Search, never app termination', () => {
  const design = read(browser + 'BrowserWorkSpaceDesignView.swift');
  // W57e reserves Cmd-W for the OS window; closing a tab is an unbound configurable action.
  assert.match(design, /case \.closeTab: store.close\(store.selectedID\)/);
  assert.doesNotMatch(design, /keyboardShortcut\("w"/);
  assert.match(design, /if let tabID = store.selectedRegistryID[\s\S]*?\} else \{ page \}/);
  assert.match(design, /private var page: some View[\s\S]*?searchBox/);
  assert.doesNotMatch(design, /NSApp.terminate|performClose/);
  assert.match(read('App/Sources/Tatwo2/Shell/AppShell.swift'), /func applicationShouldTerminateAfterLastWindowClosed\(_ sender: NSApplication\) -> Bool \{ false \}/);
  assert.match(read(browser + 'BrowserWorkSpaceCEFSurface.swift'), /if workTabs.first\(where: \{ \$0.id == id \}\)\?\.isSleeping == true \{ registry.markSleeping\(id, false\) \}/);
});

test('production Swift fixture: cold/warm/reentrant queue, owner routing, selection restore and last-close round-trip', {
  skip: process.platform !== 'darwin', timeout: 120000,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w57b-browser-'));
  const source = join(dir, 'fixture.swift');
  const binary = join(dir, 'fixture');
  const design = read(browser + 'BrowserWorkSpaceDesignView.swift');
  const from = design.indexOf('@MainActor');
  const to = design.indexOf('// MARK: - End local fixture model');
  assert.ok(from >= 0 && to > from);
  writeFileSync(source, `import SwiftUI
import Combine
${design.slice(from, to)}
@main struct Fixture {
  @MainActor static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let settingsURL = root.appendingPathComponent("settings.json")
    let registryURL = root.appendingPathComponent("tabs.json")
    let center = NotificationCenter()
    let queue = BrowserExternalURLQueue(notifications: center)
    let good = ["https://example.com/a", "http://example.com/b"].map { URL(string: $0)! }
    let bad = ["mailto:a@example.com", "javascript:alert(1)", "data:text/html,hi", "ftp://example.com/a", "about:blank", "file:///tmp/page.pdf", "file:///tmp/page.html.js", "file:///tmp/page.html", "file:///tmp/page.htm", "file://remote/page.html", "https:/missing-host"].map { URL(string: $0)! }
    for url in good { precondition(BrowserExternalURLQueue.accepts(url)) }
    for url in bad { precondition(!BrowserExternalURLQueue.accepts(url)) }
    precondition(!queue.enqueue(bad) && !queue.hasPendingURLs)
    precondition(queue.enqueue(good + bad)) // No observer mounted yet.
    queue.consume(whenMounted: false) { _ in fatalError("premature drain") }
    precondition(queue.hasPendingURLs)
    var received: [URL] = []
    queue.consume(whenMounted: true) { batch in
      received += batch
      queue.consume(whenMounted: true) { _ in fatalError("duplicate delivery") }
      queue.enqueue([good[0]]) // New delivery during drain must survive.
    }
    precondition(received == good && queue.hasPendingURLs)
    queue.consume(whenMounted: true) { received += $0 }
    precondition(received == good + [good[0]] && !queue.hasPendingURLs)

    try Data(#"{"searchEngine":"bing","futureKey":true}"#.utf8).write(to: settingsURL)
    precondition(BrowserGeneralSettings.load(from: settingsURL).lastSelectedTabID == nil)
    let registry = BrowserTabRegistry(storageURL: registryURL)
    let first = registry.spaces.first { !$0.isSessionSpace }!
    let second = registry.addSpace(name: first.name) // Identical names must not alias.
    let a = registry.openTab(owner: .workSpace(spaceID: first.id), url: good[0])
    let b = registry.openTab(owner: .workSpace(spaceID: second.id), url: good[1])
    let selected = registry.openTab(owner: b.owner, url: good[0])
    let chat = registry.openTab(owner: .chatSession(sessionID: "fixture"), url: good[0])
    let bot = registry.openTab(owner: .bot(botID: "fixture"), url: good[1])
    var settings = BrowserGeneralSettings.load(from: settingsURL)
    settings.defaultSpaceID = first.id
    settings.lastSelectedTabID = selected.id
    try settings.save(to: settingsURL)
    precondition(BrowserGeneralSettings.load(from: settingsURL) == settings)
    precondition(try JSONDecoder().decode(BrowserGeneralSettings.self, from: JSONEncoder().encode(settings)) == settings)
    let fields = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
    precondition(fields["futureKey"] as? Bool == true)
    try registry.flush()

    let restored = BrowserTabRegistry(storageURL: registryURL)
    restored.prepareForLaunch()
    precondition(restored.tabs.allSatisfy(\\.isSleeping))
    let store = BrowserWorkSpaceStore(registry: restored)
    let lifecycle = BrowserWorkSpaceLifecycle(store: store, registry: restored, queue: queue, settingsURL: settingsURL)
    try lifecycle.enter()
    precondition(store.currentSpaceUUID == second.id && store.selectedRegistryID == selected.id)
    precondition(restored.tabs.map(\\.id) == registry.tabs.map(\\.id), "restore must not reorder records")
    precondition(restored.tabs.allSatisfy(\\.isSleeping), "only a mounted CEF surface can claim awake")
    store.select(store.tabs[0].id)
    try lifecycle.recordSelection()
    precondition(BrowserGeneralSettings.load(from: settingsURL).lastSelectedTabID == b.id)
    queue.enqueue(good)
    try lifecycle.consumePendingURLs()
    precondition(!queue.hasPendingURLs && restored.tabs(ownedBy: b.owner).suffix(good.count).map(\\.url) == good.map(Optional.some))
    precondition(store.selectedTab.url == good.last!.absoluteString)
    precondition(BrowserGeneralSettings.load(from: settingsURL).lastSelectedTabID == store.selectedRegistryID)
    precondition(restored.tabs(ownedBy: chat.owner).map(\\.id) == [chat.id])
    precondition(restored.tabs(ownedBy: bot.owner).map(\\.id) == [bot.id])

    let last = store.selectedRegistryID
    store.selectSpace(store.spaces.first { $0.isSessionSpace }!.id)
    try lifecycle.recordSelection()
    precondition(BrowserGeneralSettings.load(from: settingsURL).lastSelectedTabID == last)
    queue.enqueue([good[0]])
    try lifecycle.consumePendingURLs() // Session aggregate falls back to configured regular space.
    precondition(store.currentSpaceUUID == first.id && restored.tabs(ownedBy: a.owner).count == 2)
    while !store.tabs.isEmpty { store.close(store.selectedID) }
    try lifecycle.recordSelection()
    precondition(store.selectedRegistryID == nil && store.tabs.isEmpty)
    precondition(BrowserGeneralSettings.load(from: settingsURL).lastSelectedTabID == nil)

    // No regular space: create one, never open into the Session aggregate.
    for space in restored.spaces where !space.isSessionSpace { restored.removeSpace(space.id, closingTabs: true) }
    queue.enqueue([good[0]])
    try lifecycle.consumePendingURLs()
    precondition(store.currentSpaceUUID != nil && store.tabs.count == 1 && !queue.hasPendingURLs)
    // Rebuild aliases with new spaces, then restore a selected record by UUID.
    try restored.flush()
    let reopened = BrowserTabRegistry(storageURL: registryURL)
    reopened.prepareForLaunch()
    let freshStore = BrowserWorkSpaceStore(registry: reopened)
    try BrowserWorkSpaceLifecycle(store: freshStore, registry: reopened, queue: queue, settingsURL: settingsURL).enter()
    precondition(freshStore.selectedRegistryID == store.selectedRegistryID)
    print("W57b production fixture passed")
  }
}
`.replaceAll('precondition(try ', 'precondition(try! '));
  run('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    browser + 'TatwoBrowserLaneCore.swift', browser + 'BrowserTabRegistry.swift',
    browser + 'BrowserGeneralSettings.swift', browser + 'BrowserShortcuts.swift', browser + 'BrowserDailyNavigationPolicy.swift', browser + 'BrowserExternalURLQueue.swift',
    browser + 'BrowserWorkSpaceLifecycle.swift', source, '-o', binary]);
  assert.match(run(binary, [dir]), /W57b production fixture passed/);
});
