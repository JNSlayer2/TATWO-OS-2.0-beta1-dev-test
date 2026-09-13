import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, symlinkSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
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
    for (const [name, data] of Object.entries({ same: 'same', changed: app, mode: 'mode', "space ' [x]*": 'literal', '中文 é': 'unicode' }))
      writeFileSync(join(app, 'Contents/Resources', name), data);
    symlinkSync(app === old ? 'same' : 'changed', join(app, 'Contents/Resources/link'));
    symlinkSync('same', join(app, 'Contents/Resources/unchanged-link'));
    run('chmod', ['-h', '640', join(app, 'Contents/Resources/unchanged-link')]);
  }
  writeFileSync(join(old, 'Contents/Resources/deleted'), 'gone');
  writeFileSync(join(fresh, 'Contents/Resources/new'), 'added');
  writeFileSync(join(fresh, "Contents/Resources/space ' [x]*"), 'new literal');
  chmodSync(join(fresh, 'Contents/Resources/mode'), 0o755);
  chmodSync(join(fresh, 'Contents/Resources/empty'), 0o700);
  for (const [before, after] of [[old, fresh], [fresh, old]]) {
    const name = before === old ? 'directory-to-file' : 'file-to-directory';
    mkdirSync(join(before, 'Contents/Resources', name));
    writeFileSync(join(before, 'Contents/Resources', name, 'child'), 'child');
    writeFileSync(join(after, 'Contents/Resources', name), 'file');
  }
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
  writeFileSync(join(old, 'Contents/Resources/same'), 'same');
  for (const mutate of [
    m => { m.files[1].path = '../outside'; },
    m => { m.files.push(m.files[1]); },
    m => { m.files.find(e => e.symlink).symlink = '../../outside'; },
    m => { m.files.find(e => e.path.endsWith('/changed')).sha256 = '0'.repeat(64); },
    m => { m.files.find(e => e.path.endsWith('/changed')).size++; },
    m => { m.files.find(e => e.path.endsWith('/same')).mode = '700'; },
    m => { m.files.find(e => e.path.endsWith('/unchanged-link')).symlink = 'mode'; },
  ]) {
    const bad = structuredClone(manifest); mutate(bad);
    const path = join(dir, `bad-${Math.random()}.json`); writeFileSync(path, JSON.stringify(bad));
    assert.notEqual(assemble(path, path + '.app').status, 0);
  }
  const fallback = join(dir, 'fallback.app');
  const copied = spawnSync('bash', ['-c', `set -euo pipefail\n${tree}
    cp() { return 1; }\ndelta_tree "$@"`, 'test', meta, zip, old, fallback], { encoding: 'utf8' });
  assert.equal(copied.status, 0, copied.stderr);
  assert.equal(readlinkSync(join(fallback, 'Contents/Resources/unchanged-link')), 'same');
  assert.equal(run('xattr', ['-p', 'com.example.w22', join(fallback, 'Contents/Resources/same')]).trim(), 'preserve');
  assert.ok(!existsSync(join(assembled, 'Contents/Resources/deleted')));
  assert.equal(readFileSync(join(old, 'Contents/Resources/deleted'), 'utf8'), 'gone');
  assert.ok(readdirSync(assembled + '.retained').some(name => {
    const path = join(assembled + '.retained', name);
    return lstatSync(path).isFile() && readFileSync(path, 'utf8') === 'gone';
  }), 'deleted candidate entries are retained, not destroyed');
});

test('W30 80 MiB / 2,000 resource files: delta_tree <10s, one hash batch, final seal rejects same-size reuse corruption', t => {
  const dir = mkdtempSync(join(tmpdir(), "w30-bench-'\\-"));
  const old = join(dir, 'old.app'), fresh = join(dir, 'new.app'), payload = join(dir, 'payload');
  mkdirSync(join(old, 'Contents/Resources'), { recursive: true });
  mkdirSync(join(old, 'Contents/MacOS'));
  copyFileSync('/usr/bin/true', join(old, 'Contents/MacOS/fixture'));
  writeFileSync(join(old, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>ai.tatwo.w30.fixture</string>
    <key>CFBundleExecutable</key><string>fixture</string>
    <key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
  const count = 2000, bytes = 80 * 1024 * 1024, chunk = Math.floor(bytes / count);
  for (let i = 0; i < count; i++) writeFileSync(join(old, 'Contents/Resources', `file-${i}`),
    Buffer.alloc(chunk + (i < bytes % count ? 1 : 0), i % 251));
  run('codesign', ['--force', '--sign', '-', old]);
  run('cp', ['-cRPp', old, fresh]);
  writeFileSync(join(fresh, 'Contents/Resources/file-0'), Buffer.alloc(chunk + 1, 252));
  run('codesign', ['--force', '--sign', '-', fresh]);
  const hash = data => createHash('sha256').update(data).digest('hex');
  const files = [];
  function scan(path, relative) {
    const info = lstatSync(path), e = { path: relative, mode: (info.mode & 0o7777).toString(8) };
    const data = info.isSymbolicLink() ? Buffer.from(readlinkSync(path)) : info.isDirectory() ? Buffer.alloc(0) : readFileSync(path);
    Object.assign(e, { sha256: hash(data), size: data.length });
    if (info.isSymbolicLink()) e.symlink = readlinkSync(path);
    if (info.isDirectory()) e.directory = true;
    files.push(e);
    if (info.isDirectory()) for (const name of readdirSync(path).sort())
      scan(join(path, name), relative === '.' ? name : `${relative}/${name}`);
  }
  scan(join(fresh, 'Contents'), '.');
  // Construct assets without the packager's unrelated per-file baseline simulation.
  for (const name of ['Resources/file-0', '_CodeSignature/CodeResources', 'MacOS/fixture']) {
    mkdirSync(join(payload, name.split('/')[0]), { recursive: true });
    copyFileSync(join(fresh, 'Contents', name), join(payload, name));
  }
  const manifest = join(dir, 'manifest.json'), zip = join(dir, 'delta.zip');
  writeFileSync(manifest, JSON.stringify({ schema: 1, tag: 'v2.0.6', fromTag: 'v2.0.5', files }));
  run('ditto', ['-c', '-k', '--norsrc', payload, zip]);
  const assemble = target => spawnSync('bash', ['-c', `set -euo pipefail\n${tree}\ndelta_tree "$@"`,
    'test', manifest, zip, old, target], { encoding: 'utf8', timeout: 10_000 });
  const assembled = join(dir, 'assembled.app'), start = performance.now();
  const result = assemble(assembled), treeMs = performance.now() - start;
  assert.equal(result.status, 0, result.stderr || String(result.error));
  assert.ok(treeMs < 10_000, `delta_tree ${treeMs} ms exceeds 10s`);
  const sealStart = performance.now();
  run('codesign', ['--verify', '--deep', '--strict', assembled]);
  const sealMs = performance.now() - sealStart;
  run('codesign', ['--verify', '--deep', '--strict', old]);
  const checks = readFileSync(assembled + '.checks', 'utf8').trim().split('\n');
  assert.equal(checks.length, 3, 'only changed resource, code seal and signed executable are hashed');
  assert.equal((tree.match(/shasum -a 256/g) ?? []).length, 1);
  assert.equal((tree.match(/cp -cRPp/g) ?? []).length, 1);
  t.diagnostic(JSON.stringify({ resourceFiles: count, resourceBytes: bytes, manifestEntries: files.length,
    changedFiles: checks.length, treeMs: +treeMs.toFixed(2), sealMs: +sealMs.toFixed(2), limitMs: 10_000 }));
  // No whole-tree SHA sweep: same-length damage survives assembly, but never the final deep/strict seal.
  const unchanged = join(old, 'Contents/Resources/file-1');
  writeFileSync(unchanged, Buffer.alloc(lstatSync(unchanged).size, 253));
  const corrupt = join(dir, 'corrupt.app');
  const reused = assemble(corrupt);
  assert.equal(reused.status, 0, reused.stderr);
  const rejected = spawnSync('codesign', ['--verify', '--deep', '--strict', corrupt], { encoding: 'utf8' });
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /modified|invalid|sealed resource/i);
  assert.match(install, /delta_tree "\$manifest"[^\n]+\|\| exit 1[\s\S]*?verify_signed_app "\$SOURCE"/);
  assert.match(install, /codesign --verify --deep --strict "\$app"/);
});
