import { testScratch } from './helpers/test-scratch.mjs';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
test('production scroll-follow state preserves reading intent through lazy layout', { timeout: 90_000 }, t => {
  if (process.platform !== 'darwin') return t.skip('macOS Swift fixture required');
  const output = testScratch('tatwo2-scroll-follow-');
  fs.mkdirSync(output, { recursive: true });
  const scratch = fs.mkdtempSync(path.join(output, 'scroll-follow-'));
  const binary = path.join(scratch, 'checks');
  const build = spawnSync('swiftc', [
    path.join(root, 'App/Sources/Tatwo2/Chat/ChatTranscriptScrollFollowState.swift'),
    path.join(root, 'tests/fixtures/scroll-follow-checks.swift'), '-o', binary,
  ], { encoding: 'utf8', timeout: 60_000 });
  assert.equal(build.status, 0, build.stderr || String(build.error));
  const run = spawnSync(binary, [], { encoding: 'utf8', timeout: 5_000 });
  process.stdout.write(run.stdout);
  assert.equal(run.status, 0, run.stderr || String(run.error));
  assert.match(run.stdout, /RESULT passed=17 failed=0 skipped=0/);
});
