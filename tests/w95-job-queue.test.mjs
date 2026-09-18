import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('..', import.meta.url));
const rooms = join(repo, 'scripts/rooms');
const runner = join(rooms, 'job-runner.sh');
const commit = 'a'.repeat(40);

// 全部用 TMPDIR 裡的假入口、假 staging、假腳本；不建置、不碰真實 staging、不跑 swift build。
function fixture(name) {
  const root = mkdtempSync(join(tmpdir(), `w95-${name}-`));
  const staging = join(root, 'staging');
  const bin = join(root, 'rooms-bin');
  for (const dir of [join(staging, 'jobs/queue'), join(staging, 'jobs/receipts'), join(staging, 'rooms'), bin]) {
    mkdirSync(dir, { recursive: true });
  }
  writeFileSync(join(root, 'MANIFEST.md'),
    '# W95 synthetic acceptance\n假入口／假 staging／假 kind 腳本，全部在 TMPDIR；不建置、不讀使用者資料。\n');
  return { root, staging, bin, queue: join(staging, 'jobs/queue'), receipts: join(staging, 'jobs/receipts') };
}

function enqueue(box, id, overrides = {}) {
  const job = {
    id, device: '22222222-2222-4222-8222-222222222222', branch: 'dev/macbook/w95-job-queue',
    commit, kind: 'build', tests: ['tests/w95-job-queue.test.mjs'], status: 'queued',
    submittedAt: overrides.submittedAt ?? '2026-09-18T00:00:00Z', ...overrides,
  };
  writeFileSync(join(box.queue, `${id}.json`), JSON.stringify(job, null, 1));
  return job;
}

function fakeKind(box, name, body) {
  const path = join(box.bin, name);
  writeFileSync(path, body, { mode: 0o755 });
  return path;
}

function runOnce(box, extra = {}) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('TATWO')));
  const result = spawnSync('bash', [runner, '--once'], {
    encoding: 'utf8', timeout: 120_000, maxBuffer: 4 * 1024 * 1024,
    env: {
      ...env, TATWO_ENTRY: join(box.root, 'entry'), TATWO_STAGING: box.staging,
      TATWO_REPO: join(box.root, 'entry/tatwo2'), TATWO_ROOMS_BIN: box.bin,
      TATWO_JOB_MIN_MEM_GB: '0', TATWO_JOB_MIN_STAGING_GB: '0', TATWO_JOB_MIN_SYSTEM_GB: '0',
      ...extra,
    },
  });
  return { ...result, output: (result.stdout ?? '') + (result.stderr ?? '') };
}

const readJSON = path => JSON.parse(readFileSync(path, 'utf8'));

test('W95 (b) 記憶體門檻不足：工作停在 queued，reason 非空，不留收據', () => {
  const box = fixture('mem');
  fakeKind(box, 'build-room.sh', '#!/bin/bash\necho "不該被執行"\nexit 0\n');
  enqueue(box, '11111111-1111-4111-8111-111111111111');
  const result = runOnce(box, { TATWO_JOB_MIN_MEM_GB: '999999' });
  assert.equal(result.status, 0, result.output);
  const job = readJSON(join(box.queue, '11111111-1111-4111-8111-111111111111.json'));
  assert.equal(job.status, 'queued');
  assert.match(job.reason, /記憶體不足：free\+inactive .* < 999999GB/);
  assert.equal(job.startedAt, undefined);
  assert.equal(readdirSync(box.receipts).length, 0);
  assert.match(result.output, /queued 記憶體不足/);
});

test('W95 staging／系統碟門檻不足：同樣停在 queued 並寫原因', () => {
  for (const [key, pattern] of [['TATWO_JOB_MIN_STAGING_GB', /staging 卷不足/], ['TATWO_JOB_MIN_SYSTEM_GB', /系統碟不足/]]) {
    const box = fixture('disk');
    fakeKind(box, 'build-room.sh', '#!/bin/bash\nexit 0\n');
    enqueue(box, '11111111-1111-4111-8111-111111111111');
    runOnce(box, { [key]: '999999' });
    const job = readJSON(join(box.queue, '11111111-1111-4111-8111-111111111111.json'));
    assert.equal(job.status, 'queued');
    assert.match(job.reason, pattern);
  }
});

test('W95 建置鎖被別人持有：工作停在 queued 並寫出持有者', () => {
  const box = fixture('lock');
  const lock = join(box.staging, 'rooms/.build-lock');
  mkdirSync(lock, { recursive: true });
  writeFileSync(join(lock, 'pid'), `${process.pid}\n`);
  writeFileSync(join(lock, 'owner'), 'someone/else\n');
  fakeKind(box, 'build-room.sh', '#!/bin/bash\necho "不該被執行"\nexit 0\n');
  enqueue(box, '11111111-1111-4111-8111-111111111111');
  runOnce(box);
  const job = readJSON(join(box.queue, '11111111-1111-4111-8111-111111111111.json'));
  assert.equal(job.status, 'queued');
  assert.match(job.reason, /建置鎖被佔用：someone\/else/);
});

test('W95 (c) 兩個 build 工作序列化：第二個等第一個 done', () => {
  const box = fixture('serial');
  const witness = join(box.root, 'witness.log');
  fakeKind(box, 'build-room.sh',
    '#!/bin/bash\necho "START $1" >> "$W95_WITNESS"\nsleep 1.2\necho "END $1" >> "$W95_WITNESS"\necho "swift build exit=0"\n');
  const first = '11111111-1111-4111-8111-111111111111', second = '33333333-3333-4333-8333-333333333333';
  enqueue(box, first, { branch: 'dev/macbook/job-one', submittedAt: '2026-09-18T00:00:00Z' });
  enqueue(box, second, { branch: 'dev/macbook/job-two', submittedAt: '2026-09-18T00:00:05Z' });
  const result = runOnce(box, { W95_WITNESS: witness });
  assert.equal(result.status, 0, result.output);
  assert.deepEqual(readFileSync(witness, 'utf8').trim().split('\n'),
    ['START dev/macbook/job-one', 'END dev/macbook/job-one',
     'START dev/macbook/job-two', 'END dev/macbook/job-two']);
  const one = readJSON(join(box.queue, `${first}.json`)), two = readJSON(join(box.queue, `${second}.json`));
  assert.equal(one.status, 'done');
  assert.equal(two.status, 'done');
  const receiptOne = readJSON(join(box.receipts, `${first}.json`));
  const receiptTwo = readJSON(join(box.receipts, `${second}.json`));
  assert.ok(receiptTwo.startedAt >= receiptOne.endedAt,
    `第二個工作不得在第一個結束前開始：${receiptTwo.startedAt} < ${receiptOne.endedAt}`);
});

test('W95 (d) 收據欄位齊全、logTail ≤ 200、失敗帶 exit 與 reason', () => {
  const box = fixture('receipt');
  fakeKind(box, 'build-room.sh',
    '#!/bin/bash\nfor i in $(seq 1 300); do echo "log line $i"; done\nexit 3\n');
  const id = '11111111-1111-4111-8111-111111111111';
  enqueue(box, id);
  const result = runOnce(box);
  assert.equal(result.status, 0, result.output);
  const job = readJSON(join(box.queue, `${id}.json`));
  assert.equal(job.status, 'failed');
  assert.equal(job.reason, 'exit=3');
  assert.equal(job.exit, 3);
  assert.equal(typeof job.exit, 'number');
  const receipt = readJSON(join(box.receipts, `${id}.json`));
  for (const key of ['id', 'kind', 'branch', 'commit', 'startedAt', 'endedAt', 'exit', 'logTail', 'artifacts', 'runner']) {
    assert.ok(key in receipt, `收據缺欄位 ${key}`);
  }
  assert.equal(receipt.id, id);
  assert.equal(receipt.exit, 3);
  assert.ok(receipt.endedAt >= receipt.startedAt);
  assert.equal(receipt.logTail.length, 200);
  assert.equal(receipt.logTail.at(-1), 'log line 300');
  assert.equal(receipt.logTail[0], 'log line 101');
  assert.ok(receipt.artifacts.length >= 1);
  assert.ok(typeof receipt.runner === 'string' && receipt.runner.length > 0);
});

test('W95 runner 也擋白名單外的 kind 與不合法欄位，且只跑對應表裡的腳本', () => {
  const box = fixture('whitelist');
  fakeKind(box, 'build-room.sh', '#!/bin/bash\necho ran > "$W95_WITNESS"\nexit 0\n');
  const cases = [
    ['11111111-1111-4111-8111-111111111111', { kind: 'shell' }],
    ['33333333-3333-4333-8333-333333333333', { commit: 'HEAD' }],
    ['44444444-4444-4444-8444-444444444444', { tests: ['../etc/passwd.test.mjs'] }],
    ['55555555-5555-4555-8555-555555555555', { branch: 'dev/../x' }],
  ];
  for (const [id, overrides] of cases) enqueue(box, id, overrides);
  const witness = join(box.root, 'witness.log');
  runOnce(box, { W95_WITNESS: witness });
  assert.equal(existsSync(witness), false, 'kind 腳本不該被執行');
  for (const [id] of cases) {
    const job = readJSON(join(box.queue, `${id}.json`));
    assert.equal(job.status, 'failed');
    assert.match(job.reason, /工作欄位不合法/);
  }
  const table = readFileSync(runner, 'utf8').split('set -uo pipefail')[0];
  for (const kind of ['build', 'verify', 'package', 'thrice', 'clean-gate', 'install']) {
    assert.ok(table.includes(`#   ${kind}`), `runner 頂端對應表缺 ${kind}`);
  }
});

test('W95 scripts/rooms：九支工具入庫、可執行、且沒有寫死的機器路徑', () => {
  const expected = ['build-room.sh', 'terminal-run.sh', 'thrice-candidate-full.sh', 'quit-tatwo.sh',
    'functional-check.py', 'make-offline-release.py', 'install-candidate.sh', 'job-runner.sh', 'gate-template.sh'];
  for (const name of expected) {
    const path = join(rooms, name);
    assert.ok(existsSync(path), `缺 scripts/rooms/${name}`);
    assert.ok(statSync(path).mode & 0o111, `${name} 需要可執行位元`);
    const text = readFileSync(path, 'utf8');
    assert.doesNotMatch(text, /\/Volumes/, `${name} 不得寫死 /Volumes`);
    assert.doesNotMatch(text, /\/Users\//, `${name} 不得寫死 /Users/`);
  }
  for (const name of ['build-room.sh', 'terminal-run.sh', 'thrice-candidate-full.sh', 'gate-template.sh', 'job-runner.sh']) {
    const text = readFileSync(join(rooms, name), 'utf8');
    assert.match(text, /TATWO_ENTRY/, `${name} 要由 TATWO_ENTRY 推路徑`);
    assert.match(text, /TATWO_STAGING/, `${name} 要由 TATWO_STAGING 推路徑`);
  }
  // runner 是前景腳本，不是守護程式：不得自己裝 launchd 或殺工作。
  const text = readFileSync(runner, 'utf8');
  assert.doesNotMatch(text, /launchctl|nohup|kill -9|pkill/);
  assert.match(text, /--once/);
  assert.match(text, /--watch/);
});

test('W95 (a)(e) production Swift：kind 白名單、commit／tests 驗證、device_status.capacity', { timeout: 180_000 }, () => {
  const binary = [
    process.env.TATWO2_TEST_BINARY,
    resolve('.build/debug/Tatwo2'),
    resolve(`../../build-cache/${basename(process.cwd()).replace(/^build-/, '')}/out/Products/Debug/Tatwo2`),
    resolve(`../../build-cache/${basename(process.cwd()).replace(/^build-/, '')}/arm64-apple-macosx/debug/Tatwo2`),
    resolve('../../build-cache/tatwo2-debug/arm64-apple-macosx/debug/Tatwo2'),
    resolve('../../build-cache/tatwo2-debug/out/Products/Debug/Tatwo2'),
  ].filter(Boolean).find(path => existsSync(path) && readFileSync(path).includes(Buffer.from('TATWO2_W95_TEST_ROOT')));
  assert.ok(binary, 'Build current Tatwo2 first or set TATWO2_TEST_BINARY; never skip.');
  const temp = mkdtempSync(join(tmpdir(), 'w95-swift-'));
  const root = join(temp, 'fixture');
  const environment = Object.fromEntries(Object.entries(process.env)
    .filter(([key]) => !key.startsWith('TATWO') && !key.startsWith('GIT_')));
  const result = spawnSync(binary, [], {
    env: {
      ...environment, TMPDIR: temp + '/', HOME: join(temp, 'home'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
      TATWO2_W95_TEST_ROOT: root, TATWO_OS_ROOT: join(root, 'entry'),
      TATWO2_LIVE_ROOT: join(root, 'live'), TATWO2_ENGINES_ROOT: join(root, 'engines'),
    },
    encoding: 'utf8', timeout: 150_000, maxBuffer: 1024 * 1024,
  });
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  assert.equal(result.status, 0, output);
  for (const name of [
    'kind-allowed-build', 'kind-allowed-verify', 'kind-allowed-package', 'kind-allowed-thrice',
    'kind-allowed-clean-gate', 'kind-allowed-install',
    'kind-rejected-shell', 'kind-rejected-Build', 'kind-rejected-empty', 'kind-non-string-rejected',
    'commit-rejected-0', 'commit-rejected-4', 'tests-rejected-0', 'tests-rejected-2', 'tests-rejected-4',
    'tests-accepts-empty-list', 'branch-rejected-parent-traversal', 'device-must-match-signed-sender',
    'unknown-field-rejected', 'job-submit-returns-uuid', 'queue-file-written',
    'commit-must-exist-in-primary-repository', 'job-status-unknown-id-rejected',
    'receipt-log-tail-capped-at-200', 'job-status-returns-queue-and-receipt',
    'capacity-present', 'capacity-queue-length-counts-queued', 'capacity-build-lock-empty',
    'capacity-build-lock-owner-reported', 'capacity-stale-build-lock-is-not-held',
    'device-status-capacity-numeric', 'device-status-capacity-decodes',
    'device-status-without-capacity-still-decodes',
  ]) assert.ok(output.includes(`W95TEST PASS ${name}\n`), `${name}\n${output}`);
  assert.match(output, /W95TEST SUMMARY failures=0/);
});

test('W95 job_submit/job_status 只是 W78 通道上多一種 payload，沒有第二套驗證', () => {
  const bridge = readFileSync(join(repo, 'App/Sources/Tatwo2/Facade/OSAgentBridge.swift'), 'utf8');
  const block = bridge.split('case "job_submit", "job_status":')[1]
    .split('case "dispatch_fetch", "dispatch_ack"')[0];
  assert.match(block, /DeviceDispatch\.shared\.authenticate\(method: method, proof: params\)/);
  assert.doesNotMatch(block, /ssh-keygen|publicKeyFingerprint|authorizedKeys|signed\(/);
  const queue = readFileSync(join(repo, 'App/Sources/Tatwo2/Facade/JobQueue.swift'), 'utf8');
  assert.doesNotMatch(queue, /ssh-keygen|authorizedKeysURL|publicKeyFingerprint|Process\(/);
  assert.match(queue, /static let kinds = \["build", "verify", "package", "thrice", "clean-gate", "install"\]/);
});
