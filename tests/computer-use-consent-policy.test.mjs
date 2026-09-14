import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const app = 'App/Sources/Tatwo2/';

test('swiftc: production policy matrix and session epoch lifetime', {skip: process.platform !== 'darwin'}, () => {
  const dir = path.join(root, '.build', 'w44-fixture');
  fs.mkdirSync(dir, {recursive: true});
  const source = ['Chat/TatwoCodexSandboxMode.swift', 'Chat/TatwoPermissionPreset.swift',
    'New/ComputerUseConsentPolicy.swift', 'New/ComputerUseSession.swift', 'New/ComputerUseTarget.swift']
    .map(p => read(app + p)).join('\n');
  fs.writeFileSync(path.join(dir, 'main.swift'), source + `
enum ComputerUseNative { struct State {} }
typealias P = TatwoPermissionPreset
typealias C = ComputerUseConsentPolicy
let presets: [P?] = [nil, .askFirst, .approveForMe, .fullAccess, .configFile]
for user in presets { for bot in presets { for readOnly in [false, true] {
    let mode = P.resolvedSidecarMode(user: user, bot: bot, readOnly: readOnly, legacyCodexAutoApprove: false)
    let expected: C = mode == "bypassPermissions" ? .autoAllow(clearOnHumanInput: false)
        : mode == "acceptEdits" ? .autoAllow(clearOnHumanInput: true) : .askOncePerSession
    precondition(C.resolve(user: user, bot: bot, readOnly: readOnly) == expected)
} } }
precondition(!C.autoAllow(clearOnHumanInput: false).clearOnHumanInput)
precondition(C.autoAllow(clearOnHumanInput: true).clearOnHumanInput)
precondition(C.askOncePerSession.clearOnHumanInput)
let owner = UUID()
for lane: ComputerUseSession.Lane in [.externalApplication, .builtInBrowser] {
    let gate = ComputerUseSession()
    let grant = try gate.authorize(owner: owner, scope: "scope", pid: 123, expectedEpoch: gate.currentEpoch, lane: lane, now: 100)
    precondition(grant.expiresAt == .greatestFiniteMagnitude)
    let cache = ComputerUseConsentCache(owner: owner, scope: "scope", epoch: grant.epoch, expiresAt: grant.expiresAt)
    precondition(cache.isCurrent(owner: owner, scope: "scope", epoch: gate.currentEpoch, now: 100000))
    precondition(!cache.isCurrent(owner: UUID(), scope: "scope", epoch: gate.currentEpoch, now: 101))
    precondition(!cache.isCurrent(owner: owner, scope: "other", epoch: gate.currentEpoch, now: 101))
    _ = try gate.require(owner: owner, scope: "scope", token: grant.id.uuidString, lane: lane, now: 100000)
    gate.stop()
    precondition(!cache.isCurrent(owner: owner, scope: "scope", epoch: gate.currentEpoch, now: 101))
    do { _ = try gate.require(owner: owner, scope: "scope", token: grant.id.uuidString, lane: lane, now: 101); fatalError("old token") }
    catch is ComputerUseFailure {}
    do { _ = try gate.authorize(owner: owner, scope: "scope", pid: 123, expectedEpoch: grant.epoch, lane: lane); fatalError("stale epoch") }
    catch is ComputerUseFailure {}
}
let bounded = ComputerUseSession()
let explicit = try bounded.authorize(owner: owner, scope: "scope", pid: 123, expectedEpoch: 0, expiresAt: 5000, now: 100)
precondition(explicit.expiresAt == 5000)
print("W44 policy matrix 50 combinations and lifetime fences PASS")
`);
  const binary = path.join(dir, 'fixture');
  const build = spawnSync('swiftc', [path.join(dir, 'main.swift'), '-o', binary], {encoding: 'utf8', timeout: 60000});
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(binary, [], {encoding: 'utf8', timeout: 10000});
  assert.equal(run.status, 0, run.stderr);
  process.stdout.write(run.stdout);
});

test('both starts resolve before asking, gate monitors, and keep TCC checks', () => {
  const source = read(app + 'New/ComputerUseController.swift');
  for (const [start, end] of [['private func start(caller:', '/// The browser'], ['func startBrowser(', 'func requireBrowserGrant']]) {
    const body = source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));
    assert.ok(body.indexOf('let policy = consentPolicyProvider(caller)') < body.indexOf('try await confirmConsent('));
    assert.match(body, /if policy == \.askOncePerSession && !reuse \{\s*consent = try await confirmConsent/);
    assert.match(body, /if policy.clearOnHumanInput \{ installInputMonitors\(for: grant\) \}/);
    assert.equal((body.match(/installInputMonitors\(/g) ?? []).length, 1);
    assert.match(body, /AXIsProcessTrusted\(\), CGPreflightScreenCaptureAccess\(\)/);
    assert.match(body, /expiresAt: \.greatestFiniteMagnitude/);
    assert.match(body, /reserveConsent\(caller: caller, epoch: switchEpoch\)/);
    assert.match(body, /consentPolicyProvider\(caller\) == policy/);
    assert.doesNotMatch(body, /Int\(grant.expiresAt/);
  }
  assert.match(source, /cachedPolicy != policy \|\| consentCache\?\.isCurrent/);
  assert.match(source, /let reuse = consentCache\?\.isCurrent\(owner: caller, scope: scope,/);
  assert.doesNotMatch(read(app + 'New/ComputerUseSession.swift'), /now \+ 900/);
  const bridge = read(app + 'Facade/OSAgentBridge.swift');
  assert.match(bridge, /consentPolicyProvider = \{ \[weak model\] caller in/);
  assert.match(bridge, /threadRecord\(caller\)/);
  assert.match(bridge, /user: model.permissionPreset, bot: thread.botPermissionPreset/);
  assert.match(bridge, /readOnly: thread.roomReadOnly == true/);
  assert.match(read(app + 'Facade/ChatPageModel.swift'), /record.roomReadOnly != true/);
});

test('MCP and settings describe session-level permissions, not 15-minute leases', () => {
  for (const p of ['Engines/os-mcp/server.mjs', 'Engines/browser-mcp/server.mjs']) {
    const source = read(p);
    assert.doesNotMatch(source, /15-minute/);
    assert.match(source, /授權層級跟隨這條對話的權限設定：全權／代我核准不再詢問；要求核准則每個 session 問一次/);
  }
  assert.match(read(app + 'Shell/ChatPageSettings.swift'), /授權層級跟隨對話的權限設定（要求核准／代我核准／完整存取權）/);
});

test('swiftc: existing ComputerUseSession XCTest suite without building or launching the App', {skip: process.platform !== 'darwin'}, t => {
  const xcode = spawnSync('xcode-select', ['-p'], {encoding: 'utf8'}).stdout.trim();
  const developer = path.join(xcode, 'Platforms/MacOSX.platform/Developer');
  const frameworks = path.join(developer, 'Library/Frameworks');
  const libraries = path.join(developer, 'usr/lib');
  if (!fs.existsSync(path.join(frameworks, 'XCTest.framework'))) {
    t.skip('Xcode XCTest framework unavailable; policy/session fixture above still runs'); return;
  }
  const dir = path.join(root, '.build', 'w44-session-tests');
  fs.mkdirSync(dir, {recursive: true});
  const tests = read('App/Tests/Tatwo2Tests/ComputerUseSessionTests.swift').replace('@testable import Tatwo2', '');
  const count = [...tests.matchAll(/func test\w+\(/g)].length;
  const production = ['ComputerUseSession.swift', 'ComputerUseTarget.swift', 'ComputerUseConnection.swift']
    .map(p => read(app + 'New/' + p)).join('\n');
  // State is merely stored as nil by these tests; no AX capture or app launch is performed.
  const source = production + '\nenum ComputerUseNative { struct State {} }\n' + tests + `
let suite = XCTestSuite(forTestCaseClass: ComputerUseSessionTests.self)
suite.run()
guard let run = suite.testRun, run.executionCount == ${count}, run.totalFailureCount == 0 else { exit(1) }
`;
  const file = path.join(dir, 'main.swift');
  const binary = path.join(dir, 'session-tests');
  fs.writeFileSync(file, source);
  const build = spawnSync('swiftc', ['-F', frameworks, '-I', libraries, '-L', libraries,
    '-Xlinker', '-rpath', '-Xlinker', frameworks, '-Xlinker', '-rpath', '-Xlinker', libraries,
    file, '-o', binary], {encoding: 'utf8', timeout: 60000});
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(binary, [], {encoding: 'utf8', timeout: 15000,
    env: {...process.env, DYLD_FRAMEWORK_PATH: `${frameworks}:${path.join(developer, 'Library/PrivateFrameworks')}`}});
  fs.writeFileSync(path.join(dir, 'result.log'), run.stdout + run.stderr);
  assert.equal(run.status, 0, run.stdout + run.stderr);
  process.stdout.write(`Existing ComputerUseSession XCTest: ${count} tests PASS\n`);
});
