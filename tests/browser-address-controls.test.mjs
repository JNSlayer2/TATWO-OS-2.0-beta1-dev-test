import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
const viewPath = 'App/Sources/Tatwo2/Browser/EmbeddedBrowserView.swift';
const policyPath = 'App/Sources/Tatwo2/Browser/EmbeddedBrowserAddressPresentation.swift';
const read = name => readFileSync(path.join(repo, name), 'utf8');
const view = read(viewPath);
const policy = read(policyPath);
const sha = text => createHash('sha256').update(text).digest('hex');
const section = (start, end) => {
  const from = view.indexOf(start);
  const to = view.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from);
  return view.slice(from, to);
};

test('loaded browser retains an address field and explicit history/reload controls', () => {
  assert.match(view, /browserToolbar\s+browserNavigationBar\s+Divider/);
  const bar = section('private var browserNavigationBar:', 'private var browserToolbar:');
  for (const action of ['goBack', 'goForward', 'reload']) {
    assert.match(bar, new RegExp(`action: \\.${action}`));
  }
  assert.match(bar, /TextField\("搜尋或輸入網址", text: \$addressText\)/);
  assert.match(bar, /\.focused\(\$addressFieldFocused\)/);
  assert.match(bar, /\.onSubmit\(loadAddress\)/);
  assert.match(bar, /\.onExitCommand/);
  assert.match(bar, /addressText = currentURLString/);
  assert.match(bar, /issue\(action\)/);
  assert.match(bar, /profileAccessState\.isReady/);
});

test('navigation callbacks preserve focused drafts including blank/closed callbacks', () => {
  const callback = view.slice(view.indexOf('private func applyNavigationState('));
  assert.match(callback, /clearActivePageVisibleState\(preserveAddressDraft: true\)/);
  assert.match(callback, /EmbeddedBrowserAddressPresentation\.text/);
  assert.match(callback, /isEditing: addressFieldFocused \|\| startPageFieldFocused/);
  assert.doesNotMatch(callback, /addressText = urlString/);
  // Committed state must keep following navigation even while the field is edited.
  assert.match(callback, /currentURLString = urlString/);
  assert.match(callback, /laneURLs\[selectedLaneID\] = url/);
});

test('initial panel restoration opens the saved selected page, not just its tab label', () => {
  const restored = section('} else if let saved = model.browserLanes(for: sessionID)', '} else {');
  assert.match(restored, /let selected = lanes\.selectedLaneID, let url = urls\[selected\]/);
  assert.match(restored, /_addressText = State\(initialValue: url\.absoluteString\)/);
  assert.match(restored, /_currentURLString = State\(initialValue: url\.absoluteString\)/);
  assert.match(restored, /_isBrowserRuntimeVisible = State\(initialValue: true\)/);
});

test('only explicit navigation and identity switches discard the draft', () => {
  const navigate = section('private func navigate(to url:', 'private func loadAddress()');
  assert.match(navigate, /addressFieldFocused = false/);
  assert.match(navigate, /startPageFieldFocused = false/);
  assert.match(navigate, /addressText = url\.absoluteString/);
  const reset = section('private func clearActivePageVisibleState(', 'private var browserStartPage:');
  assert.match(reset, /preserveAddressDraft: Bool = false/);
  assert.match(reset, /isEditing: preserveAddressDraft && \(addressFieldFocused \|\| startPageFieldFocused\)/);
});

test('transient preparation does not display implementation prose or relax navigation policy', () => {
  assert.doesNotMatch(view, /Lifecycle recovery, capacity|Retry formal recovery check|命令已 fail-closed/);
  assert.match(view, /Text\(validationMessage\)/);
  const submit = section('private func loadAddress()', 'private func issue(');
  assert.match(submit, /TatwoBrowserAddressResolver\.resolve/);
  assert.match(submit, /EmbeddedBrowserNavigationPolicy\.decision/);
});

// The lead owns compiler scheduling. Opt in only after its approval; default
// invocation above is source integration assertions, not native/UI acceptance.
test('native address projection keeps draft and committed navigation distinct', {
  skip: process.env.TATWO_BROWSER_ADDRESS_NATIVE !== '1'
    ? 'Lead compiler approval required (TATWO_BROWSER_ADDRESS_NATIVE=1)' : false,
}, () => {
  assert.equal(process.platform, 'darwin');
  const run = (cmd, args) => {
    const result = spawnSync(cmd, args, {
      cwd: repo, encoding: 'utf8', timeout: 60_000, maxBuffer: 1024 * 1024,
    });
    assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
    return result.stdout;
  };
  assert.equal(run('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']).trim(), '1');
  const output = path.join(repo, 'output/lightweight-repair');
  mkdirSync(output, { recursive: true });
  const root = mkdtempSync(path.join(output, 'browser-address.'));
  const lock = path.join(repo, 'scripts/tatwo-build-lock.sh');
  const acquired = run('/bin/bash', [lock, 'acquire', '--pid', String(process.pid), '--timeout', '1']);
  const token = acquired.match(/^token=([0-9a-f]+)$/m)?.[1];
  assert.ok(token);
  try {
    assert.equal(run('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']).trim(), '1');
    const swift = policy + String.raw`
var checks = 0
for draft in ["https://example.com/draft?q=1", "尚未送出的搜尋", ""] {
    for next in [String?.none, "https://example.org/redirect"] {
        let editing = EmbeddedBrowserAddressPresentation.text(
            draft: draft, navigationURL: next, isEditing: true)
        precondition(editing == draft, "navigation replaced an active draft")
        checks += 1
        let idle = EmbeddedBrowserAddressPresentation.text(
            draft: draft, navigationURL: next, isEditing: false)
        precondition(idle == (next ?? ""), "idle field did not follow navigation")
        checks += 1
    }
}
print("BROWSERADDRESS RESULT checks=\(checks) failures=0")
`;
    const main = path.join(root, 'main.swift');
    const binary = path.join(root, 'address-fixture');
    writeFileSync(main, swift);
    run('/usr/bin/xcrun', ['swiftc', '-j', '1', main, '-o', binary]);
    const result = run(binary, []);
    assert.match(result, /BROWSERADDRESS RESULT checks=12 failures=0/);
    assert.equal(sha(read(policyPath)), sha(policy), 'policy changed during fixture');
    assert.equal(sha(read(viewPath)), sha(view), 'view changed during fixture');
    writeFileSync(path.join(root, 'receipt.json'), JSON.stringify({
      at: new Date().toISOString(),
      policySHA256: sha(policy), viewSHA256: sha(view), fixtureSHA256: sha(swift),
      result,
      scope: 'Production address projection; source assertions for toolbar wiring. No rendered SwiftUI, CEF, navigation, login, profile or formal App acceptance.',
    }, null, 2));
    console.log(result.trim());
    console.log('Evidence:', root);
  } finally {
    run('/bin/bash', [lock, 'release', '--pid', String(process.pid), '--token', token]);
  }
});
