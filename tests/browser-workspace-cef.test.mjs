import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const root = new URL('../', import.meta.url);
const read = path => readFileSync(new URL(path, root), 'utf8');
const browser = 'App/Sources/Tatwo2/Browser/';
const design = read(browser + 'BrowserWorkSpaceDesignView.swift');
const runtime = read(browser + 'BrowserWorkSpaceCEFSurface.swift');
const host = read(browser + 'ChromiumCEFBackend.swift').split('final class TatwoCEFTabHostView:')[1];

test('production Swift omnibox, settings persistence and adaptive sleep boundary', { skip: process.platform !== 'darwin' }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w47-policy-'));
  const source = join(dir, 'main.swift'), binary = join(dir, 'checks');
  writeFileSync(source, `import Foundation
func check(_ value: Bool) { precondition(value) }
check(BrowserOmniboxResolver.resolve("example.com")?.absoluteString == "https://example.com")
check(BrowserOmniboxResolver.resolve("localhost:3000")?.absoluteString == "http://localhost:3000")
check(BrowserOmniboxResolver.resolve("example.com:8443/a")?.absoluteString == "https://example.com:8443/a")
check(BrowserOmniboxResolver.resolve("https://example.com/a?q=x#b")?.absoluteString == "https://example.com/a?q=x#b")
check(BrowserOmniboxResolver.resolve("about:blank")?.absoluteString == "about:blank")
check(BrowserOmniboxResolver.resolve("  ") == nil)
for engine in BrowserSearchEngine.allCases {
    let url = BrowserOmniboxResolver.resolve("how to x & 繁中", engine: engine)!
    check(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "how to x & 繁中")
    check(url == engine.searchURL("how to x & 繁中"))
}
let now = Date(timeIntervalSince1970: 2000)
let idle = BrowserMemoryPolicy.defaultSleepSeconds(physicalMemory: ProcessInfo.processInfo.physicalMemory)
check(BrowserMemorySettings().idleInterval(environment: [:]) == idle)
check(!BrowserTabSleepPolicy.shouldSleep(lastActiveAt: now.addingTimeInterval(-idle + 1), now: now, isSelected: false, interval: idle))
check(BrowserTabSleepPolicy.shouldSleep(lastActiveAt: now.addingTimeInterval(-idle), now: now, isSelected: false, interval: idle))
check(!BrowserTabSleepPolicy.shouldSleep(lastActiveAt: now.addingTimeInterval(-5000), now: now, isSelected: true, interval: idle))
check(!BrowserTabSleepPolicy.shouldSleep(lastActiveAt: now.addingTimeInterval(10), now: now, isSelected: false, interval: idle))
let settingsURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("settings.json")
check(BrowserSettings.load(from: settingsURL).searchEngine == .google)
try Data(#"{"futureField":true}"#.utf8).write(to: settingsURL)
try BrowserSettings(searchEngine: .bing).save(to: settingsURL)
check(BrowserSettings.load(from: settingsURL).searchEngine == .bing)
let fields = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
check(fields["futureField"] as? Bool == true)
try Data("broken".utf8).write(to: settingsURL)
do { try BrowserSettings().save(to: settingsURL); fatalError("corruption overwritten") } catch {}
check(try String(contentsOf: settingsURL, encoding: .utf8) == "broken")
print("W47 policies passed")
`);
  const compile = spawnSync('swiftc', ['-num-threads', '2', new URL(browser + 'BrowserWorkSpacePolicies.swift', root).pathname, new URL(browser + 'BrowserMemoryPolicy.swift', root).pathname, new URL(browser + 'BrowserMemorySettings.swift', root).pathname, new URL(browser + 'BrowserNativeMemoryBudget.swift', root).pathname, new URL(browser + 'BrowserGeneralSettings.swift', root).pathname, new URL(browser + 'BrowserShortcuts.swift', root).pathname, source, '-o', binary], { encoding: 'utf8', timeout: 90000 });
  assert.equal(compile.status, 0, compile.stderr);
  const result = spawnSync(binary, [dir], { encoding: 'utf8', timeout: 15000, env: {...process.env, TATWO_BROWSER_SLEEP_SECONDS: ''} });
  assert.equal(result.status, 0, result.stdout + result.stderr);
});

test('workspace mounts actual human CEF only after access; keeps one persistent pool across switches', () => {
  assert.match(design, /BrowserWorkSpaceCEFSurface\(tabID: tabID/);
  assert.match(runtime, /EmbeddedBrowserRuntimeMountPolicy\.allowsMount/);
  assert.match(runtime, /EmbeddedBrowserRuntimeProfile\.persistent/);
  assert.match(runtime, /recordAccessAndEnforce/);
  assert.match(runtime, /if let host \{ return host \}/);
  assert.match(host, /TatwoCEFBrowserView\(frame: \.zero, persistentProfile:[\s\S]*?actor: \.human/);
  assert.match(host, /TatwoCEFBrowserView\(frame: \.zero, sharingContextWith:[\s\S]*?actor: \.human/);
  assert.match(host, /if let browser = entries\[tabID\]/);
  assert.match(runtime, /filter \{ !\$0\.isSleeping \}/);
  assert.match(runtime, /registry\.markSleeping\(tab.id, true\)/);
  assert.match(host, /where !openTabIDs.contains\(id\)[\s\S]*?closeTab\(id\)/);
  assert.match(runtime, /registry\.touch\(selectedID\)/);
  assert.doesNotMatch(design, /\.id\(store.selectedID\)/);
});

test('W57e map is mounted in Browser; no hard-coded W/L/R/T in other branches', () => {
  const content = design.slice(design.indexOf('private var browserContent:'), design.indexOf('private var extensionStrip:'));
  // W57e mounts the map at the same Browser scope; it no longer hard-codes W/L/R/T.
  assert.match(content, /BrowserDailyNavigationControls\(/);
  assert.doesNotMatch(design, /keyboardShortcut\("[twlr]"/);
  const session = design.slice(design.indexOf('private var sessionContent:'), design.indexOf('private func favicon('));
  assert.doesNotMatch(session, /TatwoCEFBrowserView|BrowserWorkSpaceCEFSurface|keyboardShortcut/);
  assert.match(design, /if store.selectedSpace.isSessionSpace \{ sessionContent \}\s*else \{ browserContent \}/);
  for (const path of ['ChatPage.swift', 'ChatPage+Panels.swift', 'ChatPage+Sidebar.swift', 'ChatPage+Composer.swift']) {
    assert.doesNotMatch(read('App/Sources/Tatwo2/Chat/' + path), /keyboardShortcut\(\s*"[twlr]"/);
  }
  const scan = relative => {
    for (const entry of readdirSync(new URL(relative, root), { withFileTypes: true })) {
      const path = relative + entry.name;
      if (entry.isDirectory()) scan(path + '/');
      else if (entry.name.endsWith('.swift') && path !== browser + 'BrowserWorkSpaceDesignView.swift') {
        assert.doesNotMatch(read(path), /keyboardShortcut\(\s*"[wlr]"/, path);
      }
    }
  };
  scan('App/Sources/Tatwo2/');
  const panels = read('App/Sources/Tatwo2/Chat/ChatPage+Panels.swift');
  assert.match(panels, /else if model.mode == \.browser \{\s*if ChatRunMode.browserPreviewEnabled \{\s*BrowserWorkSpaceDesignView/);
});

test('metadata is native, guarded by generation and identity; downloads retain W45 human store path', () => {
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  assert.match(bridge, /void OnTitleChange/);
  assert.match(bridge, /void OnFaviconURLChange/);
  assert.match(bridge, /owner.navigationGeneration != generation_/);
  assert.match(host, /self.entries\[tabID\] === entry/);
  assert.match(host, /browser.navigationGeneration == generation/);
  assert.match(runtime, /registry.update\(uuid, url: tab.url, title:/);
  const registry = read(browser + 'BrowserTabRegistry.swift');
  assert.match(registry, /tab.url != url \|\| tab.title != title \|\| tab.faviconPNG != favicon else \{ return \}/);
  assert.match(host, /BrowserHumanInteraction.shared.configure\(browser\)/);
  assert.match(read(browser + 'BrowserHumanInteraction.swift'), /BrowserDownloadStore.shared/);
  assert.match(design, /downloadStore.downloads/);
});

test('production runtime fixture: lazy mount, switch retention, background callbacks, sleep/wake and popup owner', { skip: process.platform !== 'darwin' }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w47-runtime-'));
  const source = join(dir, 'Runtime.swift'), binary = join(dir, 'checks');
  const controller = runtime.slice(runtime.indexOf('@MainActor'), runtime.indexOf('struct BrowserWorkSpaceCEFSurface:'));
  writeFileSync(source, read('tests/fixtures/browser-workspace-runtime-stubs.swift') + '\n' + controller + `
extension BrowserWorkSpaceRuntime {
    static func fixtureSettings() { applyMemorySettings(.init(liveTabLimit:4,sleepMinutes:3)) }
    func fixtureSleep(_ now: Date) { sleepIdleTabs(now: now) }
    func fixtureReconcile() { reconcile() }
}
@main struct Checks {
    @MainActor static func main() {
        let runtime = BrowserWorkSpaceRuntime.shared
        BrowserWorkSpaceRuntime.fixtureSettings()
        let registry = BrowserTabRegistry.shared
        precondition(TatwoCEFTabHostView.creations == 0)
        let spaceA = UUID(), spaceB = UUID(), surface = UUID()
        let url = URL(string: "https://example.com")!
        let a = registry.openTab(owner: .workSpace(spaceA), url: url)
        let b = registry.openTab(owner: .workSpace(spaceB), url: url)
        let chat = registry.openTab(owner: .chat, url: url)
        precondition(TatwoCEFTabHostView.creations == 0)
        let host = runtime.mount()
        var popupSpace: UUID?
        runtime.select(a.id, surfaceID: surface, command: nil) { space, _ in popupSpace = space }
        let nativeA = host.nativeIDs[a.id.uuidString]
        precondition(!runtime.select(b.id, surfaceID: UUID(), command: nil) { _,_ in })
        precondition(host.selected == a.id.uuidString) // second window cannot steal the native host
        runtime.select(b.id, surfaceID: surface, command: nil) { space, _ in popupSpace = space }
        precondition(runtime.mount() === host && host.nativeIDs[a.id.uuidString] == nativeA)
        precondition(!host.live.contains(chat.id.uuidString))
        host.onTabPopupRequested?(b.id.uuidString, url)
        precondition(popupSpace == spaceB)
        host.onTabPopupRequested?(a.id.uuidString, url)
        precondition(registry.tabs.last?.owner == .workSpace(spaceA))
        let data = Data([1, 2, 3])
        host.onPageMetadataChange(a.id.uuidString, url.absoluteString, "Background title", data)
        precondition(registry.tabs.first { $0.id == a.id }?.title == "Background title")
        precondition(registry.tabs.first { $0.id == b.id }?.title == "Title")
        let writes = registry.writes
        host.onPageMetadataChange(a.id.uuidString, "https://stale.example", "stale", nil)
        precondition(registry.writes == writes)
        let committed = "https://example.com/committed-before-sleep"
        host.pendingState = (a.id.uuidString, EmbeddedBrowserNavigationState(committedMainFrameURLString: committed))
        runtime.fixtureSleep(Date().addingTimeInterval(1201))
        precondition(registry.tabs.first { $0.id == a.id }?.url?.absoluteString == committed)
        precondition(!host.live.contains(a.id.uuidString) && host.live.contains(b.id.uuidString))
        precondition(registry.tabs.first { $0.id == a.id }?.faviconPNG == nil) // new document clears stale icon
        precondition(registry.tabs.first { $0.id == a.id }?.isSleeping == true)
        runtime.select(a.id, surfaceID: surface, command: nil) { _,_ in }
        precondition(host.nativeIDs[a.id.uuidString] != nativeA)
        precondition(registry.tabs.first { $0.id == a.id }?.isSleeping == false)
        runtime.detach(surfaceID: UUID()) // stale dismantle cannot hide active surface
        precondition(host.selected == a.id.uuidString)
        runtime.detach(surfaceID: surface)
        precondition(host.selected == nil)
        runtime.fixtureSleep(Date().addingTimeInterval(1201))
        precondition(host.nativeIDs.isEmpty)
        precondition(runtime.mount() === host) // same host waits for native close before reacquisition
        registry.tabs.removeAll { $0.id == a.id }
        runtime.fixtureReconcile()
        host.onPageMetadataChange(a.id.uuidString, url.absoluteString, "closed", nil)
        precondition(!registry.tabs.contains { $0.id == a.id })
        print("W47 runtime lifecycle passed")
    }
}
`);
  const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2', new URL(browser + 'BrowserWorkSpacePolicies.swift', root).pathname, new URL(browser + 'BrowserMemoryPolicy.swift', root).pathname, new URL(browser + 'BrowserMemorySettings.swift', root).pathname, new URL(browser + 'BrowserNativeMemoryBudget.swift', root).pathname, new URL(browser + 'BrowserGeneralSettings.swift', root).pathname, new URL(browser + 'BrowserShortcuts.swift', root).pathname, source, '-o', binary], { encoding: 'utf8', timeout: 90000 });
  assert.equal(compile.status, 0, compile.stderr);
  const result = spawnSync(binary, [], { encoding: 'utf8', timeout: 15000, env: {...process.env, TATWO_BROWSER_SLEEP_SECONDS: ''} });
  assert.equal(result.status, 0, result.stdout + result.stderr);
});
