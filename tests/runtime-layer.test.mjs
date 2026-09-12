import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, symlinkSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const paths = readFileSync(join(root, 'scripts/runtime-layer.txt'), 'utf8').trim().split('\n');
const run = (command, args) => {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
};
const layer = (...args) => run('bash', [join(root, 'scripts/runtime-layer.sh'), ...args]);
const sha = path => createHash('sha256').update(readFileSync(path)).digest('hex');

test('deterministic manifest, disjoint archives and a sealed reassembly (real ditto/codesign)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w20-layer-'));
  const app = join(dir, 'TATWO OS.app'), contents = join(app, 'Contents');
  for (const path of paths) {
    mkdirSync(join(contents, path, ...(path.startsWith('Frameworks/') ? ['Resources'] : [])), { recursive: true });
    writeFileSync(join(contents, path, path.startsWith('Frameworks/') ? 'Resources/fixture.txt' : 'fixture file'), `runtime ${path}`);
  }
  const framework = join(contents, 'Frameworks/Chromium Embedded Framework.framework');
  mkdirSync(join(framework, 'Resources'), { recursive: true });
  copyFileSync('/usr/bin/true', join(framework, 'RuntimeExecutable'));
  writeFileSync(join(framework, 'Resources/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>example.fixture.runtime</string>
    <key>CFBundleExecutable</key><string>RuntimeExecutable</string>
    <key>CFBundlePackageType</key><string>FMWK</string></dict></plist>`);
  run('codesign', ['--force', '--sign', '-', framework]);
  mkdirSync(join(contents, 'MacOS'));
  copyFileSync('/usr/bin/true', join(contents, 'MacOS/tatwo2'));
  writeFileSync(join(contents, 'Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>ai.tatwo.tatwo2</string>
    <key>CFBundleExecutable</key><string>tatwo2</string>
    <key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
  symlinkSync('fixture file', join(contents, paths[0], 'link'));
  const metadata = join(contents, 'Resources/runtime-layer.json');
  layer('prepare', app);
  const original = readFileSync(metadata, 'utf8'), manifest = JSON.parse(original);
  assert.deepEqual(manifest.paths, paths);
  assert.match(manifest.sha, /^[0-9a-f]{64}$/);
  layer('prepare', app);
  assert.equal(readFileSync(metadata, 'utf8'), original);
  // Absolute location and App-only edits must not affect the runtime hash.
  const relocated = join(dir, 'relocated.app');
  run('ditto', [app, relocated]);
  writeFileSync(join(relocated, 'Contents/Resources/app-only'), 'new UI');
  layer('prepare', relocated);
  assert.equal(readFileSync(join(relocated, 'Contents/Resources/runtime-layer.json'), 'utf8'), original);
  const changed = join(relocated, 'Contents', paths[0], 'fixture file');
  writeFileSync(changed, 'changed runtime');
  layer('prepare', relocated);
  assert.notEqual(JSON.parse(readFileSync(join(relocated, 'Contents/Resources/runtime-layer.json'))).sha, manifest.sha);
  writeFileSync(changed, `runtime ${paths[0]}`);
  chmodSync(changed, 0o755);
  layer('prepare', relocated);
  assert.notEqual(JSON.parse(readFileSync(join(relocated, 'Contents/Resources/runtime-layer.json'))).sha, manifest.sha);
  chmodSync(changed, 0o644);
  // A new link (including a dangling target) changes the content-addressed identity.
  symlinkSync('different target', join(relocated, 'Contents', paths[0], 'extra-link'));
  layer('prepare', relocated);
  assert.notEqual(JSON.parse(readFileSync(join(relocated, 'Contents/Resources/runtime-layer.json'))).sha, manifest.sha);
  run('codesign', ['--force', '--sign', '-', app]); // Disposable fixture only; no keys or installed apps.
  const out = join(dir, 'release');
  layer('split', app, out);
  const appZip = join(out, 'TATWO-OS-app.zip');
  const runtimeZip = join(out, `TATWO-OS-runtime-${manifest.sha.slice(0, 12)}.zip`);
  const appEntries = run('unzip', ['-Z1', appZip]).split('\n');
  const runtimeEntries = run('unzip', ['-Z1', runtimeZip]).split('\n');
  assert.ok(appEntries.includes('TATWO OS.app/Contents/Resources/runtime-layer.json'));
  for (const path of paths) {
    assert.ok(!appEntries.some(e => e.startsWith(`TATWO OS.app/Contents/${path}/`)));
    assert.ok(runtimeEntries.some(e => e.startsWith(`${path}/`)));
  }
  assert.ok(runtimeEntries.every(e => paths.some(p => e === `${p}/` || e.startsWith(`${p}/`) || `${p}/`.startsWith(e))));
  assert.ok([...appEntries, ...runtimeEntries].every(e => !e.includes('/._')));
  for (const zip of [appZip, runtimeZip]) assert.equal(readFileSync(`${zip}.sha256`, 'utf8').split(' ')[0], sha(zip));
  const assembled = join(dir, 'assembled');
  run('ditto', ['-x', '-k', appZip, assembled]);
  const target = join(assembled, 'TATWO OS.app');
  run('ditto', ['-x', '-k', runtimeZip, join(target, 'Contents')]);
  assert.equal(readlinkSync(join(target, 'Contents', paths[0], 'link')), 'fixture file');
  run('codesign', ['--verify', '--deep', '--strict', target]);
  assert.equal(readFileSync(metadata, 'utf8'), original, 'split never changes the signed source');
  writeFileSync(join(target, 'Contents', paths[0], 'fixture file'), 'corruption');
  assert.notEqual(spawnSync('codesign', ['--verify', '--deep', '--strict', target]).status, 0);
  const bad = spawnSync('bash', [join(root, 'scripts/runtime-layer.sh'), 'split', relocated, join(dir, 'bad')]);
  // Fresh manifest works; changing bytes after preparation must fail before producing ZIPs.
  assert.equal(bad.status, 0, bad.stderr.toString());
  writeFileSync(changed, 'changed after prepare');
  assert.notEqual(spawnSync('bash', [join(root, 'scripts/runtime-layer.sh'), 'split', relocated, join(dir, 'stale')]).status, 0);
  assert.ok(!existsSync(join(dir, 'stale/TATWO-OS-app.zip')));
});

test('build prepares the sealed manifest after nested signing and before outer signing; release keeps full ZIP', () => {
  const build = readFileSync(join(root, 'scripts/build-app.sh'), 'utf8');
  assert.equal((build.match(/python3 -E "\$ROOT\/scripts\/runtime-sign.py"[^\n]*\n  bash "\$ROOT\/scripts\/runtime-layer.sh" prepare "\$APP"\n  codesign/g) ?? []).length, 2);
  const pkg = readFileSync(join(root, 'scripts/package-release.sh'), 'utf8');
  assert.match(pkg, /ditto -c -k --norsrc --keepParent "\$OUT\/TATWO OS.app" "\$OUT\/TATWO-OS.zip"/);
  assert.match(pkg, /runtime-layer.sh split/);
  assert.match(pkg, /"\$OUT"\/\*\.zip "\$OUT"\/\*\.zip\.sha256/);
});
