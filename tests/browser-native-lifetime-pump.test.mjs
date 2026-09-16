import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('..', import.meta.url));
const native = readFileSync(path.join(repo, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');
const swift = readFileSync(path.join(repo, 'App/Sources/Tatwo2/Browser/ChromiumCEFBackend.swift'), 'utf8');
function section(source, from, to) {
  const start = source.indexOf(from), end = source.indexOf(to, start + from.length);
  assert.ok(start >= 0 && end > start, from);
  return source.slice(start, end);
}
function run(command, args, timeout = 60000) {
  const result = spawnSync(command, args, { cwd: repo, encoding: 'utf8', timeout });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

test('native ownership ends at real close, not at view dealloc', () => {
  const dealloc = section(native, '- (void)dealloc {', '- (void)viewDidMoveToWindow');
  assert.doesNotMatch(dealloc, /\[self closeBrowser/);
  assert.match(dealloc, /_cefState == nullptr/);
  const create = section(native, 'BrowserState *CreateBrowserState(TatwoCEFBrowserView *view) {', 'bool TatwoClient::OnBeforePopup(');
  assert.match(create, /NSPointerFunctionsStrongMemory/);
  const complete = section(native, 'void CompleteBrowserClose(TatwoCEFBrowserView *view, BrowserState *state) {', 'void TatwoClient::OnAfterCreated(');
  assert.ok(complete.indexOf('view->_cefState = nullptr') < complete.indexOf('[g_live_browser_views removeObject:view]'));
  const after = section(native, 'void TatwoClient::OnAfterCreated(', 'bool TatwoClient::DoClose(');
  assert.match(after, /SetAccessibilityState\(STATE_ENABLED\)/);
  const startup = section(native, '  void OnBeforeCommandLineProcessing(', '  void OnBeforeChildProcessLaunch(');
  assert.match(startup, /if \(!process_type\.empty\(\)\) \{\s*return;/);
  assert.match(startup, /AppendSwitchWithValue\("force-renderer-accessibility", "complete"\)/);
  assert.doesNotMatch(startup, /AppendSwitch\("force-renderer-accessibility"\)/);
});

test('production lifetime token closes abandoned owners and aggregates real completion', { timeout: 90000 }, t => {
  if (process.platform !== 'darwin') return t.skip('requires macOS Swift');
  const scratch = mkdtempSync(path.join(tmpdir(), 'tatwo-lifetime-'));
  const token = section(swift, '    @MainActor final class BrowserLifetime {', '\n    private var passwordAssist:');
  const source = `import AppKit
@MainActor final class TatwoCEFBrowserView: NSObject {
  static var live: [TatwoCEFBrowserView] = []
  static var deallocations = 0
  var closeCalls = 0
  var callback: (() -> Void)?
  override init() { super.init(); Self.live.append(self) }
  func closeBrowser(completion: @escaping () -> Void) {
    weak var registeredWhileAlive = self
    precondition(registeredWhileAlive != nil)
    closeCalls += 1; callback = completion
  }
  func nativeDidClose() {
    let finish = callback; callback = nil
    Self.live.removeAll { $0 === self }; finish?()
  }
  deinit { MainActor.assumeIsolated { Self.deallocations += 1 } }
}
${token}
@MainActor func checks() {
  func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.06)) }
  weak var released: TatwoCEFBrowserView?
  do {
    let browser = TatwoCEFBrowserView(); released = browser
    var lifetime: BrowserLifetime? = BrowserLifetime(browser)
    lifetime = nil // no explicit host close, the crash-triggering ownership pattern
    drain()
    precondition(browser.closeCalls == 1 && browser.callback != nil)
    browser.nativeDidClose()
  }
  precondition(released == nil && TatwoCEFBrowserView.deallocations == 1)
  do {
    let browser = TatwoCEFBrowserView()
    var lifetime: BrowserLifetime? = BrowserLifetime(browser)
    var completions = 0
    lifetime!.close { completions += 1 }
    lifetime!.close { completions += 1 }
    precondition(browser.closeCalls == 1 && completions == 0)
    lifetime = nil // pending CEF completion retains the operation
    drain(); precondition(completions == 0)
    browser.nativeDidClose()
    precondition(completions == 2)
  }
  precondition(TatwoCEFBrowserView.live.isEmpty)
  precondition(TatwoCEFBrowserView.deallocations == 2)
  print("LIFETIME actual Swift token / controlled native completion PASS")
}
MainActor.assumeIsolated { checks() }
`;
  const sourcePath = path.join(scratch, 'main.swift'), binary = path.join(scratch, 'checks');
  writeFileSync(sourcePath, source);
  run('/usr/bin/xcrun', ['swiftc', '-swift-version', '5', sourcePath, '-o', binary]);
  process.stdout.write(run(binary, [], 10000));
});

test('production continuation processes work after load and in modal modes, then stops', { timeout: 90000 }, t => {
  if (process.platform !== 'darwin') return t.skip('requires macOS AppKit');
  const scratch = mkdtempSync(path.join(tmpdir(), 'tatwo-continuation-'));
  const arm = section(native, 'void ArmCEFMessagePumpContinuation() {', '\nvoid StartCEFMessagePumpIdleTimer()');
  const stop = section(native, 'void StopCEFMessagePumpIdleTimer() {', '\nvoid ScheduleCEFMessagePumpWork(int64_t delay_ms) {');
  const source = `#import <AppKit/AppKit.h>
#include <atomic>
#include <cassert>
std::atomic_bool g_initialized{true}, g_shutdown{false}, g_shutdown_requested{false};
NSTimer *g_message_pump_idle_timer = nil;
int work = 0;
void ArmCEFMessagePumpContinuation();
bool RunCEFMessagePumpWorkOnMainThread() {
  if (!g_initialized || g_shutdown || g_shutdown_requested) return false;
  ++work; ArmCEFMessagePumpContinuation(); return true;
}
void W60CancelVendorTimers() {}
${arm}
${stop}
void drain(NSString *mode, double seconds) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (until.timeIntervalSinceNow > 0)
    [[NSRunLoop mainRunLoop] runMode:mode beforeDate:until];
}
int main() { @autoreleasepool {
  // No navigation/loading flag and no vendor callback: IPC still advances.
  ArmCEFMessagePumpContinuation();
  drain(NSDefaultRunLoopMode, 0.18); assert(work >= 3 && work <= 8);
  int before = work;
  drain(NSModalPanelRunLoopMode, 0.18); assert(work - before >= 3 && work - before <= 8);
  // Re-arming must replace, rather than multiply, runtime timers.
  for (int i=0;i<50;++i) ArmCEFMessagePumpContinuation();
  before = work; drain(NSDefaultRunLoopMode, 0.18); assert(work-before >= 3 && work-before <= 8);
  g_shutdown_requested = true; StopCEFMessagePumpIdleTimer(); before = work;
  drain(NSDefaultRunLoopMode, 0.12); assert(work == before && g_message_pump_idle_timer == nil);
  ArmCEFMessagePumpContinuation(); assert(g_message_pump_idle_timer == nil);
  puts("PUMP actual AppKit continuation / controlled CEF work PASS");
} }
`;
  const sourcePath = path.join(scratch, 'checks.mm'), binary = path.join(scratch, 'checks');
  writeFileSync(sourcePath, source);
  run('/usr/bin/xcrun', ['clang++', '-std=c++20', '-fobjc-arc', '-framework', 'AppKit', sourcePath, '-o', binary]);
  process.stdout.write(run(binary, [], 10000));
});
