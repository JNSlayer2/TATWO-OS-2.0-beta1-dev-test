import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

test('production Swift transfer and engine content-cache synthetic fixtures', () => {
  const candidates = [
    process.env.TATWO2_TEST_BINARY,
    resolve('.build/debug/Tatwo2'),
    resolve(`../../build-cache/${basename(process.cwd()).replace(/^build-/, '')}/out/Products/Debug/Tatwo2`),
    resolve('../../build-cache/tatwo2-debug/out/Products/Debug/Tatwo2'),
    // build-room.sh shared scratch path, relative to staging/rooms/build-<room>.
    resolve('../../build-cache/tatwo2-debug/arm64-apple-macosx/debug/Tatwo2'),
  ].filter(Boolean);
  // Do not accidentally launch the older REMOTETEST suite from a stale shared cache.
  const binary = candidates.find(path => existsSync(path) && readFileSync(path).includes(Buffer.from('TATWO2_W72_TEST_ROOT')));
  assert.ok(binary, 'Build Tatwo2 first or set TATWO2_TEST_BINARY; never silently skip.');
  const temp = mkdtempSync(join(tmpdir(), 'w72-swift-'));
  const root = join(temp, 'fixture');
  mkdirSync(root);
  writeFileSync(join(root, 'owned-fixture'), 'synthetic W72 fixture\n');
  writeFileSync(join(temp, 'MANIFEST.md'),
    '# W72 synthetic test receipts\nOriginal source: generated fixture only.\n' +
    'All files retained in TMPDIR for review; no permanent deletion.\n');
  const p = spawnSync(binary, [], {
    env: { ...process.env, TMPDIR: temp + '/', HOME: join(temp, 'home'),
      TATWO2_REMOTETEST: '1', TATWO2_W72_TEST_ROOT: root,
      TATWO2_LIVE_ROOT: join(root, 'live'), TATWO2_ENGINES_ROOT: join(root, 'homes') },
    encoding: 'utf8', timeout: 120_000, maxBuffer: 1024 * 1024,
  });
  const output = p.stdout + p.stderr;
  assert.equal(p.status, 0, output);
  for (const name of [
    'thread-scope', 'unknown-thread-empty', 'source-baseline', 'unrelated-not-packed',
    'conflict-rejected', 'conflict-unchanged', 'legacy-baseline-rejected',
    'changed-source-not-automatic', 'selection-race-rejected', 'subdir-literal-baseline',
    'unsafe-path-../outside', 'unsafe-path-/absolute', 'unsafe-path-.git/config',
    'symlink-receiver', 'symlink-sender', 'symlink-unchanged',
    'midflight-rejected', 'rollback-both-ends', 'receipt-outside-project',
    'invalid-base64-preflight', 'invalid-preflight-unchanged', 'successful-batch',
    'duplicate-path-rejected', 'late-symlink-rejected', 'late-symlink-rollback',
    'rollback-conflict-not-overwritten', 'rollback-conflict-backup-retained',
    'engine-unchanged-skips', 'engine-only-tree', 'engine-within-24h-redeploys',
    'engine-path-hashed', 'engine-failure-no-stamp', 'engine-mutating-source-no-stamp',
    'engine-symlink-not-followed',
  ]) assert.ok(output.includes(`W72TEST PASS ${name}\n`), `${name}\n${output}`);
  assert.match(output, /W72TEST SUMMARY failures=0/);
  console.log(output.trim());
});
