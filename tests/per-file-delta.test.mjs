import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
const script = new URL('../scripts/per-file-delta.py', import.meta.url).pathname;
const install = readFileSync(new URL('../install.sh', import.meta.url), 'utf8');
const tree = install.split('# DELTA-TREE-BEGIN\n')[1].split('# DELTA-TREE-END')[0];
const run = (cmd, args) => {
  const r = spawnSync(cmd, args, { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr); return r.stdout;
};
test('W22 manifests, mode/link/new/deleted files and production offline assembly', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w22-delta-')), old = join(dir, 'old.app'), fresh = join(dir, 'new.app');
  for (const app of [old, fresh]) {
    mkdirSync(join(app, 'Contents/Resources/empty'), { recursive: true });
    for (const [name, data] of Object.entries({ same: 'same', changed: app, mode: 'mode', "space ' [x]*": 'literal' }))
      writeFileSync(join(app, 'Contents/Resources', name), data);
    symlinkSync(app === old ? 'same' : 'changed', join(app, 'Contents/Resources/link'));
    symlinkSync('same', join(app, 'Contents/Resources/unchanged-link'));
  }
  writeFileSync(join(old, 'Contents/Resources/deleted'), 'gone');
  writeFileSync(join(fresh, 'Contents/Resources/new'), 'added');
  writeFileSync(join(fresh, "Contents/Resources/space ' [x]*"), 'new literal');
  chmodSync(join(fresh, 'Contents/Resources/mode'), 0o755);
  chmodSync(join(fresh, 'Contents/Resources/empty'), 0o700);
  run('xattr', ['-w', 'com.example.w22', 'preserve', join(old, 'Contents/Resources/same')]);
  const base = join(dir, 'base'), release = join(dir, 'release');
  run('python3', [script, old, base, 'v2.0.5']);
  const oldManifest = join(base, 'TATWO-OS.manifest.json');
  run('python3', [script, fresh, release, 'v2.0.6', oldManifest]);
  const meta = join(release, 'TATWO-OS.manifest.json'), zip = join(release, 'TATWO-OS-delta-v2.0.5-v2.0.6.zip');
  const manifest = JSON.parse(readFileSync(meta));
  assert.equal(manifest.fromTag, 'v2.0.5');
  assert.ok(!manifest.files.some(e => e.path.endsWith('/deleted')));
  const entries = run('unzip', ['-Z1', zip]);
  for (const name of ['changed', 'new', 'mode', 'link']) assert.ok(entries.includes(`Resources/${name}\n`));
  assert.doesNotMatch(entries, /Resources\/(same|deleted|unchanged-link)\n/);
  const assembled = join(dir, 'assembled.app');
  const assemble = (m, target, baseline = old) => spawnSync('bash', ['-c', `set -euo pipefail\n${tree}\ndelta_tree "$@"`, 'test', m, zip, baseline, target], { encoding: 'utf8' });
  let result = assemble(meta, assembled); assert.equal(result.status, 0, result.stderr);
  assert.equal(run('xattr', ['-p', 'com.example.w22', join(assembled, 'Contents/Resources/same')]).trim(), 'preserve');
  run('python3', [script, assembled, join(dir, 'check'), 'v2.0.6', oldManifest]);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, 'check/TATWO-OS.manifest.json'))), manifest);
  writeFileSync(join(old, 'Contents/Resources/same'), 'damaged installed bytes');
  assert.notEqual(assemble(meta, join(dir, 'corrupt.app')).status, 0);
  for (const mutate of [
    m => { m.files[1].path = '../outside'; },
    m => { m.files.push(m.files[1]); },
    m => { m.files.find(e => e.symlink).symlink = '../../outside'; },
    m => { m.files.find(e => e.path.endsWith('/changed')).sha256 = '0'.repeat(64); },
  ]) {
    const bad = structuredClone(manifest); mutate(bad);
    const path = join(dir, `bad-${Math.random()}.json`); writeFileSync(path, JSON.stringify(bad));
    assert.notEqual(assemble(path, path + '.app').status, 0);
  }
  assert.ok(!existsSync(join(assembled, 'Contents/Resources/deleted')));
});
