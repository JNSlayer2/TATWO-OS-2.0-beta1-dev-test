import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mergeReports, previewRooms, resolveInside } from '../src/core.mjs';

test('preview is dry-run and grants no authority', () => {
  const result = previewRooms({
    version: 1,
    dryRun: true,
    allowedRoot: '/tmp/public-test',
    rooms: [{ id: 'r1', title: 'Review', engine: 'other', brief: 'Read only', workingRoot: 'rooms/r1', acceptance: ['Report findings'] }],
  });
  assert.equal(result.authority, 'none');
  assert.equal(result.rooms[0].action, 'preview_only');
});

test('non dry-run is rejected', () => {
  assert.throws(() => previewRooms({ version: 1, dryRun: false, allowedRoot: '/tmp/x', rooms: [{}] }), /requires_dry_run/);
});

test('path traversal is rejected', () => {
  assert.throws(() => resolveInside('/tmp/root', '../escape'), /outside_allowed_root/);
  assert.throws(() => resolveInside('/tmp/root', '/etc/passwd'), /outside_allowed_root/);
  assert.throws(() => resolveInside('relative-root', 'child'), /must_be_absolute/);
});

test('unknown fields are rejected', () => {
  assert.throws(() => previewRooms({ version: 1, dryRun: true, allowedRoot: '/tmp/x', rooms: [], token: 'x' }), /unknown_field/);
});

test('merged reports are explicitly unverified', () => {
  const result = mergeReports([{ roomID: 'r1', status: 'completed', summary: 'reviewed', evidence: ['test output'] }]);
  assert.equal(result.verified, false);
  assert.match(result.warning, /not code integration or acceptance/);
});


test('CLI does not echo invalid input bytes', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tatwo-public-cli-'));
  const input = path.join(dir, 'invalid.json');
  fs.writeFileSync(input, 'PRIVATE_SENTINEL not-json');
  const cli = fileURLToPath(new URL('../bin/tatwo-os-2-public.mjs', import.meta.url));
  const result = spawnSync(process.execPath, [cli, 'preview', input], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.equal(result.stderr.trim(), 'input_not_valid_json');
  assert.doesNotMatch(result.stderr, /PRIVATE_SENTINEL/);
});

test('safety scanner has a failing negative case', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tatwo-public-scan-'));
  fs.writeFileSync(path.join(dir, 'leak.txt'), ['/', 'Users', 'example', 'private'].join('/'));
  const scanner = fileURLToPath(new URL('../scripts/public-safety-scan.mjs', import.meta.url));
  const result = spawnSync(process.execPath, [scanner, dir], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /PUBLIC SAFETY SCAN FAIL/);
});
