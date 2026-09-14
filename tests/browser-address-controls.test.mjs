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

const toolbar = read('App/Sources/Tatwo2/Browser/EmbeddedBrowserToolbar.swift').split('struct EmbeddedBrowserToolbar: View')[1];
const runtime = read('App/Sources/Tatwo2/Browser/BrowserWorkSpaceCEFSurface.swift');
test('shared toolbar retains address, explicit history/reload, focus and escape', () => {
  assert.match(view, /EmbeddedBrowserToolbar\(/);
  for (const action of ['goBack', 'goForward', 'reload']) assert.ok(toolbar.includes('.' + action));
  assert.match(toolbar, /TextField\("搜尋或輸入網址", text: \$addressText\)/);
  assert.match(toolbar, /\.focused\(addressFieldFocused\)/);
  assert.match(toolbar, /\.onSubmit \{[\s\S]*?choose\(choices\[selection\]\)[\s\S]*?onSubmit\(\)/);
  assert.match(toolbar, /\.onExitCommand/);
  assert.match(toolbar, /addressText = state.urlString \?\? ""/);
});
test('navigation preserves focused drafts; committed URLs are persisted by the shared runtime', () => {
  assert.match(view, /EmbeddedBrowserAddressPresentation\.text/);
  assert.match(view, /isEditing: addressFieldFocused/);
  assert.match(runtime, /EmbeddedBrowserView.committedURLForPersistence\(state\)/);
  assert.match(runtime, /registry.update\(uuid, url: url/);
  assert.match(view, /state.phase == \.committed \|\| state.phase == \.finished/);
  assert.match(view, /state.hasExplicitCommittedURL/);
});
test('initial restoration reads registry selected tab and its URL', () => {
  assert.match(view, /registry.selectedTab\(ownedBy: owner\)/);
  assert.match(view, /addressText = selected\?\.url\?\.absoluteString \?\? ""/);
  assert.match(view, /BrowserWorkSpaceCEFSurface\(tabID: tab.id/);
});
test('identity switches discard drafts but do not discard commands addressed to the new tab', () => {
  const reset = section('private func syncSelection()', 'private func select(');
  assert.match(reset, /addressFieldFocused = false/);
  assert.match(reset, /commandTabID != selected\?\.id/);
});
test('transient failures are actionable and navigation still uses human policy', () => {
  assert.doesNotMatch(view, /Lifecycle recovery, capacity|Retry formal recovery check|命令已 fail-closed/);
  assert.match(view, /Text\(validationMessage\)/);
  const submit = section('private func loadAddress()', 'private func issue(');
  assert.match(submit, /BrowserOmniboxResolver\.resolve/);
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
