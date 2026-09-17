import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
const app = 'App/Sources/Tatwo2/';
const read = p => readFileSync(join(repo, p), 'utf8');
let binary;
function fixture() {
  if (!binary) {
    const root = testScratch('w68-upstream-compiled-');
    binary = join(root, 'checks');
    const files = ['Facade/TatwoResources.swift', 'Facade/OSUpstreamRefresh.swift', 'Facade/OSUpstreamLineDiff.swift',
      'Facade/OSUpstreamUpdateModel.swift', 'New/OSUpstreamUpdateView.swift', 'New/IslandNotice.swift'];
    execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', '-num-threads', '2',
      ...files.map(file => join(repo, app, file)), join(repo, 'tests/fixtures/os-upstream-update-checks.swift'),
      '-o', binary], { encoding: 'utf8', timeout: 180_000 });
  }
  return binary;
}

for (const [scenario, description] of [
  ['managed', 'matching installed hash auto-updates runtime and marker, with exact preimage backup'],
  ['custom', 'edited runtime is preserved and writes a visible pending notice'],
  ['unmarked', 'missing marker never grants automatic ownership'],
  ['empty-marker', 'empty marker is untrusted and leaves runtime unchanged'],
  ['equal-unmarked', 'equal unmarked content hides the row without adopting ownership for a later update'],
  ['backup-failure', 'failed backup aborts replacement and preserves the existing backup'],
  ['symlink-backup', 'runtime symlink backup retains actual preimage bytes when its target changes later'],
  ['dangling-link', 'dangling runtime symlink is not treated as a new installation'],
  ['write-failure', 'failed manual replacement does not claim ownership of custom contents'],
  ['keep', 'unmarked custom keep preserves bytes and keptUserEdited across model recreation'],
  ['changed-choice', 'changed bundled OR runtime contents re-enable notice after keep'],
  ['corrupt-choice', 'an unreadable keep receipt is not consent and cannot hide the actionable difference'],
  ['apply', 'explicit apply adopts an unmarked runtime only after private backup and records the bundled digest'],
  ['stale-runtime', 'review actions cannot act on an external runtime edit made after preview'],
  ['stale-bundle', 'review actions cannot act on a changed bundled version after preview'],
  ['diff', 'line diff preserves context, repeated/empty lines and terminal newline changes'],
  ['ui', 'native settings row exists only for pending differences; diff actions and Island are wired'],
  ['ui-actions', 'native row click opens a sheet and both real buttons persist, dismiss and hide the row'],
  ['ui-stale', 'native stale preview preserves external edits, refreshes the sheet and requires another decision'],
]) {
  test(`W68 ${description}`, { skip: process.platform !== 'darwin', timeout: 240_000 }, () => {
    const root = testScratch(`w68-${scenario}-`);
    const marker = join(root, 'os-upstream.installed.sha256');
    assert.equal(existsSync(marker), false, 'fixture must begin without an installed marker');
    const output = execFileSync(fixture(), [scenario, root], {
      encoding: 'utf8', timeout: 60_000,
    });
    assert.match(output, new RegExp(`W68 PASS ${scenario}`));
    if (scenario === 'apply' || scenario === 'keep') {
      const runtime = readFileSync(join(root, 'os-upstream.md'));
      const bundled = readFileSync(join(root, 'bundle.md'));
      const original = Buffer.from('# Rules\nKeep custom preferences\n\n');
      const hash = bytes => createHash('sha256').update(bytes).digest('hex');
      assert.notDeepEqual(original, bundled, 'fixture must exercise different contents');
      const backups = readdirSync(root).filter(name => name.startsWith('os-upstream.md.bak-'));
      assert.equal(existsSync(join(root, 'os-upstream.update-available.md')), false);
      if (scenario === 'apply') {
        assert.equal(backups.length, 1);
        const backup = join(root, backups[0]);
        assert.deepEqual(readFileSync(backup), original);
        assert.equal(statSync(backup).mode & 0o777, 0o600);
        assert.deepEqual(runtime, bundled);
        assert.equal(readFileSync(marker, 'utf8'), hash(bundled) + '\n');
      } else {
        assert.deepEqual(runtime, original);
        assert.equal(existsSync(marker), false, 'keep must not adopt ownership');
        assert.equal(backups.length, 0);
        assert.equal(readFileSync(join(root, 'os-upstream.kept-custom.sha256'), 'utf8'),
          hash(original) + '\n' + hash(bundled) + '\n');
        // The production Swift fixture also asserts .keptUserEdited after
        // relaunch and a hidden pending row after recreating the model.
      }
    }
  });
}

test('W68 update completion uses the relaunched App bundle and not the old downloader resources', () => {
  const shell = read(app + 'Shell/AppShell.swift');
  assert.match(read('install.sh'), /open "\$DEST"/);
  assert.match(shell, /InAppUpdater\.reconcileOnLaunch\(\)[\s\S]*OSUpstreamRefresh\.applyOnLaunch\(\)/);
  assert.match(shell, /islandShellController\?\.show\(\)[\s\S]*OSUpstreamUpdateModel\.shared\.reload\(notify: true\)/);
  assert.match(read(app + 'New/OSBindingCard.swift'), /OSUpstreamUpdateView\(update: \.shared\)/);
  const view = read(app + 'New/OSUpstreamUpdateView.swift');
  assert.match(view, /if let pending = update.pending[\s\S]*os-upstream-update-row/);
  assert.doesNotMatch(view, /已是最新|已經是最新/);
  assert.match(view, /Button\("套用 App 內建版本", action: apply\)/);
  assert.match(view, /Button\("保留我的自訂", action: keep\)/);
  assert.match(view, /\.defaultScrollAnchor\(\.topLeading\)/);
});
