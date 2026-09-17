import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

test('W83 production transfer: signed dual-device roundtrip, interruption, four checkpoints and screenshot',
  { timeout: 180_000 }, () => {
    assert.ok(process.env.TMPDIR, 'explicit isolated TMPDIR required');
    assert.ok(process.env.TATWO2_TEST_BINARY, 'current room binary required; never skip');
    const root = mkdtempSync(join(process.env.TMPDIR, 'w83-transfer-'));
    const home = join(root, 'home');
    mkdirSync(home);
    writeFileSync(join(root, 'owned-fixture'), 'synthetic only\n');
    const result = spawnSync(process.env.TATWO2_TEST_BINARY, [], {
      env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: home, CFFIXED_USER_HOME: home,
        TATWO2_W83_TEST_ROOT: root, TATWO2_LIVE_ROOT: join(root, 'unused-live'),
        TATWO_OS_ROOT: join(root, 'unused-entry'), TATWO2_OS_ROOT: join(root, 'unused-entry'),
        TATWO2_OS_UPSTREAM_PATH: join(root, 'unused-upstream.md'),
        GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' },
      encoding: 'utf8', timeout: 150_000, maxBuffer: 1024 * 1024,
    });
    const output = result.stdout + result.stderr;
    assert.equal(result.status, 0, output);
    for (const label of [
      'offline-primary-cannot-start', 'offline-target-cannot-start',
      'prepare-ack-loss', 'cancel-before-epoch-restores-normal-dispatch', 'committed-epoch-cannot-cancel',
      'hash-mismatch-keeps-epoch', 'hash-mismatch-no-partial-authority',
      'old-primary-demoted-first', 'interrupted-ack', 'epoch-is-not-completion',
      'lost-reply-after-commit', 'bundle-record-epoch-mismatch-rejected',
      'restart-retry-preserves-epoch', 'old-epoch-dispatch-rejected', 'forged-transfer-epoch-rejected',
      'constitution-source-switched', 'gbrain-page-mismatch-rejected', 'failed-step-keeps-completed-items',
      'checkpoint-waits-for-readback', 'completed-checkpoints-survive-next-step',
      'post-switch-edits-preserved', 'metadata-and-document-acks-independent',
      'retained-brain-explicitly-verified', 'missing-certificate', 'missing-dependency',
      'four-items-mirrored-complete', 'roundtrip-epoch-increments-twice',
      'cannot-discard-prior-transfer-checkpoints',
      'roundtrip-roles-restored', 'roundtrip-four-items-mirrored', 'no-database-or-key-export',
      'all-devices-ack-required', 'partial-epoch-blocks-source-switch', 'observer-receives-authority',
      'no-stranded-observer-handback',
      'all-devices-epoch-converged', 'participant-set-cannot-shrink',
      'incomplete-transfer-can-hand-back', 'stale-rpc-after-handback-rejected', 'handback-does-not-fake-completion',
    ]) assert.ok(output.includes(`W83TEST PASS ${label}`), output);
    assert.match(output, /W83TEST SUMMARY failures=0/);
    for (const i of [0, 1, 2]) {
      const identity = JSON.parse(readFileSync(join(root, `device-${i}/entry/device.json`)));
      assert.equal(identity.epoch, 11);
      assert.equal(identity.primaryDeviceID, '11111111-1111-4111-8111-111111111111');
      assert.equal(identity.transfer.constitution, false);
    }
    const completed = JSON.parse(readFileSync(join(root, 'two-device-completed.json')));
    assert.equal(completed.epoch, 8);
    assert.equal(completed.constitution, true);
    assert.equal(completed.brain, 'retained');
    assert.equal(completed.release, 'ready');
    assert.equal(completed.acknowledgedRevision, completed.revision);
    assert.ok(existsSync(join(root, 'w83-four-statuses.png')));
    console.log(output.trim());
  });
