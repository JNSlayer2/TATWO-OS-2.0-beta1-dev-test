import { testScratch, stageFixtureFiles } from './helpers/test-scratch.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const browser = 'App/Sources/Tatwo2/Browser/';
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
const backend = read(browser + 'ChromiumCEFBackend.swift');
const run = (cmd, args, options = {}) => {
  const r = spawnSync(cmd, args, {cwd:root, encoding:'utf8', timeout:150000, env: {...process.env, TATWO_BROWSER_SLEEP_SECONDS: ''}, ...options});
  assert.equal(r.status, 0, `${r.error ?? ''}\n${r.stdout}\n${r.stderr}`);
  return r.stdout;
};
function fixture(name, source, files) {
  const dir = path.join(testScratch('browser-stress-'), name);
  fs.mkdirSync(dir, {recursive:true});
  const file = path.join(dir, 'Checks.swift'), binary = path.join(dir, 'checks');
  fs.writeFileSync(file, source);
  run('swiftc', ['-parse-as-library','-swift-version','6','-num-threads','2',
    ...files.map(p => path.join(root,p)), file, '-o',binary]);
  const output = run(binary, [dir]);
  process.stdout.write(output);
  return output;
}

test('W60 actual registry and lease registry: 30 opens, 200 switches, 20 closes, sleep/wake, drain', {
  skip: process.platform !== 'darwin', timeout:180000,
}, () => {
  // Complete production lease registry, including its wait/release semantics.
  // Only the unused destructive maintenance services are fail-fast doubles.
  const errors = backend.slice(backend.indexOf('enum TatwoCEFProfileLeaseError:'),
    backend.indexOf('enum TatwoCEFOriginDataClearBridge {'));
  const leases = backend.slice(backend.indexOf('@MainActor\nfinal class TatwoCEFProfileLeaseRegistry'),
    backend.indexOf('enum TatwoCEFProfileCeilingError:'));
  assert.ok(leases.includes('func activeLeaseCount') && !leases.includes('struct TatwoCEFProfileCeilingResult'));
  const hostClose = backend.slice(backend.indexOf('    private func closeTab(_ tabID: String)'),
    backend.indexOf('struct EmbeddedChromiumBrowserView:'));
  assert.ok(hostClose.includes('closingCount -= 1'));
  const output = fixture('registry', `import Foundation
${errors}
struct TatwoCEFProfileStore {
  func profileURL(for id: UUID) throws -> URL { fatalError("not a maintenance test") }
  func rotateProfile(for id: UUID) throws -> URL { fatalError("not a maintenance test") }
}
enum TatwoCEFOriginDataClearBridge {
  static func clear(origin: String, persistentProfilePath: String,
    completion: @escaping @Sendable (Result<TatwoCEFOriginDataClearReceipt,TatwoCEFOriginDataClearError>) -> Void) {
    fatalError("must not clear profiles")
  }
}
final class TatwoCEFOriginDataClearCallbackGate: @unchecked Sendable {
  func claimTerminalResult() -> Bool { fatalError("not a maintenance test") }
}
${leases}
@MainActor final class TatwoWebMCPRuntime {
 static let shared = TatwoWebMCPRuntime()
 func detach(tabID: String) {}
}
@MainActor final class BrowserAgentBridge {
 static let shared = BrowserAgentBridge()
 func detachAILogin(tabID: String) {}
}
@MainActor final class ClosingContainer {
 var completion: (() -> Void)?
 func close(completion: @escaping () -> Void) { precondition(self.completion == nil); self.completion = completion }
 func removeFromSuperview() {}
 func finish() { let callback = completion; completion = nil; callback?() }
}
@MainActor final class HostCloseFixture {
 struct Entry { let container: ClosingContainer; var memorySlot: UUID? = nil }
 var entries: [String:Entry] = [:]
 var closingCount = 0
 var profileLease: TatwoCEFProfileLeaseRegistry.Lease?
 var isClosing = false
 var pendingCommand: Bool?
 var onIdle: (() -> Void)?
 func ensureSelectedTab() {}
 // Exact production close aggregation below; only the native callback transport is doubled.
${hostClose}
@main struct Checks {
 @MainActor static func main() async throws {
  let registry = BrowserTabRegistry(storageURL: nil)
  let space = registry.spaces.first { !$0.isSessionSpace }!.id
  let owner = BrowserTabOwner.workSpace(spaceID: space)
  let chat = BrowserTabOwner.chatSession(sessionID: "stress-chat")
  let leaseRegistry = TatwoCEFProfileLeaseRegistry()
  let profileIDs = [UUID(), UUID()] // One profile lease per host, NOT per CEF tab.
  func acquire(_ id: UUID) throws -> TatwoCEFProfileLeaseRegistry.Lease {
    try leaseRegistry.acquire(identifier: id, profileURL: URL(fileURLWithPath:
      "tatwo-profile-\\(id.uuidString.lowercased())-generation-0", relativeTo:
        URL(fileURLWithPath:CommandLine.arguments[1]))).get()
  }
  var seed: UInt64 = 60
  func random(_ upper: Int) -> Int {
    seed = seed &* 6364136223846793005 &+ 1
    return Int((seed >> 32) % UInt64(upper))
  }
  var peakEstimate = 0
  for cycle in 0..<5 {
    var held = try profileIDs.map(acquire)
    let tabs = (0..<30).map { i in registry.openTab(owner: i < 20 ? owner : chat,
        url:URL(string:"https://example.com"), title:"tab-\\(i)") }
    let ids = Set(tabs.map(\\.id))
    precondition(ids.count == 30 && registry.tabs.count == 30)
    // Estimate only active record payload, not allocator RSS / Chromium memory.
    let estimate = registry.tabs.reduce(0) { $0 + $1.title.utf8.count + ($1.url?.absoluteString.utf8.count ?? 0) }
    if cycle == 0 { peakEstimate = estimate } else { precondition(estimate == peakEstimate) }
    for _ in 0..<200 {
      let tab = tabs[random(30)]
      registry.select(tab.id)
      precondition(registry.selectedTab(ownedBy: tab.owner)?.id == tab.id)
      precondition(Set(registry.tabs.map(\\.id)) == ids)
    }
    for tab in tabs.prefix(20) { registry.close(tab.id) }
    precondition(registry.tabs.count == 10 && registry.tabs(ownedBy: owner).isEmpty)
    precondition(leaseRegistry.release(held.removeFirst()))
    for tab in registry.tabs { registry.markSleeping(tab.id, true) }
    // Native close is represented by an explicit completion, never a timeout.
    let closingLease = held.removeFirst()
    precondition(leaseRegistry.activeLeaseCount(for: profileIDs[1]) == 1)
    precondition(leaseRegistry.release(closingLease))
    precondition(!leaseRegistry.release(closingLease)) // duplicate completion is inert
    precondition(leaseRegistry.activeProfileIdentifiers.isEmpty)
    precondition(registry.tabs.allSatisfy(\\.isSleeping))
    let awake = registry.tabs[0]
    registry.markSleeping(awake.id, false); registry.select(awake.id)
    let wakeLease = try acquire(profileIDs[1])
    precondition(registry.tabs.filter { !$0.isSleeping }.count == 1)
    registry.closeAll(ownedBy: chat)
    precondition(leaseRegistry.release(wakeLease))
    precondition(registry.tabs.isEmpty && leaseRegistry.activeProfileIdentifiers.isEmpty)
    for id in profileIDs { precondition(leaseRegistry.activeLeaseCount(for:id) == 0) }
  }
  // Exercise the actual host close aggregation under delayed/out-of-order callbacks.
  let shared = TatwoCEFProfileLeaseRegistry.shared, id = UUID()
  let path = URL(fileURLWithPath:"tatwo-profile-\\(id.uuidString.lowercased())-generation-0",
      relativeTo:URL(fileURLWithPath:CommandLine.arguments[1]))
  var host: HostCloseFixture? = HostCloseFixture()
  weak var retainedHost = host
  host!.profileLease = try shared.acquire(identifier:id,profileURL:path).get()
  let budget = BrowserNativeMemoryBudget.shared
  budget.configure(limit:nil)
  let containers = (0..<30).map { _ in ClosingContainer() }
  for (index,container) in containers.enumerated() {
    let slot = budget.acquire(owner:host!,retry:{})!
    host!.entries[String(index)] = .init(container:container,memorySlot:slot)
  }
  budget.configure(limit:4)
  host!.close(); host!.close()
  precondition(host!.entries.isEmpty && host!.closingCount == 30 && shared.activeLeaseCount(for:id) == 1)
  precondition(budget.count == 30) // sleep/close requests do not fake native release
  host = nil
  precondition(retainedHost != nil) // Real close closures retain the host and profile until completion.
  for index in (1..<30).reversed() {
    containers[index].finish()
    precondition(shared.activeLeaseCount(for:id) == 1)
    precondition(budget.count == index)
  }
  containers[0].finish(); containers[0].finish()
  precondition(shared.activeLeaseCount(for:id) == 0 && retainedHost == nil)
  precondition(budget.count == 0)
  print("W60 registry PASS cycles=5 opens=30 switches=200 closes=20 activeLeaseCount=0 activeRecordEstimateStable=true delayedHostClose=PASS; CEF/RSS not simulated")
 }
}
`, [browser+'TatwoBrowserLaneCore.swift',browser+'BrowserTabRegistry.swift',browser+'BrowserMemoryPolicy.swift',browser+'BrowserMemorySettings.swift',browser+'BrowserNativeMemoryBudget.swift']);
  assert.match(output, /activeLeaseCount=0/);
});

test('W60 production runtime stress: surface exclusivity, native identity retention, sleep removal', {
  skip: process.platform !== 'darwin', timeout:180000,
}, () => {
  const source = read(browser+'BrowserWorkSpaceCEFSurface.swift');
  const controller = source.slice(source.indexOf('@MainActor'), source.indexOf('struct BrowserWorkSpaceCEFSurface:'));
  const output = fixture('runtime', read('tests/fixtures/browser-workspace-runtime-stubs.swift') + controller + `
extension BrowserWorkSpaceRuntime {
 func fixtureSleep(_ now: Date) { sleepIdleTabs(now: now) }
 func fixtureReconcile() { reconcile() }
 static func fixtureSettings() { applyMemorySettings(.init(liveTabLimit:4,sleepMinutes:3)) }
}
@main struct Checks {
 @MainActor static func main() {
  let registry = BrowserTabRegistry.shared, surface = UUID(), competitor = UUID()
  let session = UUID().uuidString
  let runtime = BrowserWorkSpaceRuntime.forChat(session)
  let other = BrowserWorkSpaceRuntime.forChat(UUID().uuidString)
  BrowserWorkSpaceRuntime.fixtureSettings()
  let host = runtime.mount()
  precondition(host !== other.mount() && host !== BrowserWorkSpaceRuntime.shared.mount())
  let tabs = (0..<30).map { _ in registry.openTab(owner:.chatSession(sessionID:session),url:URL(string:"https://example.com")) }
  for tab in tabs { precondition(runtime.select(tab.id,surfaceID:surface,command:nil) { _,_ in }) }
  let limit = 4
  precondition(host.nativeIDs.count == limit && registry.tabs.filter { !$0.isSleeping }.count == limit)
  let identities = host.nativeIDs
  for i in 0..<200 {
    // Deterministic permutation, independent of UUID values.
    let tab = tabs[(i * 17 + 3) % 30]
    precondition(runtime.select(tab.id,surfaceID:surface,command:nil) { _,_ in })
    precondition(!runtime.select(tab.id,surfaceID:competitor,command:nil) { _,_ in })
    runtime.detach(surfaceID:competitor)
    precondition(runtime.surfaceID == surface && host.nativeIDs.count <= limit)
    precondition(registry.tabs.filter { !$0.isSleeping }.count <= limit)
    precondition(registry.tabs.first { $0.id == tab.id }?.isSleeping == false)
  }
  let closed = Set(tabs.prefix(20).map(\\.id))
  registry.tabs.removeAll { closed.contains($0.id) }
  runtime.fixtureReconcile()
  precondition(host.nativeIDs.count <= limit)
  runtime.detach(surfaceID:surface)
  runtime.fixtureSleep(Date().addingTimeInterval(181))
  precondition(host.nativeIDs.isEmpty && registry.tabs.allSatisfy(\\.isSleeping))
  let tab = registry.tabs[0]
  precondition(runtime.select(tab.id,surfaceID:competitor,command:nil) { _,_ in })
  let awakeHost = runtime.mount()
  precondition(awakeHost.nativeIDs.count == 1 && awakeHost.nativeIDs[tab.id.uuidString] != identities[tab.id.uuidString])
  registry.tabs.removeAll()
  runtime.fixtureReconcile()
  precondition(awakeHost.nativeIDs.isEmpty)
  print("W60 runtime wiring PASS; native engine is a double, not GUI/renderer acceptance")
 }
}
`, [browser+'TatwoBrowserLaneCore.swift', browser+'BrowserWorkSpacePolicies.swift', browser+'BrowserMemoryPolicy.swift', browser+'BrowserMemorySettings.swift', browser+'BrowserNativeMemoryBudget.swift',browser+'BrowserGeneralSettings.swift',browser+'BrowserShortcuts.swift']);
  assert.match(output, /W60 runtime wiring PASS/);
});

test('W60 production scheduler obeys immediate/delayed/cancel/overdue/shutdown semantics', {
  skip:process.platform !== 'darwin', timeout:180000,
}, () => {
  const sandbox = stageFixtureFiles([
    'scripts/browser-pump-probe.sh', 'scripts/browser-pump-probe.mjs',
    'scripts/tatwo-build-lock.sh', 'tests/fixtures/browser-pump-probe.mm.in',
    'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm',
  ]);
  // The real script still serializes compilers with the shared build lock.
  assert.match(run('bash', ['scripts/browser-pump-probe.sh','--checks'],
    { cwd: sandbox, timeout: 220000 }), /scheduler checks PASS/);
});

test('W60 quiet UI and lifetime boundaries stay wired to production', () => {
  const surface = read(browser+'BrowserWorkSpaceCEFSurface.swift');
  assert.match(surface, /case \.none, \.pageCreating, \.loadedAwaitingPaint, \.blankNoncommitted, \.httpFailure:\s*EmptyView\(\)/);
  for (const file of ['EmbeddedBrowserView.swift','BrowserWorkSpaceDesignView.swift']) {
    assert.match(read(browser+file), /BrowserNavigationProgress\(tabID:/);
  }
  const progress = read(browser+'BrowserNavigationProgress.swift');
  for (const token of ['frame(height: 2)', 'accessibilityReduceMotion','.easeOut(duration: 0.2)',
    'Task.sleep(for: .milliseconds(200))','.task(id: update)']) assert.ok(progress.includes(token),token);
  const show = backend.slice(backend.indexOf('    private func showSelectedTab()'), backend.indexOf('    private func ensureSelectedTab()'));
  assert.match(show, /entry\.container\.isHidden = hidden/);
  assert.doesNotMatch(show, /init\(|closeTab\(|removeFromSuperview/);
  assert.match(backend, /entries\.removeValue\(forKey: tabID\)/);
  assert.match(backend, /closingBrowser\.closeBrowser \{/);
  assert.match(backend, /private func finishClose[\s\S]*TatwoCEFProfileLeaseRegistry\.shared\.release\(lease\)/);
  assert.match(bridge, /launchMeaning=attempt_not_restart/);
  assert.doesNotMatch(bridge, /restartCount=%llu|phase=message_pump_loading_fallback|constexpr uint64_t interval = \(1000 \/ 30\)/);
  const termination = bridge.slice(bridge.indexOf('  void OnRenderProcessTerminated('), bridge.indexOf('\n private:', bridge.indexOf('  void OnRenderProcessTerminated(')));
  assert.ok(termination.indexOf('IsActiveMountCallback') < termination.indexOf('W57dInvalidate'));
  assert.match(termination, /W60RecordRendererTermination/);
  assert.match(bridge, /g_w60_renderer_terminations\.count > 10/);
});

test('W60 diagnostics sanitizes and bounds ten terminations without inventing PID restarts', {
  skip:process.platform !== 'darwin', timeout:180000,
}, () => {
  assert.match(fixture('health', `import Foundation
@main struct Checks {
 static func main() {
  // Construct synthetic URL credentials; this is not a stored mailbox or real secret.
  var url = URLComponents()
  url.scheme = "https"; url.host = "example.com"; url.user = "fixture"; url.password = "secret"
  url.path = "/private"; url.query = "q=secret"
  let rows: [[String:Any]] = (0..<15).map { i in ["time":Double(i), "status":"TS_PROCESS_CRASHED",
    "mountGeneration":NSNumber(value:i), "host":url.string!, "code":11] }
  let health = BrowserProcessHealth(["recentTerminations":rows,
    "launchCounts":["renderer":NSNumber(value:23)],"terminationCallbackCount":NSNumber(value:15)])
  precondition(health.launchCounts["renderer"] == 23 && health.terminationCallbackCount == 15)
  precondition(health.recentTerminations.count == 10 && health.recentTerminations.first?.mountGeneration == 5)
  precondition(health.recentTerminations.allSatisfy { $0.host == "example.com" && !$0.text.contains("secret") })
  precondition(BrowserProcessHealth.restartCountText.contains("未知"))
  var report = BrowserDiagnosticsReport()
  report.processHealth = health
  precondition(report.text.contains("H.264") && report.text.contains("WebAuthn Touch ID"))
  print("W60 health PASS last10=true restartCount=unknown")
 }
}
`, ['BrowserDiagnosticsPrivacy','BrowserProcessSampler','BrowserDiagnosticsAudit','BrowserPolicyLog','BrowserDiagnosticsReport']
    .map(n => browser+'Diagnostics/'+n+'.swift')), /W60 health PASS/);
});

test('W60 real navigation-state activity policy: no stuck progress on same-page/stop/error', {
  skip:process.platform !== 'darwin', timeout:180000,
}, () => {
  const source = read(browser+'EmbeddedBrowserSecurity.swift');
  const models = source.slice(source.indexOf('enum EmbeddedBrowserLoadPhase:'), source.indexOf('enum EmbeddedBrowserSurfaceCondition:'));
  assert.match(fixture('progress', `import Foundation
struct EmbeddedBrowserVisibleError: Equatable {}
${models}
${read(browser+'BrowserNavigationProgressPolicy.swift')}
@main struct Checks {
 static func main() {
  for (phase, loading, active): (EmbeddedBrowserLoadPhase, Bool, Bool) in [
    (.creating,false,true), (.loading,true,true), (.committed,true,true),
    (.committed,false,false), (.loading,false,false), (.finished,true,false),
    (.blank,false,false), (.closed,false,false), (.rendererFailed,true,false),
    (.navigationFailed,true,false), (.blockedBySecurity,true,false)
  ] {
    let state = EmbeddedBrowserNavigationState(urlString:nil,canGoBack:false,canGoForward:false,
        visibleError:nil,isLoading:loading,phase:phase)
    precondition(state.showsNavigationProgress == active)
  }
  print("W60 progress policy PASS")
 }
}
`, []), /W60 progress policy PASS/);
});
