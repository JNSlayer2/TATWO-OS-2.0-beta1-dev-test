import { testScratch, stageFixtureFiles } from './helpers/test-scratch.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import vm from 'node:vm';

const root = fileURLToPath(new URL('../', import.meta.url));
const browser = 'App/Sources/Tatwo2/Browser/';
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const policyFiles = ['BrowserMemoryPolicy', 'BrowserMemorySettings', 'BrowserNativeMemoryBudget']
  .map(name => browser + name + '.swift');
const run = (cmd, args, options = {}) => {
  const result = spawnSync(cmd, args, {cwd: root, encoding: 'utf8', timeout: 90000, env: {...process.env, TATWO_BROWSER_SLEEP_SECONDS: ''}, ...options});
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
};
function fixture(name, source, extra = []) {
  const dir = path.join(testScratch('browser-memory-policy-'), name);
  fs.mkdirSync(dir, {recursive: true});
  const file = path.join(dir, 'Checks.swift'), binary = path.join(dir, 'checks');
  fs.writeFileSync(file, source);
  run('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    ...[...policyFiles, ...extra].map(file => path.join(root, file)), file, '-o', binary]);
  return run(binary, [dir]);
}

test('W60b production policy: memory boundaries, deterministic LRU, selected immunity and pressure', {
  skip: process.platform !== 'darwin',
}, () => {
  assert.match(fixture('policy', String.raw`import Foundation
@main struct Checks {
 static func main() {
  let gib: UInt64 = 1 << 30
  for (bytes, limit, idle): (UInt64, Int, Double) in [
    (0,4,180), (4*gib,4,180), (8*gib,4,180), (8*gib+1,6,300),
    (16*gib,6,300), (16*gib+1,8,300), (.max,8,300)
  ] {
    precondition(BrowserMemoryPolicy.defaultLimit(physicalMemory:bytes) == limit)
    precondition(BrowserMemoryPolicy.defaultSleepSeconds(physicalMemory:bytes) == idle)
    precondition(BrowserMemorySettings().limit(physicalMemory:bytes) == limit)
  }
  let ids = (0..<8).map { UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",$0))! }
  let tabs = ids.enumerated().map { i,id in BrowserMemoryPolicy.Tab(
      id:id,lastActiveAt:Date(timeIntervalSince1970:Double(i)),isSleeping:i == 7) }
  // Oldest is selected; it is never evicted, even at critical pressure.
  let selected: Set<UUID> = [ids[0]]
  precondition(BrowserMemoryPolicy.sleepCandidates(tabs:tabs,selected:selected,limit:4) == Array(ids[1...3]))
  precondition(BrowserMemoryPolicy.sleepCandidates(tabs:tabs,selected:selected,limit:nil).isEmpty)
  let protected: Set<UUID> = [ids[1], ids[2]]
  precondition(BrowserMemoryPolicy.sleepCandidates(tabs:tabs,selected:selected,limit:4,protected:protected) == Array(ids[3...5]))
  precondition(BrowserMemoryPolicy.sleepCandidates(tabs:tabs,selected:selected,limit:1,protected:protected,pressure:.critical) == Array(ids[3...6]))
  for pressure in [BrowserMemoryPressure.warning, .critical] {
    precondition(BrowserMemoryPolicy.sleepCandidates(tabs:tabs,selected:selected,limit:nil,pressure:pressure) == Array(ids[1...6]))
    precondition(BrowserMemoryPolicy.sleepCandidates(tabs:tabs,selected:Set(ids),limit:1,pressure:pressure).isEmpty)
  }
  precondition(BrowserMemoryPolicy.sleepCandidates(tabs:[],selected:[],limit:4).isEmpty)
  let tied = ids.reversed().map { BrowserMemoryPolicy.Tab(id:$0,lastActiveAt:.distantPast,isSleeping:false) }
  precondition(BrowserMemoryPolicy.sleepCandidates(tabs:tied,selected:[],limit:4) == Array(ids.prefix(4)))
  // Even a configured limit below visible selections never sleeps a selected tab.
  precondition(!BrowserMemoryPolicy.sleepCandidates(tabs:tabs,selected:Set(ids.prefix(4)),limit:2).contains(ids[0]))
  print("W60b pure policy PASS")
 }
}`), /W60b pure policy PASS/);
});

test('W60b settings round-trip, old/stale writer compatibility, invalid settings and sleep options', {
  skip: process.platform !== 'darwin',
}, () => {
  assert.match(fixture('settings', String.raw`import Foundation
@main struct Checks {
 static func main() throws {
  let url = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("settings.json")
  try Data(#"{"searchEngine":"google","future":42}"#.utf8).write(to:url)
  let stale = BrowserGeneralSettings.load(from:url)
  for cap in BrowserMemorySettings.limitOptions {
    for minutes in BrowserMemorySettings.sleepOptions {
      try BrowserMemorySettings.save(.liveTabLimit,value:cap,to:url)
      try BrowserMemorySettings.save(.sleepMinutes,value:minutes,to:url)
      try stale.save(to:url)
      try BrowserSettings(searchEngine:.bing).save(to:url)
      let settings = BrowserMemorySettings.load(from:url)
      precondition(settings.liveTabLimit == cap && settings.sleepMinutes == minutes)
      let fields = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
      precondition(fields["future"] as? Int == 42)
      precondition(settings.limit(physicalMemory:8 << 30) == (cap == 0 ? nil : cap == -1 ? 4 : cap))
      let expected: Double = minutes == 0 ? .infinity : minutes == -1 ? 180 : Double(minutes*60)
      let idle = settings.idleInterval(physicalMemory:8 << 30,environment:[:])
      precondition(idle == expected)
      let now = Date()
      precondition(!BrowserTabSleepPolicy.shouldSleep(lastActiveAt:.distantPast,now:now,isSelected:true,interval:idle))
      if idle.isFinite {
        precondition(!BrowserTabSleepPolicy.shouldSleep(lastActiveAt:now.addingTimeInterval(-idle+0.1),now:now,isSelected:false,interval:idle))
        precondition(BrowserTabSleepPolicy.shouldSleep(lastActiveAt:now.addingTimeInterval(-idle),now:now,isSelected:false,interval:idle))
      } else {
        precondition(!BrowserTabSleepPolicy.shouldSleep(lastActiveAt:.distantPast,now:now,isSelected:false,interval:idle))
      }
    }
  }
  for json in [#"{"liveTabLimit":false,"sleepMinutes":true}"#, #"{"liveTabLimit":4.5,"sleepMinutes":999}"#,
               #"{"liveTabLimit":"0","sleepMinutes":-20}"#, "{}"] {
    try Data(json.utf8).write(to:url)
    precondition(BrowserMemorySettings.load(from:url) == BrowserMemorySettings())
  }
  try Data("broken".utf8).write(to:url)
  do { try BrowserMemorySettings.save(.liveTabLimit,value:4,to:url); fatalError("overwrote corruption") } catch {}
  let preserved = try String(contentsOf:url,encoding:.utf8)
  precondition(preserved == "broken")
  do { try BrowserMemorySettings.save(.liveTabLimit,value:999,to:url); fatalError("accepted invalid cap") } catch {}
  print("W60b settings PASS")
 }
}`, [browser+'TatwoBrowserLaneCore.swift', browser+'BrowserWorkSpacePolicies.swift', browser+'BrowserGeneralSettings.swift', browser+'BrowserShortcuts.swift']),
  /W60b settings PASS/);
});

test('W60b global runtime: 30 opens, cross-session LRU, flush, wake, warning/critical and notification', {
  skip: process.platform !== 'darwin',
}, () => {
  const source = read(browser+'BrowserWorkSpaceCEFSurface.swift');
  const controller = source.slice(source.indexOf('@MainActor'), source.indexOf('struct BrowserWorkSpaceCEFSurface:'));
  assert.match(fixture('runtime', read('tests/fixtures/browser-workspace-runtime-stubs.swift') + controller + String.raw`
extension BrowserWorkSpaceRuntime {
 var fixtureNativeCount: Int { host?.nativeIDs.count ?? 0 }
 static func fixtureSettings(_ settings: BrowserMemorySettings) {
    applyMemorySettings(settings)
 }
}
@main struct Checks {
 @MainActor static func main() {
  // Diagnostics may instantiate a stale native budget before runtime exists.
  let expectedStartupLimit = BrowserMemorySettings.load().limit()
  BrowserNativeMemoryBudget.shared.configure(limit:expectedStartupLimit == 2 ? 4 : 2)
  precondition(BrowserWorkSpaceRuntime.memoryPressureText == "尚未監看")
  let registry = BrowserTabRegistry.shared, surface = UUID(), otherSurface = UUID()
  let session = UUID().uuidString, otherSession = UUID().uuidString
  let runtime = BrowserWorkSpaceRuntime.forChat(session)
  precondition(BrowserNativeMemoryBudget.shared.limit == expectedStartupLimit)
  let other = BrowserWorkSpaceRuntime.forChat(otherSession)
  BrowserWorkSpaceRuntime.fixtureSettings(.init(liveTabLimit:4,sleepMinutes:0))
  var ids: [UUID] = []
  for i in 0..<30 {
    let active = i % 2 == 0 ? runtime : other
    let tab = registry.openTab(owner:.chatSession(sessionID:i % 2 == 0 ? session : otherSession),
                              url:URL(string:"https://example.com"))
    ids.append(tab.id)
    precondition(active.select(tab.id,surfaceID:i % 2 == 0 ? surface : otherSurface,command:nil) { _,_ in })
    precondition(runtime.fixtureNativeCount + other.fixtureNativeCount <= 4)
    precondition(registry.tabs.filter { !$0.isSleeping }.count <= 4)
  }
  precondition(registry.tabs.filter { !$0.isSleeping }.count == 4)
  precondition(Set(registry.tabs.filter { !$0.isSleeping }.map(\.id)) == Set(ids.suffix(4)))
  let host = runtime.mount(), otherHost = other.mount()
  // Nonselected metadata is flushed before the sleep flag suppresses callbacks.
  let background = ids[26], favicon = Data([1,2,3])
  host.onPageMetadataChange(background.uuidString,"https://example.com","Retained title",favicon)
  host.pendingState = (background.uuidString,.init(committedMainFrameURLString:"https://example.com"))
  BrowserWorkSpaceRuntime.handleMemoryPressure(.warning)
  precondition(host.nativeIDs.count + otherHost.nativeIDs.count == 2)
  precondition(registry.tabs.first { $0.id == background }?.title == "Retained title")
  precondition(registry.tabs.first { $0.id == background }?.faviconPNG == favicon)
  precondition(registry.tabs.first { $0.id == background }?.isSleeping == true)
  precondition(IslandNotice.shared.messages.isEmpty)
  BrowserWorkSpaceRuntime.handleMemoryPressure(.normal)
  let original = host.nativeIDs[ids[28].uuidString]
  precondition(runtime.select(background,surfaceID:surface,command:nil) { _,_ in })
  precondition(host.nativeIDs[background.uuidString] != nil)
  BrowserWorkSpaceRuntime.handleMemoryPressure(.critical)
  precondition(BrowserWorkSpaceRuntime.memoryPressure == .critical)
  precondition(registry.tabs.filter { !$0.isSleeping }.count == 2)
  precondition(IslandNotice.shared.messages == ["記憶體吃緊，已釋放 1 個分頁"])
  BrowserWorkSpaceRuntime.handleMemoryPressure(.critical)
  precondition(IslandNotice.shared.messages.count == 1)
  // Persisting pressure still evicts the previous selection on a user switch.
  runtime.select(ids[28],surfaceID:surface,command:nil) { _,_ in }
  precondition(host.nativeIDs.count == 1 && host.nativeIDs[ids[28].uuidString] != original)
  runtime.detach(surfaceID:surface)
  other.detach(surfaceID:otherSurface)
  precondition(host.nativeIDs.isEmpty && otherHost.nativeIDs.isEmpty)
  BrowserWorkSpaceRuntime.handleMemoryPressure(.normal)
  BrowserWorkSpaceRuntime.fixtureSettings(.init(liveTabLimit:0,sleepMinutes:0))
  for id in ids where registry.tabs.first(where:{$0.id == id})?.owner == .chatSession(sessionID:session) {
    runtime.select(id,surfaceID:surface,command:nil) { _,_ in }
  }
  precondition(runtime.mount().nativeIDs.count == 15)
  BrowserWorkSpaceRuntime.fixtureSettings(.init(liveTabLimit:2,sleepMinutes:0))
  precondition(runtime.mount().nativeIDs.count == 2)
  print("W60b runtime PASS; native callback transport doubled")
 }
}`, [browser+'TatwoBrowserLaneCore.swift', browser+'BrowserWorkSpacePolicies.swift', browser+'BrowserGeneralSettings.swift', browser+'BrowserShortcuts.swift']),
  /W60b runtime PASS/);
});

test('W60b actual admission budget holds closing slots, wakes across hosts and never fakes completion', {
  skip: process.platform !== 'darwin',
}, () => {
  assert.match(fixture('budget', String.raw`import Foundation
@main struct Checks {
 @MainActor static func main() async throws {
  let budget = BrowserNativeMemoryBudget()
  budget.configure(limit:4)
  let owners = (0..<5).map { _ in NSObject() }
  let slots = owners.prefix(4).map { budget.acquire(owner:$0,retry:{fatalError("not waiting")})! }
  var admitted: UUID?
  precondition(budget.acquire(owner:owners[4],retry:{
    admitted = budget.acquire(owner:owners[4],retry:{})
  }) == nil)
  // Merely waiting (as with delayed OnBeforeClose) never frees a slot.
  try await Task.sleep(for:.milliseconds(80))
  precondition(budget.count == 4 && admitted == nil)
  budget.release(slots[0])
  try await Task.sleep(for:.milliseconds(80))
  precondition(budget.count == 4 && admitted != nil)
  budget.release(slots[0]) // duplicate native completion cannot create capacity
  precondition(budget.count == 4)
  budget.configure(limit:2) // outstanding closes remain counted
  precondition(budget.acquire(owner:owners[0],retry:{}) == nil)
  budget.cancelWait(owner:owners[0])
  for slot in slots.dropFirst() { budget.release(slot) }
  budget.release(admitted!)
  precondition(budget.count == 0)
  budget.configure(limit:nil)
  var unlimited: [UUID] = []
  for _ in 0..<30 { unlimited.append(budget.acquire(owner:owners[0],retry:{})!) }
  precondition(budget.count == 30)
  for slot in unlimited { budget.release(slot) }
  precondition(budget.count == 0)
  // A new selected tab must be admitted even when every old tab has edits.
  budget.configure(limit:2, protectedMinimum:5)
  let protectedSlots = owners.map { budget.acquire(owner:$0,retry:{})! }
  precondition(budget.count == 5 && budget.effectiveLimit == 5)
  budget.configure(limit:2, protectedMinimum:1)
  precondition(budget.acquire(owner:owners[0],retry:{}) == nil)
  budget.cancelWait(owner:owners[0])
  for slot in protectedSlots { budget.release(slot) }
  precondition(budget.count == 0 && budget.effectiveLimit == 2)
  print("W60b close-budget PASS")
 }
}`), /W60b close-budget PASS/);
});

test('activity helper retains edits and playback without reading form values', () => {
  const source = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const script = source.match(/const char kBrowserActivityScript\[\] = R"JS\(([\s\S]*?)\)JS";/)?.[1];
  assert.ok(script);
  const listeners = new Map(), reports = [], timers = [];
  const media = [{paused:true, ended:false}];
  const document = {
    addEventListener: (name, callback) => listeners.set(name, callback),
    querySelectorAll: selector => { assert.equal(selector, 'audio,video'); return media; },
  };
  const install = vm.runInNewContext(script, {document, setInterval: callback => timers.push(callback)});
  assert.equal(install((dirty, playing) => reports.push([dirty, playing])), true);
  const target = {closest: () => true, get value() { throw Error('must not read a secret'); }};
  listeners.get('input')({target}); assert.deepEqual(reports.at(-1), [true, false]);
  media[0].paused = false; listeners.get('play')(); assert.deepEqual(reports.at(-1), [true, true]);
  media[0].paused = true; listeners.get('pause')(); assert.deepEqual(reports.at(-1), [true, false]);
  const trackEvents = new Map();
  const track = {readyState:'live', addEventListener:(name, callback) => trackEvents.set(name, callback),
    get label() { throw Error('must not inspect camera or microphone identity'); }};
  media[0].srcObject = {getTracks:() => [track]};
  timers[0](); assert.deepEqual(reports.at(-1), [true, true], 'paused preview still protects a live stream');
  const reportCount = reports.length;
  timers[0](); assert.equal(reports.length, reportCount, 'unchanged activity does not emit IPC');
  track.readyState = 'ended'; trackEvents.get('ended')();
  assert.deepEqual(reports.at(-1), [true, false]);
  // A fresh renderer context alone resets sticky edits; media events do not.
  const fresh = [], second = new Map();
  vm.runInNewContext(script, {setInterval:() => {}, document: {
    addEventListener: (name, callback) => second.set(name, callback),
    querySelectorAll: () => [],
  }})((dirty, playing) => fresh.push([dirty, playing]));
  second.get('DOMContentLoaded')(); assert.deepEqual(fresh.at(-1), [false, false]);
  assert.match(source, /found->second.token != token/);
  assert.match(source, /!state->activity_main_ready/);
  assert.match(source, /HasActiveHumanDownloads\(\)/);
  assert.match(source, /HasActiveMediaCapture\(\)/);
  assert.match(source, /main_world->IsSame\(context\)/);
});

test('production activity reducer rejects stale frame contexts and keeps edit state sticky', {
  skip: process.platform !== 'darwin',
}, () => {
  const source = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const reducer = source.slice(source.indexOf('void UpdateBrowserActivity('), source.indexOf('bool HasActiveBrowserPumpWork(const BrowserState'));
  const fields = source.match(/struct BrowserState \{([\s\S]*?)#pragma mark - W57a/)?.[1];
  assert.ok(reducer && fields);
  const dir = path.join(root, '.build/w60b/tests/activity');
  fs.mkdirSync(dir, {recursive:true});
  const input = path.join(dir, 'Activity.cpp'), output = path.join(dir, 'activity');
  fs.writeFileSync(input, `#include <map>\n#include <string>\n#include <cassert>\n#include <iostream>\nstruct BrowserState {${fields}};\n${reducer}\n` + String.raw`
int main() {
  BrowserState s;
  auto send = [&](const char *frame, const char *token, const char *kind, bool main, bool dirty=false, bool playing=false) {
    UpdateBrowserActivity(&s, frame, token, kind, main, dirty, playing);
  };
  send("main", "old", "update", true, true); assert(s.activity_frames.empty());
  send("main", "old", "ready", true); assert(s.activity_main_ready);
  send("main", "old", "update", true, true, true);
  send("main", "old", "update", true, false, false);
  assert(s.activity_frames.at("main").dirty && !s.activity_frames.at("main").playing);
  send("main", "old", "ready", true); assert(s.activity_frames.at("main").dirty);
  send("main", "new", "ready", true); assert(!s.activity_frames.at("main").dirty);
  send("main", "new", "update", true, true);
  send("main", "old", "released", true); assert(s.activity_main_ready);
  send("main", "old", "update", true, false, true);
  assert(s.activity_frames.at("main").dirty && !s.activity_frames.at("main").playing);
  send("child", "c1", "ready", false); send("child", "c1", "update", false, true);
  send("child", "c1", "released", false); assert(s.activity_main_ready);
  assert(s.activity_frames.size() == 1);
  send("main", "new", "released", true); assert(!s.activity_main_ready && s.activity_frames.empty());
  std::cout << "activity frame context reducer PASS\n";
}`);
  run('xcrun', ['clang++', '-std=c++17', input, '-o', output]);
  assert.match(run(output, []), /activity frame context reducer PASS/);
});

test('W60b native wiring, secure flags, settings and diagnostics retain honest process semantics', () => {
  const backend = read(browser+'ChromiumCEFBackend.swift');
  const close = backend.slice(backend.indexOf('    private func closeTab('), backend.indexOf('    private func releaseLeaseIfIdle()'));
  assert.match(close, /entry\.container\.close \{ \[self\] in[\s\S]*BrowserNativeMemoryBudget\.shared\.release\(slot\)/);
  assert.match(backend, /guard let memorySlot = BrowserNativeMemoryBudget.shared.acquire/);
  assert.match(backend, /configureRendererProcessLimit\(BrowserMemorySettings\.load\(\)\.limit\(\) \?\? 0\)/);
  const runtime = read(browser+'BrowserWorkSpaceCEFSurface.swift');
  assert.match(runtime, /makeMemoryPressureSource\(eventMask: \[\.normal, \.warning, \.critical\], queue: \.main\)/);
  assert.match(runtime, /flags.contains\(\.critical\) \? \.critical : flags.contains\(\.warning\)/);
  assert.match(runtime, /publisher\(for: BrowserMemorySettings.changed\)/);
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  assert.match(bridge, /AppendSwitchWithValue\("renderer-process-limit"/);
  assert.doesNotMatch(bridge, /AppendSwitch\("process-per-site"\)|"site-per-process"/);
  assert.match(read('App/Sources/Tatwo2/Shell/ChatPageSettings.swift'), /BrowserMemorySettingsView\(\)/);
  assert.match(read(browser+'BrowserMemorySettingsView.swift'), /不限制可能耗盡記憶體/);
  assert.match(read(browser+'Diagnostics/BrowserDiagnosticsView.swift'), /memoryStatusText/);
  assert.match(read(browser+'Diagnostics/BrowserDiagnosticsReport.swift'), /存活分頁.*上限.*睡眠.*記憶體壓力狀態/);
  assert.match(read(browser+'Diagnostics/BrowserDiagnosticsReport.swift'), /不含 AI 登入彈窗/);
  const perf = read('scripts/browser-perf.sh');
  assert.match(perf, /after_opening_10_tabs/);
  assert.match(perf, /"rss_metric": "ri_resident_size"/);
  assert.match(perf, /"helper_count": helpers.count/);
  assert.match(run('bash', ['scripts/browser-perf.sh','--ten-plan']), /exactly 10 tabs/);
});

test('W60b ten-tab sampler executes and reports unavailable helper RSS as null, not zero/PASS', {
  skip: process.platform !== 'darwin',
}, () => {
  const dir = testScratch('browser-memory-policy-');
  fs.mkdirSync(dir, {recursive: true});
  const registry = path.join(dir, 'tabs.json');
  fs.writeFileSync(registry, JSON.stringify({
    tabs: Array.from({length: 10}, (_, i) => ({tab: {isSleeping: i >= 4}})),
  }));
  // Read-only sampling of this test process, not a real browser workload.
  const sandbox = stageFixtureFiles([
    'scripts/browser-perf.sh', 'scripts/tatwo-build-lock.sh',
    'App/Sources/Tatwo2/Browser/Diagnostics/BrowserProcessSampler.swift',
  ]);
  // The outer deadline includes the real script's 120s compiler-lock wait.
  const output = run('bash', ['scripts/browser-perf.sh', '--capture-ten',
    String(process.pid), dir, registry], { cwd: sandbox, timeout: 220000 });
  const sample = JSON.parse(output);
  assert.equal(sample.stage, 'after_opening_10_tabs');
  assert.equal(sample.tab_count, 10);
  assert.equal(sample.live_tabs, 4);
  assert.equal(sample.sleeping_tabs, 6);
  assert.equal(sample.helper_count, 0);
  assert.equal(sample.helper_rss_mb, null);
  assert.equal(sample.helper_footprint_mb, null);
  assert.equal(sample.verdict, 'measurement_only_not_acceptance');
});
