import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, resolve, join } from 'node:path';
import { spawnSync } from 'node:child_process';

test('W78 production Swift: dual-root dispatch, signed RPC, documents, inbox and pull files', { timeout: 180_000 }, () => {
  const binary = [
    process.env.TATWO2_TEST_BINARY,
    resolve('.build/debug/Tatwo2'),
    resolve(`../../build-cache/${basename(process.cwd()).replace(/^build-/, '')}/out/Products/Debug/Tatwo2`),
    resolve(`../../build-cache/${basename(process.cwd()).replace(/^build-/, '')}/arm64-apple-macosx/debug/Tatwo2`),
    resolve('../../build-cache/tatwo2-debug/arm64-apple-macosx/debug/Tatwo2'),
    resolve('../../build-cache/tatwo2-debug/out/Products/Debug/Tatwo2'),
  ].filter(Boolean).find(path => existsSync(path) && readFileSync(path).includes(Buffer.from('TATWO2_W78_TEST_ROOT')));
  assert.ok(binary, 'Build current Tatwo2 first or set TATWO2_TEST_BINARY; never skip.');
  const temp = mkdtempSync(join(tmpdir(), 'w78-swift-'));
  const root = join(temp, 'fixture');
  mkdirSync(root);
  writeFileSync(join(root, 'owned-fixture'), 'synthetic W78 data only\n');
  writeFileSync(join(temp, 'MANIFEST.md'),
    '# W78 synthetic acceptance\nAll inputs generated in TMPDIR. No user key, keychain or live data read.\n' +
    'Real test SSH signatures and local Git push; RPC transport injected in process, not physical SSH E2E.\n');
  const environment = Object.fromEntries(Object.entries(process.env)
    .filter(([key]) => !key.startsWith('TATWO') && !key.startsWith('GIT_') &&
      key !== 'SSH_AUTH_SOCK' && key !== 'SSH_AGENT_PID'));
  const result = spawnSync(binary, [], {
    env: { ...environment, TMPDIR: temp + '/', HOME: join(temp, 'home'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
      TATWO2_W78_TEST_ROOT: root, TATWO_OS_ROOT: join(root, 'secondary/entry'),
      TATWO2_LIVE_ROOT: join(root, 'secondary/live'), TATWO2_ENGINES_ROOT: join(root, 'engines') },
    encoding: 'utf8', timeout: 150_000, maxBuffer: 1024 * 1024,
  });
  const output = result.stdout + result.stderr;
  assert.equal(result.status, 0, output);
  for (const name of [
    'symlink-entry-note-relative-paths',
    'dual-root-core-converged-under-60s', 'readback-hashes', 'readonly-copies',
    'bad-primary-key', 'old-epoch', 'bad-content-hash', 'replay-seq', 'replay-after-restart',
    'late-ack-rejected',
    'bad-client-proof', 'replayed-client-proof', 'revoked-client-key', 'host-pin-mismatch',
    'interruption-not-converged', 'timeout-visible', 'fresh-seq-retry-readback',
    'offline-no-false-convergence', 'reconnect-catches-up', 'online-doc-source-commit',
    'removed-note-archived-not-deleted', 'applied-is-not-converged', 'archive-retry-full-manifest',
    'other-staged-and-worktree-unchanged', 'offline-doc-originals-unchanged',
    'lost-reply-idempotent-retry', 'conflict-both-originals-unchanged', 'user-choice-required',
    'local-conflict-before-primary-write',
    'inflight-draft-not-lost',
    'submission-no-source-mutation', 'primary-inbox-receipt',
    'pull-thread-provenance', 'pull-conflict-no-overwrite', 'pull-batch-all-or-none',
    'pull-files-arrive', 'pull-source-boundary',
  ]) assert.ok(output.includes(`W78TEST PASS ${name}\n`), `${name}\n${output}`);
  assert.match(output, /W78TEST SUMMARY failures=0/);
  console.log(output.trim());
});

test('W78 catalog routes A/E to one adapter and C to git, never entrance legacy files', () => {
  const catalog = JSON.parse(readFileSync('config/tatwo-sync-catalog-v1.json', 'utf8'));
  const entries = Object.fromEntries(catalog.entries.map(row => [row.id, row]));
  assert.deepEqual(catalog.systemPullItemIDs, []);
  assert.equal(catalog.dispatchTransport, 'RemoteHostLink');
  for (const [id, path] of [['os.constitution', 'os.md'], ['skills.skillet', 'skillet.md'], ['memory.global-notes', 'note/']]) {
    assert.equal(entries[id].relativePath, path);
    assert.equal(entries[id].transportAdapter, 'RemoteHostLink');
  }
  for (const id of ['os.issue', 'os.todo']) assert.equal(entries[id].transportAdapter, 'git');
  const script = readFileSync('scripts/tatwo-device-sync.sh', 'utf8');
  const adapter = script.split('system_item_source_file() {')[1].split('\n}')[0];
  assert.doesNotMatch(adapter, /\$OS_ROOT\/(?:issue\.md|TODO\.md)/);
  const bridge = readFileSync('App/Sources/Tatwo2/Facade/OSAgentBridge.swift', 'utf8');
  const pull = bridge.split('case "pull_thread":')[1].split('case "dispatch_rooms":')[0];
  assert.match(pull, /Self\.pullThreadFiles/);
  assert.doesNotMatch(pull, /changedFiles\(in:/);
  assert.doesNotMatch(bridge, /case "dispatch_apply"/);
  for (const name of ['prepare_system_payload', 'apply_system_manifest']) {
    const body = script.split(`${name}() {`)[1].split('\n}')[0];
    assert.match(body.slice(0, 240), /legacy_system_adapter_available \|\|/);
  }
  const gate = 'legacy_system_adapter_available() {' +
    script.split('legacy_system_adapter_available() {')[1].split('\n}')[0] + '\n}';
  const refused = spawnSync('/bin/bash', ['-c',
    'SYNC_CATALOG=fixture; json_get() { printf "%s\\n" RemoteHostLink; }; log() { :; };\n' +
    gate + '\nlegacy_system_adapter_available'], { encoding: 'utf8' });
  assert.equal(refused.status, 1, 'legacy adapter must reject in the caller, not yield an empty successful payload');
  assert.equal(spawnSync('/bin/bash', ['-n', 'scripts/tatwo-device-sync.sh']).status, 0);
});
