import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const browser = 'App/Sources/Tatwo2/Browser/';

test('W53 chat is a registry window using shared rows and CEF, without duplicate bookmark/state UI', () => {
  const view = read(browser + 'EmbeddedBrowserView.swift');
  assert.doesNotMatch(view, /bookmarkRail|bookmarkBubble|laneURLs|laneState/);
  assert.ok(view.trimEnd().split('\n').length < 1000);
  assert.match(view, /registry\.tabs\(ownedBy: \.chatSession\(sessionID: sessionID\)\)/);
  for (const token of ['BrowserTabRow(', 'BrowserWorkSpaceCEFSurface(', 'registry.openTab(',
    'registry.select(', 'registry.close(', 'registry.setPinned(', 'registry.move(']) assert.ok(view.includes(token), token);
  const design = read(browser + 'BrowserWorkSpaceDesignView.swift');
  assert.ok((design.match(/BrowserTabRow\(/g) ?? []).length >= 2);
  assert.match(design, /BrowserBotTabRows\(tabs: store.botTabs\)/);
  assert.match(read(browser + 'BrowserTabRow.swift'), /ForEach\(tabs\)/);
  assert.match(read('App/Sources/Tatwo2/Chat/ChatPage+Panels.swift'), /agentControllable: true/);
  assert.match(view, /BrowserChatRequestRouting.canConsume[\s\S]*?consumeBrowserAgentNavigation/);
  assert.match(view, /surfaceID: panelID/);
});

test('W53 native input recovery is scoped, excludes own synthetic events and resets native policy/prefs', () => {
  const host = read(browser + 'ChromiumCEFBackend.swift');
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  assert.match(host, /event.window === window/);
  assert.match(host, /target.isDescendant\(of: entry.container\)/);
  assert.match(host, /source != Int64\(getpid\(\)\)/);
  assert.match(host, /BrowserActorRecovery.shouldRestore/);
  assert.match(host, /now - event.timestamp <= 1/); // freshness at capture, not while draining
  assert.match(host, /revokeRequests\(\)[\s\S]*?pendingCommand = nil[\s\S]*?restoreHumanInteraction\(\)/);
  const recovery = bridge.slice(bridge.indexOf('- (BOOL)restoreHumanInteraction'), bridge.indexOf('- (nullable instancetype)initForPopupWithFrame:', bridge.indexOf('- (BOOL)restoreHumanInteraction')));
  for (const token of ['IsSame(state->request_context)', 'ApplyPrivacyStrictRequestContextPreferences',
    'TatwoCEFBrowserActorHuman', 'InvalidateResourceErrors()', 'self.agentControlled = NO', 'phase=actor_recovery']) assert.ok(recovery.includes(token), token);
  assert.match(read('App/Sources/Tatwo2/Facade/ChatLiveEngine.swift'), /BrowserChatLifecycle.didClose\(threadID.uuidString.lowercased\(\)/);
});

test('W53 swiftc: two chat tabs, selection, keep/closeWithChat, owner isolation, human recovery', {
  skip: process.platform !== 'darwin', timeout: 120000,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w53-chat-'));
  const source = join(dir, 'Checks.swift'), binary = join(dir, 'checks');
  writeFileSync(source, `import Foundation
@main struct Checks {
 @MainActor static func main() {
  let registry = BrowserTabRegistry(storageURL: nil)
  let owner = BrowserTabOwner.chatSession(sessionID: "fixture-chat")
  let a = registry.openTab(owner: owner), b = registry.openTab(owner: owner)
  let bot = registry.openTab(owner: .bot(botID: "fixture-bot"))
  precondition(registry.tabs(ownedBy: owner).count == 2)
  registry.select(a.id)
  precondition(registry.selectedTab(ownedBy: owner)?.id == a.id)
  precondition(registry.laneSnapshot(for: "fixture-chat")?.laneState.selectedLaneID?.rawValue == a.id.uuidString)
  registry.select(b.id)
  BrowserChatLifecycle.didClose("fixture-chat", registry: registry, retention: .keep)
  precondition(registry.tabs(ownedBy: owner).count == 2)
  BrowserChatLifecycle.didClose("fixture-chat", registry: registry, retention: .closeWithChat)
  precondition(registry.tabs(ownedBy: owner).isEmpty)
  precondition(registry.tabs.map(\\.id) == [bot.id])
  precondition(!BrowserActorRecovery.shouldRestore(agentControlled: false, inFlight: 0, lastAgentActionAt: nil, humanInputAt: 10, now: 10))
  for age in [TimeInterval?.none, -1, .infinity, .nan] {
    precondition(!BrowserActorRecovery.shouldRestore(agentControlled: true, inFlight: 0, lastAgentActionAt: nil, humanInputAt: age.map { 10 - $0 }, now: 10))
  }
  let panel = UUID()
  precondition(!BrowserChatRequestRouting.canConsume(panelID: panel, mountedSurfaceID: nil))
  precondition(!BrowserChatRequestRouting.canConsume(panelID: panel, mountedSurfaceID: UUID()))
  precondition(BrowserChatRequestRouting.canConsume(panelID: panel, mountedSurfaceID: panel))
  var agentControlled = true
  if BrowserActorRecovery.shouldRestore(agentControlled: agentControlled, inFlight: 0, lastAgentActionAt: 9, humanInputAt: 9.99, now: 10) { agentControlled = false }
  precondition(!agentControlled)
  for (inFlight, last, human, now, expected) in [
    (1, 9.0, 9.9, 10.0, false), (2, 8.0, 9.9, 10.0, false),
    (0, 9.8, 9.9, 10.0, false), (0, 9.7, 10.0, 10.01, true),
    (0, 10.0, 9.9, 10.31, true), (0, 11.0, 9.9, 10.0, false),
    (0, 9.6, 8.0, 10.0, true), (0, 8.0, 11.0, 10.0, false)
  ] {
    precondition(BrowserActorRecovery.shouldRestore(agentControlled: true, inFlight: inFlight,
      lastAgentActionAt: last, humanInputAt: human, now: now) == expected)
  }
  for invalid in [Double.infinity, Double.nan] {
    precondition(!BrowserActorRecovery.shouldRestore(agentControlled: true, inFlight: 0,
      lastAgentActionAt: invalid, humanInputAt: 10, now: 10))
  }
  print("W53 chat fixture passed")
 }
}
`);
  const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    browser + 'TatwoBrowserLaneCore.swift', browser + 'BrowserTabRegistry.swift', browser + 'BrowserGeneralSettings.swift', browser + 'BrowserShortcuts.swift', browser + 'BrowserDailyNavigationPolicy.swift',
    browser + 'BrowserChatLifecycle.swift', source, '-o', binary], { encoding: 'utf8', timeout: 90000 });
  assert.equal(compile.status, 0, compile.stderr);
  const result = spawnSync(binary, [], { encoding: 'utf8', timeout: 15000, env: {...process.env, TATWO_BROWSER_SLEEP_SECONDS: ''} });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /W53 chat fixture passed/);
});

test('W53 production runtime isolates chat hosts, retains background tabs, sleeps/wakes and closes', {
  skip: process.platform !== 'darwin', timeout: 120000,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w53-runtime-'));
  const source = join(dir, 'Runtime.swift'), binary = join(dir, 'checks');
  const runtime = read(browser + 'BrowserWorkSpaceCEFSurface.swift');
  const controller = runtime.slice(runtime.indexOf('@MainActor'), runtime.indexOf('struct BrowserWorkSpaceCEFSurface:'));
  writeFileSync(source, read('tests/fixtures/browser-workspace-runtime-stubs.swift') + '\n' + controller + `
extension BrowserWorkSpaceRuntime {
 static func fixtureSettings() { applyMemorySettings(.init(liveTabLimit:4,sleepMinutes:3)) }
 func fixtureSleep(_ now: Date) { sleepIdleTabs(now: now) }
 func fixtureReconcile() { reconcile() }
}
@main struct Checks {
 @MainActor static func main() {
  let registry = BrowserTabRegistry.shared
  let session = UUID().uuidString, other = UUID().uuidString
  let owner = BrowserTabOwner.chatSession(sessionID: session)
  let a = registry.openTab(owner: owner, url: URL(string: "https://example.com"))
  let b = registry.openTab(owner: owner, url: nil)
  let c = registry.openTab(owner: .chatSession(sessionID: other), url: nil)
  let runtime = BrowserWorkSpaceRuntime.forChat(session)
  let otherRuntime = BrowserWorkSpaceRuntime.forChat(other)
  BrowserWorkSpaceRuntime.fixtureSettings()
  precondition(runtime === BrowserWorkSpaceRuntime.forChat(session))
  precondition(TatwoCEFTabHostView.creations == 0)
  let host = runtime.mount(), surface = UUID()
  precondition(runtime.select(a.id, surfaceID: surface, command: nil) { _,_ in })
  precondition(host.live == Set([a.id.uuidString, b.id.uuidString]))
  precondition(!runtime.select(c.id, surfaceID: surface, command: nil) { _,_ in })
  let nativeA = host.nativeIDs[a.id.uuidString]
  runtime.select(b.id, surfaceID: surface, command: nil) { _,_ in }
  precondition(host.nativeIDs[a.id.uuidString] == nativeA)
  runtime.fixtureSleep(Date().addingTimeInterval(1201))
  precondition(registry.tabs.first { $0.id == a.id }!.isSleeping)
  precondition(!registry.tabs.first { $0.id == b.id }!.isSleeping)
  runtime.select(a.id, surfaceID: surface, command: nil) { _,_ in }
  precondition(host.nativeIDs[a.id.uuidString] != nativeA)
  precondition(otherRuntime.mount() !== host)
  let count = registry.tabs.count
  host.onTabPopupRequested?(a.id.uuidString, URL(string: "https://example.org")!)
  precondition(registry.tabs.count == count + 1 && registry.tabs.last?.owner == owner)
  registry.tabs.removeAll { $0.owner == owner }
  runtime.fixtureReconcile()
  precondition(host.nativeIDs.isEmpty)
  precondition(registry.tabs.map(\\.id) == [c.id])
  runtime.detach(surfaceID: surface)
  precondition(BrowserWorkSpaceRuntime.forChat(session) === runtime) // a surviving panel reuses its controller
  runtime.detach(surfaceID: surface)
  print("W53 runtime fixture passed")
 }
}
`);
  const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    browser + 'TatwoBrowserLaneCore.swift', browser + 'BrowserWorkSpacePolicies.swift', browser + 'BrowserMemoryPolicy.swift', browser + 'BrowserMemorySettings.swift', browser + 'BrowserNativeMemoryBudget.swift', browser + 'BrowserGeneralSettings.swift', browser + 'BrowserShortcuts.swift', source, '-o', binary],
    { encoding: 'utf8', timeout: 90000 });
  assert.equal(compile.status, 0, compile.stderr);
  const result = spawnSync(binary, [], { encoding: 'utf8', timeout: 15000, env: {...process.env, TATWO_BROWSER_SLEEP_SECONDS: ''} });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /W53 runtime fixture passed/);
});

test('W53 executes the production native recovery method: shared context, close completion, prefs failure', {
  skip: process.platform !== 'darwin', timeout: 120000,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w53-actor-native-'));
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const start = bridge.indexOf('- (BOOL)restoreHumanInteraction');
  const end = bridge.indexOf('- (nullable instancetype)initForPopupWithFrame:', start);
  const source = join(dir, 'fixture.mm'), binary = join(dir, 'fixture');
  writeFileSync(source, read('tests/fixtures/browser-actor-recovery.mm.in')
    .replace('// INSERT recovery', bridge.slice(start, end)));
  const compile = spawnSync('xcrun', ['clang++', '-std=c++20', '-fobjc-arc', '-framework', 'Foundation', source, '-o', binary],
    { encoding: 'utf8', timeout: 90000 });
  assert.equal(compile.status, 0, compile.stderr);
  const result = spawnSync(binary, [], { encoding: 'utf8', timeout: 15000, env: {...process.env, TATWO_BROWSER_SLEEP_SECONDS: ''} });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /W53 native actor recovery passed/);
});


test('W53b WK never mounts a surface; bridge returns an engine error rather than looking for WK', () => {
  for (const file of ['EmbeddedBrowserView.swift', 'BrowserWorkSpaceDesignView.swift', 'BrowserWorkSpaceCEFSurface.swift']) {
    assert.match(read(browser + file), /if EmbeddedBrowserEnginePolicy.current != \.chromiumCEF \{\s*BrowserEngineUnavailablePlaceholder\(\)/);
  }
  assert.doesNotMatch(read(browser + 'EmbeddedBrowserView.swift'), /EmbeddedBrowserWebView\(/);
  assert.match(read(browser + 'BrowserWorkSpaceCEFSurface.swift'), /此建置未包含 Chromium 引擎，瀏覽器無法使用/);
  const bridge = read('App/Sources/Tatwo2/Facade/BrowserAgentBridge.swift');
  const surface = bridge.slice(bridge.indexOf('    private func activeSurface('), bridge.indexOf('    private func openInSelectedEngine'));
  assert.match(surface, /failure\(\.engineUnavailable\)/);
  assert.doesNotMatch(surface, /findWebView\(/);
  assert.match(bridge, /throw BrowserError.engineUnavailable/);
  assert.match(bridge, /內建瀏覽器引擎不可用/);
  assert.match(bridge, /beginAgentAction\(\)\s*defer \{ finishAgentAction\(\) \}/);
  assert.match(bridge, /var inFlightAgentActions: Int/);
});

test('W53b shared surface owns the complete state card and annotation entrypoints use one sheet', () => {
  const surface = read(browser + 'BrowserWorkSpaceCEFSurface.swift');
  // W60: transient navigation/HTTP states are quiet; only actionable failures draw cards.
  assert.match(surface, /case \.none, \.pageCreating, \.loadedAwaitingPaint, \.blankNoncommitted, \.httpFailure:\s*EmptyView\(\)/);
  for (const state of ['subprocessRestart', 'navigationFailure', 'blockedBySecurity'])
    assert.ok(surface.includes('case let .' + state), state);
  assert.doesNotMatch(surface, /embedded-browser-(?:page-creating|awaiting-first-paint|http-status|blank-noncommitted)/);
  assert.match(surface, /BrowserSurfaceStateOverlay\(navigationState: runtime.navigationState\)/);
  assert.match(surface, /retryCommand = EmbeddedBrowserCommand\(action: \.reload\)/);
  assert.match(surface, /BrowserSurfaceText.diagnostic/);
  const sheet = read(browser + 'BrowserAnnotationSheet.swift');
  for (const token of ['EmbeddedBrowserAnnotationStore.shared', 'store.annotations(forURL:', 'profileKey: profileKey', 'store.remove(annotation)']) assert.ok(sheet.includes(token));
  assert.match(read(browser + 'EmbeddedBrowserView.swift'), /accessibilityLabel\("註解"\)/);
  assert.match(read(browser + 'BrowserWorkSpaceDesignView.swift'), /contextMenu \{[\s\S]*?Button\("註解…"\)/);
});

test('W53b workspace/session row variants keep exact baseline values and no inner workspace selection fill', () => {
  const metrics = read('App/Sources/Tatwo2/Visual/WorkspaceSidebarMetrics.swift');
  for (const [name, value] of Object.entries({workspaceRowFontSize:'13.5',workspaceRowMinHeight:'34',workspaceFaviconSize:'16',rowVerticalPadding:'7',rowFontSize:'13',metaFontSize:'11.5',rowIconWidth:'18',childLeadingInset:'30'}))
    assert.ok(metrics.includes(`static let ${name}: CGFloat = ${value}`), name);
  const row = read(browser + 'BrowserTabRow.swift');
  assert.match(row, /enum Variant \{ case workspace, session \}/);
  assert.match(row, /selected && variant == \.session/);
  for (const token of ['workspaceRowFontSize', 'workspaceRowMinHeight', 'workspaceFaviconSize', 'rowVerticalPadding']) assert.ok(row.includes(token));
  assert.match(read(browser + 'BrowserWorkSpaceDesignView.swift'), /BrowserTabRow\(variant: \.workspace/);
  const base = spawnSync('git', ['merge-base', 'beta1/integration', 'HEAD'], {encoding:'utf8'});
  assert.equal(base.status, 0);
  const baseline = spawnSync('git', ['show', base.stdout.trim()+':App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift'], {encoding:'utf8'});
  assert.equal(baseline.status, 0);
  // Integration now includes W53b's row extraction; verify that baseline through
  // its real row + metrics rather than requiring the pre-extraction inline syntax.
  assert.match(baseline.stdout, /BrowserTabRow\(variant: \.workspace/);
  const baselineRow = spawnSync('git', ['show', base.stdout.trim()+':App/Sources/Tatwo2/Browser/BrowserTabRow.swift'], {encoding:'utf8'});
  const baselineMetrics = spawnSync('git', ['show', base.stdout.trim()+':App/Sources/Tatwo2/Visual/WorkspaceSidebarMetrics.swift'], {encoding:'utf8'});
  assert.equal(baselineRow.status, 0);
  assert.equal(baselineMetrics.status, 0);
  for (const [name, value] of Object.entries({workspaceRowFontSize:'13.5',workspaceRowMinHeight:'34',workspaceFaviconSize:'16'})) {
    assert.ok(baselineRow.stdout.includes(name), name);
    assert.ok(baselineMetrics.stdout.includes(`static let ${name}: CGFloat = ${value}`), name);
  }
});

test('W53b native order cancels callbacks under strict actor before actor transition and human prefs', () => {
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const start = bridge.indexOf('- (BOOL)restoreHumanInteraction');
  const method = bridge.slice(start, bridge.indexOf('- (nullable instancetype)initForPopup', start));
  assert.ok(method.indexOf('CancelPendingWebMCPInvocations') < method.indexOf('self.agentControlled = NO'));
  assert.ok(method.indexOf('self.agentControlled = NO') < method.indexOf('ApplyPrivacyStrictRequestContextPreferences'));
});

test('W53b durable bookmark migration, retry, unknown profile preservation and delete/undo fixture', {
  skip: process.platform !== 'darwin', timeout: 120000,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w53b-migration-'));
  const source = join(dir, 'Checks.swift'), binary = join(dir, 'checks');
  const design = read(browser + 'BrowserWorkSpaceDesignView.swift');
  const store = design.slice(design.indexOf('@MainActor'), design.indexOf('// MARK: - End local fixture model'));
  writeFileSync(source, `import Foundation
import Combine
${store}
@main struct Checks {
 @MainActor static func main() throws {
  let root = URL(fileURLWithPath: CommandLine.arguments[1])
  let file = root.appendingPathComponent("tabs.json"), legacy = root.appendingPathComponent("old.json")
  let id = "fixture-chat", profile = TatwoBrowserProfileIdentity(sessionID: id)!.dataStoreIdentifier
  let other = "fixture-other", otherProfile = TatwoBrowserProfileIdentity(sessionID: "fixture-other")!.dataStoreIdentifier
  let a = UUID(), b = UUID(), c = UUID()
  func payload(_ profile: UUID) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      ["id": a.uuidString, "profileKey": profile.uuidString, "url": "https://example.com", "title": "A", "createdAt": 1],
      ["id": b.uuidString, "profileKey": profile.uuidString, "url": "https://example.org", "title": "B", "createdAt": 2],
      ["id": c.uuidString, "profileKey": otherProfile.uuidString, "url": "https://example.net", "title": "C", "createdAt": 3]])
  }
  try payload(profile).write(to: legacy)
  let registry = BrowserTabRegistry(storageURL: file, titleProvider: { ($0 == id ? "測試討論串" : "另一討論串", "") })
  try registry.migrateLegacyBookmarks(at: legacy, sessionIDs: [id, other, "empty-session"])
  precondition(!FileManager.default.fileExists(atPath: legacy.path))
  precondition(FileManager.default.fileExists(atPath: legacy.appendingPathExtension("migrated").path))
  let folders = registry.spaces.first { !$0.isSessionSpace }!.folders
  precondition(folders.filter { $0.name.hasPrefix("chat 書籤 · ") }.count == 2)
  precondition(folders.first { $0.name == "chat 書籤 · 另一討論串" }!.bookmarks.map(\\.id) == [c])
  precondition(registry.spaces.first { $0.isSessionSpace }!.folders.isEmpty)
  let folder = folders.first { $0.name == "chat 書籤 · 測試討論串" }!
  precondition(folder.name == "chat 書籤 · 測試討論串" && folder.bookmarks.map(\\.id) == [a,b])
  let reopened = BrowserTabRegistry(storageURL: file)
  precondition(reopened.spaces == registry.spaces)
  // Simulate crash after durable commit, before rename (retain backup elsewhere).
  try FileManager.default.moveItem(at: legacy.appendingPathExtension("migrated"), to: legacy)
  try reopened.migrateLegacyBookmarks(at: legacy, sessionIDs: [id, other, "empty-session"])
  precondition(reopened.spaces == registry.spaces)
  let store = BrowserWorkSpaceStore(registry: reopened)
  store.deleteBookmark(a)
  precondition(reopened.bookmarkRemoval(a) == nil)
  store.undoBookmarkDeletion()
  precondition(reopened.spaces == registry.spaces)
  store.deleteBookmark(a); store.deleteBookmark(b); store.undoBookmarkDeletion()
  precondition(reopened.bookmarkRemoval(a) == nil && reopened.bookmarkRemoval(b) != nil)
  store.undoBookmarkDeletion()
  precondition(reopened.bookmarkRemoval(a) == nil)
  let bad = root.appendingPathComponent("unknown.json")
  try payload(UUID()).write(to: bad)
  let isolated = BrowserTabRegistry(storageURL: root.appendingPathComponent("unknown-tabs.json"))
  let before = isolated.spaces
  do { try isolated.migrateLegacyBookmarks(at: bad, sessionIDs: [id, other, "empty-session"]); preconditionFailure("must preserve unknown profile") }
  catch { precondition(isolated.spaces == before && FileManager.default.fileExists(atPath: bad.path)) }
  print("W53b migration and undo passed")
 }
}
`);
  const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    browser+'TatwoBrowserLaneCore.swift', browser+'BrowserTabRegistry.swift', browser+'BrowserDailyNavigationPolicy.swift', source, '-o', binary], {encoding:'utf8',timeout:90000});
  assert.equal(compile.status, 0, compile.stderr);
  const result = spawnSync(binary, [dir], {encoding:'utf8',timeout:15000});
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /W53b migration and undo passed/);
  assert.match(design, /Button\("刪除書籤"\)/);
  assert.match(design, /registry.removeBookmark\(id\)/);
  assert.match(design, /shortcutMap\.bindings\[\.undoBookmarkDeletion\]/);
  assert.doesNotMatch(design, /keyboardShortcut\("z", modifiers: \.command\)/);
  assert.match(design, /IslandNotice.shared.info\(title: "已刪除書籤", detail:.*duration: 6\)/);
  assert.match(read('App/Sources/Tatwo2/Facade/ChatPageModel.swift'), /browserTabRegistry.migrateLegacyBookmarks/);
});

test('W53b production action counter balances nested and throwing methods and marks completion time', {
  skip: process.platform !== 'darwin', timeout: 120000,
}, () => {
  const bridge = read('App/Sources/Tatwo2/Facade/BrowserAgentBridge.swift');
  const counter = bridge.slice(bridge.indexOf('    private var agentActionCount'), bridge.indexOf('    private var activeRequest:'));
  // The class body ends at onMain; later `extension BrowserAgentBridge` blocks (W59 custody)
  // are outside the counter's scope, so slice to the class's closing brace, not the file's.
  const onMainStart = bridge.indexOf('    private func onMain<T>');
  const classEnd = bridge.indexOf('\n}\n', onMainStart);
  const dispatch = bridge.slice(onMainStart, classEnd);
  const dir = mkdtempSync(join(tmpdir(), 'w53b-counter-'));
  const source = join(dir, 'Checks.swift'), binary = join(dir, 'checks');
  writeFileSync(source, `import Foundation
final class Counter: @unchecked Sendable {
 let stateLock = NSLock()
 ${counter}
 ${dispatch}
 enum Failure: Error { case fixture }
 @MainActor func check() {
  precondition(inFlightAgentActions == 0 && agentActionState.lastAgentActionAt == nil)
  beginAgentAction()
  precondition(inFlightAgentActions == 1)
  func nested() throws {
   beginAgentAction(); defer { finishAgentAction() }
   precondition(inFlightAgentActions == 2)
   throw Failure.fixture
  }
  do { try nested(); preconditionFailure() } catch {}
  precondition(inFlightAgentActions == 1)
  let before = ProcessInfo.processInfo.systemUptime
  finishAgentAction()
  precondition(inFlightAgentActions == 0 && agentActionState.lastAgentActionAt! >= before)
  print("W53b action counter passed")
 }
}
@main struct Checks { @MainActor static func main() { Counter().check() } }
`);
  const compile = spawnSync('swiftc', ['-parse-as-library','-swift-version','5',source,'-o',binary], {encoding:'utf8',timeout:90000});
  assert.equal(compile.status,0,compile.stderr);
  const result = spawnSync(binary,[],{encoding:'utf8',timeout:15000});
  assert.equal(result.status,0,result.stdout+result.stderr);
  assert.match(result.stdout,/W53b action counter passed/);
});
