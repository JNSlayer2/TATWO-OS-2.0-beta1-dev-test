import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import vm from 'node:vm';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = p => readFileSync(join(root, p), 'utf8');
const app = 'App/Sources/Tatwo2/Browser/';
const native = 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/';
const bridge = read(native + 'TatwoCEFBridge.mm');
const sections = [...bridge.matchAll(/#pragma mark - W57c[^\n]*\n([\s\S]*?)#pragma mark - W57c End/g)]
  .map(m => m[1]).join('\n');
const script = bridge.match(/kW57cPasswordScript = R"W57C\(([\s\S]*?)\)W57C";/)[1];

test('W57c dedicated callbacks and fill are actor, document, origin, generation and revocation gated', () => {
  const header = read(native + 'include/TatwoCEFBridge.h');
  for (const name of ['onLoginFormDetected', 'onCredentialSubmitted', 'fillCredentialUsername:',
    'onPasswordAssistPageLoaded', 'onPasswordAssistInvalidated']) assert.ok(header.includes(name), name);
  for (const marker of ['#pragma mark - W57c', 'view.browserActor == TatwoCEFBrowserActorHuman',
    '!view.agentControlled', 'state->navigation_generation != g', 'state->close_requested',
    'page.generation != generation', 'page.token != token', 'page.context->IsSame(context)',
    'PID_BROWSER', 'PID_RENDERER', 'state->password_assist_scan_pending',
    'state->password_assist_status >= 200', 'W57cLoadEnd(owner, frame, http_status_code)',
    'W57cInvalidate(self, false, false)', '[reason isEqualToString:@"reload"]']) {
    assert.ok(bridge.includes(marker), marker);
  }
  assert.match(read(native + 'TatwoCEFBridgeUnavailable.m'), /fillCredentialUsername:.*\{\}/);
  const backend = read(app + 'ChromiumCEFBackend.swift');
  assert.match(backend, /BrowserPasswordAssist\(bridge: browserView\)/);
  assert.match(backend, /browserActor == .human && !agentControlled/);
  assert.match(backend, /passwordAssist\?\.invalidate\(\)/);
});

test('W57c values never enter diagnostics, telemetry, agent bridge or interpolated scripts', () => {
  // The one native pump call has a constant reason; no logger receives credential arguments.
  assert.doesNotMatch(sections, /\b(?:NSLog|printf|LogBrowser\w*|Append\w*Telemetry\w*)\s*\(/);
  assert.doesNotMatch(sections, /ExecuteJavaScript|CefWriteJSON|WriteFile|BrowserAgentBridge/);
  const swift = read(app + 'BrowserPasswordAssist.swift');
  assert.doesNotMatch(swift, /\b(?:print|NSLog|debugPrint|os_log|JSONEncoder)\s*\(/);
  assert.doesNotMatch(read('App/Sources/Tatwo2/Facade/BrowserAgentBridge.swift'),
    /fillCredentialUsername|onCredentialSubmitted|onLoginFormDetected|passwordForApprovedFill/);
  assert.match(swift, /BrowserPasswordAutofillPlanner.decision/);
  assert.match(swift, /BrowserPasswordSavePlanner.decision/);
  assert.match(swift, /timeout: 20/);
  assert.match(read(app + 'BrowserPasswordsSettingsView.swift'), /Toggle\("自動填入與儲存提示"/);
  assert.match(read(app + 'BrowserGeneralSettings.swift'), /var passwordAssist = true/);
  const extractor = read(app + 'EmbeddedBrowserProfile.swift').split('static let javaScript =')[1].split('"""#')[0];
  assert.doesNotMatch(extractor, /\.value\b/); // Existing generic extractor remains metadata-only.
});

function rendererFixture({usernameType = 'email', passwordType = 'password', autocomplete = 'current-password',
  action = 'https://example.com/auth', prefilled = '', origin = 'https://example.com'} = {}) {
  class Input {
    constructor(type, autocomplete) {
      this.type = type; this.autocomplete = autocomplete; this.isConnected = true;
      this.disabled = false; this.readOnly = false; this.hidden = false; this.events = [];
      this._value = '';
    }
    get value() { return this._value; }
    set value(value) { this._value = value; }
    getClientRects() { return [{}]; }
    dispatchEvent(event) { this.events.push(event.type); }
  }
  const user = new Input(usernameType, 'username');
  const password = new Input(passwordType, autocomplete);
  user.value = prefilled;
  const form = {isConnected: true, action, elements: [user, password]};
  user.form = password.form = form;
  const listeners = new Map(), events = [];
  const document = {forms: [form], baseURI: origin + '/login',
    addEventListener: (name, fn, capture) => { assert.equal(capture, true); listeners.set(name, fn); },
    removeEventListener: name => listeners.delete(name)};
  const context = vm.createContext({HTMLInputElement: Input, URL, Map, String, Array, Object,
    document, location: {origin, protocol: new URL(origin).protocol, href: origin + '/login'},
    getComputedStyle: () => ({visibility: 'visible', display: 'block'}),
    performance: {now: () => 1000}, Event: class {constructor(type) {this.type = type;}}});
  const factory = vm.runInContext(script, context);
  const controller = factory((...args) => events.push(args), origin);
  controller.scan();
  return {controller, events, listeners, user, password, form, document, context};
}

test('W57c actual renderer factory fills only bound visible login fields and dispatches input/change, never submit', () => {
  const f = rendererFixture();
  const detected = f.events.find(e => e[0] === 'detected');
  assert.ok(detected);
  assert.equal(f.controller.fill(detected[1], 'alice', 'fixture-secret-renderer'), true);
  assert.equal(f.password.value, 'fixture-secret-renderer');
  assert.deepEqual(f.user.events, ['input', 'change']);
  assert.deepEqual(f.password.events, ['input', 'change']);
  assert.equal(f.events.filter(e => e[0] === 'submitted').length, 0);
  assert.equal(f.controller.fill(detected[1], 'alice', 'other'), false);
  for (const mutate of [
    f => {f.password.type = 'hidden';}, f => {f.password.type = 'text';},
    f => {f.user.type = 'hidden';}, f => {f.password.isConnected = false;},
    f => {f.user.value = 'changed-after-ask';}, f => {f.password.value = 'human-typed';},
    f => {f.form.action = 'https://other.example/auth';},
    f => {f.form.elements = [];}, f => {f.password.form = {};},
    f => {f.controller.stop();}, f => {f.context.location.origin = 'https://other.example';},
  ]) {
    const f = rendererFixture();
    const id = f.events.find(e => e[0] === 'detected')[1];
    mutate(f);
    assert.equal(f.controller.fill(id, 'alice', 'fixture-secret-rejected'), false);
    assert.notEqual(f.password.value, 'fixture-secret-rejected');
  }
  for (const options of [
    {passwordType: 'hidden'}, {passwordType: 'text'}, {usernameType: 'hidden'},
    {autocomplete: 'new-password'}, {action: 'https://other.example/auth'},
    {origin: 'http://example.com'},
  ]) assert.equal(rendererFixture(options).events.some(e => e[0] === 'detected'), false);
});

test('W57c actual submit/Enter capture is trusted, memory-only, deduplicated and removable', () => {
  const f = rendererFixture({prefilled: 'alice'});
  f.password.value = 'fixture-secret-submitted';
  f.listeners.get('submit')({isTrusted: false, target: f.form});
  assert.equal(f.events.filter(e => e[0] === 'submitted').length, 0);
  f.listeners.get('keydown')({isTrusted: true, key: 'Enter', target: f.password});
  f.listeners.get('submit')({isTrusted: true, target: f.form});
  assert.deepEqual(f.events.filter(e => e[0] === 'submitted'),
    [['submitted', 'alice', 'fixture-secret-submitted']]);
  f.controller.stop();
  assert.equal(f.listeners.size, 0);
  const empty = rendererFixture();
  empty.listeners.get('keydown')({isTrusted: true, key: 'Enter', target: empty.password});
  assert.equal(empty.events.filter(e => e[0] === 'submitted').length, 0);
});

test('W57c real Swift coordinator/vault/planners: Island allow/deny, save/update/none, settings and stale replies', {
  timeout: 150000, skip: process.platform !== 'darwin',
}, () => {
  const dir = join(root, '.build/w57c/fill-fixture');
  mkdirSync(dir, {recursive: true});
  const profile = read(app + 'EmbeddedBrowserProfile.swift');
  const metadata = profile.slice(profile.indexOf('struct EmbeddedBrowserPasswordFormMetadata:'),
    profile.indexOf('struct EmbeddedBrowserNavigationJournal:'));
  writeFileSync(join(dir, 'metadata.swift'), 'import Foundation\nimport WebKit\n' + metadata);
  const binary = join(dir, 'fixture');
  const result = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    app + 'BrowserPasswordVault.swift', app + 'BrowserPasswordAssist.swift', app + 'BrowserGeneralSettings.swift', app + 'BrowserShortcuts.swift',
    join(dir, 'metadata.swift'), 'tests/fixtures/browser-password-fill-checks.swift', '-o', binary],
  {cwd: root, encoding: 'utf8', timeout: 120000});
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  const run = spawnSync(binary, [join(dir, 'settings.json')], {encoding: 'utf8', timeout: 20000});
  assert.equal(run.status, 0, `${run.error ?? ''}\n${run.stdout}\n${run.stderr}`);
  assert.match(run.stdout, /W57c password fill fixture passed: \d+ checks/);
  assert.doesNotMatch(result.stdout + result.stderr + run.stdout + run.stderr, /fixture-secret-/);
  console.log(run.stdout.trim());
});
